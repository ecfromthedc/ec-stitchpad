#!/usr/bin/env bash
# stitchpad core library — sourced by every command/daemon/adapter.
# The whole system is: one markdown file (stitchpad.md) whose own header declares
# its roster, plus a generic watcher that fires each user's adapter on @mention.
#
# A pad is a directory with:
#   stitchpad.md   the markdown bus (roster block + messages)
#   stitchpad-git/ isolated git history (one commit per post)
#   .state/        runtime flags/counters/inboxes (gitignored)
#
# Roster lives INSIDE stitchpad.md as a fenced ```roster block:
#   name | adapter | wake | target
# wake = push (daemon spawns them) | pull (daemon flags+notifies; they read later)

set -uo pipefail

# ── PASTURE COMPAT (migration stage 1) ──────────────────────────────
# PASTURE_* env wins; STITCHPAD_* stays accepted until stage 4 retires it.
# Normalized ONCE here so every shell consumer keeps reading STITCHPAD_*.
for _pv_name in NAME SESSION PAD_DIR STEAL HOME CWD RELAY TOKEN PAD HANDLE INVITE \
                FORCE_BIND HEARTBEAT_INTERVAL HEARTBEAT_PARENT_PID HEARTBEAT_AUTOSTART \
                ALLOW_WHOAMI_FALLBACK MODEL PADS SUMMARIZER; do
  eval "_pv_val=\${PASTURE_${_pv_name}:-}"
  [ -n "$_pv_val" ] && eval "export STITCHPAD_${_pv_name}=\"\$_pv_val\""
done
unset _pv_name _pv_val

# TASK-5: scope manifests and deployment authority
[ -n "${BIN_DIR:-}" ] && [ -f "$BIN_DIR/scope-authority.sh" ] && source "$BIN_DIR/scope-authority.sh" || true

# STITCHPAD_HOME is the checkout's tool/ dir (holds bin/ + adapters/). If the
# caller already resolved BIN_DIR (via the symlink-safe header), derive HOME from
# it so install-by-symlink works without anyone exporting STITCHPAD_HOME.
if [ -z "${STITCHPAD_HOME:-}" ] && [ -n "${BIN_DIR:-}" ]; then
  STITCHPAD_HOME="$(cd -P "$BIN_DIR/.." && pwd)"
fi
STITCHPAD_HOME="${STITCHPAD_HOME:-$HOME/.stitchpad}"
ADAPTER_DIR="$STITCHPAD_HOME/adapters"

# Watch admission policy has one shell-owned source of truth.  Python health
# receives this exact value from the CLI rather than carrying a drifting copy.
STITCHPAD_WATCH_START_GRACE="${STITCHPAD_WATCH_START_GRACE:-5}"
STITCHPAD_WATCH_STAGE_STALE_SECONDS="${STITCHPAD_WATCH_STAGE_STALE_SECONDS:-60}"
export STITCHPAD_WATCH_START_GRACE STITCHPAD_WATCH_STAGE_STALE_SECONDS

# One canonical prompt fragment for every runtime. Keep model adapters thin:
# they call this builder instead of carrying per-model copies that drift.
# `full` is Ponytail's upstream default; an explicit `off` is the only opt-out.
sp_ponytail_mode() {
  local mode="${STITCHPAD_PONYTAIL_MODE:-${PONYTAIL_DEFAULT_MODE:-full}}"
  mode="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
  case "$mode" in off) printf 'off\n' ;; *) printf 'full\n' ;; esac
}

sp_ponytail_instructions() {
  [ "$(sp_ponytail_mode)" = "off" ] && return 0
  local fragment="$STITCHPAD_HOME/instructions/ponytail.md"
  [ -f "$fragment" ] || return 0
  cat "$fragment"
}

# Read a complete prompt on stdin and emit it with the canonical fragment at
# most once. Prefix by default; `append` preserves the wake nudge's historical
# first-line contract. Only the complete canonical block at a prompt boundary
# counts as composed. Spoofed boundary tokens in untrusted text are neutralized.
sp_prompt_with_ponytail() {
  local placement="${1:-prepend}" body rules trusted_placement=""
  body="$(cat)"
  rules="$(sp_ponytail_instructions)"
  if [ -z "$rules" ]; then
    printf '%s\n' "$body"
    return 0
  fi
  # Preserve one complete, exact trusted block only when it occupies a prompt
  # boundary. Remove it temporarily so every marker token in the remaining
  # user-controlled text is neutralized before the prompt is reconstructed.
  case "$body" in
    "$rules") printf '%s\n' "$rules"; return 0 ;;
    "$rules"$'\n\n'*)
      body="${body#"$rules"$'\n\n'}"
      trusted_placement="prepend"
      ;;
    *$'\n\n'"$rules")
      body="${body%$'\n\n'"$rules"}"
      trusted_placement="append"
      ;;
  esac
  # Pad/handoff text is untrusted. A copied marker must remain ordinary text,
  # not an instruction-suppression primitive or a second canonical block.
  body="$(printf '%s' "$body" | sed \
    -e 's|<!-- stitchpad:ponytail:v1 |<!-- stitchpad:user-text:ponytail:v1 |g' \
    -e 's|<!-- /stitchpad:ponytail:v1 -->|<!-- stitchpad:user-text:/ponytail:v1 -->|g')"
  [ -n "$trusted_placement" ] && placement="$trusted_placement"
  if [ "$placement" = "append" ]; then
    printf '%s\n\n%s\n' "$body" "$rules"
  else
    printf '%s\n\n%s\n' "$rules" "$body"
  fi
}

# ── Pad resolution ──────────────────────────────────────────────────
# Find the pad dir: explicit $PAD_DIR, else nearest .stitchpad up the tree.
sp_find_pad() {
  if [ -n "${PAD_DIR:-}" ]; then echo "$PAD_DIR"; return; fi
  local d="${1:-$PWD}"
  while [ "$d" != "/" ]; do
    [ -d "$d/.pasture" ] && { echo "$d/.pasture"; return; }     # migrated pad wins
    [ -d "$d/.stitchpad" ] && { echo "$d/.stitchpad"; return; } # legacy accepted
    d="$(dirname "$d")"
  done
  return 1
}

# Keep the entire pad out of the surrounding project's Git worktree. The pad
# has its own isolated Git history; if the outer repo sees stitchpad.md as an
# untracked file, `git stash -u` temporarily removes it while live writers keep
# running and can recreate a headerless pad. Use info/exclude so existing repos
# become safe without requiring a tracked .gitignore edit.
sp_ensure_outer_git_ignore() {
  local proj prefix exclude pattern
  proj="$(dirname "$PAD_DIR")"
  git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  prefix="$(git -C "$proj" rev-parse --show-prefix 2>/dev/null || true)"
  exclude="$(git -C "$proj" rev-parse --git-path info/exclude 2>/dev/null || true)"
  [ -n "$exclude" ] || return 0
  case "$exclude" in /*) ;; *) exclude="$proj/$exclude" ;; esac
  pattern="/${prefix}.stitchpad/"
  mkdir -p "$(dirname "$exclude")" 2>/dev/null || return 0
  grep -Fqx "$pattern" "$exclude" 2>/dev/null || printf '\n# stitchpad runtime (isolated history)\n%s\n' "$pattern" >> "$exclude"
}

sp_init_paths_readonly() {
  # Resolution order for which pad we operate on:
  #   1. explicit arg ($1)            — caller passed a dir
  #   2. STITCHPAD_PAD_DIR env        — pin a pad regardless of cwd (daemons/hooks)
  #   3. $PWD                         — the pad under the current directory
  # Without #2, a watcher/daemon launched from the wrong cwd silently watched the
  # wrong pad (ocean-os's watcher latched onto stitchpad-live). Honor the pin.
  PAD_DIR="$(sp_find_pad "${1:-${STITCHPAD_PAD_DIR:-$PWD}}")" || { echo "no pasture found (run: pasture init)" >&2; return 1; }
  PAD_DIR="$(cd -P "$PAD_DIR" 2>/dev/null && pwd)" \
    || { echo "stitchpad: could not canonicalize pad directory" >&2; return 1; }
  # migrated pads carry pasture.md/pasture-git; legacy names accepted until stage 4
  if [ -f "$PAD_DIR/pasture.md" ]; then PAD_MD="$PAD_DIR/pasture.md"; else PAD_MD="$PAD_DIR/stitchpad.md"; fi
  if [ -d "$PAD_DIR/pasture-git" ]; then PAD_GIT="$PAD_DIR/pasture-git"; else PAD_GIT="$PAD_DIR/stitchpad-git"; fi
  PAD_STATE="$PAD_DIR/.state"
  # Task cards live in a SIBLING file so a `task move` never rewrites (or
  # commits) the whole conversation. Legacy inline ```task blocks in the pad are
  # still read — see sp_tasks() — so existing pads keep working untouched.
  PAD_TASKS="$PAD_DIR/tasks.md"
  PAD_ARCHIVE_DIR="$PAD_DIR/archive"
}

sp_init_paths() {
  sp_init_paths_readonly "${1:-}" || return 1
  mkdir -p "$PAD_STATE/sessions"
  # Recovery is intentionally NOT performed here. sp_init_paths is used by
  # passive/read-only commands and runs outside the pad mutation lock. Only
  # sp_lock may reconcile a promoted write generation.
  sp_ensure_outer_git_ignore
  # Pad git is load-bearing (read --new deltas, say auto-commits, compaction
  # audit trail) but NOTHING ever initialized it — sp_commit just no-ops when
  # it's absent, so a pad without it degrades silently. Self-heal on first use.
  if [ ! -d "$PAD_GIT" ] && [ -f "$PAD_MD" ] && command -v git >/dev/null 2>&1; then
    git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" init -q 2>/dev/null || true
    git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" add stitchpad.md 2>/dev/null || true
    git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" -c user.name=stitchpad -c user.email=pad@local \
      commit -q -m "bootstrap: pad git (re)initialized" 2>/dev/null || true
  fi
}

# Evidence label (TASK-6): stamp the current environment + immutable candidate
# for a verification artifact. Delegates to tool/bin/evidence-stamp when
# present and never fails the caller when the helper is unavailable — the
# stamp is a label on evidence, not a gate.
sp_evidence_stamp() {
  local _stamp
  _stamp="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence-stamp"
  if [ -x "$_stamp" ]; then
    "$_stamp" "$@"
  else
    echo "# evidence-stamp: unavailable"
  fi
}

# ── Identity ─────────────────────────────────────────────────────────
# Identity is bound to the agent's SESSION, declared once via the MCP `join` tool
# (which calls `stitchpad bind-session <id> <name>`, writing .state/sessions/<id>).
# Resolution order — SESSION BINDING WINS:
#   1. .state/sessions/$STITCHPAD_SESSION   (the durable identity bound at join)
#   2. explicit STITCHPAD_NAME              (fallback when no session binding)
# The session binding is checked FIRST so a STALE STITCHPAD_NAME left in the shell
# (e.g. a session that re-joined under a new handle but whose shell still exports the
# OLD name) cannot override the real identity. This is the @Jill→@deepseek bug: the
# session rebound to deepseek but the shell still had STITCHPAD_NAME=Jill, so every
# post was mis-stamped @Jill. Session id is the source of truth; env name is a hint.
sp_me() {
  # Session binding wins. Prefer the explicit STITCHPAD_SESSION, but fall back to
  # the runtime's own session id ($CLAUDE_CODE_SESSION_ID) when the shell never
  # exported STITCHPAD_SESSION — that gap is exactly what let a stale STITCHPAD_NAME
  # leak through and mis-stamp posts (@Jill bug). Try both before trusting the name.
  local sid="${STITCHPAD_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [ -n "$sid" ] && [ -f "$PAD_STATE/sessions/$sid" ]; then
    local _bound; _bound="$(cat "$PAD_STATE/sessions/$sid" 2>/dev/null)"
    # Binding wins (kills the stale-STITCHPAD_NAME @Jill bug). But if the live
    # invocation ALSO declared a different STITCHPAD_NAME, the binding may be a
    # cross-bind (the @codex bleed): surface it loudly so it's not silent.
    if [ -n "${STITCHPAD_NAME:-}" ] && [ -n "$_bound" ] && [ "$_bound" != "$STITCHPAD_NAME" ]; then
      echo "stitchpad: WARNING — session $sid is bound to @$_bound but STITCHPAD_NAME=@$STITCHPAD_NAME." >&2
      echo "  Posting as @$_bound (binding wins). If wrong, rebind: STITCHPAD_FORCE_BIND=1 stitchpad bind-session $sid $STITCHPAD_NAME" >&2
    fi
    echo "$_bound"; return
  fi
  if [ -n "${STITCHPAD_NAME:-}" ]; then echo "$STITCHPAD_NAME"; return; fi
  # Herdr terminal resolution: a process in a managed pane can resolve its stable
  # terminal id and find the matching roster target without shared whoami state.
  local _surface_id="$(sp_this_surface)"
  if [ -n "$_surface_id" ]; then
    local _wname
    _wname="$(sp_roster | awk -F'|' -v w="$_surface_id" '
      { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $4)
        n=$4; sub(/.*@@/, "", n)
        if (n == w) { print $1; exit } }' 2>/dev/null)"
    if [ -n "$_wname" ]; then echo "$_wname"; return; fi
  fi
  # Last-resort pad default is intentionally opt-in. A shared whoami file can
  # collapse multiple agents into whoever joined last (for example, everyone
  # posting as @nancy). Prefer explicit STITCHPAD_NAME, STITCHPAD_SESSION, or
  # Herdr terminal resolution; fail closed instead of misattributing work.
  if [ "${STITCHPAD_ALLOW_WHOAMI_FALLBACK:-0}" = "1" ]; then
    cat "$PAD_STATE/whoami" 2>/dev/null || true
  fi
}

# Resolve identity from the bound session only. Used by the Stop hook so a stale
# STITCHPAD_NAME in the runtime env cannot override the session mapping.
sp_session_name() {
  [ -n "${PAD_STATE:-}" ] || return 0
  local sid="${STITCHPAD_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [ -n "$sid" ] && [ -f "$PAD_STATE/sessions/$sid" ]; then
    cat "$PAD_STATE/sessions/$sid" 2>/dev/null || true
  fi
}

# ── Model pinning (requested vs resolved) ───────────────────────────
# Every seat carries TWO model truths, persisted separately:
#   .state/seat-model.<name>          REQUESTED — operator-owned pin. Never
#                                     written by telemetry; roster columns are
#                                     not a second authority either.
#   .state/resolved-model.<name>      RESOLVED — written ONLY from telemetry:
#                                     the binding runtime's own env, or the
#                                     daemon session-config readback after a
#                                     wake. An empty read never overwrites.
#   .state/resolved-provider.<name>   RESOLVED provider (best-effort).
#   .state/resolved-model-meta.<name> provenance: <source>|<epoch>|<session>
#   .state/model-mismatch.<name>      ACTIVE mismatch marker:
#                                     <requested>|<resolved>|<epoch>. Written
#                                     when requested != resolved, removed when
#                                     truth heals. Its presence is the signal.
# Policy (STITCHPAD_MODEL_PIN_POLICY or .state/model-pin-policy):
#   surface (default) — loud stderr line + marker; work continues.
#   refuse            — wake paths (ocean adapter, seat-keeper) refuse to wake
#                       while a mismatch is active or the seat is unpinned.
# Identity binding (bind-session) always surfaces, never refuses: the resolved
# record is evidence, and refusing to record identity over metadata would hide
# exactly the drift this mechanism exists to catch.

sp_model_pin_valid_name() {
  case "$1" in ''|.*|*/*|*[[:space:]]*) return 1 ;; *) return 0 ;; esac
}

sp_model_pin_policy() {
  # $1 = state dir. Prints "refuse" or "surface" (default).
  local p="${STITCHPAD_MODEL_PIN_POLICY:-}"
  [ -n "$p" ] || p="$(cat "$1/model-pin-policy" 2>/dev/null || true)"
  case "$p" in refuse) printf 'refuse\n' ;; *) printf 'surface\n' ;; esac
}

sp_model_pin_requested() {
  # $1 = state dir, $2 = name. Prints the operator-pinned model (may be empty).
  sp_model_pin_valid_name "${2:-}" || return 1
  cat "$1/seat-model.$2" 2>/dev/null || true
}

sp_model_pin_record_resolved() {
  # $1=state $2=name $3=model $4=provider $5=source $6=session(optional).
  # Telemetry writer. An empty model read NEVER erases a prior resolved truth.
  local state="$1" name="$2" model="$3" provider="${4:-}" source="$5" session="${6:-}" now
  sp_model_pin_valid_name "$name" || return 1
  [ -n "$model" ] || return 0
  now="$(date +%s)"
  printf '%s' "$model" > "$state/resolved-model.$name.tmp.$$" \
    && mv "$state/resolved-model.$name.tmp.$$" "$state/resolved-model.$name" || return 1
  if [ -n "$provider" ]; then
    printf '%s' "$provider" > "$state/resolved-provider.$name.tmp.$$" \
      && mv "$state/resolved-provider.$name.tmp.$$" "$state/resolved-provider.$name"
  fi
  printf '%s|%s|%s' "$source" "$now" "$session" > "$state/resolved-model-meta.$name.tmp.$$" \
    && mv "$state/resolved-model-meta.$name.tmp.$$" "$state/resolved-model-meta.$name"
}

sp_model_pin_check() {
  # $1 = state dir, $2 = name. Compares requested vs resolved.
  # rc 0 = no active mismatch (marker cleared); rc 2 = mismatch (marker
  # written, loud line on stderr). Never fails closed on missing data:
  # an unpinned seat or an uninstrumented runtime is not a mismatch.
  local state="$1" name="$2" req res now
  sp_model_pin_valid_name "$name" || return 1
  req="$(sp_model_pin_requested "$state" "$name")"
  res="$(cat "$state/resolved-model.$name" 2>/dev/null || true)"
  if [ -n "$req" ] && [ -n "$res" ] && [ "$req" != "$res" ]; then
    now="$(date +%s)"
    printf '%s|%s|%s' "$req" "$res" "$now" > "$state/model-mismatch.$name.tmp.$$" \
      && mv "$state/model-mismatch.$name.tmp.$$" "$state/model-mismatch.$name"
    echo "[model-pin] MISMATCH @$name: requested '$req' (.state/seat-model.$name) != resolved '$res' — marker .state/model-mismatch.$name" >&2
    return 2
  fi
  rm -f "$state/model-mismatch.$name" 2>/dev/null
  return 0
}

sp_model_pin_preflight() {
  # $1 = state dir, $2 = name. Gate run by wake paths (ocean adapter,
  # seat-keeper) BEFORE posting a turn. Guarantees no seat silently inherits
  # the daemon global default: unpinned seats are always surfaced, and under
  # policy=refuse they (and active mismatches) refuse the wake with rc 2.
  local state="$1" name="$2" policy req rc
  sp_model_pin_valid_name "$name" || return 1
  policy="$(sp_model_pin_policy "$state")"
  req="$(sp_model_pin_requested "$state" "$name")"
  if [ -z "$req" ]; then
    echo "[model-pin] @$name has NO requested pin (.state/seat-model.$name) — a wake would silently inherit the daemon global default" >&2
    if [ "$policy" = "refuse" ]; then
      echo "[model-pin] policy=refuse: refusing unpinned wake for @$name" >&2
      return 2
    fi
  fi
  sp_model_pin_check "$state" "$name"
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$policy" = "refuse" ]; then
    echo "[model-pin] policy=refuse: refusing wake for @$name while a requested/resolved mismatch is active" >&2
    return 2
  fi
  return 0
}

# ── Do Not Disturb ──────────────────────────────────────────────────
# DND is a local wake-suppression flag. It never mutates the pad or seen cursor:
# mentions accumulate behind .state/seen.<name> and can be drained on return.
sp_dnd_file() { printf '%s/dnd.%s\n' "$PAD_STATE" "$1"; }
sp_dnd_is_on() { [ -f "$(sp_dnd_file "$1")" ]; }

# ── Heartbeat ticker ownership ────────────────────────────────────────
# A PID alone is never ownership proof: after a crash the kernel may reuse it
# for an unrelated process.  New ticker locks therefore carry the process start
# identity, exact command line, pad, and seat that the spawning parent observed.
# Stop/reset callers must match every field against the live process before
# sending any signal.  Legacy locks without this record deliberately fail
# closed while their recorded PID is live.
sp_process_start() {
  # MP-1: lstart output is LOCALE-DEPENDENT (%a %b localize — C: "Mon Aug  3",
  # de_DE: "Mo.  3 Aug."). Claim start tokens are written once and compared
  # byte-for-byte by later checks possibly running under a different locale;
  # force LC_ALL=C so writer and checker always see the same format (flash
  # re-attack MP-1; TASK-14 env-invariance applied to production code).
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

sp_process_command() {
  ps -p "$1" -o command= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

sp_process_identity_matches() {
  local pid="$1" expected_start="$2" expected_command="$3" started command
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$expected_start" ] && [ -n "$expected_command" ] \
    && [ "$started" = "$expected_start" ] && [ "$command" = "$expected_command" ]
}

sp_b64_encode() {
  python3 - "$1" <<'PY'
import base64, sys
print(base64.b64encode(sys.argv[1].encode()).decode())
PY
}

sp_b64_decode() {
  python3 - "$1" <<'PY'
import base64, sys
try:
    print(base64.b64decode(sys.argv[1], validate=True).decode(), end="")
except Exception:
    raise SystemExit(1)
PY
}

sp_generation_is_safe() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]* ) return 1 ;;
    * ) [ "${#1}" -le 128 ] ;;
  esac
}

sp_ticker_launcher_claim() {
  local lockd="$1" generation="$2" who="$3" pid started command tmp
  pid="$$"
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$generation" ] && [ -n "$started" ] && [ -n "$command" ] || return 1
  tmp="$PAD_STATE/.heartbeat-launcher.$$.$RANDOM"
  python3 - "$generation" "$pid" "$started" "$command" "$PAD_DIR" "$who" > "$tmp" <<'PY'
import json, sys
generation, pid, started, command, pad, name = sys.argv[1:]
print(json.dumps({
    "generation": generation,
    "pid": int(pid),
    "processStart": started,
    "command": command,
    "pad": pad,
    "name": name,
}, separators=(",", ":")))
PY
  [ -d "$lockd" ] && [ "$(cat "$lockd/generation" 2>/dev/null || true)" = "$generation" ] \
    && [ -s "$tmp" ] && ln "$tmp" "$lockd/launcher" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  rm -f "$tmp" 2>/dev/null || true
}

sp_ticker_manifest_is_valid() {
  local path="$1" generation="$2" who="$3"
  [ -f "$path" ] || return 1
  python3 - "$path" "$generation" "$PAD_DIR" "$who" <<'PY'
import json, sys
path, generation, pad, name = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        owner = json.load(handle)
    assert set(owner) == {"generation", "pid", "processStart", "command", "pad", "name"}
    assert owner["generation"] == generation and owner["pad"] == pad and owner["name"] == name
    assert isinstance(owner["pid"], int) and owner["pid"] > 0
    assert all(isinstance(owner[k], str) and owner[k]
               for k in ("processStart", "command"))
except Exception:
    raise SystemExit(1)
PY
}

sp_ticker_manifest_is_live() {
  local path="$1" generation="$2" who="$3" pid started command
  sp_ticker_manifest_is_valid "$path" "$generation" "$who" || return 1
  pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$path" 2>/dev/null || true)"
  started="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["processStart"])' "$path" 2>/dev/null || true)"
  command="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["command"])' "$path" 2>/dev/null || true)"
  sp_process_identity_matches "$pid" "$started" "$command"
}

sp_ticker_owner_claim() {
  local lockd="$1" generation="$2" pid="$3" who="$4" started command tmp
  [ "${STITCHPAD_HEARTBEAT_TEST_OWNER_WRITE_FAIL:-0}" != "1" ] || return 1
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$generation" ] && [ -n "$started" ] && [ -n "$command" ] || return 1
  tmp="$PAD_STATE/.heartbeat-owner.$pid.$RANDOM"
  python3 - "$generation" "$pid" "$started" "$command" "$PAD_DIR" "$who" > "$tmp" <<'PY'
import json, sys
generation, pid, started, command, pad, name = sys.argv[1:]
print(json.dumps({
    "generation": generation,
    "pid": int(pid),
    "processStart": started,
    "command": command,
    "pad": pad,
    "name": name,
}, separators=(",", ":")))
PY
  [ -d "$lockd" ] && [ "$(cat "$lockd/generation" 2>/dev/null || true)" = "$generation" ] \
    && [ -s "$tmp" ] && ln "$tmp" "$lockd/owner" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
  rm -f "$tmp" 2>/dev/null || true
  sp_ticker_owner_matches "$lockd" "$generation" "$pid" "$who"
}

sp_ticker_owner_matches() {
  local lockd="$1" generation="$2" pid="$3" who="$4" started command
  [ "$(cat "$lockd/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  sp_ticker_manifest_is_valid "$lockd/owner" "$generation" "$who" || return 1
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$started" ] && [ -n "$command" ] || return 1
  python3 - "$lockd/owner" "$pid" "$started" "$command" <<'PY'
import json, sys
path, pid, started, command = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        owner = json.load(handle)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if owner["pid"] == int(pid)
                 and owner["processStart"] == started
                 and owner["command"] == command else 1)
PY
}

sp_ticker_retire_generation() {
  local lockd="$1" generation="$2" retired="$1.retired.$2"
  sp_generation_is_safe "$generation" \
    && [ "$(cat "$lockd/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  [ ! -e "$retired" ] || return 1
  mv "$lockd" "$retired" 2>/dev/null || return 1
  printf '%s\n' "$retired"
}

sp_ticker_retired_cleanup() {
  local retired="$1"
  rm -f "$retired/owner" "$retired/launcher" "$retired/pid" "$retired/cancel" \
    "$retired/generation" 2>/dev/null || true
  rmdir "$retired" 2>/dev/null
}

sp_ticker_cancel_generation() {
  local lockd="$1" generation="$2" tmp="$PAD_STATE/.heartbeat-cancel.$$.$RANDOM"
  sp_generation_is_safe "$generation" \
    && [ "$(cat "$lockd/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  if [ -f "$lockd/cancel" ]; then
    [ "$(cat "$lockd/cancel" 2>/dev/null || true)" = "$generation" ]
    return
  fi
  printf '%s' "$generation" > "$tmp" || return 1
  [ "$(cat "$lockd/generation" 2>/dev/null || true)" = "$generation" ] \
    && ln "$tmp" "$lockd/cancel" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null || true
      [ "$(cat "$lockd/cancel" 2>/dev/null || true)" = "$generation" ]
      return
    }
  rm -f "$tmp" 2>/dev/null || true
}

sp_ticker_generation_cleanup() {
  local lockd="$1" generation="$2"
  sp_generation_is_safe "$generation" \
    && [ "$(cat "$lockd/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  rm -f "$lockd/owner" "$lockd/launcher" "$lockd/pid" "$lockd/cancel" "$lockd/generation" 2>/dev/null || true
  rmdir "$lockd" 2>/dev/null
}

sp_ticker_alive_remove_generation() {
  local who="$1" generation="$2" alive="$PAD_STATE/alive.$1" observed actual
  [ -f "$alive" ] || return 0
  actual="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("generation",""))' "$alive" 2>/dev/null || true)"
  [ "$actual" = "$generation" ] || return 0
  observed="$(cat "$alive" 2>/dev/null || true)"
  [ -n "$observed" ] && [ "$(cat "$alive" 2>/dev/null || true)" = "$observed" ] \
    && rm -f "$alive" 2>/dev/null || true
}

sp_ticker_alive_remove_snapshot() {
  local who="$1" alive="$PAD_STATE/alive.$1" observed
  [ -f "$alive" ] || return 0
  observed="$(cat "$alive" 2>/dev/null || true)"
  [ -n "$observed" ] && [ "$(cat "$alive" 2>/dev/null || true)" = "$observed" ] \
    && rm -f "$alive" 2>/dev/null || true
}

sp_ticker_stop_owned() {
  local who="$1" lockd="$PAD_STATE/heartbeat.$1.lock" generation pid started command launcher_pid launcher_start launcher_command i=0 legacy_pid
  if [ ! -d "$lockd" ]; then
    sp_ticker_alive_remove_snapshot "$who"
    return 0
  fi
  generation="$(cat "$lockd/generation" 2>/dev/null || true)"
  if [ -z "$generation" ] || ! sp_ticker_manifest_is_valid "$lockd/launcher" "$generation" "$who"; then
    # Legacy/unknown state is removable only when its bare PID is not live.
    # A live numeric PID without a valid exact manifest is never signal authority.
    legacy_pid="$(cat "$lockd/pid" 2>/dev/null || true)"
    if [ -n "$legacy_pid" ] && kill -0 "$legacy_pid" 2>/dev/null; then
      echo "stitchpad: heartbeat @$who has live but unverified pid $legacy_pid; refusing to signal or remove its state" >&2
      return 1
    fi
    # Only the exact legacy pid-only shape is understood. Malformed manifests
    # and unknown files are preserved byte-for-byte for operator repair.
    if [ -n "$(find "$lockd" -mindepth 1 -maxdepth 1 ! -name pid -print -quit 2>/dev/null)" ]; then
      echo "stitchpad: malformed heartbeat @$who lock left untouched" >&2
      return 1
    fi
    rm -f "$lockd/pid" 2>/dev/null || true
    rmdir "$lockd" 2>/dev/null || return 1
    return 0
  fi
  if [ -f "$lockd/owner" ]; then
    if ! sp_ticker_manifest_is_valid "$lockd/owner" "$generation" "$who"; then
      echo "stitchpad: malformed heartbeat @$who owner left untouched" >&2
      return 1
    fi
    pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$lockd/owner" 2>/dev/null || true)"
    started="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["processStart"])' "$lockd/owner" 2>/dev/null || true)"
    command="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["command"])' "$lockd/owner" 2>/dev/null || true)"
  else
    pid=""; started=""; command=""
  fi
  launcher_pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$lockd/launcher" 2>/dev/null || true)"
  launcher_start="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["processStart"])' "$lockd/launcher" 2>/dev/null || true)"
  launcher_command="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["command"])' "$lockd/launcher" 2>/dev/null || true)"
  # Keep the canonical name occupied while cancellation drains publishers. This
  # prevents an old check-then-link/write from landing in a successor's lock.
  sp_ticker_cancel_generation "$lockd" "$generation" || return 1
  if [ -n "${STITCHPAD_HEARTBEAT_TEST_STOP_AFTER_CANCEL_BARRIER:-}" ]; then
    local stop_barrier="$STITCHPAD_HEARTBEAT_TEST_STOP_AFTER_CANCEL_BARRIER"
    printf '%s' ready > "$stop_barrier.ready"
    while [ ! -f "$stop_barrier.release" ]; do sleep 0.01; done
  fi
  if [ -n "$pid" ] && sp_process_identity_matches "$pid" "$started" "$command"; then
    kill "$pid" 2>/dev/null || true
  fi
  while [ "$i" -lt 20 ]; do
    # A child may publish owner just after cancellation was recorded. It cannot
    # write a heartbeat, and once visible it is stopped using exact identity.
    if [ -f "$lockd/owner" ] && sp_ticker_manifest_is_valid "$lockd/owner" "$generation" "$who"; then
      pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$lockd/owner" 2>/dev/null || true)"
      started="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["processStart"])' "$lockd/owner" 2>/dev/null || true)"
      command="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["command"])' "$lockd/owner" 2>/dev/null || true)"
      sp_process_identity_matches "$pid" "$started" "$command" && kill "$pid" 2>/dev/null || true
    fi
    if ! sp_process_identity_matches "$pid" "$started" "$command" \
      && ! sp_process_identity_matches "$launcher_pid" "$launcher_start" "$launcher_command"; then
      break
    fi
    sleep 0.1; i=$((i + 1))
  done
  sp_process_identity_matches "$pid" "$started" "$command" && kill -KILL "$pid" 2>/dev/null || true
  if sp_process_identity_matches "$launcher_pid" "$launcher_start" "$launcher_command"; then
    echo "stitchpad: heartbeat @$who launcher did not observe cancellation; state preserved" >&2
    return 1
  fi
  sp_ticker_alive_remove_generation "$who" "$generation"
  # A child's exact cleanup may already have removed the generation.
  [ ! -d "$lockd" ] || sp_ticker_generation_cleanup "$lockd" "$generation"
}

# ── Atomic pad mutation lock ─────────────────────────────────────────
# Multiple agents may say/join the same pad concurrently. stitchpad.md is mutated
# by bare appends (say) and read-rewrite (join); without serialization those race
# (interleaved lines / lost updates). mkdir is atomic on every POSIX fs, so we use
# a lock DIR as the mutex — no flock dependency (macOS lacks it). Auto-breaks a
# stale lock so a crashed writer can't wedge the pad forever.
SP_LOCK_TIMEOUT="${SP_LOCK_TIMEOUT:-5}"   # seconds to wait for the lock
SP_LOCK_STALE="${SP_LOCK_STALE:-30}"      # seconds before a held lock is "stale"
_SP_LOCK_DIR=""
_SP_LOCK_GENERATION=""
_SP_LOCK_PID=""
_SP_LOCK_SUBSHELL=""

sp_lock_owner_write() {
  local lock="$1" generation="$2" pid="$3" started command tmp
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$started" ] && [ -n "$command" ] || return 1
  # Build outside the canonical lock directory. A SIGKILL during publication
  # can leave only an empty reclaimable lock, never a non-empty ownerless wedge.
  tmp="$PAD_STATE/.lock-owner.$$.$RANDOM"
  python3 - "$generation" "$pid" "$started" "$command" > "$tmp" <<'PY'
import json, sys
generation, pid, started, command = sys.argv[1:]
print(json.dumps({
    "generation": generation,
    "pid": int(pid),
    "processStart": started,
    "command": command,
}, separators=(",", ":")))
PY
  [ -s "$tmp" ] && mv "$tmp" "$lock/owner" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
}

sp_lock_owner_matches() {
  local lock="$1" generation="$2" pid="$3" started command
  [ -f "$lock/owner" ] || return 1
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$started" ] && [ -n "$command" ] || return 1
  python3 - "$lock/owner" "$generation" "$pid" "$started" "$command" <<'PY'
import json, sys
path, generation, pid, started, command = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        owner = json.load(handle)
except Exception:
    raise SystemExit(1)
expected = {
    "generation": generation,
    "pid": int(pid),
    "processStart": started,
    "command": command,
}
raise SystemExit(0 if owner == expected else 1)
PY
}

sp_lock_owner_is_live() {
  local lock="$1" pid started command expected_start expected_command
  [ -f "$lock/owner" ] || return 1
  pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$lock/owner" 2>/dev/null || true)"
  expected_start="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("processStart",""))' "$lock/owner" 2>/dev/null || true)"
  expected_command="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("command",""))' "$lock/owner" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$expected_start" ] && [ -n "$expected_command" ] \
    && [ "$started" = "$expected_start" ] && [ "$command" = "$expected_command" ]
}

sp_lock_owner_is_valid() {
  local lock="$1"
  [ -f "$lock/owner" ] || return 1
  python3 - "$lock/owner" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        owner = json.load(handle)
    assert set(owner) == {"generation", "pid", "processStart", "command"}
    assert isinstance(owner["pid"], int) and owner["pid"] > 0
    assert all(isinstance(owner[k], str) and owner[k]
               for k in ("generation", "processStart", "command"))
except Exception:
    raise SystemExit(1)
PY
}

# Every mutation lock protects the two canonical content paths.  Recovery
# already refuses symlinked targets, but append-only writers do not pass through
# recovery when no .ready generation exists.  Validate with lstat before any
# locked recovery, create, rewrite, or append so neither an existing symlink nor
# a broken tasks.md symlink can redirect a write outside the pad.
sp_mutation_targets_are_safe() {
  [ -n "${PAD_MD:-}" ] && [ -n "${PAD_TASKS:-}" ] || return 1
  python3 - "$PAD_MD" "$PAD_TASKS" <<'PY'
import os, stat, sys
pad, tasks = sys.argv[1:]
try:
    if os.path.lexists(pad) and not stat.S_ISREG(os.lstat(pad).st_mode):
        raise ValueError("pad is not a regular file")
    if os.path.lexists(tasks) and not stat.S_ISREG(os.lstat(tasks).st_mode):
        raise ValueError("tasks is not a regular file")
except Exception:
    raise SystemExit(1)
PY
}

sp_lock() {
  local lock="$PAD_STATE/.lock" age now mtime observed pid_capture _jitter
  local _start _elapsed
  _start=$(date +%s)
  while ! mkdir "$lock" 2>/dev/null; do
    # Break a stale lock when its exact recorded owner is no longer live.
    # A long-running but live writer is never evicted merely because the lock's
    # directory mtime is old.
    if [ -d "$lock" ]; then
      now=$(date +%s)
      mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
      age=$(( now - mtime ))
      # F2: proactive dead-holder reclaim. Before waiting out SP_LOCK_STALE,
      # check if the owner manifest is valid AND the owner PID is provably
      # dead (kill -0 fails or processStart/command mismatch). A SIGKILL'd
      # holder is dead immediately — there's no reason to wait 30s for the
      # stale window. This runs on EVERY loop iteration (every ~0.05s).
      # Falls through to the age-based check below for empty/unknown locks.
      if [ -f "$lock/owner" ] && sp_lock_owner_is_valid "$lock"; then
        if ! sp_lock_owner_is_live "$lock"; then
          observed="$(cat "$lock/owner" 2>/dev/null || true)"
          [ -n "$observed" ] && [ "$(cat "$lock/owner" 2>/dev/null || true)" = "$observed" ] \
            && rm -f "$lock/owner" 2>/dev/null || true
          rmdir "$lock" 2>/dev/null || true
          [ -d "$lock" ] || continue
        fi
      elif [ "$age" -ge "$SP_LOCK_STALE" ]; then
        # Fallback: age-based stale-break for pre-generation or empty locks.
        # Non-empty unknown locks fail closed because their contents are not
        # ownership proof.
        rmdir "$lock" 2>/dev/null || true
        [ -d "$lock" ] || continue
      fi
    fi
    # F1: track elapsed wall-clock time (not iteration count) since jitter
    # makes each iteration variable-length.
    now=$(date +%s)
    _elapsed=$(( now - _start ))
    [ "$_elapsed" -ge "$SP_LOCK_TIMEOUT" ] && { echo "stitchpad: pad busy (lock timeout)" >&2; return 1; }
    # F1: jittered backoff instead of fixed 0.1s. Under N>=10 concurrent
    # writers, a fixed sleep causes thundering-herd: all losers retry on the
    # same tick and the winner is one mkdir among N. Jitter spreads the
    # retries across the interval, increasing the effective admission rate.
    _jitter=$(( (RANDOM % 10) + 1 ))   # 1-10 centiseconds (0.01-0.10s)
    sleep 0.${_jitter}
  done
  _SP_LOCK_DIR="$lock"
  # `$$` does not change in a Bash 3.2 subshell. Ask a direct child for its
  # parent PID so the lock records the shell that actually owns this execution
  # context, not an ancestor whose EXIT trap may be inherited.
  if [ -n "${STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER:-}" ]; then
    local barrier="$STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER" barrier_i=0
    printf '%s' ready > "$barrier.ready"
    while [ ! -f "$barrier.release" ] && [ "$barrier_i" -lt 500 ]; do
      sleep 0.01; barrier_i=$((barrier_i + 1))
    done
    [ -f "$barrier.release" ] || return 1
  fi
  pid_capture="$PAD_STATE/.pid-capture.$$.$RANDOM"
  /bin/sh -c 'printf "%s" "$PPID"' > "$pid_capture" || true
  _SP_LOCK_PID="$(cat "$pid_capture" 2>/dev/null || true)"
  rm -f "$pid_capture" 2>/dev/null || true
  case "$_SP_LOCK_PID" in ''|*[!0-9]*)
    rmdir "$lock" 2>/dev/null || true
    _SP_LOCK_DIR=""; _SP_LOCK_PID=""
    echo "stitchpad: could not resolve pad-lock owner pid" >&2
    return 1
    ;;
  esac
  _SP_LOCK_SUBSHELL="${BASH_SUBSHELL:-0}"
  _SP_LOCK_GENERATION="$(date +%s).${_SP_LOCK_PID}.${RANDOM:-0}"
  if ! sp_lock_owner_write "$lock" "$_SP_LOCK_GENERATION" "$_SP_LOCK_PID"; then
    rmdir "$lock" 2>/dev/null || true
    _SP_LOCK_DIR=""; _SP_LOCK_GENERATION=""; _SP_LOCK_PID=""; _SP_LOCK_SUBSHELL=""
    echo "stitchpad: could not publish pad-lock ownership" >&2
    return 1
  fi
  # Signals exit first; the EXIT trap then releases only this exact generation.
  # An INT/TERM handler that merely unlocked and returned could let mutation
  # continue after forfeiting ownership.
  trap 'sp_unlock' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! sp_mutation_targets_are_safe; then
    echo "stitchpad: refusing non-regular or symlinked mutation target" >&2
    sp_unlock
    return 1
  fi
  # Reconcile only after acquiring the same generation-owned mutation lock
  # used by writers. A passive sp_init_paths call can never consume .ready.
  if ! sp_recover_inplace "$PAD_MD" || ! sp_recover_inplace "$PAD_TASKS"; then
    sp_unlock
    return 1
  fi
  sp_reap_applied_generations "$PAD_MD"
  sp_reap_applied_generations "$PAD_TASKS"
  return 0
}

sp_unlock() {
  # An EXIT trap inherited by command substitution must not release its
  # parent's live lock. Bash 3.2 exposes the nesting level via BASH_SUBSHELL.
  if [ "${BASH_SUBSHELL:-0}" = "${_SP_LOCK_SUBSHELL:-}" ] \
    && [ -n "$_SP_LOCK_DIR" ] && [ -n "$_SP_LOCK_GENERATION" ] && [ -n "$_SP_LOCK_PID" ] \
    && sp_lock_owner_matches "$_SP_LOCK_DIR" "$_SP_LOCK_GENERATION" "$_SP_LOCK_PID"; then
    rm -f "$_SP_LOCK_DIR/owner" 2>/dev/null || true
    rmdir "$_SP_LOCK_DIR" 2>/dev/null || true
  fi
  _SP_LOCK_DIR=""; _SP_LOCK_GENERATION=""; _SP_LOCK_PID=""; _SP_LOCK_SUBSHELL=""
}

# ── Inode-stable rewrites ────────────────────────────────────────────
# EVERY full-file rewrite used to end in `mv tmp pad`, which REPLACES the pad's
# inode. A `tail -f` / `tail -F` watcher then re-opens the new file and replays
# the ENTIRE pad as if it were new — 200 KB and 200+ messages arriving at once,
# every single time anyone ran `task move`. That silently broke live agent
# watchers (the operator's messages went unanswered for hours because the agent
# watching the pad drowned in replayed history and was killed).
#
# The cure is to write back over the SAME file, through the existing inode and
# WITHOUT truncating it first: `dd conv=notrunc` overwrites in place, and the
# file is shortened afterwards only when the new content is genuinely smaller.
# A reader therefore never sees the pad's size go backwards, which matters just
# as much as the inode: `tail` treats a shrink as "file truncated" and rewinds
# to offset 0, replaying everything all over again. Roster edits and task edits
# grow the file, so after this change they produce a delta and nothing more.
#
#   sp_stage <target>            → path to a staging file next to <target>
#   sp_write_inplace <staged> <target>
#       0 = written · 2 = identical, nothing written · 1 = failed, target intact
#   sp_recover_inplace <target>  → replay an interrupted, proven generation
#
# Crash-safety is preserved WITHOUT a rename over the pad. The staged file is a
# complete copy on disk; a generation directory containing the content plus an
# exact owner/checksum manifest is promoted to "<target>.ready" (the pad is never
# the rename destination) and only then copied over the target. If the process
# dies mid-copy, the proven generation survives and the next mutation recovers
# it while holding the same pad lock. A passive command never performs recovery.
sp_stage() {
  local target="${1:-$PAD_MD}"
  mktemp "$(dirname "$target")/.sp-stage.XXXXXX"
}

sp_ready_generation_validate() {
  local ready="$1" target="$2" expected="${3:-}"
  [ -d "$ready" ] || return 1
  python3 - "$ready" "$target" "$expected" <<'PY'
import hashlib, json, os, re, stat, sys
ready, target, expected = sys.argv[1:]
try:
    if not stat.S_ISDIR(os.lstat(ready).st_mode):
        raise ValueError("generation path is not a real directory")
    if os.path.islink(target):
        raise ValueError("target is a symlink")
    if set(os.listdir(ready)) != {"content", "owner"}:
        raise ValueError("unexpected generation contents")
    owner_path = os.path.join(ready, "owner")
    content = os.path.join(ready, "content")
    if not stat.S_ISREG(os.lstat(owner_path).st_mode) or not stat.S_ISREG(os.lstat(content).st_mode):
        raise ValueError("generation files are not regular files")
    with open(owner_path, encoding="utf-8") as handle:
        owner = json.load(handle)
    if set(owner) != {"generation", "pid", "processStart", "command", "target", "size", "sha256"}:
        raise ValueError("unexpected manifest schema")
    if owner["target"] != target or not isinstance(owner["pid"], int):
        raise ValueError("wrong target or pid")
    if not all(isinstance(owner[k], str) and owner[k] for k in ("generation", "processStart", "command", "sha256")):
        raise ValueError("incomplete manifest")
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", owner["generation"]):
        raise ValueError("unsafe generation")
    if expected and owner["generation"] != expected:
        raise ValueError("wrong generation")
    stat = os.stat(content)
    if stat.st_size != owner["size"]:
        raise ValueError("wrong size")
    digest = hashlib.sha256()
    with open(content, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != owner["sha256"]:
        raise ValueError("wrong digest")
except Exception:
    raise SystemExit(1)
print(owner["generation"])
PY
}

sp_ready_owner_is_live() {
  local ready="$1" pid expected_start expected_command started command
  pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$ready/owner" 2>/dev/null || true)"
  expected_start="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("processStart",""))' "$ready/owner" 2>/dev/null || true)"
  expected_command="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("command",""))' "$ready/owner" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$expected_start" ] && [ -n "$expected_command" ] \
    && [ "$started" = "$expected_start" ] && [ "$command" = "$expected_command" ]
}

sp_reap_applied_generations() {
  local target="$1" applied generation
  for applied in "$target.ready.applied."*; do
    [ -d "$applied" ] || continue
    generation="$(sp_ready_generation_validate "$applied" "$target" 2>/dev/null || true)"
    [ -n "$generation" ] || continue
    rm -f "$applied/content" "$applied/owner" 2>/dev/null || true
    rmdir "$applied" 2>/dev/null || true
  done
}

sp_apply_ready_generation() {
  local ready="$1" target="$2" generation="$3" content="$1/content" newsize oldsize applied
  sp_ready_generation_validate "$ready" "$target" "$generation" >/dev/null || return 1
  newsize="$(wc -c < "$content" | tr -d ' ')"
  oldsize="$(wc -c < "$target" 2>/dev/null | tr -d ' ')"; oldsize="${oldsize:-0}"
  if dd if="$content" of="$target" conv=notrunc bs=65536 2>/dev/null; then
    if [ "$newsize" -lt "$oldsize" ]; then
      perl -e 'truncate($ARGV[0], $ARGV[1]) or exit 1' "$target" "$newsize" 2>/dev/null \
        || return 1
    fi
    # Retire the canonical generation atomically before cleanup. A crash before
    # rename leaves a valid replayable generation; a crash after rename leaves
    # only non-blocking applied-generation litter, never malformed `.ready`.
    sp_ready_generation_validate "$ready" "$target" "$generation" >/dev/null || return 1
    applied="$ready.applied.$generation"
    [ ! -e "$applied" ] || return 1
    mv "$ready" "$applied" 2>/dev/null || return 1
    if [ -n "${STITCHPAD_WRITE_TEST_AFTER_RETIRE_BARRIER:-}" ]; then
      local retire_barrier="$STITCHPAD_WRITE_TEST_AFTER_RETIRE_BARRIER" retire_i=0
      printf '%s' ready > "$retire_barrier.ready"
      while [ ! -f "$retire_barrier.release" ] && [ "$retire_i" -lt 500 ]; do
        sleep 0.01; retire_i=$((retire_i + 1))
      done
      [ -f "$retire_barrier.release" ] || return 1
    fi
    rm -f "$applied/content" "$applied/owner" 2>/dev/null || return 1
    rmdir "$applied" 2>/dev/null || return 1
    return 0
  fi
  return 1
}

sp_write_inplace() {
  local staged="$1" target="$2" ready="$2.ready" generation_dir generation owner_tmp
  if [ "${_SP_LOCK_DIR:-}" != "$PAD_STATE/.lock" ] \
    || [ -z "${_SP_LOCK_GENERATION:-}" ] \
    || [ -z "${_SP_LOCK_PID:-}" ] \
    || ! sp_lock_owner_matches "$_SP_LOCK_DIR" "$_SP_LOCK_GENERATION" "$_SP_LOCK_PID"; then
    echo "stitchpad: refusing unlocked in-place write of $(basename "$target")" >&2
    rm -f "$staged" 2>/dev/null || true
    return 1
  fi
  if [ -L "$target" ] || [ -L "$ready" ]; then
    echo "stitchpad: refusing symlinked in-place write path for $(basename "$target")" >&2
    rm -f "$staged" 2>/dev/null || true
    return 1
  fi
  # Never let a broken awk/sed pipeline truncate a live pad to nothing.
  if [ ! -s "$staged" ]; then
    echo "stitchpad: refusing to write an empty $(basename "$target") — staged write produced no content" >&2
    rm -f "$staged" 2>/dev/null
    return 1
  fi
  # No-op guard: identical content means no write, no mtime bump, no watcher
  # event and no commit churn. `task move X <same status>` is now free.
  if [ -f "$target" ] && cmp -s "$staged" "$target"; then
    rm -f "$staged" 2>/dev/null
    return 2
  fi
  [ ! -e "$ready" ] || {
    echo "stitchpad: unresolved write generation already exists for $(basename "$target")" >&2
    rm -f "$staged" 2>/dev/null || true
    return 1
  }
  generation_dir="$(mktemp -d "$(dirname "$target")/.sp-ready.$(basename "$target").XXXXXX")" || return 1
  generation="$(basename "$generation_dir").$(date +%s).${_SP_LOCK_PID}.${RANDOM:-0}"
  mv "$staged" "$generation_dir/content" 2>/dev/null || {
    rmdir "$generation_dir" 2>/dev/null || true
    return 1
  }
  owner_tmp="$generation_dir/.owner"
  python3 - "$generation_dir/content" "$owner_tmp" "$generation" "$_SP_LOCK_PID" \
    "$(sp_process_start "$_SP_LOCK_PID")" "$(sp_process_command "$_SP_LOCK_PID")" "$target" <<'PY' || {
import hashlib, json, os, sys
content, output, generation, pid, started, command, target = sys.argv[1:]
digest = hashlib.sha256()
with open(content, "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
with open(output, "w", encoding="utf-8") as handle:
    json.dump({
        "generation": generation,
        "pid": int(pid),
        "processStart": started,
        "command": command,
        "target": target,
        "size": os.stat(content).st_size,
        "sha256": digest.hexdigest(),
    }, handle, separators=(",", ":"))
PY
    rm -f "$generation_dir/content" "$owner_tmp" 2>/dev/null || true
    rmdir "$generation_dir" 2>/dev/null || true
    return 1
  }
  if ! mv "$owner_tmp" "$generation_dir/owner"; then
    rm -f "$generation_dir/content" "$owner_tmp" 2>/dev/null || true
    rmdir "$generation_dir" 2>/dev/null || true
    return 1
  fi
  mv -n "$generation_dir" "$ready" 2>/dev/null || true
  if [ -d "$generation_dir" ] \
    || ! sp_ready_generation_validate "$ready" "$target" "$generation" >/dev/null; then
    rm -f "$generation_dir/content" "$generation_dir/owner" 2>/dev/null || true
    rmdir "$generation_dir" 2>/dev/null || true
    echo "stitchpad: could not promote owned write generation for $(basename "$target")" >&2
    return 1
  fi
  if [ -n "${STITCHPAD_WRITE_TEST_AFTER_PROMOTION_BARRIER:-}" ]; then
    local barrier="$STITCHPAD_WRITE_TEST_AFTER_PROMOTION_BARRIER" i=0
    printf '%s' ready > "$barrier.ready"
    while [ ! -f "$barrier.release" ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$((i+1)); done
    [ -f "$barrier.release" ] || {
      echo "stitchpad: write test barrier timed out" >&2
      return 1
    }
  fi
  if sp_apply_ready_generation "$ready" "$target" "$generation"; then return 0; fi
  echo "stitchpad: in-place write of $(basename "$target") failed — proven content preserved in $ready" >&2
  return 1
}

sp_recover_inplace() {
  local target="${1:-$PAD_MD}" ready generation
  [ -n "$target" ] || return 0
  ready="$target.ready"
  [ -e "$ready" ] || return 0
  if [ "${_SP_LOCK_DIR:-}" != "$PAD_STATE/.lock" ] \
    || [ -z "${_SP_LOCK_GENERATION:-}" ] \
    || [ -z "${_SP_LOCK_PID:-}" ] \
    || ! sp_lock_owner_matches "$_SP_LOCK_DIR" "$_SP_LOCK_GENERATION" "$_SP_LOCK_PID"; then
    echo "stitchpad: refusing unlocked recovery of $(basename "$target")" >&2
    return 1
  fi
  if [ ! -d "$ready" ]; then
    echo "stitchpad: unowned legacy recovery file for $(basename "$target") left untouched" >&2
    return 1
  fi
  generation="$(sp_ready_generation_validate "$ready" "$target" 2>/dev/null || true)"
  [ -n "$generation" ] || {
    echo "stitchpad: malformed recovery generation for $(basename "$target") left untouched" >&2
    return 1
  }
  if sp_ready_owner_is_live "$ready"; then
    echo "stitchpad: live writer still owns recovery generation for $(basename "$target")" >&2
    return 1
  fi
  echo "stitchpad: recovering interrupted write of $(basename "$target")" >&2
  sp_apply_ready_generation "$ready" "$target" "$generation"
}

# Append a small italic system/presence line to the pad (join/leave, etc.).
# Not a message — no @sender — so it never trips mention detection or the gate.
sp_system() {
  local msg="$1" ts; ts="$(date '+%I:%M %p')"
  printf '\n*%s · %s*\n' "$msg" "$ts" >> "$PAD_MD"
}

# Isolated git wrapper: history of just stitchpad.md, separate from project repo.
sgit() { git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" "$@"; }

# The pad's isolated git ignores everything but the pad file (info/exclude is
# `*` + `!stitchpad.md`). tasks.md and archive/ are pad content too — un-ignore
# them so they are versioned alongside the conversation.
sp_ensure_pad_git_exclude() {
  local ex="$PAD_GIT/info/exclude" pat
  [ -d "$PAD_GIT" ] || return 0
  mkdir -p "$PAD_GIT/info" 2>/dev/null || return 0
  for pat in '!tasks.md' '!archive/' '!archive/**'; do
    grep -Fqx "$pat" "$ex" 2>/dev/null || printf '%s\n' "$pat" >> "$ex"
  done
}

# sp_commit <msg> [path...]  — paths are relative to the pad dir; defaults to
# the pad file. Passing paths lets a task-only or archive-only change commit
# just that file instead of the whole conversation.
#
# Returns 0 when the commit landed or there was verifiably nothing to commit,
# nonzero when a git-backed pad FAILED to record staged changes. Callers that
# interlock durable state with the commit (session registry / pad header) key
# rollback off this status — the old `|| true` tail let a failed commit look
# like success. Pads without a git dir keep the historical no-op success.
sp_commit() {
  local msg="$1"; shift 2>/dev/null || true
  local paths=("$@")
  [ "${#paths[@]}" -eq 0 ] && paths=("$(basename "$PAD_MD")")
  # C4 / H11b: distinguish absent git-dir (benign — no git backing, return 0)
  # from a git-dir that exists but is broken (fatal — config corruption,
  # missing objects, return 1).  rev-parse --git-dir itself exits 128 on a
  # corrupt config, so the original H11b guard returned 0 before cat-file -t
  # HEAD was ever reached.  Check -d first, then let each failure be honest.
  if [ ! -d "$PAD_GIT" ]; then
    return 0  # No git dir at all — benign
  fi
  # H11b: git dir exists — verify it's reachable
  if ! sgit rev-parse --git-dir >/dev/null 2>&1; then
    echo "stitchpad: git repository is broken (rev-parse failed on $PAD_GIT) — commit refused" >&2
    return 1
  fi
  # C5: check HEAD reachability ONLY if HEAD exists.  An unborn HEAD
  # (fresh repo before first commit) is benign — skip so the first commit
  # can proceed.  A repo where HEAD exists but isn't a valid commit is broken.
  if sgit rev-parse --verify HEAD >/dev/null 2>&1; then
    if ! sgit cat-file -t HEAD >/dev/null 2>&1; then
      echo "stitchpad: git repository is broken (HEAD unreachable) — commit refused" >&2
      return 1
    fi
  fi
  [ -f "$PAD_MD" ] || return 0
  if [ "${STITCHPAD_TEST_MODE:-}" = "1" ] && [ -n "${STITCHPAD_TEST_COMMIT_FAIL:-}" ]; then
    return 1
  fi
  sp_ensure_pad_git_exclude
  # N2: a SIGKILLed writer (ours or, historically, an external git process)
  # can leave $PAD_GIT/index.lock behind. Git refuses every future add/commit
  # while it exists, so with no self-heal this becomes a PERMANENT pad wedge
  # ("commit failed... message NOT posted" forever, confirmed by fx3 repro).
  # sgit is not always called under our own sp_lock (watch.sh's periodic
  # auto-commit runs unlocked by design), so a fresh index.lock COULD be a
  # genuinely concurrent writer — never remove on sight. Only break it after
  # an age threshold well beyond any realistic commit duration on this small
  # pad file, and log loudly so a real double-writer bug is still visible.
  local _idxlock="$PAD_GIT/index.lock"
  if [ -f "$_idxlock" ]; then
    local _lock_age now_ts mtime_ts
    now_ts="$(date +%s)"
    mtime_ts="$(stat -f %m "$_idxlock" 2>/dev/null || stat -c %Y "$_idxlock" 2>/dev/null || echo "$now_ts")"
    _lock_age=$(( now_ts - mtime_ts ))
    if [ "$_lock_age" -ge 15 ]; then
      echo "stitchpad: stale git index.lock (age ${_lock_age}s) — breaking to unwedge pad (N2)" >&2
      rm -f "$_idxlock" 2>/dev/null || true
    fi
  fi
  sgit add -A -f -- "${paths[@]}" 2>/dev/null || return 1
  sgit diff --cached --quiet -- "${paths[@]}" 2>/dev/null && return 0
  # H5b: capture HEAD BEFORE the commit attempt.  Use --verify -q to avoid
  # rev-parse polluting stdout with "HEAD" on an unborn HEAD.
  local _head_before=""
  _head_before="$(sgit rev-parse --verify -q HEAD 2>/dev/null || echo "")"
  # RP-2: capture staged blob hashes BEFORE commit for post-commit byte
  # verification.  A hook that keeps the path but replaces content passes
  # Z1 but commits tampered bytes — we verify exact blob match vs HEAD.
  local _rp2_hashes="" _p _ph
  for _p in "${paths[@]}"; do
    _ph="$(sgit ls-files --stage -- "$_p" 2>/dev/null | awk '{print $2}')" || _ph=""
    [ -n "$_ph" ] && _rp2_hashes="${_rp2_hashes}${_p}:${_ph}"$'\n'
  done
  _rp2_hashes="${_rp2_hashes%$'\n'}"
  if sgit commit -q -m "$msg" >/dev/null 2>/dev/null; then
    # C3: commit exited 0, but a pre-commit hook that empties the index
    # makes git produce an EMPTY commit — HEAD advances, index is clean,
    # but our write bytes are in neither HEAD nor HEAD~1.  Journaled
    # callers (lifecycle_commit, rollback) treat rc=0 as success and drop
    # the journal → write permanently lost.
    local _head_after=""
    _head_after="$(sgit rev-parse --verify -q HEAD 2>/dev/null || echo "")"
    # --- Empty-tree guard (success branch) ---
    if [ -n "$_head_before" ] && [ -n "$_head_after" ] && [ "$_head_before" != "$_head_after" ]; then
      if [ -z "$(sgit diff-tree --name-only "${_head_before}" "$_head_after" 2>/dev/null)" ]; then
        echo "stitchpad: commit produced an empty tree (hook may have cleared the index) — write NOT committed" >&2
        return 1
      fi
    fi
    # C5: unborn HEAD — no prior commit. Compare against empty tree.
    if [ -z "$_head_before" ] && [ -n "$_head_after" ]; then
      local _empty_tree=""
      _empty_tree="$(echo -n | sgit hash-object -t tree --stdin 2>/dev/null)" || _empty_tree=""
      if [ -n "$_empty_tree" ] && [ -z "$(sgit diff-tree --name-only "${_empty_tree}" "$_head_after" 2>/dev/null)" ]; then
        echo "stitchpad: first commit produced an empty tree (hook may have cleared the index) — write NOT committed" >&2
        return 1
      fi
    fi
    # Z1: C3-fix bypass — hook can exclude our staged file while leaving
    # an unrelated file in HEAD (diff-tree non-empty, passes empty-tree check).
    # Verify the staged paths specifically appear in HEAD as added/modified.
    if [ -n "$_head_before" ] && [ -n "$_head_after" ] && [ "$_head_before" != "$_head_after" ]; then
      if [ -z "$(sgit diff --name-only --diff-filter=AM "${_head_before}" "${_head_after}" -- "${paths[@]}" 2>/dev/null)" ]; then
        echo "stitchpad: commit succeeded but staged paths NOT in HEAD — write NOT committed (hook may have excluded them)" >&2
        return 1
      fi
    fi
    if [ -z "$_head_before" ] && [ -n "$_head_after" ]; then
      if [ -z "$(sgit diff --name-only --diff-filter=AM "${_empty_tree:-$(echo -n | sgit hash-object -t tree --stdin 2>/dev/null)}" "$_head_after" -- "${paths[@]}" 2>/dev/null)" ]; then
        echo "stitchpad: first commit succeeded but staged paths NOT in HEAD — write NOT committed (hook may have excluded them)" >&2
        return 1
      fi
    fi
    # RP-2: verify exact bytes in HEAD match what we staged before the
    # hook ran.  A hook that keeps the path but replaces content leaves
    # the path in HEAD (Z1 passes) but with tampered content.
    if [ -n "$_rp2_hashes" ]; then
      local _rp2_line _rp2_path _rp2_staged _rp2_head_hash _rp2_ok=1
      while IFS=: read -r _rp2_path _rp2_staged; do
        [ -n "$_rp2_path" ] && [ -n "$_rp2_staged" ] || continue
        _rp2_head_hash="$(sgit ls-tree "$_head_after" -- "$_rp2_path" 2>/dev/null | awk '{print $3}')" || _rp2_head_hash=""
        if [ -n "$_rp2_head_hash" ] && [ "$_rp2_staged" != "$_rp2_head_hash" ]; then
          echo "stitchpad: commit succeeded but staged bytes differ from HEAD for $_rp2_path (hook may have altered content) — write NOT committed" >&2
          _rp2_ok=0
          break
        fi
      done <<< "$_rp2_hashes"
      [ "$_rp2_ok" -eq 1 ] || return 1
    fi
    return 0
  fi
  # H5b: commit failed (exit != 0). Check HEAD moved AND index is clean.
  local _head_after=""
  _head_after="$(sgit rev-parse --verify -q HEAD 2>/dev/null || echo "")"
  if [ -n "$_head_before" ] && [ -n "$_head_after" ] && [ "$_head_before" != "$_head_after" ]; then
    if [ -z "$(sgit diff-tree --name-only "${_head_before}" "$_head_after" 2>/dev/null)" ]; then
      echo "stitchpad: git commit failed but HEAD advanced with an empty tree — write NOT committed" >&2
      return 1
    fi
    # Z1 failure branch: same staged-paths verification
    if [ -z "$(sgit diff --name-only --diff-filter=AM "${_head_before}" "$_head_after" -- "${paths[@]}" 2>/dev/null)" ]; then
      echo "stitchpad: git commit failed but staged paths NOT in HEAD — write NOT committed (hook may have excluded them)" >&2
      return 1
    fi
    sgit diff --cached --quiet -- "${paths[@]}" 2>/dev/null && return 0
  fi
  # C5 failure branch: unborn HEAD, commit rc != 0 but HEAD advanced.
  if [ -z "$_head_before" ] && [ -n "$_head_after" ]; then
    local _empty_tree=""
    _empty_tree="$(echo -n | sgit hash-object -t tree --stdin 2>/dev/null)" || _empty_tree=""
    if [ -n "$_empty_tree" ] && [ -z "$(sgit diff-tree --name-only "${_empty_tree}" "$_head_after" 2>/dev/null)" ]; then
      echo "stitchpad: git commit failed but HEAD advanced with an empty tree (hook on unborn HEAD) — write NOT committed" >&2
      return 1
    fi
    # Z1 failure branch on unborn HEAD
    if [ -z "$(sgit diff --name-only --diff-filter=AM "${_empty_tree}" "$_head_after" -- "${paths[@]}" 2>/dev/null)" ]; then
      echo "stitchpad: git commit failed but staged paths NOT in HEAD (hook on unborn HEAD) — write NOT committed" >&2
      return 1
    fi
    sgit diff --cached --quiet -- "${paths[@]}" 2>/dev/null && return 0
  fi
  # H5b: HEAD didn't move — real failure, write NOT committed.
  return 1
}

# ── Roster parsing (the magic: roster is IN the markdown) ────────────
# Emits "name|adapter|wake|target" per participant from the ```roster fence.
sp_roster() {
  awk '
    /^```roster/ { inblk=1; next }
    /^```/       { inblk=0 }
    inblk {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      n=split(line, f, /[ \t]*\|[ \t]*/)
      if (n>=2) {
        name=f[1]; adapter=f[2];
        # crews annotate models as a 3rd column (name|adapter|MODEL|wake|target)
        # — tolerate it: if col3 is not a wake mode, shift wake/target right.
        # (The ocean-os crew invented this and the strict parser read "push" as
        # a TERMINAL ID, minting a lock literally named push — never again.)
        if (n>=5 && f[3] !~ /^(push|pull)$/) { wake=f[4]; target=f[5] }
        else { wake=(n>=3?f[3]:"pull"); target=(n>=4?f[4]:"-") }
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        print name "|" adapter "|" wake "|" target
      }
    }
  ' "$PAD_MD"
}

# Roster filtered to LIVE sessions: an agent is shown only if its heartbeat
# (alive.<name>, mtime < 90s) is fresh — same liveness rule as sp_any_alive.
# A session that closed without leaving simply stops appearing; no graveyard.
# Operators/humans have no heartbeat and are always kept (they read, not woken).
sp_roster_live() {
  local now; now=$(date +%s)
  sp_roster | while IFS='|' read -r name adapter wake target; do
    [ -n "$name" ] || continue
    local rt; rt="$(cat "$PAD_STATE/runtime.$name" 2>/dev/null || true)"
    if [ "$rt" = "operator" ] || [ "$rt" = "human" ]; then
      printf '%s|%s|%s|%s\n' "$name" "$adapter" "$wake" "$target"; continue
    fi
    local hb="$PAD_STATE/alive.$name" ts
    [ -f "$hb" ] || continue
    ts=$(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null || echo 0)
    [ $(( now - ts )) -lt 90 ] || continue
    printf '%s|%s|%s|%s\n' "$name" "$adapter" "$wake" "$target"
  done
}

# ── Tasks parser (```task blocks) ────────────────────────────────────────
# Each task is a ```task TASK-N fenced block with YAML-like frontmatter and
# a markdown description after the --- separator.
#
# Output: id|title|status|priority|assignee|labels|created
#
# sp_tasks                → all tasks in created order
# sp_tasks --mine <name>  → tasks assigned to <name>
# sp_tasks --status <s>    → tasks with matching status
#
# BACKWARD COMPATIBILITY: tasks are read from the pad AND from the sibling
# tasks.md. Old pads with inline ```task blocks keep working with no migration;
# new tasks are written to tasks.md. tasks.md is read LAST so a migrated card
# wins over a stale inline copy of the same id (the parser is last-wins).
sp_task_files() {
  local out=("$PAD_MD")
  [ -n "${PAD_TASKS:-}" ] && [ -f "$PAD_TASKS" ] && out+=("$PAD_TASKS")
  printf '%s\n' "${out[@]}"
}

# Which file holds <id>? tasks.md wins. Prints the path, or fails if unknown —
# so `task move` on a typo'd id errors instead of rewriting the whole pad.
sp_task_file() {
  local id="$1" f
  for f in "${PAD_TASKS:-}" "$PAD_MD"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if awk -v tid="$id" '$1=="```task" && $2==tid { found=1; exit } END { exit !found }' "$f"; then
      printf '%s' "$f"; return 0
    fi
  done
  return 1
}

sp_tasks() {
  local filter_name="" filter_status=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mine)   filter_name="$2"; shift 2 ;;
      --status) filter_status="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local _tf=(); while IFS= read -r _f; do _tf+=("$_f"); done < <(sp_task_files)
  awk -v fn="$filter_name" -v fs="$filter_status" '
    BEGIN { id=""; title=""; status=""; priority=""; assignee=""; labels=""; created=""; desc="" }
    # multiple inputs (pad + tasks.md): never let an unterminated block in one
    # file bleed into the next
    FNR==1                           { inblk=0; meta=0; id="" }
    /^```task /                      { inblk=1; meta=1; id=$2; gsub(/^ *| *$/,"",id); title=""; status="todo"; priority="none"; assignee=""; labels=""; created=""; desc="" }
    /^```$/ && inblk                 { inblk=0; if (id!="") {
      # duplicate blocks (compact-carried copies, re-posts): LAST occurrence wins
      if (!(id in seen)) { order[++nord]=id; seen[id]=1 }
      data[id] = id "|" title "|" status "|" priority "|" assignee "|" labels "|" created "|" substr(desc, 1, 240)
      fa[id]=assignee; fst[id]=status; id="" } }
    inblk && /^---/                   { meta=0; next }
    inblk && !meta && !/^```/ {
      line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line != "") desc = (desc == "" ? line : desc " / " line)
    }
    inblk && meta && !/^```/ {
      line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line ~ /^title:/)    { gsub(/^title: */, "", line); title=line }
      if (line ~ /^status:/)   { gsub(/^status: */, "", line); status=line }
      if (line ~ /^priority:/) { gsub(/^priority: */, "", line); priority=line }
      if (line ~ /^assignee:/) { gsub(/^assignee: */, "", line); assignee=line }
      if (line ~ /^labels:/)   { gsub(/^labels: */, "", line); labels=line }
      if (line ~ /^created:/)  { gsub(/^created: */, "", line); created=line }
    }
    END { for (i=1; i<=nord; i++) { k=order[i]
      if ((fn=="" || fa[k]==fn) && (fs=="" || fst[k]==fs)) print data[k] } }
  ' "${_tf[@]}"
}

# Create tasks.md (with its header) if it does not exist yet. Callers hold the lock.
sp_ensure_tasks_file() {
  [ -n "${PAD_TASKS:-}" ] || return 1
  [ -f "$PAD_TASKS" ] && return 0
  cat > "$PAD_TASKS" <<'TASKSEOF'
# 📋 tasks

> Task cards for this pad, split out of the conversation so that creating or
> moving a ticket no longer rewrites (and re-commits) the whole transcript.
> Format is unchanged: one ```task TASK-N fenced block per ticket.
>
> Legacy inline ```task blocks still in the pad are read too — run
> `stitchpad task migrate` to move them here.

TASKSEOF
}

# Leave ONE pointer in the pad so every reader (and the phone bridge, which only
# ships the pad) knows where the board went. Idempotent: the marker means done.
# Callers hold the lock.
sp_ensure_tasks_pointer() {
  [ -f "$PAD_MD" ] || return 0
  grep -Fq '<!-- tasks:file -->' "$PAD_MD" 2>/dev/null && return 0
  local base tmp
  base="$(basename "$PAD_TASKS")"
  if grep -q '^## Tasks' "$PAD_MD" 2>/dev/null; then
    tmp="$(sp_stage "$PAD_MD")"
    awk -v base="$base" '
      { print }
      !stamped && /^## Tasks/ {
        print ""
        print "<!-- tasks:file -->"
        print "> 📋 Task cards live in `" base "` beside this pad. `stitchpad task list|new|move|edit` reads and writes there, so a ticket update no longer rewrites this conversation. Legacy task blocks left below are still read."
        stamped=1
      }
    ' "$PAD_MD" > "$tmp"
    sp_write_inplace "$tmp" "$PAD_MD"
  else
    # No Tasks section: append (cheap, tail-safe — an append never moves bytes
    # a watcher already read).
    {
      printf '\n## Tasks\n\n<!-- tasks:file -->\n'
      printf '> 📋 Task cards live in `%s` beside this pad. `stitchpad task list|new|move|edit` reads and writes there.\n' "$base"
    } >> "$PAD_MD"
  fi
  return 0
}

# Look up one field for a user. sp_user_field <name> <adapter|wake|target>
sp_user_field() {
  local who="$1" field="$2"
  sp_roster | awk -F'|' -v w="$who" -v f="$field" '
    tolower($1)==tolower(w) {
      if (f=="adapter") print $2;
      else if (f=="wake") print $3;
      else if (f=="target") print $4;
      exit
    }'
}

sp_user_exists() { [ -n "$(sp_user_field "$1" adapter)" ]; }

# ── @mention detection ───────────────────────────────────────────────
# Count lines in the pad addressed TO <name> (a line starting with @name). Used
# by the watcher to detect when a NEW mention has landed (count went up).
sp_count_to() {
  local who="$1" file="${2:-$PAD_MD}" n
  # @all is a broadcast — it counts as a mention TO everyone.
  n=$(grep -icE "(^|[^a-z0-9_-])@(${who}|all)([^a-z0-9_-]|$)" "$file" 2>/dev/null) || true
  echo "${n:-0}"
}

# Extract the latest message block addressed to <name>: from the last "## "
# header owning an @name mention, up to the next "## " header. Mentions can be
# inline ("dale @larry ..."), but must respect handle boundaries.
sp_latest_to() {
  local who="$1"
  local since="${2:-0}"  # skip mentions with ordinal <= since (FIFO cursor)
  awk -v who="$who" -v since="$since" '
    BEGIN { mention = "(^|[^a-z0-9_-])@" tolower(who) "([^a-z0-9_-]|$)" }
    # Only authored blocks (## @...) are candidates. Anonymous blocks like
    # ## Tasks or ## Summary are never wake sources. Track author for self-skip.
    /^## / {
      if (last && !end) end=NR-1
      sub_start=NR
      # Extract author: "## @name" blocks are authored; all others are anonymous.
      if ($2 ~ /^@/) { a=$2; sub(/^@/,"",a); author=tolower(a); n++ }
      else           { author="" }
    }
    { lines[NR]=$0 }
    # FIFO: find first block authored by someone ELSE mentioning <who>
    # with ordinal > since. Never overwrite — the wake cursor steps one
    # ordinal per delivery instead of jumping to the newest.
    !last && author != "" && author != tolower(who) && tolower($0) ~ mention && n > since {
      last=sub_start; end=0
    }
    END { if (!end) end=NR; if (last) for (i=last;i<=end;i++) print lines[i] }
  ' "$PAD_MD"
}

# Print one authored message block by its authored-block ordinal.  Delivery
# state uses this ordinal rather than a byte offset so an append-only pad can be
# re-read after a watcher/worker restart without persisting untrusted body text
# in .state.  Anonymous headings do not consume an ordinal, matching
# sp_engagement.
sp_message_ordinal() {
  local want="$1"
  awk -v want="$want" '
    /^## / {
      if (emit) exit
      if ($2 ~ /^@/) {
        n++
        if (n == want) emit=1
      }
    }
    emit { print }
  ' "$PAD_MD"
}

# Return the newest currently-unanswered directive for <who> after <since> as:
#   ordinal|sender|stable-message-id|first-TASK-N-or--
#
# Push delivery intentionally coalesces to current work instead of replaying an
# unbounded FIFO after a worker was offline.  Per-sender reply tracking keeps a
# reply to Alice from hiding Bob's newer unresolved directive.  Silent acks,
# fenced/code mentions, self-mentions and handle-boundary rules mirror the
# engagement gate.  The stable id binds the ordinal to the exact message bytes,
# so compaction/rewrite drift is rejected before adapter submission.
sp_current_to_meta() {
  local who="$1" since="${2:-0}" agents raw ordinal sender block checksum task
  agents="$(sp_roster 2>/dev/null | cut -d'|' -f1 | tr 'A-Z' 'a-z' | paste -sd, -)"
  raw="$(awk -v who="$(printf '%s' "$who" | tr 'A-Z' 'a-z')" -v agents="$agents" -v since="$since" '
    function body_mentions(name,   re) {
      re="(^|[ \t])@(" name "|all)([^a-z0-9_-]|$)"
      return (buf ~ re)
    }
    function record_replies(   count,tokens,i,t,name) {
      count=split(buf, tokens, /[ \t\n]+/)
      for (i=1; i<=count; i++) {
        t=tolower(tokens[i])
        if (t ~ /^@[a-z0-9_-]+/) {
          name=substr(t, 2)
          sub(/[^a-z0-9_-].*$/, "", name)
          if (name != "" && name != "all" && name != who) reply[name]=n
        }
      }
    }
    function flush() {
      if (author == "") return
      n++
      if (author == who) {
        if (silent || buf ~ /(^|[ \t])@[a-z0-9_-]/) record_replies()
      } else if (!silent && n > since && body_mentions(who)) {
        mention[author]=n
      }
    }
    /^## @/ {
      flush()
      a=$2; sub(/^@/, "", a); author=tolower(a)
      buf=""; silent=0; seen_body=0; infence=0
      next
    }
    /^[[:space:]]*```/ { infence=!infence; next }
    infence { next }
    !seen_body && /[^[:space:]]/ {
      seen_body=1
      b=tolower($0); sub(/^[ \t]*/, "", b)
      n_at=0; tmp=b
      while (match(tmp, /@[a-z0-9_-]+/)) { n_at++; tmp=substr(tmp, RSTART+RLENGTH) }
      sub(/^(@[a-z0-9_-]+[ \t]*)+/, "", b); sub(/[ \t]+$/, "", b)
      if (n_at < 2) {
        if (b ~ /^(\.|\[ack\])/) silent=1
        if (index("," agents ",", "," author ",") > 0 && b ~ /^(ack|read|noted|got it|standing down|standing by|stand by|will do|understood|done here|copy|sounds good)[. !]*$/) silent=1
      }
    }
    { line=tolower($0); gsub(/`[^`]*`/, " ", line); buf=buf " " line }
    END {
      flush()
      best=0; best_sender=""
      for (s in mention) {
        if (mention[s] > reply[s] && mention[s] > best) {
          best=mention[s]; best_sender=s
        }
      }
      if (best > 0) print best "|" best_sender
    }
  ' "$PAD_MD")"
  [ -n "$raw" ] || return 1
  IFS='|' read -r ordinal sender <<< "$raw"
  block="$(sp_message_ordinal "$ordinal")"
  [ -n "$block" ] || return 1
  checksum="$(printf '%s' "$block" | cksum | awk '{print $1}')"
  task="$(printf '%s\n' "$block" | grep -oE 'TASK-[0-9]+' | head -1 || true)"
  [ -n "$task" ] || task="-"
  printf '%s|%s|m%s-%s|%s\n' "$ordinal" "$sender" "$ordinal" "$checksum" "$task"
}

# Engagement gate derived from pad CONTENT, not git commit subjects. The watch.sh
# daemon auto-commits the pad as "update (HH:MM:SS)", which clobbers the authored
# "<name>: <text>" subject the old gate relied on — so git subjects are unreliable.
# The markdown is ground truth. Walks "## @author · time" blocks in order:
#   - a block authored by someone ELSE that @-mentions me  → a mention TO me
#   - a block authored by ME that @-mentions anyone else   → an addressed reply
# Prints "<first_open_mention_ordinal> <mention_sender> <last_reply_ordinal>
# <reply_target>" (0 if none). The scan is two-phase: it buffers every block,
# then returns the first mention after `since` that is NOT answered — a reply
# suppresses only the mentions from its target sender that predate it, so later
# mentions from other senders always deliver FIFO (never starved behind an
# already-answered oldest mention). Author-skip is built in: my own blocks never
# count as mentions to me, killing the self-ack loop too.
# Silent-ack convention: a block whose first content line starts with "." or "[ack]"
# is invisible to the gate — it neither wakes a mentioned target nor counts as an
# addressed reply. Lets agents post acknowledgements/status without costing anyone a
# wake. Sender opt-in, no content guessing.
sp_engagement() {
  local who="$1"
  local since="${2:-0}"  # skip mentions with ordinal <= since (FIFO cursor)
  local raw="${3:-}"     # non-empty: old forward-scan semantics — return the
                         # first mention > since even when an addressed reply
                         # closed it (reset --redeliver validation needs to
                         # distinguish "answered" from "not open")
  # roster names, for the implicit-silent word list below: only AGENT authors get
  # their bare "ack"/"noted" posts silenced. A human operator typing "@pi ack"
  # means "wake pi" — guessing it silent made operator pings vanish (the pi bug).
  local agents
  agents="$(sp_roster 2>/dev/null | cut -d'|' -f1 | tr 'A-Z' 'a-z' | paste -sd, -)"
  awk -v who="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" -v agents="$agents" -v since="$since" -v raw="$raw" '
    # An ADDRESS is "@name" at line-start or after whitespace — NOT after punctuation
    # like / ` " (), so a quoted/referenced "@name" (e.g. "the @john/@dale discussion")
    # or a backticked `@name` does not count as addressing someone. buf joins lines with
    # a leading space, so (^|[ \t]) covers block-start, every line-start, and mid-sentence.
    function body_mentions(name,   re) { re="(^|[ \t])@(" name "|all)([^a-z0-9_-]|$)"; return (buf ~ re) }
    # flush() buffers per-block metadata (author/silent/body) so the END scan
    # runs with COMPLETE reply knowledge: a forward-only pass cannot know about
    # a reply that appears AFTER the mention it answers.
    function flush(   i, n_tok, t, name, block_target) {
      if (author=="") return
      n++
      b_auth[n]=author; b_silent[n]=silent; b_buf[n]=buf
      if (author==who) {                                          # my own block:
        if (silent || buf ~ /(^|[ \t])@[a-z0-9_-]/) {           # a silent ack OR a real @-address reply
          last_reply=n                                           # newest reply ordinal
          # Extract every @target of this reply. PORTABLE: no gawk
          # match()-with-array; uses substr + sub. ORDINAL loop, NOT `for (i in
          # tokens)`: hash-order iteration visits token 2 first and the old
          # `if (i > 20) break` compared STRINGS ("2" > "20" is true), so only
          # token 2 was ever examined — reply_target stayed empty for any reply
          # whose @target was not the second word (Defect A). Per-sender map:
          # reply[target] = newest reply ordinal, so a reply suppresses ONLY
          # the mentions from that target sender that predate it (Defect B).
          n_tok=split(buf, tokens, /[ \t\n]+/)
          for (i=1; i<=n_tok && i<=20; i++) {
            t=tolower(tokens[i])
            if (t ~ /^@[a-z0-9_-]+/) {
              name=substr(t, 2)
              sub(/[^a-z0-9_-].*$/, "", name)
              if (name != "" && name != "all" && name != who) {
                reply[name]=n
                if (block_target == "") block_target=name
              }
            }
          }
          # reply_target = first @target of the newest reply block that has one
          # (old output semantics preserved; the wake gate same-sender check
          # is now belt-and-suspenders — the END scan only returns open mentions,
          # so it can never misfire on one).
          if (block_target != "") reply_target=block_target
        }
      }
    }
    /^## @/ {
      flush()
      a=$2; sub(/^@/,"",a); author=tolower(a); buf=""; silent=0; seen_body=0; infence=0
      next
    }
    # A fenced code block (``` toggles) is never an address — doctor output, diffs and
    # code paste "@name" listings (e.g. "✓ @dale — healthy") must not wake anyone. The
    # fence lines themselves and their contents are excluded from the mention buffer.
    /^[[:space:]]*```/ { infence = !infence; next }
    infence { next }
    # first non-empty content line decides silent-ack (leading "." or "[ack]")
    !seen_body && /[^[:space:]]/ {
      seen_body=1
      b=tolower($0); sub(/^[ \t]*/,"",b)
      # count @mentions before stripping; 2+ means broadcast — never silent
      n_at=0; tmp=b; while (match(tmp,/@[a-z0-9_-]+/)) { n_at++; tmp=substr(tmp,RSTART+RLENGTH) }
      sub(/^(@[a-z0-9_-]+[ \t]*)+/,"",b); sub(/[ \t]+$/,"",b)
      if (n_at < 2) {
        if (b ~ /^(\.|\[ack\])/) silent=1   # explicit opt-in: silent for anyone
        # implicit word-list: agents only — an operator addressing an agent always wakes it
        if (index("," agents ",", "," author ",") > 0 && b ~ /^(ack|read|noted|got it|standing down|standing by|stand by|will do|understood|done here|copy|sounds good)[. !]*$/) silent=1
      }
    }
    # Strip inline code (`...`) before appending to buffer — prevents `@name` in code
    # snippets from counting as an address. Real addresses survive because only the
    # backtick-delimited content is blanked, not the surrounding text.
    { line = tolower($0); gsub(/`[^`]*`/, " ", line); buf = buf " " line }
    END {
      flush()
      # FIFO scan with complete per-sender reply knowledge. A reply suppresses
      # ONLY the mentions from its target sender that predate it (reply[sender]
      # > k). A mention posted AFTER my reply to that sender, and any mention
      # from a sender I never replied to, stays open — so later mentions from
      # other senders always deliver instead of starving behind an
      # already-answered oldest mention (Defect B). raw mode keeps the old
      # forward-scan contract (first mention > since, answered or not) for
      # reset --redeliver validation.
      for (k = 1; k <= n; k++) {
        if (k <= since) continue
        if (b_auth[k] == who) continue
        if (b_silent[k]) continue
        if (b_buf[k] !~ "(^|[ \t])@(" who "|all)([^a-z0-9_-]|$)") continue
        if (raw == "" && (b_auth[k] in reply) && (reply[b_auth[k]] > k)) continue
        last_mention = k; mention_sender = b_auth[k]
        break
      }
      print (last_mention+0) " " (mention_sender) " " (last_reply+0) " " (reply_target)
    }
  ' "$PAD_MD"
}

# Return a stable identity for one exact, currently-open mention ordinal.
# Empty/nonzero means the ordinal is absent, already answered by the same
# sender, or malformed.  The digest binds reset recovery provenance to the
# exact authored block rather than merely to a reusable numeric cursor.
sp_open_mention_identity() {
  local who="$1" ordinal="$2" engagement open sender last_reply reply_target block digest
  case "$ordinal" in ''|0|0[0-9]*|*[!0-9]*) return 1;; esac
  [ "${#ordinal}" -le 9 ] || return 1
  engagement="$(sp_engagement "$who" "$((ordinal - 1))")"
  read -r open sender last_reply reply_target <<<"$engagement"
  [ "${open:-0}" = "$ordinal" ] || return 1
  if [ "${last_reply:-0}" -gt "$ordinal" ] 2>/dev/null \
    && [ -n "${sender:-}" ] && [ "${reply_target:-}" = "$sender" ]; then
    return 1
  fi
  block="$(sp_latest_to "$who" "$((ordinal - 1))")"
  [ -n "$block" ] || return 1
  digest="$(printf '%s' "$block" | cksum | awk '{print $1 "-" $2}')"
  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
}

# ── Terminal-identity locks (machine-global) ─────────────────────────
# ONE TERMINAL = ONE (pad, name). ~/.stitchpad-terminals/<surface_id> holds
# "pad_dir|name|epoch" (pad_dir = the .stitchpad dir). join/set-wake CLAIM the
# terminal, heartbeats refresh the claim, leave releases it; wake delivery,
# DM routing and the MCP server all consult it. This is the wall that stops
# two pads from cross-wiring into the same terminal: a terminal freshly bound
# to pad A cannot be claimed by pad B, addressed by pad B's wakes, or used to
# post into pad B, unless the operator explicitly steals it (STITCHPAD_STEAL=1)
# or the old claim goes stale (>300s without a heartbeat).
# migrated machines use ~/.pasture-terminals (stage 2 moves the registry whole);
# until then the legacy dir remains the single source of truth
if [ -d "$HOME/.pasture-terminals" ]; then SP_TERMDIR="$HOME/.pasture-terminals"; else SP_TERMDIR="$HOME/.stitchpad-terminals"; fi
sp_term_surface_of() { # sanitize: a surface is a FILENAME under $SP_TERMDIR
  # — refuse anything that could escape it (flash re-attack recommendation;
  # the mutex mkdir caught "../" only incidentally).
  case "$1" in ''|.|..|*/*|*".."*) return 1 ;; esac
  printf '%s' "$1"
}   # Herdr terminal ids and Ocean session ids are direct targets
# The terminal id of THIS shell's Herdr pane. Herdr exports a pane id, so
# resolve it to the stable terminal id used by roster targets and isolation locks.
# MULTI-PAD (H3): when Herdr can't resolve a surface (non-herdr shell), fall
# back to a session-env identity so the one-terminal-one-pad guard still has a
# stable key instead of silently disabling itself. Session ids are already
# first-class lock targets ("Ocean session ids are direct targets") and are
# used RAW so the guard intersects with roster-target claims.
sp_this_surface() {
  local _s=""
  if [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then
    _s="$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null \
      | sed -n 's/.*"terminal_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi
  if [ -z "$_s" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    # herdr binary absent/unreachable but the pane id is exported: key on the
    # pane id directly (rc7's F3 fix direction). Consistent between join and
    # say inside the same pane; namespaced so it can never alias a term_* id.
    local _p
    _p="$(printf '%s' "$HERDR_PANE_ID" | tr -cd 'A-Za-z0-9._:-' | cut -c1-64)"
    [ -n "$_p" ] && _s="pane-$_p"
  fi
  if [ -z "$_s" ]; then
    local _cand
    for _cand in "${STITCHPAD_SESSION:-}" "${CLAUDE_CODE_SESSION_ID:-}" "${CODEX_SESSION_ID:-}"; do
      # path-clean, bounded, never "." / ".." / hidden
      _cand="$(printf '%s' "$_cand" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
      case "$_cand" in ''|.*) continue ;; esac
      _s="$_cand"; break   # RAW id: Ocean roster targets ARE session ids —
                           # claim and say-guard must key identically
    done
  fi
  printf '%s' "$_s"
  return 0
}
_sp_term_mutex_acquire() { # $1=surface — mkdir mutex for atomic claim (H4)
  local m="$SP_TERMDIR/.mutex.$1" i mnow mtime
  for i in $(seq 1 30); do
    mkdir "$m" 2>/dev/null && return 0
    mnow="$(date +%s)"; mtime="$(stat -f %m "$m" 2>/dev/null || stat -c %Y "$m" 2>/dev/null || echo 0)"
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    # stale-break: a claimant that died mid-claim never wedges the surface
    if [ $((mnow - mtime)) -gt 10 ]; then rm -rf "$m" 2>/dev/null || true; continue; fi
    python3 -c 'import time; time.sleep(0.1)' 2>/dev/null || sleep 1
  done
  return 1
}
_sp_term_mutex_release() { rm -rf "$SP_TERMDIR/.mutex.$1" 2>/dev/null || true; }
# A claim line is "pad|name|epoch[|owner_pid|owner_start]". The 3-field form is
# the legacy shape; the 5-field form lets a steal attempt distinguish a DEAD
# owner (heartbeat gap → claim is fair game) from a LIVE one whose heartbeat
# merely hiccuped (rc7 F4: timestamp-only steal evicts live owners).
# identity-less posting evidence: prints the owning pad and returns 1 when
# $1=name holds a LIVE identity-backed claim in a DIFFERENT pad; else 0.
# Fresh index entries whose surface claim is mid-rotation (missing) also
# count; stale entries are residue and never block.
sp_term_byname_check() { # $1=name
  local bk bf bpad bsurf bts now
  bk="$(_sp_term_byname_key "$1")" || return 0
  bf="$SP_TERMDIR/.byname.$bk"
  [ -f "$bf" ] || return 0
  IFS='|' read -r bpad bsurf bts < "$bf"
  [ -n "$bpad" ] && [ -n "$bsurf" ] || return 0
  [ "$bpad" = "$PAD_DIR" ] && return 0
  now="$(date +%s)"
  case "$bts" in ''|*[!0-9]*) bts=0 ;; esac
  if _sp_term_claim_honored "$(cat "$SP_TERMDIR/$bsurf" 2>/dev/null)"; then
    printf '%s' "$bpad"
    return 1
  fi
  if [ ! -f "$SP_TERMDIR/$bsurf" ] && [ $((now - bts)) -lt 300 ]; then
    printf '%s' "$bpad"
    return 1
  fi
  return 0
}

_sp_term_claim_honored() { # $1=claim-line → 0 if the claim must still be honored
  local pad name ts pid pstart now
  IFS='|' read -r pad name ts pid pstart <<<"$1"
  now="$(date +%s)"
  [ $((now - ${ts:-0})) -lt 300 ] && return 0
  # Stale timestamp: honor the claim anyway when the recorded owner process is
  # demonstrably alive (kill -0 + start-time match against pid reuse). A claim
  # with no owner identity (legacy 3-field) falls back to timestamp-only.
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -n "$pstart" ]; then
    [ "$(sp_process_start "$pid" 2>/dev/null)" = "$pstart" ] || return 1
  fi
  return 0
}
# Reverse name index (MP-2 fail-closed evidence): identity-shaped claims also
# record $SP_TERMDIR/.byname.<name> = "pad|surface|epoch". A shell with NO
# resolvable identity (env cleared — the trivial MP-2 bypass) consults this
# index before posting: a LIVE identity-backed claim for the same name in a
# DIFFERENT pad is positive ghost-post evidence and refuses. Only
# IDENTITY-SHAPED surfaces index (herdr term_* ids, pane- fallbacks, session
# ids/uuids) — arbitrary routing labels ("target-123", fixture names) do not,
# so sequential same-name fixture moves stay legal.
_sp_term_byname_key() { # $1=name → sanitized key (empty if unusable)
  local k
  k="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  case "$k" in ''|.*) return 1 ;; esac
  printf '%s' "$k"
}
_sp_term_surface_is_identity() { # $1=surface → 0 if identity-shaped
  case "$1" in
    term_[0-9a-fA-F]*)           return 0 ;;  # herdr terminal id
    pane-*)                       return 0 ;;  # pane-id fallback
    ????????-????-????-????-*)    return 0 ;;  # session-id / uuid roster target
  esac
  return 1
}
_sp_term_byname_write() { # $1=surface $2=name (best-effort; identity-shaped only)
  _sp_term_surface_is_identity "$1" || return 0
  local bk
  bk="$(_sp_term_byname_key "$2")" || return 0
  printf '%s|%s|%s' "$PAD_DIR" "$1" "$(date +%s)" > "$SP_TERMDIR/.byname.$bk" 2>/dev/null
}
_sp_term_byname_drop() { # $1=name — remove only if the entry is ours
  local bk bf bpad bsurf bts
  bk="$(_sp_term_byname_key "$1")" || return 0
  bf="$SP_TERMDIR/.byname.$bk"
  if [ -f "$bf" ]; then
    IFS='|' read -r bpad bsurf bts < "$bf"
    [ "$bpad" = "$PAD_DIR" ] && rm -f "$bf"
  fi
  return 0
}

sp_term_lock_claim() { # $1=target/surface $2=name [$3=owner_pid] — refuses on a live foreign claim
  local surface who opid cur pad name ts now
  surface="$(sp_term_surface_of "$1")"; who="$2"; opid="${3:-}"
  [ -n "$surface" ] && [ "$surface" != "-" ] || return 0
  case "$opid" in ''|*[!0-9]*) opid="" ;; esac
  [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null && opid=""
  mkdir -p "$SP_TERMDIR"
  # H4: the check-then-write below is only safe under the per-surface mutex;
  # without it two pads claiming one surface concurrently both pass the check
  # and both write (TOCTOU double-claim). Failure to take the mutex fails
  # CLOSED — a claim that might not be exclusive must never succeed silently.
  _sp_term_mutex_acquire "$surface" || {
    echo "stitchpad: REFUSED — could not take the terminal-claim mutex for $surface (contention); retry." >&2
    return 1
  }
  cur="$(cat "$SP_TERMDIR/$surface" 2>/dev/null || true)"
  if [ -n "$cur" ]; then
    IFS='|' read -r pad name ts <<<"$cur"
    if { [ "$pad" != "$PAD_DIR" ] || [ "$name" != "$who" ]; } \
       && _sp_term_claim_honored "$cur" && [ "${STITCHPAD_STEAL:-0}" != "1" ]; then
      _sp_term_mutex_release "$surface"
      echo "stitchpad: REFUSED — terminal $surface is live as @$name in $pad. One terminal = one pad. 'stitchpad leave $name' there first, or STITCHPAD_STEAL=1 to take it over." >&2
      return 1
    fi
  fi
  if [ -n "$opid" ]; then
    printf '%s|%s|%s|%s|%s' "$PAD_DIR" "$who" "$(date +%s)" "$opid" \
      "$(sp_process_start "$opid" 2>/dev/null)" > "$SP_TERMDIR/$surface"
  else
    printf '%s|%s|%s' "$PAD_DIR" "$who" "$(date +%s)" > "$SP_TERMDIR/$surface"
  fi
  _sp_term_mutex_release "$surface"
  _sp_term_byname_write "$surface" "$who"
  return 0
}
sp_term_lock_touch() { # heartbeat path: refresh ours / claim vacant — NEVER steal
  local surface who cur pad name ts pid pstart
  surface="$(sp_term_surface_of "$1")"; who="$2"
  [ -n "$surface" ] && [ "$surface" != "-" ] || return 0
  cur="$(cat "$SP_TERMDIR/$surface" 2>/dev/null || true)"
  if [ -n "$cur" ]; then
    IFS='|' read -r pad name ts pid pstart <<<"$cur"
    { [ "$pad" = "$PAD_DIR" ] && [ "$name" = "$who" ]; } || return 0
  fi
  mkdir -p "$SP_TERMDIR"
  # preserve owner identity across refreshes (never downgrade a 5-field claim)
  if [ -n "${pid:-}" ]; then
    printf '%s|%s|%s|%s|%s' "$PAD_DIR" "$who" "$(date +%s)" "$pid" "${pstart:-}" > "$SP_TERMDIR/$surface"
  else
    printf '%s|%s|%s' "$PAD_DIR" "$who" "$(date +%s)" > "$SP_TERMDIR/$surface"
  fi
  _sp_term_byname_write "$surface" "$who"
  return 0
}
sp_term_lock_release() { # drop every claim this (pad, name) holds
  local who="$1" f pad name ts
  for f in "$SP_TERMDIR"/*; do
    [ -f "$f" ] || continue
    IFS='|' read -r pad name ts < "$f"
    [ "$pad" = "$PAD_DIR" ] && [ "$name" = "$who" ] && rm -f "$f"
  done
  _sp_term_byname_drop "$who"
  return 0
}
sp_term_lock_check() { # $1=target $2=name → 0 ok; 1 = LIVE claim by someone else (prints holder)
  local surface who cur pad name ts now
  surface="$(sp_term_surface_of "$1")"; who="$2"
  [ -n "$surface" ] && [ "$surface" != "-" ] || return 0
  cur="$(cat "$SP_TERMDIR/$surface" 2>/dev/null || true)"; [ -n "$cur" ] || return 0
  IFS='|' read -r pad name ts <<<"$cur"
  # honored = fresh timestamp OR live owner process (rc7 F4); neither → expired
  _sp_term_claim_honored "$cur" || return 0
  if [ "$pad" != "$PAD_DIR" ] || [ "$name" != "$who" ]; then printf '%s' "$cur"; return 1; fi
  return 0
}

# ── Notifications ────────────────────────────────────────────────────
sp_notify() {
  local title="$1" msg="$2" sound="${3:-Glass}"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -message "$msg" -sound "$sound" 2>/dev/null || true
  else
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\" sound name \"$sound\"" 2>/dev/null || true
  fi
}

# ── Watcher lifecycle (singleton) ────────────────────────────────────
# ensure_watcher: called on every stitchpad subcommand exit. Spawns the pad
# watcher (watch.sh) iff (a) any agent heartbeat is fresh AND (b) no watcher
# already holds the singleton lock. Uses mkdir-atomic to guarantee exactly one
# watcher per pad — same pattern as sp_lock() and claims.
#
# Heartbeat freshness: .state/alive.<name> mtime < 90s AND kill -0 pid succeeds.
# Self-exit: watch.sh polls heartbeats and removes the lock + exits when ALL
# heartbeats are stale (all agents' terminals closed).
# Has any agent posted a fresh heartbeat recently?
# MATCHES watch.sh react(): fresh mtime alone counts as alive when pid is empty
# or zero (e.g. pre-ticker pads, corrupted alive files). Only stale mtime means
# dead. This prevents the supervisor from exiting just because heartbeats lack
# a pid field.
sp_any_alive() {
  local now alive heart file pid ts
  now=$(date +%s)
  for heart in "$PAD_STATE"/alive.*; do
    [ -f "$heart" ] || continue
    ts=$(stat -f %m "$heart" 2>/dev/null || stat -c %Y "$heart" 2>/dev/null || echo 0)
    [ $(( now - ts )) -lt 90 ] || continue
    pid=$(grep -o '"pid":[0-9]*' "$heart" 2>/dev/null | head -1 | cut -d: -f2)
    # Fresh heartbeat with no pid still counts as alive (unknown != dead).
    [ -z "$pid" ] && return 0
    # Fresh heartbeat with live pid counts as alive.
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

# Physically delete the corpses the 90s-TTL liveness rules already ignore, so
# .state/ doesn't accumulate a graveyard across sessions. Logic was always
# self-healing (roster/sp_any_alive skip stale mtime); this just reclaims disk.
# Safe to call any time — it only removes things proven dead. Called on join
# and on supervisor exit.
sp_watch_stage_reap() {
  [ -n "${PAD_STATE:-}" ] && [ -d "$PAD_STATE" ] && [ ! -L "$PAD_STATE" ] || return 0
  local now stale f base pid mtime size age observed_mtime observed_size
  now="$(date +%s)"
  stale="$STITCHPAD_WATCH_STAGE_STALE_SECONDS"
  case "$stale" in ''|*[!0-9]*) return 1 ;; esac
  # Publication stages are never runtime authority.  Remove only an exact,
  # bounded regular-file shape whose named publisher PID is dead and whose age
  # exceeds the configured grace.  Symlinks, directories and richer names are
  # preserved as evidence.
  for f in "$PAD_STATE"/.watch-generation.* "$PAD_STATE"/.watch-launcher.* \
           "$PAD_STATE"/.watch-launcher-transfer.* "$PAD_STATE"/.watch-owner.*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    base="${f##*/}"
    printf '%s\n' "$base" | grep -Eq \
      '^\.watch-(generation|launcher|launcher-transfer|owner)\.[0-9]+\.[0-9]+$' \
      || continue
    pid="$(printf '%s\n' "$base" | sed -E \
      's/^\.watch-(generation|launcher|launcher-transfer|owner)\.([0-9]+)\.[0-9]+$/\2/')"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue
    mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$now")"
    size="$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f" 2>/dev/null || echo 999999)"
    case "$mtime:$size" in *[!0-9:]*) continue ;; esac
    [ "$size" -le 4096 ] || continue
    age=$((now - mtime))
    [ "$age" -ge "$stale" ] || continue
    # Re-prove the leaf immediately before unlinking its name.
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    observed_mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo -1)"
    observed_size="$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f" 2>/dev/null || echo -1)"
    [ "$observed_mtime" = "$mtime" ] && [ "$observed_size" = "$size" ] || continue
    rm -f "$f" 2>/dev/null || return 1
  done
  return 0
}

sp_reap_dead() {
  [ -n "${PAD_STATE:-}" ] || return 0
  local now; now=$(date +%s)
  sp_watch_stage_reap || true
  # 1. leftover atomic-write tmp files (.alive.<who>.<pid>) whose rename never
  #    completed — never read by anything, pure litter.
  for f in "$PAD_STATE"/.alive.*; do
    [ -e "$f" ] || continue
    local pid="${f##*.}"
    kill -0 "$pid" 2>/dev/null || rm -f "$f"
  done
  # 1b. abandoned .sp-stage.* files from a rewrite that died before promotion.
  #     Never touches .ready files — those are recoverable content, not litter.
  for f in "$PAD_DIR"/.sp-stage.*; do
    [ -f "$f" ] || continue
    local sts; sts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$now")
    [ $(( now - sts )) -gt 3600 ] && rm -f "$f"
  done
  # 2. presence heartbeats (alive.<name>) gone stale: mtime >90s AND pid dead.
  #    operators/humans have no pid and never expire — leave them.
  for f in "$PAD_STATE"/alive.*; do
    [ -f "$f" ] || continue
    local ts; ts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    [ $(( now - ts )) -lt 90 ] && continue
    local pid; pid=$(grep -o '"pid":[0-9]*' "$f" 2>/dev/null | head -1 | cut -d: -f2)
    [ -z "$pid" ] || [ "$pid" = "0" ] && continue   # unknown/operator → keep
    # Presence metadata is disposable; a ticker lock is not. Its generation
    # protocol alone decides whether an owner/publisher may be stopped.
    kill -0 "$pid" 2>/dev/null || rm -f "$f" 2>/dev/null
  done
  # 3. file-claims whose holder pid is gone (holder line: "<name> <ts> <path>";
  #    no pid recorded, so fall back to staleness — claims older than 1h are dead).
  for d in "$PAD_STATE"/claims/*.d; do
    [ -d "$d" ] || continue
    local cts; cts=$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo 0)
    [ $(( now - cts )) -gt 3600 ] && rm -rf "$d"
  done
  return 0
}

# Is the watcher running? (lock dir exists AND PID alive)
# Diagnostic callers use this non-mutating probe. The operational sibling below
# deliberately reclaims stale locks, so it must never back `status`/`health`.
sp_watcher_alive_readonly() {
  local watch_lock="$PAD_STATE/watch.lock.d" p
  [ ! -L "$PAD_STATE" ] || return 1
  [ ! -L "$watch_lock" ] || return 1
  [ -d "$watch_lock" ] || return 1
  [ ! -L "$watch_lock/pid" ] || return 1
  p="$(cat "$watch_lock/pid" 2>/dev/null || true)"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$p" -gt 0 ] 2>/dev/null || return 1
  kill -0 "$p" 2>/dev/null
}

sp_watch_owner_claim() {
  local lock="$1" generation="$2" pid="$3" started command tmp
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$generation" ] && [ -n "$started" ] && [ -n "$command" ] || return 1
  tmp="$PAD_STATE/.watch-owner.$pid.$RANDOM"
  python3 - "$generation" "$pid" "$started" "$command" "$PAD_MD" > "$tmp" <<'PY'
import json, sys
generation, pid, started, command, pad = sys.argv[1:]
print(json.dumps({
    "generation": generation,
    "pid": int(pid),
    "processStart": started,
    "command": command,
    "pad": pad,
}, separators=(",", ":")))
PY
  # Hard-link publication is atomic and non-overwriting. A contender can never
  # replace a live owner's manifest between validation and fswatch startup.
  [ -d "$lock" ] && [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] \
    && [ -s "$tmp" ] && ln "$tmp" "$lock/owner" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
  rm -f "$tmp" 2>/dev/null || true
  sp_watch_owner_matches "$lock" "$generation" "$pid"
}

sp_watch_generation_write() {
  local lock="$1" generation="$2" tmp="$PAD_STATE/.watch-generation.$$.$RANDOM"
  sp_generation_is_safe "$generation" || return 1
  printf '%s' "$generation" > "$tmp" || return 1
  [ -d "$lock" ] && [ ! -e "$lock/generation" ] && [ ! -L "$lock/generation" ] \
    && ln "$tmp" "$lock/generation" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
  rm -f "$tmp" 2>/dev/null || true
}

sp_watch_launcher_write() {
  local lock="$1" generation="$2" tmp="$PAD_STATE/.watch-launcher.$$.$RANDOM"
  python3 - "$generation" "$PAD_MD" > "$tmp" <<'PY'
import json, os, subprocess, sys
generation, pad = sys.argv[1:]
pid = os.getppid()
def ps(field):
    return subprocess.check_output(
        ["ps", "-p", str(pid), "-o", field + "="], text=True
    ).strip()
print(json.dumps({
    "generation": generation,
    "pid": pid,
    "processStart": ps("lstart"),
    "command": ps("command"),
    "pad": pad,
}, separators=(",", ":")))
PY
  [ -d "$lock" ] && [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] \
    && [ -s "$tmp" ] && ln "$tmp" "$lock/launcher" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
  rm -f "$tmp" 2>/dev/null || true
}

sp_watch_launcher_is_valid() {
  local lock="$1" generation="$2"
  [ -f "$lock/launcher" ] || return 1
  python3 - "$lock/launcher" "$generation" "$PAD_MD" <<'PY'
import json, sys
path, generation, pad = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        owner = json.load(handle)
    assert set(owner) == {"generation", "pid", "processStart", "command", "pad"}
    assert owner["generation"] == generation and owner["pad"] == pad
    assert isinstance(owner["pid"], int) and owner["pid"] > 0
    assert all(isinstance(owner[k], str) and owner[k]
               for k in ("processStart", "command"))
except Exception:
    raise SystemExit(1)
PY
}

sp_watch_launcher_is_live() {
  local lock="$1" pid started command
  sp_watch_launcher_is_valid "$lock" "$(cat "$lock/generation" 2>/dev/null || true)" || return 1
  pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$lock/launcher" 2>/dev/null || true)"
  started="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["processStart"])' "$lock/launcher" 2>/dev/null || true)"
  command="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["command"])' "$lock/launcher" 2>/dev/null || true)"
  sp_process_identity_matches "$pid" "$started" "$command"
}

sp_watch_launcher_transfer_to_pid() {
  local lock="$1" generation="$2" pid="$3" started command tmp
  sp_watch_launcher_is_valid "$lock" "$generation" || return 1
  # Only the exact process recorded as the current launcher may transfer its
  # lease to the just-spawned supervisor.
  python3 - "$lock/launcher" <<'PY' || return 1
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    owner = json.load(handle)
raise SystemExit(0 if owner.get("pid") == os.getppid() else 1)
PY
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$started" ] && [ -n "$command" ] || return 1
  tmp="$PAD_STATE/.watch-launcher-transfer.$$.$RANDOM"
  python3 - "$generation" "$pid" "$started" "$command" "$PAD_MD" > "$tmp" <<'PY'
import json, sys
generation, pid, started, command, pad = sys.argv[1:]
print(json.dumps({
    "generation": generation,
    "pid": int(pid),
    "processStart": started,
    "command": command,
    "pad": pad,
}, separators=(",", ":")))
PY
  [ -d "$lock" ] && [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] \
    && mv "$tmp" "$lock/launcher" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
}

sp_watch_owner_matches() {
  local lock="$1" generation="$2" pid="$3" started command
  [ -f "$lock/owner" ] || return 1
  [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  started="$(sp_process_start "$pid")"
  command="$(sp_process_command "$pid")"
  [ -n "$started" ] && [ -n "$command" ] || return 1
  python3 - "$lock/owner" "$generation" "$pid" "$started" "$command" "$PAD_MD" <<'PY'
import json, sys
path, generation, pid, started, command, pad = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        owner = json.load(handle)
except Exception:
    raise SystemExit(1)
expected = {
    "generation": generation,
    "pid": int(pid),
    "processStart": started,
    "command": command,
    "pad": pad,
}
raise SystemExit(0 if owner == expected else 1)
PY
}

sp_watch_owner_is_valid() {
  local lock="$1" generation="$2"
  [ -f "$lock/owner" ] || return 1
  [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  python3 - "$lock/owner" "$generation" "$PAD_MD" <<'PY'
import json, sys
path, generation, pad = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        owner = json.load(handle)
    assert set(owner) == {"generation", "pid", "processStart", "command", "pad"}
    assert owner["generation"] == generation and owner["pad"] == pad
    assert isinstance(owner["pid"], int) and owner["pid"] > 0
    assert all(isinstance(owner[k], str) and owner[k]
               for k in ("processStart", "command"))
except Exception:
    raise SystemExit(1)
PY
}

sp_watch_lock_remove_generation() {
  local lock="$1" generation="$2" retired
  retired="$(sp_watch_lock_retire_generation "$lock" "$generation")" || return 1
  sp_watch_retired_cleanup "$retired"
}

sp_watch_lock_retire_generation() {
  local lock="$1" generation="$2" retired="$1.retired.$2"
  sp_generation_is_safe "$generation" \
    && [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  [ ! -e "$retired" ] || return 1
  mv "$lock" "$retired" 2>/dev/null || return 1
  printf '%s\n' "$retired"
}

sp_watch_retired_cleanup() {
  local retired="$1"
  rm -f "$retired/owner" "$retired/launcher" "$retired/pid" "$retired/ts" \
    "$retired/heartbeat" "$retired/cancel" "$retired/generation" 2>/dev/null || true
  rmdir "$retired" 2>/dev/null
}

sp_watch_cancel_generation() {
  local lock="$1" generation="$2" tmp="$PAD_STATE/.watch-cancel.$$.$RANDOM"
  sp_generation_is_safe "$generation" \
    && [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  if [ -f "$lock/cancel" ]; then
    [ "$(cat "$lock/cancel" 2>/dev/null || true)" = "$generation" ]
    return
  fi
  printf '%s' "$generation" > "$tmp" || return 1
  [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] \
    && ln "$tmp" "$lock/cancel" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null || true
      [ "$(cat "$lock/cancel" 2>/dev/null || true)" = "$generation" ]
      return
    }
  rm -f "$tmp" 2>/dev/null || true
}

sp_watch_generation_cleanup() {
  local lock="$1" generation="$2"
  sp_generation_is_safe "$generation" \
    && [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  rm -f "$lock/owner" "$lock/launcher" "$lock/pid" "$lock/ts" "$lock/heartbeat" \
    "$lock/cancel" "$lock/generation" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null
}

sp_watch_launcher_matches_pid() {
  local lock="$1" generation="$2" pid="$3" recorded
  sp_watch_launcher_is_valid "$lock" "$generation" || return 1
  recorded="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$lock/launcher" 2>/dev/null || true)"
  [ "$recorded" = "$pid" ] && sp_watch_launcher_is_live "$lock"
}

sp_watch_launcher_lease_is_fresh() {
  local lock="$1" generation="$2" stamp now age
  sp_watch_launcher_is_valid "$lock" "$generation" \
    && sp_watch_launcher_is_live "$lock" || return 1
  stamp="$(cat "$lock/heartbeat" 2>/dev/null || true)"
  case "$stamp" in ''|*[!0-9]*)
    stamp="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)"
    ;;
  esac
  now="$(date +%s)"; age=$((now - stamp))
  [ "$age" -ge 0 ] && [ "$age" -lt "${STITCHPAD_WATCH_RESTART_GRACE:-5}" ]
}

sp_watch_test_barrier_wait() {
  local barrier="$1" label="$2" i=0 limit="${STITCHPAD_WATCH_TEST_BARRIER_TICKS:-500}"
  case "$limit" in ''|*[!0-9]*) limit=500 ;; esac
  printf '%s' ready > "$barrier.ready" || return 1
  while [ ! -f "$barrier.release" ] && [ "$i" -lt "$limit" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -f "$barrier.release" ] && return 0
  echo "stitchpad: $label test barrier timed out" >&2
  return 1
}

sp_watch_empty_lock_reclaim() {
  local lock="$1" now mtime age
  [ -d "$lock" ] || return 1
  [ -z "$(find "$lock" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] || return 1
  now="$(date +%s)"
  mtime="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")"
  age=$((now - mtime))
  [ "$age" -ge "$STITCHPAD_WATCH_START_GRACE" ] || return 1
  rmdir "$lock" 2>/dev/null
}

# Reclaim only the exact crash shape left after singleton acquisition published
# its generation but died before publishing launcher authority.  Richer or
# malformed lock directories remain fail-closed.  Retirement is generation-CAS
# by directory rename, so a resumed stale publisher cannot attach to a newer
# generation and no PID is ever signalled from this ownerless evidence.
sp_watch_generation_only_lock_reclaim() {
  local lock="$1" generation now mtime age only
  [ "$lock" = "$PAD_STATE/watch.lock.d" ] || return 1
  [ ! -L "$PAD_STATE" ] && [ ! -L "$lock" ] || return 1
  [ -d "$lock" ] && [ -f "$lock/generation" ] && [ ! -L "$lock/generation" ] || return 1
  generation="$(cat "$lock/generation" 2>/dev/null || true)"
  sp_generation_is_safe "$generation" || return 1
  only="$(find "$lock" -mindepth 1 -maxdepth 1 -print 2>/dev/null || true)"
  [ "$only" = "$lock/generation" ] || return 1
  now="$(date +%s)"
  mtime="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")"
  age=$((now - mtime))
  [ "$age" -ge "$STITCHPAD_WATCH_START_GRACE" ] || return 2
  [ "$(cat "$lock/generation" 2>/dev/null || true)" = "$generation" ] || return 1
  sp_watch_lock_remove_generation "$lock" "$generation"
}

sp_watcher_alive() {
  local watch_lock="$PAD_STATE/watch.lock.d"
  sp_watch_stage_reap || true
  [ -d "$watch_lock" ] || return 1
  local generation pid observed reclaim_rc
  generation="$(cat "$watch_lock/generation" 2>/dev/null || true)"
  if [ -z "$generation" ]; then
    sp_watch_empty_lock_reclaim "$watch_lock" 2>/dev/null || true
    return 1
  fi
  if ! sp_watch_launcher_is_valid "$watch_lock" "$generation"; then
    sp_watch_generation_only_lock_reclaim "$watch_lock" 2>/dev/null
    reclaim_rc=$?
    [ "$reclaim_rc" -eq 0 ] && return 1
    if [ "$reclaim_rc" -eq 2 ]; then
      echo "stitchpad: watcher admission is still within startup grace" >&2
    else
      echo "stitchpad: malformed or unknown watcher lock left untouched" >&2
    fi
    return 1
  fi
  if [ -f "$watch_lock/owner" ]; then
    if ! sp_watch_owner_is_valid "$watch_lock" "$generation"; then
      echo "stitchpad: malformed watcher owner left untouched" >&2
      return 1
    fi
    pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$watch_lock/owner" 2>/dev/null || true)"
    if sp_watch_owner_matches "$watch_lock" "$generation" "$pid"; then return 0; fi
    # A daemon's exact live launcher may be between child generations. Remove
    # only the stale child proof and preserve that fresh supervisor lease.
    if sp_watch_launcher_lease_is_fresh "$watch_lock" "$generation"; then
      observed="$(cat "$watch_lock/owner" 2>/dev/null || true)"
      [ -n "$observed" ] && [ "$(cat "$watch_lock/owner" 2>/dev/null || true)" = "$observed" ] \
        && rm -f "$watch_lock/owner" "$watch_lock/pid" "$watch_lock/ts" 2>/dev/null || true
      return 0
    fi
    sp_watch_lock_remove_generation "$watch_lock" "$generation" 2>/dev/null || true
    return 1
  fi
  # A valid launcher owns the bounded pre-owner startup or daemon restart gap.
  if sp_watch_launcher_lease_is_fresh "$watch_lock" "$generation"; then return 0; fi
  if ! sp_watch_launcher_is_live "$watch_lock"; then
    sp_watch_lock_remove_generation "$watch_lock" "$generation" 2>/dev/null || true
  else
    echo "stitchpad: live launcher has not published a watcher owner" >&2
  fi
  return 1
}

sp_watch_pairs_for_pad() {
  [ -n "${PAD_MD:-}" ] || return 0
  local pid parent comm command exe args parent_command parent_exe parent_args proven_parent
  # Filter by the kernel-reported executable name first, then require the full
  # command to be exactly `fswatch -0 $PAD_MD`. A process merely containing
  # that text in another argv can never enter the signal candidate set.
  ps -axo pid=,ppid=,comm= | while read -r pid parent comm; do
    [ "${comm##*/}" = "fswatch" ] || continue
    command="$(sp_process_command "$pid")"
    exe="${command%% *}"; args="${command#"$exe"}"; args="${args# }"
    [ "${exe##*/}" = "fswatch" ] && [ "$args" = "-0 $PAD_MD" ] || continue
    proven_parent=0
    if [ "$parent" -gt 1 ] 2>/dev/null; then
      parent_command="$(sp_process_command "$parent")"
      parent_exe="${parent_command%% *}"
      parent_args="${parent_command#"$parent_exe"}"; parent_args="${parent_args# }"
      # Signal a non-PID1 parent only when it is this checkout's exact watch.sh
      # invocation. An unrelated parent never inherits the child's authority.
      if [ "${parent_exe##*/}" = "bash" ] \
        && [ "$parent_args" = "$STITCHPAD_HOME/bin/watch.sh" ]; then
        proven_parent="$parent"
      fi
    fi
    printf '%s %s\n' "$pid" "$proven_parent"
  done
}

sp_watch_processes_for_pad() {
  local child parent
  while read -r child parent; do
    [ -n "$child" ] && printf '%s\n' "$child"
    [ "${parent:-0}" -gt 1 ] 2>/dev/null && printf '%s\n' "$parent"
  done < <(sp_watch_pairs_for_pad)
}

sp_watcher_identity_sha256() {
  local pid="$1" command="$2" exe args comm artifact
  exe="${command%% *}"; args="${command#"$exe"}"; args="${args# }"
  if [ "${exe##*/}" = "fswatch" ] && [ "$args" = "-0 $PAD_MD" ]; then
    comm="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$comm" in /*) artifact="$comm" ;; *) artifact="$(command -v "$exe" 2>/dev/null || true)" ;; esac
  elif [ "${exe##*/}" = "bash" ] && [ "$args" = "$STITCHPAD_HOME/bin/watch.sh" ]; then
    artifact="$STITCHPAD_HOME/bin/watch.sh"
  elif [ "${exe##*/}" = "bash" ] && [ "$args" = "$STITCHPAD_HOME/bin/daemon.sh start" ]; then
    artifact="$STITCHPAD_HOME/bin/daemon.sh"
  else
    return 1
  fi
  [ -f "$artifact" ] || return 1
  python3 - "$artifact" <<'PY'
import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
}

sp_watcher_identity_matches() {
  local pid="$1" expected_start="$2" expected_command="$3" expected_sha="$4" current_sha
  sp_process_identity_matches "$pid" "$expected_start" "$expected_command" || return 1
  current_sha="$(sp_watcher_identity_sha256 "$pid" "$expected_command" 2>/dev/null || true)"
  [ -n "$expected_sha" ] && [ "$current_sha" = "$expected_sha" ]
}

sp_watch_fswatch_parents_for_pad() {
  local child parent
  while read -r child parent; do
    [ "${parent:-0}" -gt 1 ] 2>/dev/null && printf '%s\n' "$parent"
  done < <(sp_watch_pairs_for_pad)
}

sp_stop_delivery_worker() {
  local name="$1" lock="$PAD_STATE/delivery.$1.worker.lock.d" pid token owner command
  local owner_start owner_token owner_pad owner_name live_start born age tries=0
  [ -d "$lock" ] || return 0
  token="$(cat "$lock/token" 2>/dev/null || true)"
  # Mark intent first. A launcher that has created the lock but not yet spawned
  # must observe this and abort; an already-starting worker checks it before and
  # during atomic owner publication.
  : > "$lock/stop-requested" 2>/dev/null || true
  while :; do
    [ -d "$lock" ] || return 0
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    IFS='|' read -r pid owner_start owner_token owner_pad owner_name <<< "$owner"
    if [ -z "$owner_name" ] && [ "$owner_token" = "$PAD_DIR" ] && [ "$owner_pad" = "$name" ]; then
      # Rolling-upgrade compatibility with pid|token|pad|name owners.
      owner_name="$name"; owner_pad="$PAD_DIR"; owner_token="$owner_start"
      owner_start="$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
    fi
    if [ -n "$pid" ] && [ -n "$owner_start" ] && [ "$owner_token" = "$token" ] \
       && [ "$owner_pad" = "$PAD_DIR" ] && [ "$owner_name" = "$name" ]; then
      break
    fi
    born="$(cat "$lock/born" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)"
    age=$(( $(date +%s) - ${born:-0} ))
    tries=$((tries + 1))
    [ "$tries" -lt 200 ] && [ "$age" -lt 5 ] || { pid=""; break; }
    sleep 0.01
  done
  live_start="$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$live_start" = "$owner_start" ] \
     && [[ "$command" == *"--delivery-worker $name $token"* ]]; then
    kill "$pid" 2>/dev/null || true
    # The worker's TERM trap may spend up to five seconds completing one bounded
    # Ocean cancellation request. Let that exact cleanup finish before KILL.
    for _ in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  fi
  [ "$(cat "$lock/token" 2>/dev/null || true)" = "$token" ] && rm -rf "$lock"
}

sp_delivery_ocean_unresolved_after_stop() {
  local name="$1" state pending_adapter submit generation turn_file turn_id result
  state="$(sed -n 's/^state=//p' "$PAD_STATE/delivery.$name.state" 2>/dev/null | tail -1)"
  case "$state" in acceptance_unknown|cancel_pending) return 0;; esac
  pending_adapter="$(cut -d'|' -f6 "$PAD_STATE/delivery.$name.pending" 2>/dev/null || true)"
  [ "$pending_adapter" = ocean ] || return 1
  for submit in "$PAD_STATE"/delivery."$name".submit.*; do
    [ -f "$submit" ] || continue
    generation="${submit##*.submit.}"
    [ -s "$PAD_STATE/delivery.$name.turn.$generation" ] || return 0
  done
  for turn_file in "$PAD_STATE"/delivery."$name".turn.*; do
    [ -s "$turn_file" ] || continue
    turn_id="$(cat "$turn_file" 2>/dev/null || true)"
    result="$(cat "$PAD_STATE/delivery.$name.cancel.$turn_id/result" 2>/dev/null || true)"
    case "$result" in canceled|completed|errored|cancelled) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

sp_stop_delivery_workers() {
  local lock name
  for lock in "$PAD_STATE"/delivery.*.worker.lock.d; do
    [ -d "$lock" ] || continue
    name="${lock##*/delivery.}"; name="${name%.worker.lock.d}"
    sp_stop_delivery_worker "$name"
  done
}

sp_stop_watchers_for_pad() {
  [ -n "${PAD_STATE:-}" ] || return 0
  local watch_lock="$PAD_STATE/watch.lock.d"
  # A scalar list avoids macOS Bash 3.2 treating an empty declared array as an
  # unbound variable under `set -u`.
  local p pids="" records="" started command sha start64 command64 remaining i=0 generation owner_pid launcher_pid reclaim_rc
  sp_watch_stage_reap || true
  # Do not trust a bare PID file: the PID may have been reused. The exact
  # fswatch command path below proves both the fixture child and its live
  # parent relationship before either PID enters the signal list.
  while IFS= read -r p; do
    [ -n "$p" ] && pids="$pids $p"
  done < <(sp_watch_processes_for_pad)
  generation="$(cat "$watch_lock/generation" 2>/dev/null || true)"
  if [ -d "$watch_lock" ] && [ -z "$generation" ]; then
    sp_watch_empty_lock_reclaim "$watch_lock" 2>/dev/null && return 0
    echo "stitchpad: fresh or unknown ownerless watcher lock left untouched for $PAD_MD" >&2
    return 1
  fi
  if [ -d "$watch_lock" ] && ! sp_watch_launcher_is_valid "$watch_lock" "$generation"; then
    sp_watch_generation_only_lock_reclaim "$watch_lock" 2>/dev/null
    reclaim_rc=$?
    [ "$reclaim_rc" -eq 0 ] && return 0
    if [ "$reclaim_rc" -eq 2 ]; then
      echo "stitchpad: watcher admission is still within startup grace for $PAD_MD" >&2
    else
      echo "stitchpad: malformed or unknown watcher lock left untouched for $PAD_MD" >&2
    fi
    return 1
  fi
  if [ -f "$watch_lock/owner" ]; then
    if ! sp_watch_owner_is_valid "$watch_lock" "$generation"; then
      echo "stitchpad: malformed watcher ownership left untouched for $PAD_MD" >&2
      return 1
    fi
    owner_pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$watch_lock/owner" 2>/dev/null || true)"
    if sp_watch_owner_matches "$watch_lock" "$generation" "$owner_pid"; then
      pids="$pids $owner_pid"
    else
      # Valid manifest + identity mismatch proves the recorded watcher is gone.
      # Reclaim its generation below without signaling the reused PID.
      :
    fi
  fi
  if [ -d "$watch_lock" ]; then
    launcher_pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$watch_lock/launcher" 2>/dev/null || true)"
    sp_watch_launcher_is_live "$watch_lock" && pids="$pids $launcher_pid"
  fi

  # Snapshot a full process identity while the exact fswatch child/parent
  # relationship is observable. Numeric PIDs alone are never retained as
  # signal authority across the TERM→KILL window.
  for p in $pids; do
    started="$(sp_process_start "$p")"
    command="$(sp_process_command "$p")"
    sha="$(sp_watcher_identity_sha256 "$p" "$command" 2>/dev/null || true)"
    start64="$(sp_b64_encode "$started")"
    command64="$(sp_b64_encode "$command")"
    [ -n "$started" ] && [ -n "$command" ] && [ -n "$sha" ] \
      && records="${records}${p}|${sha}|${start64}|${command64}"$'\n'
  done

  if [ -n "$generation" ]; then
    # Keep canonical occupied until every exact old-generation process is dead;
    # otherwise a delayed owner link can land in a successor generation.
    sp_watch_cancel_generation "$watch_lock" "$generation" || return 1
  else
    # Only an empty pre-generation startup lock is safe to remove without
    # ownership evidence.
    rmdir "$watch_lock" 2>/dev/null || true
  fi
  while IFS='|' read -r p sha start64 command64; do
    [ -n "$p" ] || continue
    started="$(sp_b64_decode "$start64" 2>/dev/null || true)"
    command="$(sp_b64_decode "$command64" 2>/dev/null || true)"
    sp_watcher_identity_matches "$p" "$started" "$command" "$sha" \
      && kill "$p" 2>/dev/null || true
  done <<< "$records"
  sleep 0.2
  while IFS='|' read -r p sha start64 command64; do
    [ -n "$p" ] || continue
    started="$(sp_b64_decode "$start64" 2>/dev/null || true)"
    command="$(sp_b64_decode "$command64" 2>/dev/null || true)"
    sp_watcher_identity_matches "$p" "$started" "$command" "$sha" \
      && kill -KILL "$p" 2>/dev/null || true
  done <<< "$records"
  # Do not report teardown complete while an exact fixture process is still
  # visible. This also lets init reap a just-killed fswatch child before tests
  # assert zero process residue.
  while [ "$i" -lt 20 ]; do
    remaining="$(sp_watch_processes_for_pad)"
    [ -z "$remaining" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  if [ -n "$generation" ]; then
    sp_watch_generation_cleanup "$watch_lock" "$generation" 2>/dev/null || true
  else
    rmdir "$watch_lock" 2>/dev/null || true
  fi
  [ -z "${remaining:-}" ] && [ ! -d "$watch_lock" ]
}

sp_reap_duplicate_watchers_for_pad() {
  [ -n "${PAD_STATE:-}" ] || return 0
  local watch_lock="$PAD_STATE/watch.lock.d"
  local generation keep="" child parent only_parent="" count=0
  generation="$(cat "$watch_lock/generation" 2>/dev/null || true)"
  if [ -f "$watch_lock/owner" ] && sp_watch_owner_is_valid "$watch_lock" "$generation"; then
    keep="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$watch_lock/owner" 2>/dev/null || true)"
    sp_watch_owner_matches "$watch_lock" "$generation" "$keep" || keep=""
  fi
  # Count exact fswatch children, not merely their proven watch.sh parents.
  # A watch.sh SIGKILL can leave an exact orphan (reported as parent 0); that
  # child is still a duplicate and must force exact teardown/restart.
  while read -r child parent; do
    [ -n "$child" ] || continue
    only_parent="${parent:-0}"; count=$((count + 1))
  done < <(sp_watch_pairs_for_pad)
  [ "$count" -eq 1 ] && [ -n "$keep" ] && [ "$only_parent" = "$keep" ] && return 0
  # No fswatch during the bounded startup/restart phase is healthy when the
  # exact supervisor lease is fresh; do not cancel it based on a missing pid.
  [ "$count" -eq 0 ] && sp_watch_launcher_lease_is_fresh "$watch_lock" "$generation" && return 0

  sp_stop_watchers_for_pad
  return 1
}

ensure_watcher() {
  [ -n "${PAD_DIR:-}" ] || sp_init_paths || return 0
  local watch_lock="$PAD_STATE/watch.lock.d"
  local watch_log="$PAD_STATE/watch.log" watch_generation
  sp_watch_stage_reap || true
  # Only spawn if someone is alive and listening
  sp_any_alive || return 0
  # Already running? Nothing to do.
  if sp_watcher_alive; then
    if sp_reap_duplicate_watchers_for_pad; then
      sleep 0.2
      sp_watcher_alive && return 0
    fi
  fi
  sp_stop_watchers_for_pad
  # ATOMIC acquire: exactly one caller wins.
  if ! mkdir "$watch_lock" 2>/dev/null; then
    # Lost the race. Brief sleep lets winner write its PID, then re-check.
    sleep 0.3
    sp_watcher_alive && return 0
    # Unknown/ownerless contention fails closed; a later ensure can retry after
    # the exact stop path reconciles it.
    return 0
  fi
  if [ -n "${STITCHPAD_WATCH_TEST_AFTER_MKDIR_BARRIER:-}" ]; then
    local watch_mkdir_barrier="$STITCHPAD_WATCH_TEST_AFTER_MKDIR_BARRIER"
    printf '%s' ready > "$watch_mkdir_barrier.ready"
    while [ ! -f "$watch_mkdir_barrier.release" ]; do sleep 0.01; done
  fi
  watch_generation="$(date +%s).$$.${RANDOM:-0}"
  sp_watch_generation_write "$watch_lock" "$watch_generation" || {
    rmdir "$watch_lock" 2>/dev/null || true
    return 0
  }
  if [ -n "${STITCHPAD_WATCH_TEST_AFTER_GENERATION_BARRIER:-}" ]; then
    local watch_generation_barrier="$STITCHPAD_WATCH_TEST_AFTER_GENERATION_BARRIER"
    sp_watch_test_barrier_wait "$watch_generation_barrier" "watch generation" || {
      sp_watch_lock_remove_generation "$watch_lock" "$watch_generation" 2>/dev/null || true
      return 1
    }
  fi
  sp_watch_launcher_write "$watch_lock" "$watch_generation" || {
    sp_watch_lock_remove_generation "$watch_lock" "$watch_generation" 2>/dev/null || true
    return 0
  }
  date -u +%Y-%m-%dT%H:%M:%SZ > "$watch_lock/ts"
  # Spawn the watcher. No trap — the watcher removes the lock on exit.
  ( STITCHPAD_PAD_DIR="$PAD_DIR" STITCHPAD_WATCH_GENERATION="$watch_generation" \
      bash "$STITCHPAD_HOME/bin/watch.sh" >>"$watch_log" 2>&1 ) &
  # The watcher atomically claims owner and publishes its own PID. Until then,
  # ts supplies only a brief startup grace—never signal authority.
  disown %-
  return 0
}

# TASK-7 per-model telemetry (best-effort; never fails a primary operation).
# Must load LAST so every consumer (stitchpad, watch.sh, daemon.sh,
# seat-keeper.sh, tui.sh) gets it without any dependency ordering.
# Self-derive BIN_DIR when a consumer sources lib.sh directly (tests do this
# without exporting BIN_DIR) — telemetry must never break that contract.
_TEL_BIN="${BIN_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [ -f "$_TEL_BIN/telemetry.sh" ]; then
  # shellcheck disable=SC1091
  source "$_TEL_BIN/telemetry.sh"
fi
unset _TEL_BIN
