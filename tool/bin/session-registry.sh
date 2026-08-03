#!/usr/bin/env bash
# session-registry.sh — append-only session registry for stitchpad.
# Source this from stitchpad; expects PAD_STATE to be set.
#
# Each entry is a JSON line appended to .state/session-registry.jsonl.
# The registry is capped at SESSION_REGISTRY_MAX entries (default 1024).
#
# Entry schema (one JSON object per line):
#   {
#     "request_id": "provider-sid-counter",   # delegated: derived from provider + session + monotonic counter
#     "session_id": "abc123",                 # STITCHPAD_SESSION or CLAUDE_CODE_SESSION_ID etc
#     "provider": "openai",                   # resolved from model or explicit STITCHPAD_PROVIDER
#     "model": "gpt-5.6-sol",                 # STITCHPAD_MODEL or CODEX_MODEL etc
#     "worktree": "/abs/path",                # PAD_DIR or cwd
#     "start": 1690000000,                    # epoch at join (from .state/session-start.<sid>)
#     "last_activity": 1690000100,            # epoch of this write
#     "name": "deepseek",                     # STITCHPAD_NAME
#     "event": "dispatch"                     # lifecycle event: dispatch|activity|terminal|cancel|resume|rotate
#   }
#
# Provider mapping (canonical):
#   gpt-*, o1-*, o3-*, o4-*  → openai
#   claude-*                  → anthropic
#   deepseek*                 → deepseek
#   kimi*                     → kimi       (Moonshot AI, NOT deepseek)
#   gemini*                   → google
#   otherwise                 → "" (empty — preserved visibly, never collapsed to _unknown_)
#
# Status derivation (read-only, never mutates):
#   terminal   — session-start exists AND session-end exists
#   stale      — session-start exists, no activity in SESSION_STALE_SECONDS (default 3600)
#   idle       — session-start exists, no activity in SESSION_IDLE_SECONDS (default 900)
#   active     — session-start exists, activity within SESSION_IDLE_SECONDS
#
# Public API:
#   sp_session_registry_init     → ensure registry file exists, is regular, not a symlink
#   sp_session_registry_append   → append one entry (must be called under pad lock or for own session)
#   sp_session_registry_record_event → record a lifecycle event (dispatch/activity/terminal/cancel/resume/rotate)
#   sp_session_registry_project  → read-only projection (JSON array of session summaries),
#                                  sentinel-bounded and capped
#   sp_session_registry_list     → human-readable projection
#   sp_session_registry_cap      → trim oldest entries to max
#   sp_session_registry_validate_sid → validate a session id for path safety
#   sp_session_registry_pad_header → render active sessions + bounded history as markdown lines
#   sp_session_registry_sid_for_name → resolve a seat's durable session binding
#   sp_session_registry_render_pad_header → write the sentinel-bounded header
#                                  block into the pad file (requires held lock)
#   sp_session_registry_lifecycle_locked → record event + markers + header
#                                  refresh, caller already holds the pad lock
#   sp_session_registry_lifecycle_commit → same, but acquires the pad lock and
#                                  commits the header refresh (all-or-nothing)
#   sp_session_registry_journal_begin/rollback/commit → pre-op byte snapshot
#                                  and exact compensation for the registry ⟷
#                                  pad-commit interlock (no symlinks, no temps)

SESSION_REGISTRY_MAX="${SESSION_REGISTRY_MAX:-1024}"
SESSION_STALE_SECONDS="${SESSION_STALE_SECONDS:-3600}"
SESSION_IDLE_SECONDS="${SESSION_IDLE_SECONDS:-900}"
SESSION_HISTORY_MAX="${SESSION_HISTORY_MAX:-64}"
SESSION_HISTORY_LINES="${SESSION_HISTORY_LINES:-8}"

# Recovery policy for bounded journal recovery attempts.
[ -f "${BASH_SOURCE[0]%/*}/recovery-policy.sh" ] && source "${BASH_SOURCE[0]%/*}/recovery-policy.sh" || true

# ── Session ID validation ──────────────────────────────────────────────
# Session IDs appear in file paths (.state/session-start.$sid, etc).
# Reject any that contain path traversal, shell metacharacters, or
# non-printable characters.

sp_session_registry_validate_sid() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 1

  # Max length: 256 chars
  [ "${#sid}" -le 256 ] || return 1

  # Must not contain: /, newline, .., leading dot (hidden file). NUL cannot
  # survive in a shell variable, so no NUL pattern — note $'\0' in a case
  # pattern expands to the empty string and would turn the branch into `**`,
  # rejecting everything.
  case "$sid" in
    */*|*$'\n'*|*..*|.*) return 1 ;;
  esac

  # Only allow: alphanumeric, dash, underscore, dot (non-leading)
  # This is the safe set for filesystem names on all platforms.
  case "$sid" in
    *[!a-zA-Z0-9_.-]*) return 1 ;;
  esac

  return 0
}

# ── Identity resolution ────────────────────────────────────────────────

# Raw session id from the environment, same precedence as sp_me(). Unvalidated.
sp_session_registry_sid_raw() {
  printf '%s' "${STITCHPAD_SESSION:-${CLAUDE_CODE_SESSION_ID:-${CODEX_SESSION_ID:-}}}"
}

# Resolve the session id from the environment, same precedence as sp_me().
sp_session_registry_sid() {
  local sid
  sid="$(sp_session_registry_sid_raw)"
  # Validate before returning
  if sp_session_registry_validate_sid "$sid"; then
    printf '%s' "$sid"
  fi
  # Invalid or empty — silent, caller handles empty
}

# Resolve the model from environment.
sp_session_registry_model() {
  printf '%s' "${STITCHPAD_MODEL:-${CODEX_MODEL:-${CLAUDE_MODEL:-${ANTHROPIC_MODEL:-}}}}"
}

# Resolve the provider from the model or explicit env.
# Canonical mapping: kimi → kimi (Moonshot AI), NOT deepseek.
sp_session_registry_provider() {
  local provider="${STITCHPAD_PROVIDER:-}"
  if [ -z "$provider" ]; then
    local model
    model="$(sp_session_registry_model)"
    case "$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')" in
      gpt-*|o1-*|o3-*|o4-*) provider="openai" ;;
      claude-*) provider="anthropic" ;;
      deepseek*) provider="deepseek" ;;
      kimi*)     provider="kimi" ;;      # Moonshot AI — was incorrectly "deepseek"
      gemini*)   provider="google" ;;
      *)         provider="" ;;          # unknown — preserved empty, never collapsed
    esac
  fi
  printf '%s' "$provider"
}

# Resolve the name (identity).
sp_session_registry_name() {
  printf '%s' "${STITCHPAD_NAME:-}"
}

# ── Epoch capture ──────────────────────────────────────────────────────
# One captured epoch per operation, shared with date-divider and git commit.
# Call sp_date_divider_snapshot before this; the epoch flows as data from there.
# Falls back to the injected clock or date +%s ONLY if no snapshot was taken.

_sp_session_registry_now() {
  local epoch="${1:-}"
  if [ -n "$epoch" ]; then
    printf '%s' "$epoch"
    return 0
  fi
  # Fall back to the shared date-divider snapshot if present.
  if [ -n "${_SP_DATE_EPOCH:-}" ]; then
    printf '%s' "$_SP_DATE_EPOCH"
    return 0
  fi
  date +%s
}

# ── Request ID from delegated lifecycle ────────────────────────────────
# Projects the REAL delegated request id when the host runtime provides one
# (STITCHPAD_REQUEST_ID) — every say inside that delegated request carries the
# same id; nothing is minted. The id is PERSISTED per-session in
# .state/request-id.<sid> and reused across every activity entry until an
# explicit lifecycle transition (terminal/cancel/resume/rotate). Only when no
# delegated id exists is a provenance-encoded fallback derived from
# provider + session + a monotonic per-pad counter:
# "<provider>-<session-prefix>-<counter>". The counter lives in
# .state/request-counter and is advanced under the pad lock the caller holds.
#
# Arguments:
#   $1 = sid (required for persistence)
#   $2 = "new" to force a new id (lifecycle transition); omit/"" to preserve
sp_session_registry_request_id() {
  local sid="${1:-}" force_new="${2:-}"

  # Real delegated request id wins — validated with the same path-safe rules
  # as session ids before it can appear anywhere.
  local delegated="${STITCHPAD_REQUEST_ID:-}"
  local use_delegated=""
  if [ -n "$delegated" ]; then
    if sp_session_registry_validate_sid "$delegated"; then
      use_delegated="$delegated"
    else
      echo "stitchpad: invalid STITCHPAD_REQUEST_ID — falling back to derived id" >&2
    fi
  fi

  # Preserve the current request id for this session unless a lifecycle
  # transition forces a new one. This is the per-session persistence so the
  # same delegated request keeps its identity across activity entries.
  if [ -n "$sid" ] && [ "$force_new" != "new" ]; then
    local persisted="$PAD_STATE/request-id.$sid"
    if [ -f "$persisted" ] && [ ! -L "$persisted" ]; then
      local existing
      existing="$(head -c 256 "$persisted" 2>/dev/null | tr -d '\n\r' || true)"
      if [ -n "$existing" ]; then
        # If a delegated id is provided and differs from the persisted one,
        # the host is signaling a new delegated request — treat as new.
        if [ -n "$use_delegated" ] && [ "$use_delegated" != "$existing" ]; then
          : # fall through to mint new
        else
          printf '%s' "$existing"
          return 0
        fi
      fi
    fi
  fi

  # Mint a new request id (first entry, lifecycle transition, or delegated change).
  local provider sid_pref counter result
  if [ -n "$use_delegated" ]; then
    result="$use_delegated"
  else
    provider="$(sp_session_registry_provider)"
    sid="$(sp_session_registry_sid)"
    # Use first 12 chars of session id as prefix (or "nosid" if empty)
    sid_pref="${sid:0:12}"
    [ -n "$sid_pref" ] || sid_pref="nosid"

    # Read and increment the counter
    local cf="$PAD_STATE/request-counter"
    mkdir -p "$PAD_STATE" 2>/dev/null || true
    if [ -f "$cf" ] && [ ! -L "$cf" ]; then
      counter="$(head -c 32 "$cf" 2>/dev/null | tr -d '[:space:]' || echo 0)"
      case "$counter" in ''|*[!0-9]*) counter=0 ;; esac
      counter=$(( counter + 1 ))
    else
      counter=1
    fi
    printf '%s' "$counter" > "$cf" 2>/dev/null || true
    result="$(printf '%s-%s-%s' "$provider" "$sid_pref" "$counter")"
  fi

  # Persist for reuse across activity entries until the next lifecycle transition.
  if [ -n "$sid" ] && sp_session_registry_validate_sid "$sid"; then
    printf '%s' "$result" > "$PAD_STATE/request-id.$sid" 2>/dev/null || true
  fi

  printf '%s' "$result"
}

# ── Registry file management ───────────────────────────────────────────

# Ensure the registry file is safe to use.
sp_session_registry_init() {
  local reg="$PAD_STATE/session-registry.jsonl"
  mkdir -p "$PAD_STATE" 2>/dev/null || true
  if [ -L "$PAD_STATE" ]; then
    echo "stitchpad: PAD_STATE is a symlink — refusing session registry" >&2
    return 1
  fi
  if [ -L "$reg" ]; then
    echo "stitchpad: session-registry.jsonl is a symlink — refusing" >&2
    return 1
  fi
  if [ ! -f "$reg" ]; then
    touch "$reg" 2>/dev/null || return 1
  fi
  return 0
}

# Build one JSON entry from resolved fields. All values via argv to Python.
#   $1=request_id $2=sid $3=provider $4=model $5=worktree
#   $6=start $7=now $8=name $9=event
_sp_session_registry_build_entry() {
  python3 -c '
import json, sys
entry = {
    "request_id":    sys.argv[2],
    "session_id":    sys.argv[3],
    "provider":      sys.argv[4],
    "model":         sys.argv[5],
    "worktree":      sys.argv[6],
    "start":         int(sys.argv[7]),
    "last_activity": int(sys.argv[8]),
    "name":          sys.argv[9],
    "event":         sys.argv[10],
}
print(json.dumps(entry, separators=(",", ":")))
' -- "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" 2>/dev/null || true
}

# Atomically append one entry to the registry. Returns 1 on failure, 0 on success.
_sp_session_registry_append_raw() {
  local entry="$1"
  local reg="$PAD_STATE/session-registry.jsonl"
  [ -n "$entry" ] || return 1
  printf '%s\n' "$entry" >> "$reg" || return 1
  sp_session_registry_cap
}

# Core append logic shared by append() and record_event().
# Arguments:
#   $1 = event type (dispatch|activity|terminal|cancel|resume|rotate)
#   $2 = epoch override (empty → _SP_DATE_EPOCH or date +%s)
#   $3 = force_new request id ("" or "new")
_sp_session_registry_append_core() {
  local event="$1" epoch_override="${2:-}" force_new="${3:-}"
  local reg="$PAD_STATE/session-registry.jsonl"
  # A symlinked registry is refused even if its target looks like a file.
  if [ -L "$reg" ]; then
    echo "stitchpad: session-registry.jsonl is a symlink — refusing" >&2
    return 1
  fi
  [ -f "$reg" ] || sp_session_registry_init || return 1

  # Validate the session id BEFORE any marker path is constructed. A raw env
  # sid that fails validation is a hard refusal, not a silent downgrade to
  # anonymous — a hostile sid must never reach a filesystem path.
  local sid name model provider worktree request_id now
  sid="$(sp_session_registry_sid_raw)"
  if [ -n "$sid" ] && ! sp_session_registry_validate_sid "$sid"; then
    echo "stitchpad: invalid session id — refusing registry write" >&2
    return 1
  fi

  name="$(sp_session_registry_name)"
  model="$(sp_session_registry_model)"
  provider="$(sp_session_registry_provider)"
  worktree="${PAD_DIR:-$(pwd)}"
  # Use the same captured epoch as the date divider / git commit — never a
  # second date +%s in the same operation.
  now="$(_sp_session_registry_now "$epoch_override")"
  request_id="$(sp_session_registry_request_id "$sid" "$force_new")"

  # Determine session start time from the session-start marker.
  # Validate sid before constructing the path.
  local start="$now"
  if [ -n "$sid" ]; then
    sp_session_registry_validate_sid "$sid" || return 1
    local ss="$PAD_STATE/session-start.$sid"
    if [ -f "$ss" ] && [ ! -L "$ss" ]; then
      local ss_epoch
      ss_epoch="$(head -c 32 "$ss" 2>/dev/null | tr -d '[:space:]' || true)"
      case "$ss_epoch" in ''|*[!0-9]*) ;; *) start="$ss_epoch" ;; esac
    fi
  fi

  # Build the JSON entry. All values passed via argv to Python — never interpolated.
  local entry
  entry="$(_sp_session_registry_build_entry \
    "$request_id" "$sid" "$provider" "$model" "$worktree" "$start" "$now" "$name" "$event")"

  _sp_session_registry_append_raw "$entry" || return 1

  # Write a session-activity marker for staleness derivation.
  if [ -n "$sid" ]; then
    sp_session_registry_validate_sid "$sid" || return 1
    mkdir -p "$PAD_STATE" 2>/dev/null || true
    printf '%s' "$now" > "$PAD_STATE/session-activity.$sid" 2>/dev/null || true
  fi

  return 0
}

# Append one activity entry to the session registry.
# Call after a successful authored message (say), or any request dispatch.
# Arguments (both optional, positional):
#   $1 = epoch override (empty → shared snapshot or date +%s)
# Failure modes leave no partial visible state: every guard fires before the
# single appended line; the line itself is one atomic O_APPEND write.
sp_session_registry_append() {
  local epoch_override="${1:-}"
  _sp_session_registry_append_core "activity" "$epoch_override" ""
}

# Record a lifecycle event. Writes durably BEFORE returning so a successful
# sp_commit cannot leave state lagging. Valid events:
#   dispatch  — a new request/session was dispatched to this session
#   terminal  — session ended normally
#   cancel    — session was cancelled
#   resume    — session resumed after a pause/interruption
#   rotate    — session rotated (new session identity, e.g. shift-change)
#   activity  — refresh/activity (default)
# Arguments:
#   $1 = event type
#   $2 = epoch override (optional)
sp_session_registry_record_event() {
  local event="${1:-activity}"
  local epoch_override="${2:-}"
  case "$event" in
    dispatch|activity|terminal|cancel|resume|rotate) ;;
    *) echo "stitchpad: unknown registry event '$event'" >&2; return 1 ;;
  esac

  # Lifecycle transitions (terminal/cancel/resume/rotate) force a new
  # request id for the next activity entry.
  local force_new=""
  case "$event" in
    terminal|cancel|resume|rotate|dispatch) force_new="new" ;;
  esac

  _sp_session_registry_append_core "$event" "$epoch_override" "$force_new"
}

# Cap the registry to SESSION_REGISTRY_MAX entries, keeping the newest.
sp_session_registry_cap() {
  local reg="$PAD_STATE/session-registry.jsonl"
  [ -f "$reg" ] || return 0
  local max="${SESSION_REGISTRY_MAX:-1024}"
  local count
  count="$(wc -l < "$reg" 2>/dev/null | tr -d ' ' || echo 0)"
  if [ "$count" -gt "$max" ]; then
    local tmp
    tmp="$(mktemp "$PAD_STATE/.session-registry-tmp.XXXXXX")"
    tail -n "$max" "$reg" > "$tmp" && mv "$tmp" "$reg" || rm -f "$tmp"
  fi
  return 0
}

# ── Read-only projection ───────────────────────────────────────────────
# Compute status for each unique session and print as JSON array.
# Never mutates registry or state files.
#
# Sentinel controls (via env):
#   STITCHPAD_PROJECTION_SINCE=<epoch>  → only include entries with last_activity >= epoch
#   STITCHPAD_PROJECTION_MAX=<N>        → cap the returned JSON array to N sessions (default 256)
#
# The sentinel bounds prevent unbounded history reads.

sp_session_registry_project() {
  local reg="$PAD_STATE/session-registry.jsonl"
  [ -f "$reg" ] || { printf '[]\n'; return 0; }

  local since_epoch="${STITCHPAD_PROJECTION_SINCE:-0}"
  local proj_max="${STITCHPAD_PROJECTION_MAX:-256}"
  # Injectable clock for deterministic status derivation in tests. Validated
  # to digits; anything else falls back to the real clock (empty → real).
  # Injectable clock for deterministic status derivation in tests. Validated
  # to digits; anything else falls back to the real clock (empty → real).
  # Fall back to the shared _SP_DATE_EPOCH snapshot so write and read paths
  # use the same epoch — a projection right after an append must see age ≈ 0.
  local now_inject="${SP_SESSION_REGISTRY_CLOCK:-${_SP_DATE_EPOCH:-}}"
  case "$now_inject" in ''|*[!0-9]*) now_inject="" ;; esac

  # Pass reg path, state dir, idle/stale secs, since_epoch, proj_max, clock via argv.
  python3 - "$reg" "$PAD_STATE" "$SESSION_IDLE_SECONDS" "$SESSION_STALE_SECONDS" "$since_epoch" "$proj_max" "$now_inject" <<'PY'
import json, sys, os

reg_path = sys.argv[1]
state_dir = sys.argv[2]
idle_secs = int(sys.argv[3])
stale_secs = int(sys.argv[4])
since_epoch = int(sys.argv[5])
proj_max = int(sys.argv[6])
now = int(sys.argv[7]) if len(sys.argv) > 7 and sys.argv[7] else int(__import__('time').time())

# Collect entries, key by session_id, apply sentinel bound.
entries = []
try:
    with open(reg_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            # Sentinel bound: skip entries before since_epoch
            if since_epoch > 0 and e.get('last_activity', 0) < since_epoch:
                continue
            entries.append(e)
except Exception:
    print("[]")
    raise SystemExit(0)

# Build per-session summary, respecting proj_max cap on returned sessions.
sessions = {}
for e in entries:
    # Preserve explicit empty state — never collapse to _unknown_.
    sid = e.get('session_id', '')
    if sid not in sessions:
        # Hard cap on the number of projected sessions: entries for sessions
        # already admitted still fold in below; new sessions past the cap drop.
        if proj_max > 0 and len(sessions) >= proj_max:
            continue
        sessions[sid] = {
            'session_id': sid,
            'name': e.get('name', ''),
            'provider': e.get('provider', ''),
            'model': e.get('model', ''),
            'worktree': e.get('worktree', ''),
            'start': e.get('start', 0),
            'last_activity': e.get('last_activity', 0),
            'request_count': 0,
            'status': 'active',
            'last_event': e.get('event', ''),
        }
    s = sessions[sid]
    s['request_count'] += 1
    if e.get('last_activity', 0) > s['last_activity']:
        s['last_activity'] = e['last_activity']
        s['last_event'] = e.get('event', '')
    if e.get('start', 0) and (s['start'] == 0 or e['start'] < s['start']):
        s['start'] = e['start']
    # Carry forward most recent name/provider/model/worktree
    for fld in ('name', 'provider', 'model', 'worktree'):
        if e.get(fld):
            s[fld] = e[fld]

# Derive status for each session
for sid, s in sessions.items():
    age = now - s['last_activity']

    # Check for terminal marker (validated sid path)
    end_marker = os.path.join(state_dir, f'session-end.{sid}')
    if os.path.isfile(end_marker) and not os.path.islink(end_marker):
        s['status'] = 'terminal'
        continue

    if age >= stale_secs:
        s['status'] = 'stale'
    elif age >= idle_secs:
        s['status'] = 'idle'
    else:
        s['status'] = 'active'

    s['idle_seconds'] = age

print(json.dumps(list(sessions.values()), separators=(',', ':')))
PY
}

# ── Bounded history projection ─────────────────────────────────────────
# Read-only projection of recent completed/canceled/resumed/rotated entries.
# Bounded by SESSION_HISTORY_MAX lines scanned, SESSION_HISTORY_LINES returned.
sp_session_registry_history() {
  local reg="$PAD_STATE/session-registry.jsonl"
  [ -f "$reg" ] || { printf '[]\n'; return 0; }

  local hist_max="${SESSION_HISTORY_MAX:-64}"
  local hist_lines="${SESSION_HISTORY_LINES:-8}"

  # Read only the tail (bounded) and filter to lifecycle transitions.
  python3 - "$reg" "$hist_max" "$hist_lines" <<'PY'
import json, sys

reg_path = sys.argv[1]
hist_max = int(sys.argv[2])
hist_lines = int(sys.argv[3])

# Scan the tail bounded by hist_max, newest-first, then reverse for display
# order (oldest of the newest first). Iterating lines[-hist_max:] forward and
# breaking after hist_lines returned the OLDEST events — inverted for a
# "recent history" section. Reverse, collect, re-reverse.
results = []
try:
    with open(reg_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
except Exception:
    print("[]")
    raise SystemExit(0)

for line in reversed(lines[-hist_max:]):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except json.JSONDecodeError:
        continue
    evt = e.get('event', '')
    if evt in ('terminal', 'cancel', 'resume', 'rotate', 'dispatch'):
        results.append(e)
    if len(results) >= hist_lines:
        break
results.reverse()

print(json.dumps(results, separators=(',', ':')))
PY
}

# Human-readable list of session summaries (read-only).
sp_session_registry_list() {
  local data
  data="$(sp_session_registry_project)" || return 1
  if [ "$data" = "[]" ]; then
    echo "(no sessions recorded)"
    return 0
  fi

  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
if not data:
    print('(no sessions recorded)')
else:
    for s in data:
        sid = (s.get('session_id', '') or '?')[:16]
        name = s.get('name', '') or '?'
        model = s.get('model', '') or '?'
        provider = s.get('provider', '') or '?'
        status = s.get('status', '?')
        reqs = s.get('request_count', 0)
        idle = s.get('idle_seconds', 0)
        print(f'{name:12s} {status:8s} {provider:10s} {model:20s} {reqs:4d} reqs  idle {idle}s  sid={sid}')
" <<< "$data"
}

# ── Pad header rendering ───────────────────────────────────────────────
# Render the session projection as markdown lines for inclusion in the pad
# header. Shows Active Sessions (sentinel-bounded) and bounded Session History.
# Read-only — never mutates. Output is plain text lines, one per line.
sp_session_registry_pad_header() {
  local data
  data="$(sp_session_registry_project)" || return 0

  # Active Sessions section
  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
active = [s for s in data if s.get('status') in ('active', 'idle')]
if active:
    print()
    print('> **Active Sessions:**')
    for s in active:
        name = s.get('name', '') or '(unnamed)'
        provider = s.get('provider', '') or '?'
        model = s.get('model', '') or '?'
        reqs = s.get('request_count', 0)
        status = s.get('status', '?')
        sid = (s.get('session_id', '') or '')[:12]
        print(f'> @{name} — {provider}/{model} ({status}, {reqs} req) sid={sid}')
" <<< "$data" 2>/dev/null || true

  # Session History section (bounded)
  local hist
  hist="$(sp_session_registry_history)" || hist="[]"
  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
if data:
    print()
    print('> **Session History:**')
    for e in data:
        evt = e.get('event', '')
        name = e.get('name', '') or '(unnamed)'
        provider = e.get('provider', '') or '?'
        model = e.get('model', '') or '?'
        sid = (e.get('session_id', '') or '')[:12]
        print(f'> [{evt}] @{name} — {provider}/{model} sid={sid}')
" <<< "$hist" 2>/dev/null || true
}

# ── Durable seat identity lookup ───────────────────────────────────────
# Resolve the durable session binding for a roster name (written by
# bind-session into .state/sessions/<sid>). Prints the sid bound to <name>, or
# nothing when the seat has no binding — a missing identity stays visibly
# empty, never minted. Read-only.
sp_session_registry_sid_for_name() {
  local who="${1:-}" f sid
  [ -n "$who" ] || return 0
  for f in "$PAD_STATE"/sessions/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ "$(tr -d '[:space:]' < "$f" 2>/dev/null)" = "$who" ] || continue
    sid="$(basename "$f")"
    if sp_session_registry_validate_sid "$sid"; then
      printf '%s' "$sid"
      return 0
    fi
  done
  return 0
}

# ── Pad header write-back ──────────────────────────────────────────────
# Write the sentinel-bounded Active Sessions + Session History block into the
# pad file itself, from the REAL recorded events. Idempotent: an identical
# rendering is a no-op (no write, no mtime bump, no commit churn).
#
# MUST be called while holding the pad mutation lock — sp_write_inplace
# enforces exact lock ownership and refuses an unlocked write. The block lives
# between HTML-comment sentinels directly after the roster fence, before any
# authored "## @name" block, so it can never trip mention detection or the
# engagement gate. A torn block (missing end sentinel) is healed without
# swallowing any following pad content.
sp_session_registry_render_pad_header() {
  [ -n "${PAD_MD:-}" ] && [ -f "$PAD_MD" ] && [ ! -L "$PAD_MD" ] || return 0
  # Only render once real events exist — never stamp an empty block onto a pad
  # that has recorded no session lifecycle at all.
  [ -f "$PAD_STATE/session-registry.jsonl" ] && [ ! -L "$PAD_STATE/session-registry.jsonl" ] || return 0

  local body tmp rc=0
  body="$(sp_session_registry_pad_header 2>/dev/null || true)"
  tmp="$(sp_stage "$PAD_MD")" || return 1
  if ! SP_SESSIONS_HEADER_BODY="$body" python3 - "$PAD_MD" "$tmp" <<'PY'
import os, sys

pad_path, out_path = sys.argv[1], sys.argv[2]
BEGIN = '<!-- stitchpad:sessions:begin -->'
END = '<!-- stitchpad:sessions:end -->'
body = os.environ.get('SP_SESSIONS_HEADER_BODY', '').strip('\n')

with open(pad_path, encoding='utf-8', errors='surrogateescape') as f:
    lines = f.read().split('\n')

block = [BEGIN] + (body.split('\n') if body else []) + [END]

out = []
i = 0
replaced = False
while i < len(lines):
    if not replaced and lines[i].strip() == BEGIN:
        j = i + 1
        while j < len(lines) and lines[j].strip() != END:
            j += 1
        out.extend(block)
        replaced = True
        if j < len(lines):
            i = j + 1      # healthy block: consumed through the end sentinel
        else:
            i = i + 1      # torn block (no end sentinel): keep following lines
        continue
    out.append(lines[i])
    i += 1

if not replaced:
    ins = []
    in_roster = False
    inserted = False
    for line in out:
        ins.append(line)
        if not inserted:
            if line.startswith('```roster'):
                in_roster = True
            elif in_roster and line.strip() == '```':
                ins.append('')
                ins.extend(block)
                inserted = True
                in_roster = False
    if not inserted:
        # No roster fence — refuse to guess a position; leave the pad as-is.
        raise SystemExit(3)
    out = ins

result = '\n'.join(out)
if not result.endswith('\n'):
    result += '\n'
with open(out_path, 'w', encoding='utf-8', errors='surrogateescape') as f:
    f.write(result)
PY
  then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  sp_write_inplace "$tmp" "$PAD_MD"
  rc=$?
  [ "$rc" -eq 2 ] && rc=0   # identical content: idempotent no-op is success
  return "$rc"
}

# ── Pre-commit journal (atomicity / rollback) ──────────────────────────
# The say path and lifecycle_commit interlock THREE durable artifacts with one
# git commit: the registry jsonl, the lifecycle markers (session-start/end/
# activity, request-id, request-counter), the last-divider epoch, and the pad
# bytes themselves (message + refreshed header). The registry and markers live
# OUTSIDE the pad git — only the pad is committed — so a failed commit cannot
# be unwound by git. The journal captures exact pre-operation bytes so a
# failure anywhere in the window is compensated exactly:
#   journal_begin    → snapshot pad + registry + markers into a temp dir
#   journal_rollback → restore exact bytes / delete files the op created
#   journal_commit   → success: drop the journal
# No-follow: begin REFUSES over a symlinked journal target; rollback never
# writes through a symlink (a link that appeared mid-op is unlinked — rm never
# follows it — then bytes are restored). All paths are reconstructed from

# ── Stale-journal recovery ──────────────────────────────────────────────
# A crash between journal_begin and journal_commit/rollback leaves an orphan
# .registry-journal.* dir in PAD_STATE. On the next guarded operation, the
# stale journal is DETECTED and RECOVERED (not refused): the pre-crash
# snapshot is restored to return state to a known-good point, then the
# journal is removed. Recovery rather than refusal: refusing would
# permanently wedge the pad since no interactive user can clear the orphan.
# State-root identity (dev + inode) is captured at begin and revalidated
# before any rollback write; a mismatch is a LOUD refusal (rc != 0).

_sp_session_registry_journal_orphans() {
  local orphan
  for orphan in "$PAD_STATE"/.registry-journal.*; do
    [ -d "$orphan" ] || continue
    [ -L "$orphan" ] && continue
    printf '%s\n' "$orphan"
  done
}

# Recover every orphan journal: restore snapshot, remove journal.
# Called at the top of journal_begin before any new journal is created,
# ensuring crash residue never compounds.
sp_session_registry_journal_recover() {
  local orphan sid
  for orphan in $(_sp_session_registry_journal_orphans 2>/dev/null); do
    [ -d "$orphan" ] || continue
    # R1/R2: read the stamped sid from the journal, NOT from the recovering
    # caller's env.  The crashed operation stamped its own sid at journal_begin;
    # recovery must interpret the orphan with THAT sid so marker files are
    # enumerated and restored for the correct seat — never the recovering
    # seat's markers, and never empty (anonymous recovery still restores the
    # crashed seat's markers because the stamped sid is authoritative).
    if [ -f "$orphan/.sid" ]; then
      sid="$(cat "$orphan/.sid" 2>/dev/null)" || sid=""
    else
      # Legacy orphan with no stamped sid — fall back to env, but warn.
      sid="${STITCHPAD_SESSION:-}"
    fi
    # R3: refuse recovery when HEAD has advanced past the stamped base SHA.
    # The orphan's pad snapshot predates committed work; restoring it would
    # silently clobber later commits.  Refuse loudly and PRESERVE the orphan
    # for manual inspection instead of consuming it.
    if [ -f "$orphan/.base-sha" ] && [ -n "${PAD_DIR:-}" ] && \
       [ -d "${PAD_DIR}/stitchpad-git" ]; then
      local _recovery_base_sha _recovery_head_sha
      _recovery_base_sha="$(cat "$orphan/.base-sha" 2>/dev/null)" || _recovery_base_sha=""
      _recovery_head_sha="$(git --git-dir="${PAD_DIR}/stitchpad-git" rev-parse HEAD 2>/dev/null)" || _recovery_head_sha=""
      if [ -n "$_recovery_base_sha" ] && [ -n "$_recovery_head_sha" ] && \
         [ "$_recovery_base_sha" != "$_recovery_head_sha" ]; then
        echo "stitchpad: stale journal $(basename "$orphan") base SHA ($_recovery_base_sha) differs from current HEAD ($_recovery_head_sha) — committed work would be reverted; orphan PRESERVED for manual inspection at $orphan" >&2
        continue
      fi
    fi
    echo "stitchpad: recovering stale journal $(basename "$orphan") — restoring pre-crash state" >&2
    # TASK-4: bound recovery attempts per-orphan. If exhausted, preserve the
    # orphan for manual inspection instead of silently retrying forever.
    local _recovery_key="journal:$(basename "$orphan")"
    if type sp_recovery_is_exhausted >/dev/null 2>&1; then
      if sp_recovery_is_exhausted "$PAD_STATE" "$_recovery_key"; then
        type sp_recovery_terminal_refuse >/dev/null 2>&1 && \
          sp_recovery_terminal_refuse "system" "journal-recovery" "$_recovery_key"
        continue
      fi
      sp_recovery_attempt_record "$PAD_STATE" "$_recovery_key"
    fi
    # R1: temporarily suppress env-resolved sids so _sp_session_registry_journal_files
    # enumerates ONLY the stamped sid's markers, never the recovering caller's.
    # Without this, sp_session_registry_sid() inside _sp_session_registry_journal_files
    # would add the recovering seat's markers to the file list, misaligning the
    # manifest and corrupting the recovering seat's files.
    local _save_session="${STITCHPAD_SESSION:-}"
    local _save_claude="${CLAUDE_CODE_SESSION_ID:-}"
    local _save_codex="${CODEX_SESSION_ID:-}"
    export STITCHPAD_SESSION="$sid"
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID
    sp_session_registry_journal_rollback "$orphan" "$sid" >/dev/null 2>&1
    # Restore env
    if [ -n "$_save_session" ]; then export STITCHPAD_SESSION="$_save_session"; else unset STITCHPAD_SESSION; fi
    if [ -n "$_save_claude" ]; then export CLAUDE_CODE_SESSION_ID="$_save_claude"; else unset CLAUDE_CODE_SESSION_ID; fi
    if [ -n "$_save_codex" ]; then export CODEX_SESSION_ID="$_save_codex"; else unset CODEX_SESSION_ID; fi
    rm -rf "$orphan" 2>/dev/null || true
    # TASK-4: clear the recovery attempt counter on success.
    type sp_recovery_reset >/dev/null 2>&1 && \
      sp_recovery_reset "$PAD_STATE" "$_recovery_key" || true
  done
  return 0
}
_sp_session_registry_journal_files() {
  local sid="${1:-}"
  printf '%s\n' "$PAD_MD"
  printf '%s\n' "$PAD_STATE/session-registry.jsonl"
  printf '%s\n' "$PAD_STATE/last-divider-epoch"
  printf '%s\n' "$PAD_STATE/request-counter"
  # Cover marker files for the caller-supplied sid (the leave path passes the
  # seat's bound session id) AND for the env-resolved sid (the say path and
  # lifecycle_locked both call sp_session_registry_sid internally, which may
  # resolve a DIFFERENT id from CLAUDE_CODE_SESSION_ID/CODEX_SESSION_ID). When
  # the two differ, the guarded operation can write markers under either or
  # both — the journal must snapshot and restore the full set.
  local _j_sid
  for _j_sid in "$sid" "$(sp_session_registry_sid)"; do
    [ -n "$_j_sid" ] || continue
    sp_session_registry_validate_sid "$_j_sid" || continue
    printf '%s\n' "$PAD_STATE/session-start.$_j_sid"
    printf '%s\n' "$PAD_STATE/session-end.$_j_sid"
    printf '%s\n' "$PAD_STATE/session-activity.$_j_sid"
    printf '%s\n' "$PAD_STATE/request-id.$_j_sid"
  done
}

# Snapshot every interlocked file. Prints the journal dir on success.
# Also recovers any stale orphan journals from a prior crash before creating
# a new journal (deterministic recovery — never refuses). Captures the
# PAD_STATE root identity (dev+inode) so rollback can validate the state
# root has not been swapped mid-operation.
sp_session_registry_journal_begin() {
  local sid="${1:-}"
  [ -n "${PAD_STATE:-}" ] && [ -d "$PAD_STATE" ] && [ ! -L "$PAD_STATE" ] || return 1
  # C1: recover stale journals from a prior crash BEFORE any new journal.
  sp_session_registry_journal_recover
  local jdir
  jdir="$(mktemp -d "$PAD_STATE/.registry-journal.XXXXXX")" || return 1
  # R1/R2: stamp the owning sid so recovery interprets the orphan with the
  # CRASHED caller's sid, never the recovering caller's env.
  printf '%s' "$sid" > "$jdir/.sid" || { rm -rf "$jdir"; return 1; }
  # R3: stamp the pad git HEAD SHA so recovery can refuse when HEAD has
  # advanced past the base — never silently restore old bytes over committed
  # content.
  if [ -n "${PAD_DIR:-}" ] && [ -d "${PAD_DIR}/stitchpad-git" ]; then
    printf '%s' "$(git --git-dir="${PAD_DIR}/stitchpad-git" rev-parse HEAD 2>/dev/null)" \
      > "$jdir/.base-sha" 2>/dev/null || true
  fi
  # C2: capture state-root identity for rollback-time validation.
  python3 -c "import os,sys; s=os.lstat(sys.argv[1]); print(s.st_dev,s.st_ino)" \
    "$PAD_STATE" > "$jdir/.state-root" 2>/dev/null || {
    rm -rf "$jdir"
    return 1
  }
  : > "$jdir/manifest" || { rm -rf "$jdir"; return 1; }
  local i=0 f
  while IFS= read -r f; do
    if [ -L "$f" ]; then
      rm -rf "$jdir"
      echo "stitchpad: refusing to journal over symlinked state file $(basename "$f")" >&2
      return 1
    fi
    if [ -f "$f" ]; then
      cp "$f" "$jdir/$i" 2>/dev/null || { rm -rf "$jdir"; return 1; }
      printf '1\n' >> "$jdir/manifest"
    else
      printf '0\n' >> "$jdir/manifest"
    fi
    i=$(( i + 1 ))
  done < <(_sp_session_registry_journal_files "$sid")
  printf '%s' "$jdir"
}

# Restore exact pre-operation bytes. Files that existed are rewritten with
# their journaled content (in place, preserving the pad inode); files the
sp_session_registry_journal_rollback() {
  local jdir="${1:-}" sid="${2:-}"
  [ -n "$jdir" ] || return 0
  # C2: validate state-root identity before trusting the journal directory.
  # If the journal is reachable, check dev/inode match against the saved
  # identity from journal_begin. If the journal is unreachable (because
  # PAD_STATE was swapped mid-operation), detect the swap via the fact
  # that journal_begin refuses symlinked PAD_STATE — a now-symlinked (or
  # missing) PAD_STATE proves the root changed. Either way, a mismatch is
  # a LOUD refusal (rc != 0), never a silent no-op.
  if [ -f "$jdir/.state-root" ]; then
    local _sr_now _sr_saved
    _sr_now="$(python3 -c "import os,sys; s=os.lstat(sys.argv[1]); print(s.st_dev,s.st_ino)" "$PAD_STATE" 2>/dev/null)" || _sr_now=""
    _sr_saved="$(cat "$jdir/.state-root" 2>/dev/null)" || _sr_saved=""
    if [ -n "$_sr_saved" ] && [ "$_sr_now" != "$_sr_saved" ]; then
      echo "stitchpad: STATE-ROOT SWAP DETECTED — PAD_STATE dev/inode changed since journal_begin (was $_sr_saved, now $_sr_now); refusing rollback writes, journal preserved at $jdir" >&2
      return 1
    fi
  else
    # R4: journal unreachable — PAD_STATE was swapped mid-operation. The
    # state-root pin file is inside the journal dir which is now unreachable,
    # so we CANNOT validate identity.  Fail closed: a swapped root (symlink,
    # missing, OR a fresh regular directory) is a LOUD refusal.  The previous
    # -L/-d-only check let a rename-swap to a fresh regular dir pass silently.
    echo "stitchpad: STATE-ROOT SWAP DETECTED — journal unreachable after PAD_STATE changed mid-operation (symlink, missing, or directory node swapped); rollback aborted, journal preserved at $jdir" >&2
    return 1
  fi
  [ -d "$jdir" ] && [ ! -L "$jdir" ] || return 0
  local i=0 f existed
  while IFS= read -r f; do
    existed="$(sed -n "$(( i + 1 ))p" "$jdir/manifest" 2>/dev/null)"
    if [ "$existed" = "1" ]; then
      # Never write through a symlink: unlink the link itself first.
      [ -L "$f" ] && rm -f "$f" 2>/dev/null
      if [ -d "$f" ]; then
        echo "stitchpad: rollback refusing to overwrite directory $(basename "$f")" >&2
      else
        cat "$jdir/$i" > "$f" 2>/dev/null || cp "$jdir/$i" "$f" 2>/dev/null || true
      fi
    elif [ "$existed" = "0" ]; then
      # rm -f unlinks the path itself — it never follows a symlink target.
      rm -f "$f" 2>/dev/null || true
    else
      # An unreadable/truncated manifest line is not proof the file was
      # created by the operation — fail closed and leave it untouched.
      echo "stitchpad: rollback manifest line $(( i + 1 )) unreadable — leaving $(basename "$f") untouched" >&2
    fi
    i=$(( i + 1 ))
  done < <(_sp_session_registry_journal_files "$sid")
  rm -rf "$jdir" 2>/dev/null || true
}

# Success path: the operation committed durably, drop the journal.
sp_session_registry_journal_commit() {
  local jdir="${1:-}"
  [ -n "$jdir" ] && rm -rf "$jdir" 2>/dev/null || true
}

# ── Lifecycle wiring (product call sites) ──────────────────────────────
# Record a REAL lifecycle event and refresh the pad-header projection in one
# step, for callers that ALREADY hold the pad mutation lock (say/join/leave).
# Also maintains the durable start/end markers the status projection derives
# from:
#   dispatch|resume  → ensure session-start.<sid> exists; clear stale
#                      session-end.<sid> so a resumed session is active again
#   terminal|cancel  → write session-end.<sid> so status derives terminal
# One epoch is captured up front and flows into the registry entry AND the
# markers — never a second `date +%s` inside the same operation.
sp_session_registry_lifecycle_locked() {
  local event="${1:-activity}" epoch="${2:-}"
  [ -n "$epoch" ] || epoch="$(_sp_session_registry_now)"

  local sid
  sid="$(sp_session_registry_sid)"
  if [ -n "$sid" ]; then
    case "$event" in
      dispatch|resume)
        if [ ! -e "$PAD_STATE/session-start.$sid" ]; then
          mkdir -p "$PAD_STATE" 2>/dev/null || true
          printf '%s' "$epoch" > "$PAD_STATE/session-start.$sid" 2>/dev/null || true
        fi
        if [ -e "$PAD_STATE/session-end.$sid" ] && [ ! -L "$PAD_STATE/session-end.$sid" ]; then
          rm -f "$PAD_STATE/session-end.$sid" 2>/dev/null || true
        fi
        ;;
    esac
  fi

  sp_session_registry_record_event "$event" "$epoch" || return 1

  if [ -n "$sid" ]; then
    case "$event" in
      terminal|cancel)
        if [ ! -L "$PAD_STATE/session-end.$sid" ]; then
          printf '%s' "$epoch" > "$PAD_STATE/session-end.$sid" 2>/dev/null || true
        fi
        ;;
    esac
  fi

  # The header refresh is part of the interlocked unit: a stale header riding
  # a successful pad commit is exactly the divergence the journal protects
  # against, so a render failure fails the whole event (caller rolls back).
  sp_session_registry_render_pad_header || return 1
  return 0
}

# Same recording + header refresh for call sites that do NOT already hold the
# pad mutation lock (bind-session, shift-change, reset): acquires the lock,
# journals pre-operation state, records + renders, commits the header refresh,
# releases. ALL-OR-NOTHING: a failed record/render rolls back journal state
# before the commit; a failed commit rolls back registry, markers, and pad
# bytes. A busy pad returns nonzero before any mutation; callers decide
# whether a missed projection refresh is fatal — it is never left half-done.
sp_session_registry_lifecycle_commit() {
  local event="${1:-activity}" epoch="${2:-}"
  sp_lock || return 1
  local sid jdir rc=0
  sid="$(sp_session_registry_sid)"
  jdir="$(sp_session_registry_journal_begin "$sid")" || {
    sp_unlock
    echo "stitchpad: could not journal pre-lifecycle state — event not recorded" >&2
    return 1
  }
  if ! sp_session_registry_lifecycle_locked "$event" "$epoch"; then
    sp_session_registry_journal_rollback "$jdir" "$sid"
    sp_unlock
    return 1
  fi
  sp_commit "sessions: $event" || rc=1
  if [ "$rc" -ne 0 ]; then
    sp_session_registry_journal_rollback "$jdir" "$sid"
    sp_unlock
    return 1
  fi
  sp_session_registry_journal_commit "$jdir"
  sp_unlock
  return 0
}
