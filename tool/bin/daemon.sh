#!/usr/bin/env bash
# Background manager for the stitchpad watcher (per pad). SINGLETON: an atomic
# mkdir lock guarantees at most ONE supervisor per pad — no respawn pileups even
# under concurrent `start` calls or wrong-cwd launches.
# Usage: daemon.sh {start|stop|status|restart}
set -uo pipefail
_src="${BASH_SOURCE[0]}"; while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
BIN_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
source "$BIN_DIR/lib.sh"
sp_init_paths || { echo "no .stitchpad here"; exit 1; }

LOCKDIR="$PAD_STATE/watch.lock.d"     # atomic singleton gate (mkdir = atomic)
PIDFILE="$LOCKDIR/pid"                 # supervisor pid lives INSIDE the lock
LOG="$PAD_STATE/watch.log"

# alive iff the lock exists AND its pid is a live process. A stale lock (process
# gone) is auto-cleared so a crash can't wedge the pad forever.
is_running() {
  sp_watcher_alive
}

case "${1:-status}" in
  start)
    if is_running; then echo "running (pid $(cat "$PIDFILE"))"; exit 0; fi
    # ATOMIC acquire: only one caller can create the lockdir. A loser just exits —
    # this is what makes the supervisor a true singleton (no pileup).
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
      # someone else won the race; if it's alive, defer to it
      is_running && { echo "running (pid $(cat "$PIDFILE"))"; exit 0; }
      mkdir "$LOCKDIR" 2>/dev/null || { echo "could not acquire watcher lock"; exit 1; }
    fi
    watch_generation="$(date +%s).$$.${RANDOM:-0}"
    sp_watch_generation_write "$LOCKDIR" "$watch_generation" || {
      rmdir "$LOCKDIR" 2>/dev/null || true
      echo "could not publish watcher generation"
      exit 1
    }
    if [ -n "${STITCHPAD_WATCH_TEST_AFTER_GENERATION_BARRIER:-}" ]; then
      watch_generation_barrier="$STITCHPAD_WATCH_TEST_AFTER_GENERATION_BARRIER"
      printf '%s' ready > "$watch_generation_barrier.ready"
      while [ ! -f "$watch_generation_barrier.release" ]; do sleep 0.01; done
    fi
    sp_watch_launcher_write "$LOCKDIR" "$watch_generation" || {
      sp_watch_lock_remove_generation "$LOCKDIR" "$watch_generation" 2>/dev/null || true
      echo "could not publish watcher launcher ownership"
      exit 1
    }
    # Supervisor: own process group (setsid-ish via subshell), restarts watch.sh if
    # it dies, and CLEARS THE LOCK on exit so stop/crash leaves no stale gate.
    # KEEP-ALIVE: only respawn while at least one agent heartbeat is fresh.
    ( trap 'sp_watch_lock_remove_generation "$LOCKDIR" "$watch_generation" 2>/dev/null || true' EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      # Bash 3.2 (the macOS system bash) has no $BASHPID. Wait for the
      # parent to record this background subshell's real pid via $!.
      while [ ! -s "$PIDFILE" ]; do
        [ -d "$LOCKDIR" ] \
          && [ "$(cat "$LOCKDIR/generation" 2>/dev/null || true)" = "$watch_generation" ] \
          || exit 0
        sleep 0.01
      done
      watch_supervisor_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
      supervisor_owns_generation() {
        [ -d "$LOCKDIR" ] \
          && [ "$(cat "$LOCKDIR/generation" 2>/dev/null || true)" = "$watch_generation" ] \
          && [ "$(cat "$LOCKDIR/cancel" 2>/dev/null || true)" != "$watch_generation" ] \
          && sp_watch_launcher_matches_pid "$LOCKDIR" "$watch_generation" "$watch_supervisor_pid"
      }
      while true; do
        supervisor_owns_generation || exit 0
        date +%s > "$LOCKDIR/heartbeat"
        supervisor_owns_generation || exit 0
        STITCHPAD_PAD_DIR="$PAD_DIR" STITCHPAD_WATCH_GENERATION="$watch_generation" \
          bash "$STITCHPAD_HOME/bin/watch.sh" >>"$LOG" 2>&1
        watcher_rc=$?
        supervisor_owns_generation || exit 0
        date +%s > "$LOCKDIR/heartbeat"
        if [ -n "${STITCHPAD_DAEMON_TEST_BEFORE_RESTART_BARRIER:-}" ]; then
          daemon_restart_barrier="$STITCHPAD_DAEMON_TEST_BEFORE_RESTART_BARRIER"
          printf '%s' ready > "$daemon_restart_barrier.ready"
          while [ ! -f "$daemon_restart_barrier.release" ]; do
            supervisor_owns_generation || exit 0
            sleep 0.01
          done
        fi
        # check agent heartbeats before respawning
        if ! sp_any_alive; then
          echo "[stitchpad] no fresh agent heartbeats — supervisor exiting" >>"$LOG"
          sp_reap_dead   # session's over: physically sweep the dead presences/claims
          exit 0
        fi
        echo "[stitchpad] watcher exited (code $watcher_rc), restarting in 2s..." >>"$LOG"
        sleep 2
        supervisor_owns_generation || exit 0
      done
    ) &
    supervisor_pid=$!
    if ! sp_watch_launcher_transfer_to_pid "$LOCKDIR" "$watch_generation" "$supervisor_pid"; then
      kill "$supervisor_pid" 2>/dev/null || true
      wait "$supervisor_pid" 2>/dev/null || true
      sp_watch_lock_remove_generation "$LOCKDIR" "$watch_generation" 2>/dev/null || true
      echo "could not transfer watcher launcher ownership"
      exit 1
    fi
    echo "$supervisor_pid" > "$PIDFILE"
    disown
    sleep 0.3
    echo "started stitchpad watcher (pid $(cat "$PIDFILE" 2>/dev/null)); log: $LOG" ;;
  stop)
    # Always scan the exact pad path: a supervisor can die and remove its lock
    # while leaving fswatch orphaned under PID 1. The helper excludes PID 1 and
    # signals only the recorded supervisor and processes bound to this PAD_MD.
    if [ -d "$LOCKDIR" ] || [ -n "$(sp_watch_processes_for_pad)" ]; then
      sp_stop_watchers_for_pad
      watcher_was_running=1
    else watcher_was_running=0; fi
    # Per-seat supervisors are independent of fswatch and can outlive a watcher
    # crash. Daemon lifecycle operations own both layers.
    sp_stop_delivery_workers
    if [ "$watcher_was_running" -eq 1 ]; then echo "stopped"; else echo "not running"; fi ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  status)  if is_running; then echo "running (pid $(cat "$PIDFILE"))"; else echo "stopped"; fi ;;
  *) echo "usage: $0 {start|stop|status|restart}"; exit 1 ;;
esac
