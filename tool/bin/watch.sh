#!/usr/bin/env bash
# stitchpad watcher (daemon body). One fswatch on stitchpad.md. On every change:
#   - auto-commit to the isolated pad git
#   - for EACH roster member, if new lines address them (@name), fire their adapter
#
# Adapters live in ~/.stitchpad/adapters/<adapter>.sh and are called as:
#   adapter.sh <event> <to> <stitchpad.md> <task-text-file>
# where event = "mention". The adapter decides push (spawn) vs pull (flag/notify)
# vs trigger (claude.ai remote-trigger) using the wake mode passed via $SP_WAKE.
#
# BUG HISTORY: an earlier version let inner `read`s consume the fswatch pipe's
# stdin, corrupting variable names ("old<mojibake>: unbound variable"). Fixed by
# (1) snapshotting the roster into an array, (2) redirecting every inner command
# that could read stdin from /dev/null, and (3) feeding the fswatch loop a
# function that itself takes no stdin.
set -uo pipefail
_src="${BASH_SOURCE[0]}"; while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
BIN_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
source "$BIN_DIR/lib.sh"
sp_init_paths || { echo "no stitchpad"; exit 1; }

# Register an exact watcher generation before any startup work. Direct
# foreground `stitchpad watch` acquires its own lock; daemon-launched watchers
# inherit the generation published by daemon.sh. A second contender may write
# an owner, but only the final exact generation/PID/start/command owner is
# allowed to reach fswatch.
WATCH_LOCK="$PAD_STATE/watch.lock.d"
WATCH_LAUNCHED=0
if [ ! -d "$WATCH_LOCK" ]; then
  # A daemon child is never allowed to recreate a cancelled supervisor
  # generation. Only an explicitly direct watcher may acquire a fresh lock.
  [ -z "${STITCHPAD_WATCH_GENERATION:-}" ] || exit 1
  mkdir "$WATCH_LOCK" 2>/dev/null || exit 1
  WATCH_GENERATION="$(date +%s).$$.${RANDOM:-0}"
  printf '%s' "$WATCH_GENERATION" > "$WATCH_LOCK/generation" || exit 1
  sp_watch_launcher_write "$WATCH_LOCK" "$WATCH_GENERATION" || exit 1
else
  WATCH_LAUNCHED=1
  # Only a launcher that knows the exact pre-published generation may claim an
  # existing ownerless lock. An unrelated foreground contender exits without
  # modifying owner state.
  WATCH_GENERATION="${STITCHPAD_WATCH_GENERATION:-}"
  [ -n "$WATCH_GENERATION" ] \
    && [ "$(cat "$WATCH_LOCK/generation" 2>/dev/null || true)" = "$WATCH_GENERATION" ] \
    || exit 1
fi
[ -n "$WATCH_GENERATION" ] || exit 1
sp_watch_launcher_is_valid "$WATCH_LOCK" "$WATCH_GENERATION" || exit 1
[ "$(cat "$WATCH_LOCK/cancel" 2>/dev/null || true)" != "$WATCH_GENERATION" ] || exit 1
sp_watch_owner_claim "$WATCH_LOCK" "$WATCH_GENERATION" "$$" || exit 1
[ "$(cat "$WATCH_LOCK/cancel" 2>/dev/null || true)" != "$WATCH_GENERATION" ] || exit 1
printf '%s' "$$" > "$WATCH_LOCK/pid" || exit 1
printf '%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WATCH_LOCK/ts" || exit 1
watcher_cleanup() {
  if sp_watch_owner_matches "$WATCH_LOCK" "$WATCH_GENERATION" "$$" 2>/dev/null; then
    if [ "$WATCH_LAUNCHED" -eq 1 ]; then
      # The daemon supervisor retains generation+launcher across a child crash
      # so it can restart. Remove only this exact child's ownership record.
      date +%s > "$WATCH_LOCK/heartbeat" 2>/dev/null || true
      _watch_owner_observed="$(cat "$WATCH_LOCK/owner" 2>/dev/null || true)"
      [ -n "$_watch_owner_observed" ] \
        && [ "$(cat "$WATCH_LOCK/owner" 2>/dev/null || true)" = "$_watch_owner_observed" ] \
        && rm -f "$WATCH_LOCK/owner" 2>/dev/null || true
      [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$$" ] \
        || rm -f "$WATCH_LOCK/pid" "$WATCH_LOCK/ts" 2>/dev/null || true
    else
      sp_watch_lock_remove_generation "$WATCH_LOCK" "$WATCH_GENERATION" 2>/dev/null || true
    fi
  fi
}
trap 'watcher_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Deterministic startup/stop race seam. Production is unchanged unless this
# explicit test path is set.
if [ -n "${STITCHPAD_WATCH_TEST_BEFORE_FSWATCH_BARRIER:-}" ]; then
  _watch_barrier="$STITCHPAD_WATCH_TEST_BEFORE_FSWATCH_BARRIER"
  _watch_i=0
  printf '%s' ready > "$_watch_barrier.ready"
  while [ ! -f "$_watch_barrier.release" ] && [ "$_watch_i" -lt 500 ]; do
    sleep 0.01
    _watch_i=$((_watch_i + 1))
  done
  [ -f "$_watch_barrier.release" ] || exit 1
fi

[ "$(cat "$WATCH_LOCK/cancel" 2>/dev/null || true)" != "$WATCH_GENERATION" ] || exit 1

# Per-user mention counters live in state.
count_file() { echo "$PAD_STATE/count.$1"; }

# Seed baselines so we only react to NEW mentions. Snapshot the roster first so
# this loop doesn't hold a process-substitution fd open across the body.
# Bash 3.2 + `set -u` treats an expanded empty array as unbound. A skipped
# sentinel keeps empty-roster foreground watches well-defined.
declare -a SEED=( "" )
while IFS= read -r _l; do SEED+=("$_l"); done < <(sp_roster)
for _m in "${SEED[@]}"; do
  IFS='|' read -r _name _ _ _ <<< "$_m"
  [ -n "$_name" ] || continue
  sp_count_to "$_name" > "$(count_file "$_name")"
done

echo "[stitchpad] watching $PAD_MD"
for _m in "${SEED[@]}"; do
  IFS='|' read -r _name _adapter _wake _ <<< "$_m"
  [ -n "$_name" ] || continue
  echo "  · @$_name → adapter=$_adapter wake=$_wake"
done

fire_adapter() {
  local name="$1" adapter="$2" wake="$3" target="$4" since="${5:-0}"
  local script="$ADAPTER_DIR/$adapter.sh"
  if [ ! -f "$script" ]; then
    echo "[stitchpad] no adapter '$adapter' for @$name (looked in $ADAPTER_DIR)"; return 2
  fi
  local taskfile; taskfile="$(mktemp)"
  sp_latest_to "$name" "$since" > "$taskfile"
  local rc=0
  # Per-agent force-wake: if .state/forcewake.<name> exists, bypass the adapter's
  # focus-guard for this agent (wake even when its window is focused). Used for the
  # orchestrator (randy), whose window is often the focused one the human is typing
  # in — without this, pad mentions to randy chronically defer and never land.
  local force=0
  [ -f "$PAD_STATE/forcewake.$name" ] && force=1
  SP_WAKE="$wake" SP_TARGET="$target" SP_PAD_DIR="$PAD_DIR" SP_PAD_MD="$PAD_MD" STITCHPAD_FORCE_WAKE="$force" \
    bash "$script" mention "$name" "$PAD_MD" "$taskfile" </dev/null || rc=$?
  rm -f "$taskfile"
  # Return the adapter's exit code so the caller can distinguish DELIVERED (0) from
  # DEFERRED (3, focus-guard) or FAILED (1). Only a real delivery should consume the
  # gate (read-clears-gate); a defer must re-fire later, so it must NOT consume.
  [ "$rc" -ne 0 ] && echo "[stitchpad] adapter $adapter for @$name → exit $rc (not consuming gate)"
  return "$rc"
}

# react() takes NO stdin — everything inside redirects from /dev/null where it
# might otherwise read the fswatch pipe.
react() {
  # KEEP-ALIVE self-exit — SAFE version. The earlier logic suicided whenever no
  # FRESH heartbeat existed, which killed working pads whose agents predate the
  # ticker (ocean-os, stitchpad-live both died this way). Corrected rule:
  #   - If there are NO alive.* files at all → heartbeat system isn't populated for
  #     this pad → DO NOT exit (absent ≠ dead). Keep running; agents still wake.
  #   - Only exit if heartbeats EXIST but every one is stale/dead.
  shopt -s nullglob 2>/dev/null || true
  local _hearts=( "$PAD_STATE"/alive.* )
  if [ "${#_hearts[@]}" -gt 0 ]; then
    local _any_alive=0
    for _heart in "${_hearts[@]}"; do
      [ -f "$_heart" ] || continue
      local _hts _hpid _hage
      _hts=$(stat -f %m "$_heart" 2>/dev/null || stat -c %Y "$_heart" 2>/dev/null || echo 0)
      _hage=$(( $(date +%s) - _hts ))
      [ "$_hage" -lt 90 ] || continue
      _hpid=$(grep -o '"pid":[0-9]*' "$_heart" 2>/dev/null | head -1 | cut -d: -f2)
      # a heartbeat with no pid still counts as alive if its mtime is fresh
      if [ -z "$_hpid" ] || kill -0 "$_hpid" 2>/dev/null; then _any_alive=1; break; fi
    done
    if [ "$_any_alive" -eq 0 ]; then
      echo "[stitchpad] all heartbeats stale — watcher exiting"
      exit 0
    fi
  fi
  # else: no heartbeat files → system not in use here → keep watching (safe default)

  # An outer-repo `git stash -u` can briefly remove an unignored pad file. Never
  # commit that transient deletion or process a headerless recreation: either
  # would erase the roster and make @mentions disappear. The init/path guards
  # now ignore the whole pad, but this keeps older pads fail-closed too.
  if [ ! -f "$PAD_MD" ] || ! grep -q '^```roster[[:space:]]*$' "$PAD_MD" 2>/dev/null; then
    echo "[stitchpad] pad missing roster — skipping commit and wake cycle"
    return 0
  fi

  sp_commit "update ($(date '+%H:%M:%S'))"
  local -a members=( "" )
  local rline
  while IFS= read -r rline; do members+=("$rline"); done < <(sp_roster)
  local m name adapter wake target
  for m in "${members[@]}"; do
    IFS='|' read -r name adapter wake target <<< "$m"
    [ -n "$name" ] || continue
    # `pull` means the runtime's real lifecycle hook owns delivery. Never spawn
    # an external adapter for it: that creates a hidden second agent lane and
    # makes the operator's visible terminal cease to be the source of truth.
    # The watcher exists only for explicit push targets (Herdr/Ocean).
    [ "$wake" = "pull" ] && continue
    # Fire ONLY if there's an UNANSWERED mention — the same engagement gate the
    # hook wake uses (a @name newer than name's last @-reply). `wake --peek` prints
    # the pending message iff unanswered and does NOT advance any cursor.
    #
    # READ-CLEARS-GATE: after a SUCCESSFUL fire, consume the mention by running a
    # non-peek `wake` (which advances .state/seen.<name> to that mention ordinal).
    # The nudge was delivered once; the agent has now "read" it via the wake, so we
    # don't re-fire the SAME mention forever waiting for a reply. A genuinely newer
    # mention (higher ordinal) still fires. This is the structural loop-killer: an
    # agent can legitimately go silent (no post needed) and the gate is satisfied.
    # INVARIANT 5 — defer-or-queue: if a pending stamp already exists
    # (an unresolved recovery target from a prior cycle whose agent turn
    # may have crashed), defer the ENTIRE later fire/consume. Do not
    # overwrite, do not fire a newer mention over an unresolved one.
    # The existing pending ordinal will be resolved by the stop-hook;
    # the next watcher cycle then handles the new mention naturally.
    # Ocean push turns are durably accepted by ocean-daemon and the adapter waits
    # for that exact turn to finish. They do not need the shell-level
    # consumed-but-not-displayed recovery stamp: keeping one makes the normal
    # Ocean Stop hook force-deliver the same mention a second time. Retain crash
    # recovery for terminal adapters, but make daemon-owned delivery exactly-once.
    local needs_pending_recovery=1
    if [ "$adapter" = "ocean" ]; then
      needs_pending_recovery=0
      # Self-heal stamps left by older watchers so an old mention cannot replay.
      rm -f "$PAD_STATE/pending.$name" "$PAD_STATE/delivered_no_reply.$name" 2>/dev/null || true
    fi
    _existing_pending=0
    if [ "$needs_pending_recovery" -eq 1 ] && [ -f "$PAD_STATE/pending.$name" ]; then
      _existing_pending="$(cat "$PAD_STATE/pending.$name" 2>/dev/null || echo 0)"
      if [ "${_existing_pending:-0}" -gt 0 ]; then
        echo "[stitchpad] deferring @$name — pending recovery target (ordinal $_existing_pending) unresolved" >&2
        continue
      fi
    fi

    if [ -n "$("$BIN_DIR/stitchpad" wake "$name" --peek 2>/dev/null)" ]; then
      echo "[stitchpad] unanswered @$name -> firing ${adapter} (${wake})"
      # Stamp pending.<name> with the open mention ordinal BEFORE firing.
      # If the adapter's turn dies (crash, timeout, abort), the stop-hook
      # reads this ordinal and re-presents the mention via --force.
      # Uses --peek-ordinal (gate-derived, NEVER consumed) so the stamp
      # is always the SAME ordinal the wake saw — not a shifted cursor.
      if [ "$needs_pending_recovery" -eq 1 ]; then
        _pend_ord="$("$BIN_DIR/stitchpad" wake "$name" --peek-ordinal 2>/dev/null)"
        if [ -n "$_pend_ord" ]; then
          printf '%s' "$_pend_ord" > "$PAD_STATE/pending.$name"
        fi
      fi
      # Pass the current seen cursor to fire_adapter so sp_latest_to returns
      # the same mention that sp_engagement found (FIFO-aligned).
      _seen=0; [ -f "$PAD_STATE/seen.$name" ] && _seen="$(cat "$PAD_STATE/seen.$name" 2>/dev/null || echo 0)"
      if fire_adapter "$name" "$adapter" "$wake" "$target" "$_seen"; then
        # consume only if the adapter actually delivered (focus-guard/defer returns
        # 0 too, but it logs a defer and leaves the prompt untouched — re-firing on
        # the next pad change is correct there, so we key off the wake's own output)
        "$BIN_DIR/stitchpad" wake "$name" >/dev/null 2>&1 || true
        # INVARIANT 5: do NOT clear the pending stamp here. The adapter consumed
        # the wake, but the agent's turn may crash before the human sees it.
        # The stamp survives until the stop-hook confirms the agent completed a
        # turn (the stop-hook clears it) or the next watcher cycle re-stamps it.
      else
        # Adapter delivery FAILED: the stamp was created for crash recovery after
        # a successful delivery. If delivery never happened, the stamp is a
        # dead-lock trigger — the next watcher cycle sees pending and defers
        # forever. Clear it so the next cycle retries naturally.
        rm -f "$PAD_STATE/pending.$name" 2>/dev/null || true
      fi
    fi
  done
}

# Trap errors in the main loop so the watcher doesn't die on a single adapter failure.
trap 'echo "[stitchpad] watcher error at line $LINENO — continuing" >&2' ERR

# Stop may have removed or replaced the generation at any point during startup.
# Re-prove ownership immediately before spawning fswatch; the signal traps above
# exit rather than merely cleaning and continuing.
sp_watch_owner_matches "$WATCH_LOCK" "$WATCH_GENERATION" "$$" || exit 1
fswatch -0 "$PAD_MD" | while read -r -d "" _ev; do react </dev/null; done
