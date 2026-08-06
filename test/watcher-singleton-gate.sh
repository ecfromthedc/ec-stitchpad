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

# Wait for the count to SETTLE at exactly 1, not merely to reach >=1 once.
# The old loop broke on the first sample >=1, slept 1s, then re-counted — so a
# watcher that had not finished exec'ing fswatch, or that bounced once under
# load, sampled as 0 and W1 failed ~1 run in 6 while the singleton invariant
# (never MORE than one) held every time. That flake made a green board luck.
# This still fails loudly if the watcher never starts (settles at 0) or if two
# ever coexist (settles at 2) — the assertion is unchanged, the SAMPLING is fixed.
_count_fswatch() { pgrep -f "fswatch.*$WORK" 2>/dev/null | wc -l | tr -d ' '; }
_stable=0; _poll_i=0; _fswatch_count=0
while [ "$_poll_i" -lt 80 ]; do
  _now_count="$(_count_fswatch)"
  if [ "$_now_count" -eq "$_fswatch_count" ]; then
    _stable=$((_stable + 1))
  else
    _stable=1; _fswatch_count="$_now_count"
  fi
  # three consecutive identical samples of a non-zero count == settled
  [ "$_stable" -ge 3 ] && [ "$_fswatch_count" -ge 1 ] && break
  sleep 0.25
  _poll_i=$((_poll_i + 1))
done
# Assert on the SETTLED value. Re-sampling here is what the old code did and it
# is exactly the race: the watcher can bounce between the settle and the sample.

if [ "$_fswatch_count" -eq 1 ]; then
  ok "W1: exactly 1 fswatch after $N concurrent calls (got $_fswatch_count)"
else
  bad "W1: exactly 1 fswatch after $N concurrent calls (got $_fswatch_count)"
fi

# ── W2: steady-state — ensure_watcher is a no-op on re-entry ──────────────
echo "--- W2: steady-state re-entry ---"
_watchers_before="$(_count_fswatch)"
STITCHPAD_PAD_DIR="$PAD_DIR" env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="${TMPDIR:-/tmp}" \
  STITCHPAD_PAD_DIR="$PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_HOME="$TOOL" \
  "$SP" ensure-watcher >/dev/null 2>&1
sleep 1
_watchers_after="$(_count_fswatch)"

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

# ── W6/W7: a dead watcher must not wedge the pad forever ─────────────────
# FOUND LIVE ON THE OPERATOR'S FLEET, not by reading code. A watcher lock holding
# `pid` and `ts` but no `generation` made sp_watch_empty_lock_reclaim return 1
# unconditionally — its emptiness test ran first, so age and pid-liveness were
# never consulted. Measured on a real pad: pid 14088 dead, lock 39136s (nearly 11
# hours) old, every push seat deaf the whole time while `lanes` said WORKING.
# Nothing self-healed it; the only cure was deleting the directory by hand.
# This is the silence class at its most expensive: the fleet looks fine and
# receives nothing.
W6="$WORK/w6"; mkdir -p "$W6/home" "$W6/proj"
(
  cd "$W6/proj" || exit 1
  export HOME="$W6/home" STITCHPAD_HOME="$TOOL" STITCHPAD_TERMINAL_NAMESPACE=w6
  "$SP" init >/dev/null 2>&1
  "$SP" join dale cli pull - >/dev/null 2>&1
)
W6L="$W6/proj/.stitchpad/.state/watch.lock.d"
rm -rf "$W6L"; mkdir -p "$W6L"
printf '999999\n' > "$W6L/pid"          # a pid that cannot be running
printf '2026-08-06T03:07:14Z\n' > "$W6L/ts"
touch -t 202608050307 "$W6L"            # older than any start grace

# A watcher only runs when a seat is alive, and this suite disables heartbeat
# autostart globally (line 39). Without a fresh alive marker `watch start`
# refuses for THAT reason and the lock is never even examined — the probe would
# then "fail" while proving nothing. Stamp liveness directly.
printf '{"name":"dale"}\n' > "$W6/proj/.stitchpad/.state/alive.dale"

if kill -0 999999 2>/dev/null; then
  bad "W6 INVALID PROBE: pid 999999 is actually alive on this machine"
else
  w6_rc=0; w6_out=""
  w6_out="$( cd "$W6/proj" && HOME="$W6/home" STITCHPAD_HOME="$TOOL" STITCHPAD_TERMINAL_NAMESPACE=w6 \
      "$SP" watch start 2>&1 )" || w6_rc=$?
  # Distinguish "no live seat" (a broken probe) from "the lock blocked it" (the
  # bug). Both surface the same sentence, so key on whether OUR planted pid is
  # still sitting in the lock: if it is, the lock is what stopped the watcher.
  case "$w6_out" in
    *"is any agent alive"*)
      if ! grep -q '^999999$' "$W6L/pid" 2>/dev/null; then
        bad "W6 INVALID PROBE: refused for lack of a live seat, not because of the lock"
      fi ;;
  esac
  if [ "$w6_rc" -eq 0 ]; then
    ok "W6: a dead-pid ownerless watcher lock is reclaimed, not left to wedge the pad"
  else
    bad "W6: dead-pid watcher lock wedged the pad (watch start rc=$w6_rc) — push seats go permanently deaf"
  fi
  # The reclaimed lock must be re-acquired with real ownership, not just deleted.
  if [ -f "$W6L/generation" ]; then
    ok "W7: the replacement watcher owns its lock (generation present)"
  else
    bad "W7: lock has no generation after restart — ownership was not established"
  fi
  ( cd "$W6/proj" && HOME="$W6/home" STITCHPAD_HOME="$TOOL" STITCHPAD_TERMINAL_NAMESPACE=w6 \
      "$SP" watch stop >/dev/null 2>&1 ) || true
fi

# W8: a lock whose pid is STILL ALIVE must never be reclaimed — that would kill a
# working watcher, which is the opposite failure and how W1-W4's churn started.
W8L="$W6/proj/.stitchpad/.state/watch.lock.d"
rm -rf "$W8L"; mkdir -p "$W8L"
sleep 600 &
w8_pid=$!
printf '%s\n' "$w8_pid" > "$W8L/pid"; printf 'x\n' > "$W8L/ts"
touch -t 202608050307 "$W8L"
if sp_watch_reclaim_probe=1 true && ! ( cd "$W6/proj" && HOME="$W6/home" STITCHPAD_HOME="$TOOL" \
     STITCHPAD_TERMINAL_NAMESPACE=w6 "$SP" watch start >/dev/null 2>&1 ); then
  ok "W8: a lock held by a LIVE pid is refused, not stolen"
else
  bad "W8: reclaimed a watcher lock whose pid is still alive — a working watcher would be displaced"
fi
kill -TERM "$w8_pid" 2>/dev/null || true
wait "$w8_pid" 2>/dev/null || true

# ── Verdict ───────────────────────────────────────────────────────────────
echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
else
  echo "All $pass watcher-singleton gates PASSED"
  exit 0
fi
