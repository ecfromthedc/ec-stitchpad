#!/usr/bin/env bash
# empty-lock-reclaim-gate.sh — prove the empty-lock wedge (half of F1) is fixed.
#
# F1 from fx1-lock-wedge-timing: when a SIGKILLed writer leaves an EMPTY
# .lock dir (no owner file), the next writer hits "pad busy (lock timeout)"
# at 5 s and every retry fails until the 30 s SP_LOCK_STALE age-based path.
#
# Fix: sp_lock() now reclaims an empty (ownerless) lock after a short bounded
# wait (SP_LOCK_EMPTY_RECLAIM, default 1 s). The owner file is written within
# ~ms of mkdir, so an empty lock older than 1 s means the creator is dead.
#
# Gates:
#   G1: next post after empty-lock crash succeeds within 5 s AND is committed
#   G2: two writers never both acquire under contention
#   G3: mutant — remove empty-lock reclaim → next post gets "pad busy (lock timeout)"
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP="$HERE/../tool/bin/stitchpad"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-elr.XXXXXX")"
writer_pid=""
crash_pid=""
cleanup() {
  for pid in "$writer_pid" "$crash_pid"; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK" "$WORK2" 2>/dev/null || true
}
trap cleanup EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

PAD_DIR="$WORK/.stitchpad"
LOCK="$PAD_DIR/.state/.lock"
HOME="$WORK/home" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" init "$PAD_DIR" >/dev/null 2>&1 || true
mkdir -p "$HOME"
HOME="$WORK/home" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" join tester cli pull - >/dev/null 2>&1 || true

pad_git="$PAD_DIR/stitchpad-git"
pad_md="$PAD_DIR/stitchpad.md"

# ── G1: next post after empty-lock crash succeeds within bounded time ────
echo "--- G1: empty-lock reclaim ---"

# Post a baseline
HOME="$WORK/home" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" say "baseline before crash" >/dev/null 2>&1 || true

# Crash a writer in the mkdir→owner-write window
BARRIER="$WORK/barrier-g1"
(
  trap - EXIT
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$PAD_DIR" STITCHPAD_NAME=tester \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER="$BARRIER" \
    exec "$SP" say 'killed before lock ownership'
) > "$WORK/g1-crash.out" 2>&1 &
crash_pid=$!

# Wait for the barrier
for _ in $(seq 1 300); do [ -f "$BARRIER.ready" ] && break; sleep 0.02; done
if [ -f "$BARRIER.ready" ]; then
  ok "G1a: crash seam reached (writer parked at barrier)"
else
  bad "G1a: crash seam reached (writer never parked)"
fi

# Verify lock is empty
if [ -d "$LOCK" ] && [ ! -f "$LOCK/owner" ]; then
  ok "G1b: empty lock confirmed (dir present, owner absent)"
else
  bad "G1b: empty lock confirmed (lock=$(ls "$LOCK" 2>/dev/null || echo absent))"
fi

# SIGKILL
kill -KILL "$crash_pid" 2>/dev/null || true; wait "$crash_pid" 2>/dev/null || true; crash_pid=""

# Lock still there, still empty
if [ -d "$LOCK" ] && [ ! -f "$LOCK/owner" ]; then
  ok "G1c: empty lock persists after SIGKILL"
else
  bad "G1c: empty lock persists after SIGKILL"
fi

# Post — should succeed in well under 5 s (1 s reclaim + jitter)
G1_START=$(date +%s)
G1_OUT="$(HOME="$WORK/home" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" say "recovered after empty-lock crash" 2>&1)" || true
G1_END=$(date +%s)
G1_ELAPSED=$((G1_END - G1_START))

if echo "$G1_OUT" | grep -q '✓ posted'; then
  ok "G1d: post succeeded after empty-lock crash (elapsed ${G1_ELAPSED}s)"
else
  bad "G1d: post succeeded after empty-lock crash (got: $G1_OUT)"
fi

if [ "$G1_ELAPSED" -lt 5 ]; then
  ok "G1e: post completed within 5 s (${G1_ELAPSED}s)"
else
  bad "G1e: post completed within 5 s (${G1_ELAPSED}s)"
fi

# Message committed
grep -q 'recovered after empty-lock crash' "$pad_md" \
  && ok "G1f: recovered message committed to pad" \
  || bad "G1f: recovered message committed to pad"

# Lock freed
[ ! -d "$LOCK" ] && ok "G1g: lock released after successful post" \
  || bad "G1g: lock released after successful post"

# ── G2: two writers never both acquire ──────────────────────────────────
echo "--- G2: mutual exclusion ---"

BARRIER_A="$WORK/barrier-g2a"
BARRIER_B="$WORK/barrier-g2b"

(
  trap - EXIT
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$PAD_DIR" STITCHPAD_NAME=tester \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER="$BARRIER_A" \
    exec "$SP" say 'writer A'
) > "$WORK/g2a.out" 2>&1 &
PA=$!

(
  trap - EXIT
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$PAD_DIR" STITCHPAD_NAME=tester \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER="$BARRIER_B" \
    exec "$SP" say 'writer B'
) > "$WORK/g2b.out" 2>&1 &
PB=$!

# Wait for the first to hit the barrier
FIRST=""
for _ in $(seq 1 300); do
  [ -f "$BARRIER_A.ready" ] && { FIRST=A; break; }
  [ -f "$BARRIER_B.ready" ] && { FIRST=B; break; }
  sleep 0.02
done

if [ -n "$FIRST" ]; then
  ok "G2a: one writer acquired the lock (writer $FIRST)"
else
  bad "G2a: one writer acquired the lock (neither parked)"
fi

# Release the first
if [ "$FIRST" = "A" ]; then
  touch "$BARRIER_A.release"; wait "$PA" 2>/dev/null || true; PA=""
else
  touch "$BARRIER_B.release"; wait "$PB" 2>/dev/null || true; PB=""
fi

# Second should acquire
SECOND=""
for _ in $(seq 1 300); do
  if [ "$FIRST" = "A" ] && [ -f "$BARRIER_B.ready" ]; then SECOND=B; break; fi
  if [ "$FIRST" = "B" ] && [ -f "$BARRIER_A.ready" ]; then SECOND=A; break; fi
  sleep 0.02
done

if [ -n "$SECOND" ]; then
  ok "G2b: second writer acquired lock only after first released"
else
  bad "G2b: second writer acquired lock only after first released"
fi

# Release second
if [ "$SECOND" = "A" ]; then
  touch "$BARRIER_A.release"; wait "$PA" 2>/dev/null || true; PA=""
else
  touch "$BARRIER_B.release"; wait "$PB" 2>/dev/null || true; PB=""
fi

kill -9 "$PA" "$PB" 2>/dev/null || true; wait 2>/dev/null || true

grep -q 'writer A' "$pad_md" && grep -q 'writer B' "$pad_md" \
  && ok "G2c: both writers' messages committed (serialized, no loss)" \
  || bad "G2c: both writers' messages committed"

# ── G3 (MUTANT): remove empty-lock reclaim → next post gets timeout ─────
echo "--- G3: mutant (no empty-lock reclaim) ---"

WORK2="$(mktemp -d "${TMPDIR:-/tmp}/sp-elr2.XXXXXX")"
PAD_DIR2="$WORK2/.stitchpad"
LOCK2="$PAD_DIR2/.state/.lock"
HOME="$WORK/home" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR2" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" init "$PAD_DIR2" >/dev/null 2>&1 || true
HOME="$WORK/home" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR2" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" join tester cli pull - >/dev/null 2>&1 || true

HOME="$WORK/home" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR2" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" say "mutant baseline" >/dev/null 2>&1 || true

BARRIER3="$WORK2/barrier"
(
  trap - EXIT
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$PAD_DIR2" STITCHPAD_NAME=tester \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER="$BARRIER3" \
    exec "$SP" say 'killed before lock ownership'
) > "$WORK2/g3-crash.out" 2>&1 &
crash_pid=$!

for _ in $(seq 1 300); do [ -f "$BARRIER3.ready" ] && break; sleep 0.02; done
kill -KILL "$crash_pid" 2>/dev/null || true; wait "$crash_pid" 2>/dev/null || true; crash_pid=""

# MUTANT: SP_LOCK_EMPTY_RECLAIM absurdly high so it never fires
G3_START=$(date +%s)
SP_LOCK_EMPTY_RECLAIM=99999 \
  HOME="$WORK/home" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR2" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$SP" say "should fail" > "$WORK2/g3-post.out" 2>&1 || true
G3_END=$(date +%s)
G3_ELAPSED=$((G3_END - G3_START))
G3_OUT="$(cat "$WORK2/g3-post.out")"

if echo "$G3_OUT" | grep -q 'pad busy'; then
  ok "G3a: mutant (no reclaim) → pad busy (lock timeout)"
else
  bad "G3a: mutant (no reclaim) → pad busy (got: $G3_OUT)"
fi

# Verify message NOT posted
if ! grep -q 'should fail' "$PAD_DIR2/stitchpad.md"; then
  ok "G3b: mutant message NOT committed (gate RED)"
else
  bad "G3b: mutant message NOT committed"
fi

# ── Verdict ──────────────────────────────────────────────────────────────
echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
fi
echo "All $pass empty-lock-reclaim gates PASSED"
exit 0
