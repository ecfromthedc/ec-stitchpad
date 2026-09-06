#!/usr/bin/env bash
# recovery-policy.sh — Bounded recovery, rotation, and idempotent reassignment
#
# TASK-4: every recovery path (journal recovery, seat reset, keeper repair,
# watcher restart) gets an explicit bound — attempt counts and time budgets —
# with terminal refusal + surfaced state when exhausted, never unbounded retry.
# Seat rotation and reassignment must be idempotent.
#
# This module is sourced by watch.sh, session-registry.sh, seat-keeper.sh, and
# stitchpad. It provides:
#
#   sp_recovery_attempt_record  STATE_FILE KEY   — record an attempt (incrementing count + timestamp)
#   sp_recovery_attempt_count   STATE_FILE KEY   — print current attempt count for a key
#   sp_recovery_first_attempt   STATE_FILE KEY   — print epoch of first attempt (0 if none)
#   sp_recovery_is_exhausted    STATE_FILE KEY   — return 0 if exhausted (terminal), 1 if budget remains
#   sp_recovery_terminal_refuse WHO PATH KEY     — emit terminal refusal diagnostic to stderr
#   sp_recovery_reset           STATE_FILE KEY   — clear attempt tracking for a key (success/clear)
#
# Bounds (overridable via env):
#   SP_RECOVERY_MAX_ATTEMPTS (default 3)   — max attempts per recovery key
#   SP_RECOVERY_BUDGET_SECONDS (default 120) — time budget from first attempt
#
# Attempt tracking files live in PAD_STATE/recovery-attempts/ as simple
# key|count|first_epoch files, one per recovery key.

# Guard against double-source
[ -n "${_SP_RECOVERY_POLICY_LOADED:-}" ] && return 0
_SP_RECOVERY_POLICY_LOADED=1

_sp_recovery_attempts_dir() {
  printf '%s/recovery-attempts' "${PAD_STATE:-${STITCHPAD_PAD_DIR:-.}/.state}"
}

# E5b: refuse to write counter files into a symlinked recovery-attempts dir
_sp_recovery_safe_mkdir() {
  local dir
  dir="$(_sp_recovery_attempts_dir)"
  # If PAD_STATE itself is a symlink, refuse (journal_begin already checks this,
  # but recovery-policy may be sourced independently)
  [ -L "${PAD_STATE:-${STITCHPAD_PAD_DIR:-.}/.state}" ] && return 1
  if [ -L "$dir" ]; then
    echo "stitchpad: refusing to use symlinked recovery-attempts dir: $dir" >&2
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  # Re-check after mkdir in case of race
  [ -L "$dir" ] && return 1
  return 0
}

# E5c: validate bounds — 0 or junk => default, never instant-wedge
_sp_recovery_effective_max() {
  local v="${SP_RECOVERY_MAX_ATTEMPTS:-3}"
  case "$v" in
    *[!0-9]*|'') printf '%s' "3" ;;  # junk → default
    *) [ "$v" -ge 1 ] 2>/dev/null && printf '%s' "$v" || printf '%s' "3" ;;
  esac
}

_sp_recovery_effective_budget() {
  local v="${SP_RECOVERY_BUDGET_SECONDS:-120}"
  case "$v" in
    *[!0-9]*|'') printf '%s' "120" ;;  # junk → default
    *) [ "$v" -ge 1 ] 2>/dev/null && printf '%s' "$v" || printf '%s' "120" ;;
  esac
}

_sp_recovery_file() {
  local state_file="$1" key="$2"
  # Sanitize key to a safe filename component
  local safe_key
  safe_key="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
  # The once-only refusal marker for a key lives at "<file>.refused" (see
  # sp_recovery_terminal_refuse). '.' survives the sanitizer, so a key whose
  # sanitized form ALREADY ends in .refused would land on another key's marker
  # and silence its diagnostic forever. Mangle that one suffix so the two
  # namespaces provably cannot meet: a counter path never ends in .refused,
  # and a marker path always does.
  case "$safe_key" in
    *.refused) safe_key="${safe_key}_" ;;
  esac
  printf '%s/%s' "$(_sp_recovery_attempts_dir)" "$safe_key"
}

# Record an attempt: increment count, stamp first_epoch if new.
# F3: atomic read-modify-write via kernel-level fcntl.flock. fx3 proved 6/40
# lost increments under concurrency because the bare cat|cut|count|printf>file
# RMW raced. The per-key mkdir-atomic lock was insufficient under high
# contention (timeout at 3s with 40 writers needing ~4s). fcntl.flock is a
# kernel-level mutex: blocking, zero-contention-loss, auto-released on process
# death (no stale-lock cleanup needed). The read-increment-write is performed
# atomically inside the lock in a single Python invocation.
sp_recovery_attempt_record() {
  local state_file="$1" key="$2"
  local dir file
  dir="$(_sp_recovery_attempts_dir)"
  _sp_recovery_safe_mkdir || return 1
  file="$(_sp_recovery_file "$state_file" "$key")"
  # Saturate at the bound rather than counting past it. Once a key is
  # exhausted the count is a VERDICT, not a tally, and nothing downstream
  # reads a value above max. Counting on regardless cost two real things on
  # this fleet: a python3 spawn + flock + write for every stuck orphan on
  # EVERY guarded operation (12 orphans on one pad = 12 spawns per `say`),
  # and a count marching toward the >999 branch below — which would then
  # report ordinary week-long operation as a "corrupt" counter, a false
  # claim an operator would act on. A count already inside [max, 999] is
  # left exactly as it is. A count OUTSIDE that range still reaches python,
  # so E5a's sanitize-first ordering is preserved unchanged.
  local _sat_max _sat_cur
  _sat_max="$(_sp_recovery_effective_max)"
  _sat_cur="$(sp_recovery_attempt_count "$state_file" "$key")"
  if [ "$_sat_cur" -ge "$_sat_max" ] 2>/dev/null && [ "$_sat_cur" -le 999 ] 2>/dev/null; then
    return 0
  fi
  python3 - "$file" <<'PYF3'
import fcntl, os, sys, time
path = sys.argv[1]
try:
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
except OSError as e:
    print(f"stitchpad: recovery counter open failed: {e}", file=sys.stderr)
    sys.exit(1)
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    raw = b""
    try:
        raw = os.read(fd, 4096)
    except OSError:
        pass
    now = int(time.time())
    if b'|' in raw:
        parts = raw.split(b'|', 1)
        try: count = int(parts[0])
        except (ValueError, IndexError): count = 0
        try: first_epoch = int(parts[1].strip())
        except (ValueError, IndexError): first_epoch = now
    else:
        count = 0
        first_epoch = now
    if count > 999 or count < 0:
        print(f"stitchpad: recovery counter corrupt (count={count}); resetting to 0", file=sys.stderr)
        count = 0
    count += 1
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, f"{count}|{first_epoch}".encode())
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
PYF3
}

# Print the current attempt count for a key (0 if none).
sp_recovery_attempt_count() {
  local state_file="$1" key="$2"
  local file count
  file="$(_sp_recovery_file "$state_file" "$key")"
  [ -f "$file" ] || { echo 0; return 0; }
  count="$(cat "$file" 2>/dev/null | cut -d'|' -f1)"
  case "$count" in *[!0-9]*|'') count=0;; esac
  printf '%s' "$count"
}

# Print the first-attempt epoch (0 if none).
sp_recovery_first_attempt() {
  local state_file="$1" key="$2"
  local file first_epoch
  file="$(_sp_recovery_file "$state_file" "$key")"
  [ -f "$file" ] || { echo 0; return 0; }
  first_epoch="$(cat "$file" 2>/dev/null | cut -d'|' -f2)"
  case "$first_epoch" in *[!0-9]*|'') first_epoch=0;; esac
  printf '%s' "$first_epoch"
}

# Return 0 (true) if the recovery key is exhausted — either the attempt count
# has hit the max OR the time budget has elapsed since the first attempt.
# Return 1 (false) if budget remains.
# E5a: an out-of-range stored count (> 999) is corrupt/poisoned, NOT a legit
# exhaustion. Treat it as 0 (budget remains) so a poisoned counter can never
# wedge recovery permanently on the first pass. The CLI reset surface
# (stitchpad reset --recovery-counters) handles operator-initiated clears.
sp_recovery_is_exhausted() {
  local state_file="$1" key="$2"
  local count first_epoch now max budget
  max="$(_sp_recovery_effective_max)"
  budget="$(_sp_recovery_effective_budget)"
  count="$(sp_recovery_attempt_count "$state_file" "$key")"
  first_epoch="$(sp_recovery_first_attempt "$state_file" "$key")"
  # E5a: corrupted/poisoned count (e.g. 999999 seeded by an attacker) must NOT
  # trigger exhaustion. Clamp to 0 and warn so the caller proceeds normally;
  # the count will be sanitized to a clean value on the next attempt_record.
  if [ "$count" -gt 999 ] 2>/dev/null; then
    echo "stitchpad: recovery counter for $key is corrupt (count=$count > 999); treating as 0, not exhausted" >&2
    count=0
  fi
  [ "$count" -ge "$max" ] && return 0
  if [ "$first_epoch" -gt 0 ]; then
    now="$(date +%s)"
    [ $((now - first_epoch)) -ge "$budget" ] && return 0
  fi
  return 1
}

# Emit a terminal refusal diagnostic. Used when a recovery path is exhausted.
sp_recovery_terminal_refuse() {
  local who="$1" path="$2" key="$3"
  local count first_epoch max budget file marker
  max="$(_sp_recovery_effective_max)"
  budget="$(_sp_recovery_effective_budget)"
  count="$(sp_recovery_attempt_count "$PAD_STATE" "$key")"
  first_epoch="$(sp_recovery_first_attempt "$PAD_STATE" "$key")"
  # Say it ONCE per key. A terminal refusal is a standing fact about a
  # preserved orphan, not news, and re-shouting it on every guarded operation
  # is how the ACTIONABLE warnings that share this stream — UNREACHABLE PUSH
  # SEAT, SESSION BINDING DIVERGED, an unknown --flag refusal — get tuned out.
  # Suppressing the repeat hides nothing: the orphan is still preserved on
  # disk and still enumerated by `stitchpad doctor`, which is the surface for
  # asking "what is stuck right now". sp_recovery_reset clears the marker, so
  # a key that becomes terminal again is announced again.
  file="$(_sp_recovery_file "$PAD_STATE" "$key")"
  marker="${file}.refused"
  if [ -L "$marker" ]; then
    # Not ours. Never write through it, and never let it buy silence.
    :
  elif [ -e "$marker" ]; then
    return 0
  else
    : > "$marker" 2>/dev/null || true
  fi
  echo "stitchpad: RECOVERY EXHAUSTED for @$who ($path) — $count/$max attempts, budget ${budget}s; key=$key; state preserved for manual inspection. Said once — run 'stitchpad doctor' to list what is still stuck." >&2
}

# Clear attempt tracking for a key (on success or after explicit reset).
sp_recovery_reset() {
  local state_file="$1" key="$2"
  local file
  file="$(_sp_recovery_file "$state_file" "$key")"
  # The once-only refusal marker is part of this key's state: leaving it
  # behind would silence the diagnostic for a key that is about to start a
  # fresh attempt budget and may become terminal again for a new reason.
  rm -f "$file" "${file}.refused" 2>/dev/null || true
}

# E5: CLI reset surface — clear ALL recovery counters for a seat or all seats.
# Gated by TASK-5 authority (operator-only, never callable by a roster seat).
sp_recovery_reset_all() {
  local state_file="$1" seat="${2:-}" dir f
  dir="$(_sp_recovery_attempts_dir)"
  [ -d "$dir" ] || return 0
  if [ -n "$seat" ]; then
    # Clear counters matching this seat's key pattern
    for f in "$dir"/*"$seat"*; do
      [ -f "$f" ] && [ ! -L "$f" ] && rm -f "$f" 2>/dev/null || true
    done
  else
    # Clear all counters
    rm -rf "$dir" 2>/dev/null || true
    mkdir -p "$dir" 2>/dev/null || true
  fi
}
