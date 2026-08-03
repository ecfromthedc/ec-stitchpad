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

_sp_recovery_file() {
  local state_file="$1" key="$2"
  # Sanitize key to a safe filename component
  local safe_key
  safe_key="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s/%s' "$(_sp_recovery_attempts_dir)" "$safe_key"
}

# Record an attempt: increment count, stamp first_epoch if new.
sp_recovery_attempt_record() {
  local state_file="$1" key="$2"
  local dir file count first_epoch now
  dir="$(_sp_recovery_attempts_dir)"
  mkdir -p "$dir" 2>/dev/null || return 1
  file="$(_sp_recovery_file "$state_file" "$key")"
  now="$(date +%s)"
  if [ -f "$file" ]; then
    count="$(cat "$file" 2>/dev/null | cut -d'|' -f1)"
    first_epoch="$(cat "$file" 2>/dev/null | cut -d'|' -f2)"
    case "$count" in *[!0-9]*|'') count=0;; esac
    case "$first_epoch" in *[!0-9]*|'') first_epoch="$now";; esac
    count=$((count + 1))
  else
    count=1
    first_epoch="$now"
  fi
  printf '%s|%s' "$count" "$first_epoch" > "$file"
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
sp_recovery_is_exhausted() {
  local state_file="$1" key="$2"
  local count first_epoch now max budget
  max="${SP_RECOVERY_MAX_ATTEMPTS:-3}"
  budget="${SP_RECOVERY_BUDGET_SECONDS:-120}"
  count="$(sp_recovery_attempt_count "$state_file" "$key")"
  first_epoch="$(sp_recovery_first_attempt "$state_file" "$key")"
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
  local count first_epoch max budget
  max="${SP_RECOVERY_MAX_ATTEMPTS:-3}"
  budget="${SP_RECOVERY_BUDGET_SECONDS:-120}"
  count="$(sp_recovery_attempt_count "$PAD_STATE" "$key")"
  first_epoch="$(sp_recovery_first_attempt "$PAD_STATE" "$key")"
  echo "stitchpad: RECOVERY EXHAUSTED for @$who ($path) — $count/$max attempts, budget ${budget}s; key=$key; state preserved for manual inspection" >&2
}

# Clear attempt tracking for a key (on success or after explicit reset).
sp_recovery_reset() {
  local state_file="$1" key="$2"
  local file
  file="$(_sp_recovery_file "$state_file" "$key")"
  rm -f "$file" 2>/dev/null || true
}
