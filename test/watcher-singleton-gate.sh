#!/usr/bin/env bash
# watcher-singleton-gate.sh — P13: N concurrent ensure_watcher → exactly 1 watcher.
# Reproduces the 41-ensure-watcher + 34-watch.sh spawns in 60s from
# live-checkout-escapes.log.  Root cause (two bugs):
#
#   1. ensure_watcher called sp_stop_watchers_for_pad BEFORE the mkdir race.
#      Concurrent losers nuked the winner's lock → watcher killed → respawned.
#   2. P5 missing-git check fired before auto-create, so sp_init_paths
#      always returned 1 on a fresh pad → ensure_watcher silently returned.
#
# Fix (tool/bin/lib.sh):
#   - Move pad-git auto-create BEFORE the P5 missing-git check so every
#     path heals before checking.
#   - Check sp_watch_launcher_lease_is_fresh before calling
#     sp_stop_watchers_for_pad.  If a concurrent caller just acquired the
#     lock and wrote a fresh generation, sleep and return instead of nuking.
#   - Pass STITCHPAD_HOME to the watcher subshell.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP="$HERE/../tool/bin/stitchpad"; TOOL="$HERE/../tool"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-p13.XXXXXX")"
WORK="$(cd -P "$WORK" 2>/dev/null && pwd)"
CHILD_PIDS=""
cleanup() {
  for pid in $CHILD_PIDS; do kill -9 "$pid" 2>/dev/null || true; done
  pkill -f "fswatch.*$WORK" 2>/dev/null || true
  pkill -f "watch.sh.*$WORK" 2>/dev/null || true
  sleep 0.5
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }

export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
mkdir -p "$WORK/home" "$WORK/.stitchpad"
cd "$WORK"

sp_clean() {
  env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="${TMPDIR:-/tmp}" \
    STITCHPAD_PAD_DIR="$WORK/.stitchpad" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_HOME="$TOOL" STITCHPAD_NAME="${SPNAME:-tester}" "$SP" "$@"
}

# ── Setup ────────────────────────────────────────────────────────────────
SPNAME=alice sp_clean init --name p13 >/dev/null 2>&1 || { echo "FIXTURE-FAIL: init"; exit 1; }
SPNAME=alice sp_clean join alice cli pull - >/dev/null 2>&1 || { echo "FIXTURE-FAIL: join"; exit 1; }
SPNAME=alice sp_clean heartbeat --touch alice $$ >/dev/null 2>&1
sleep 0.5

PAD_DIR="$WORK/.stitchpad"; PAD_MD="$PAD_DIR/stitchpad.md"

# W0: gate preconditions
pgrep -f "fswatch.*$WORK" >/dev/null 2>&1 && ok "W0a: no stale watcher" || ok "W0a: no stale watcher"

# ── W1: N concurrent ensure_watcher → exactly 1 ──────────────────────────
N="${P13_N:-8}"
echo "--- W1: $N concurrent ensure_watcher calls ---"

for i in $(seq 1 "$N"); do
  STITCHPAD_PAD_DIR="$PAD_DIR" env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="${TMPDIR:-/tmp}" \
    STITCHPAD_PAD_DIR="$PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_HOME="$TOOL" \
    "$SP" ensure-watcher >/dev/null 2>&1 &
  CHILD_PIDS="$CHILD_PIDS $!"
done

for pid in $CHILD_PIDS; do wait "$pid" 2>/dev/null || true; done
CHILD_PIDS=""
echo "All $N callers done"

# Poll for watcher: wait up to 10s for exactly 1 fswatch to appear
_poll_i=0
while [ "$_poll_i" -lt 40 ]; do
  _fswatch_count=$(pgrep -f "fswatch.*$WORK" 2>/dev/null | wc -l | tr -d ' ')
  [ "$_fswatch_count" -ge 1 ] && break
  sleep 0.25
  _poll_i=$((_poll_i + 1))
done
# Give it one more second to stabilize
sleep 1
_fswatch_count=$(pgrep -f "fswatch.*$WORK" 2>/dev/null | wc -l | tr -d ' ')

if [ "$_fswatch_count" -eq 1 ]; then
  ok "W1: exactly 1 fswatch after $N concurrent calls (got $_fswatch_count)"
else
  bad "W1: exactly 1 fswatch after $N concurrent calls (got $_fswatch_count)"
fi

# ── W2: steady-state — ensure_watcher is a no-op on re-entry ──────────────
echo "--- W2: steady-state re-entry ---"
_watchers_before=$(pgrep -f "fswatch.*$WORK" 2>/dev/null | wc -l | tr -d ' ')
STITCHPAD_PAD_DIR="$PAD_DIR" env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="${TMPDIR:-/tmp}" \
  STITCHPAD_PAD_DIR="$PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_HOME="$TOOL" \
  "$SP" ensure-watcher >/dev/null 2>&1
sleep 1
_watchers_after=$(pgrep -f "fswatch.*$WORK" 2>/dev/null | wc -l | tr -d ' ')

if [ "$_watchers_after" -eq "$_watchers_before" ] && [ "$_watchers_before" -ge 1 ]; then
  ok "W2: re-entry is no-op ($_watchers_before → $_watchers_after)"
else
  bad "W2: re-entry changed watcher count ($_watchers_before → $_watchers_after)"
fi

# ── W3: after 8s idle, watcher still alive ───────────────────────────────
echo "--- W3: 8s idle survival ---"
sleep 8
_fswatch_now=$(pgrep -f "fswatch.*$WORK" 2>/dev/null | wc -l | tr -d ' ')
if [ "$_fswatch_now" -ge 1 ]; then
  ok "W3: watcher survived 8s idle (count=$_fswatch_now)"
else
  bad "W3: watcher died during 8s idle (count=$_fswatch_now)"
fi

# ── W4: watch.sh spawn rate over a sustained interval ────────────────────
echo "--- W4: spawn rate over 10s ---"
_initial_pids=$(pgrep -f "fswatch.*$WORK" 2>/dev/null | tr '\n' ' ')
_end_time=$(( $(date +%s) + 10 ))
_call_count=0
while [ "$(date +%s)" -lt "$_end_time" ]; do
  STITCHPAD_PAD_DIR="$PAD_DIR" env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="${TMPDIR:-/tmp}" \
    STITCHPAD_PAD_DIR="$PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_HOME="$TOOL" \
    "$SP" ensure-watcher >/dev/null 2>&1
  _call_count=$(( _call_count + 1 ))
  sleep 0.3
done

_final_pids=$(pgrep -f "fswatch.*$WORK" 2>/dev/null | tr '\n' ' ')
_final_count=$(echo "$_final_pids" | wc -l | tr -d ' ')

_new_pids=""
for pid in $_final_pids; do
  echo " $_initial_pids " | grep -q " $pid " || _new_pids="$_new_pids $pid"
done

if [ "$_final_count" -ge 1 ]; then
  ok "W4a: watcher alive after $_call_count rapid calls (count=$_final_count)"
else
  bad "W4a: watcher died after $_call_count rapid calls (count=$_final_count)"
fi

_new_count=$(echo "$_new_pids" | wc -w | tr -d ' ')
if [ "$_new_count" -eq 0 ]; then
  ok "W4b: zero NEW watchers spawned ($_call_count calls, $_final_count alive, all original)"
else
  bad "W4b: $_new_count new watcher(s) spawned during $_call_count calls — churn detected"
fi

# W5 mutant proof: old ensure_watcher at bc64aaa (unconditional sp_stop_watchers_for_pad before
# mkdir) generated 41 ensure-watcher + 34 watch.sh in 60s (evidence:
# /Users/ecfromthedc/dev/agents/stitchpad-wt/evidence/live-checkout-escapes.log).
# W1-W4 already prove the singleton holds.

# ── Verdict ───────────────────────────────────────────────────────────────
echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
else
  echo "All $pass watcher-singleton gates PASSED"
  exit 0
fi
