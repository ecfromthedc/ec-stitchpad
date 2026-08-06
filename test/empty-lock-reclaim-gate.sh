#!/usr/bin/env bash
# empty-lock-reclaim-gate.sh — prove the empty-lock wedge (half of F1) is fixed.
#
# F1 from fx1-lock-wedge-timing: when a SIGKILLed writer leaves an EMPTY
# .lock dir (no owner file), the next writer hits "pad busy (lock timeout)"
# at 5 s and every retry fails until the 30 s SP_LOCK_STALE age-based path.
#
# Fix: sp_lock() now reclaims an empty (ownerless) lock after a short bounded
# wait (SP_LOCK_EMPTY_RECLAIM, default 1 s).
#
# THE PREMISE THAT WAS WRONG, and it lived in this very comment: "the owner file
# is written within ~ms of mkdir, so an empty lock older than 1 s means the
# creator is dead." It does not. sp_lock_owner_write cannot publish until it has
# spawned /bin/sh (for PPID), ps twice, and a python3 interpreter. On a loaded
# machine that exceeds 1 s, so this reclaim was robbing writers that were alive
# and mid-publication — two writers then believed they held the same critical
# section (deepseek F1). sp_lock now stamps a `claiming` marker with a bash
# builtin the instant mkdir wins, and E1 only reclaims from a claimant that is
# provably gone. The 30 s SP_LOCK_STALE path stays age-only on purpose, so a
# reused pid cannot wedge the pad forever.
#
# Gates:
#   G1: next post after empty-lock crash succeeds within 5 s AND is committed
#   G2: two writers never both acquire under contention
#   G3: mutant — remove empty-lock reclaim → next post gets "pad busy (lock timeout)"
#   G4: a LIVE claimant mid-publication is never robbed (the F1 steal)
#   G5: a SIGKILLed claimant IS still reclaimed (G1's purpose survives the fix)
#   G6: rollback refuses to restore the pad when HEAD advanced (F1, second half)
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP="$HERE/../tool/bin/stitchpad"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-elr.XXXXXX")"
cd "$WORK" || exit 1   # fixture must own its cwd (fx5)
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
cd "$WORK2" || exit 1
PAD_DIR2="$WORK2/.stitchpad"
HOME2="$WORK2/home"; mkdir -p "$HOME2"   # G3 needs its own terminal store (one terminal = one pad)
LOCK2="$PAD_DIR2/.state/.lock"
HOME="$HOME2" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR2" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" init "$PAD_DIR2" >/dev/null 2>&1 || true
HOME="$HOME2" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR2" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" join tester cli pull - >/dev/null 2>&1 || true

HOME="$HOME2" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR2" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" say "mutant baseline" >/dev/null 2>&1 || true

BARRIER3="$WORK2/barrier"
(
  trap - EXIT
  HOME="$HOME2" STITCHPAD_PAD_DIR="$PAD_DIR2" STITCHPAD_NAME=tester \
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
  HOME="$HOME2" STITCHPAD_NAME=tester STITCHPAD_PAD_DIR="$PAD_DIR2" \
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

# ═════════════════════════════════════════════════════════════════════════
# G4/G5/G6 — deepseek F1: the reclaim must tell "slow" from "dead"
# ═════════════════════════════════════════════════════════════════════════
echo ""
echo "--- G4/G5/G6: live claimant vs dead claimant, and the rollback guard ---"

WORK3="$(mktemp -d "${TMPDIR:-/tmp}/sp-f1.XXXXXX")"
f1_pid=""
_f1_cleanup() {
  [ -n "$f1_pid" ] && kill -KILL "$f1_pid" 2>/dev/null
  [ -n "$f1_pid" ] && wait "$f1_pid" 2>/dev/null
  rm -rf "$WORK3" 2>/dev/null || true
}

mkdir -p "$WORK3/home" "$WORK3/proj"
(
  cd "$WORK3/proj" || exit 1
  HOME="$WORK3/home" STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" init >/dev/null 2>&1
  HOME="$WORK3/home" STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" join dale cli pull - >/dev/null 2>&1
  HOME="$WORK3/home" STITCHPAD_TERMINAL_NAMESPACE=t2 STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    "$SP" join larry cli pull - >/dev/null 2>&1
)

# ── G4: park a writer between mkdir and owner-publication, then let a second
# writer try. Pre-fix, the second writer reclaimed the lock at 1 s, posted, and
# the parked (live) writer died with "could not publish pad-lock ownership" —
# its message lost despite having won the lock.
BAR="$WORK3/barrier"
(
  cd "$WORK3/proj" || exit 1
  HOME="$WORK3/home" STITCHPAD_NAME=dale STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER="$BAR" \
    "$SP" say "HOLDER-MSG" > "$WORK3/holder.out" 2>&1
  echo $? > "$WORK3/holder.rc"
) &
f1_pid=$!
_i=0; while [ ! -f "$BAR.ready" ] && [ "$_i" -lt 200 ]; do sleep 0.05; _i=$(( _i + 1 )); done

if [ ! -f "$BAR.ready" ]; then
  bad "G4 INVALID PROBE: writer never parked at the pre-owner barrier"
  bad "G4b INVALID PROBE (holder never ran)"
else
  # The claim marker must exist BEFORE ownership is published — that is the fix.
  if [ -f "$WORK3/proj/.stitchpad/.state/.lock/claiming" ]; then
    ok "G4a: the lock is claimed the instant mkdir wins, before owner is published"
  else
    bad "G4a: no claim marker while a writer is mid-publication — E1 can still steal"
  fi
  sleep 1.6   # exceed SP_LOCK_EMPTY_RECLAIM (1 s)
  contender_out="$(cd "$WORK3/proj" && HOME="$WORK3/home" STITCHPAD_TERMINAL_NAMESPACE=t2 \
    STITCHPAD_NAME=larry STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" say "THIEF-MSG" 2>&1)"
  contender_rc=$?
  printf 'go' > "$BAR.release"
  wait "$f1_pid" 2>/dev/null; f1_pid=""
  holder_rc="$(cat "$WORK3/holder.rc" 2>/dev/null || echo 99)"

  if [ "$contender_rc" -ne 0 ]; then
    ok "G4: a contender is REFUSED while the holder is mid-publication (rc=$contender_rc)"
  else
    bad "G4: contender acquired the lock from a LIVE claimant — the F1 steal is back"
  fi
  if [ "$holder_rc" = "0" ] && grep -q 'HOLDER-MSG' "$WORK3/proj/.stitchpad/stitchpad.md" 2>/dev/null; then
    ok "G4b: the holder kept the lock and its message landed"
  else
    bad "G4b: the holder lost its message (rc=$holder_rc) — robbed mid-publication"
  fi
fi

# ── G5: the ORIGINAL purpose of E1 must survive the fix. A claimant that is
# genuinely dead has to be reclaimed, or a crash wedges the pad forever.
# Each sub-pad needs its OWN terminal namespace. One terminal holds one identity
# per pad, so reusing the namespace here makes `join` refuse and the probe then
# measures a pad with no seat instead of the thing it claims to measure.
mkdir -p "$WORK3/proj2"
(
  cd "$WORK3/proj2" || exit 1
  export HOME="$WORK3/home" STITCHPAD_TERMINAL_NAMESPACE=g5 STITCHPAD_HEARTBEAT_AUTOSTART=0
  "$SP" init >/dev/null 2>&1
  "$SP" join dale cli pull - >/dev/null 2>&1
)
BAR2="$WORK3/barrier2"
(
  cd "$WORK3/proj2" || exit 1
  export HOME="$WORK3/home" STITCHPAD_TERMINAL_NAMESPACE=g5 STITCHPAD_HEARTBEAT_AUTOSTART=0
  STITCHPAD_NAME=dale STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER="$BAR2" \
    "$SP" say "DOOMED" >/dev/null 2>&1
) &
f1_pid=$!
_i=0; while [ ! -f "$BAR2.ready" ] && [ "$_i" -lt 200 ]; do sleep 0.05; _i=$(( _i + 1 )); done
claim_pid="$(cat "$WORK3/proj2/.stitchpad/.state/.lock/claiming" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$claim_pid" ]; then
  bad "G5 INVALID PROBE: no claim marker to kill"
else
  kill -KILL "$claim_pid" 2>/dev/null
  wait "$f1_pid" 2>/dev/null; f1_pid=""
  sleep 1.6
  if (cd "$WORK3/proj2" && HOME="$WORK3/home" STITCHPAD_TERMINAL_NAMESPACE=g5 \
      STITCHPAD_NAME=dale STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$SP" say "AFTER-CRASH" >/dev/null 2>&1); then
    ok "G5: a DEAD claimant's lock is still reclaimed — the crash path is intact"
  else
    bad "G5: a dead claimant wedges the pad — the fix broke empty-lock recovery"
  fi
fi

# ── G6: rollback must not rewind a pad whose history advanced under it.
mkdir -p "$WORK3/proj3"
(
  cd "$WORK3/proj3" || exit 1
  export HOME="$WORK3/home" STITCHPAD_TERMINAL_NAMESPACE=g6 STITCHPAD_HEARTBEAT_AUTOSTART=0
  "$SP" init >/dev/null 2>&1
  "$SP" join dale cli pull - >/dev/null 2>&1
  STITCHPAD_NAME=dale "$SP" say "COMMITTED-BY-OTHER-WRITER" >/dev/null 2>&1
)
G6_OUT="$(
  cd "$WORK3/proj3" || exit 1
  export PAD_DIR="$PWD/.stitchpad" PAD_STATE="$PWD/.stitchpad/.state"
  export PAD_GIT="$PWD/.stitchpad/stitchpad-git" PAD_MD="$PWD/.stitchpad/stitchpad.md"
  export STITCHPAD_HOME="$HERE/../tool" HOME="$WORK3/home"
  . "$HERE/../tool/bin/lib.sh" 2>/dev/null
  . "$HERE/../tool/bin/session-registry.sh" 2>/dev/null
  J="$PAD_STATE/j-g6"; mkdir -p "$J"
  printf '%s\n' "$PAD_MD" > "$J/.paths"; printf '1\n' > "$J/manifest"
  printf 'ZZSTALEZZ\n' > "$J/0"
  python3 -c "import os,sys; s=os.lstat(sys.argv[1]); print(s.st_dev,s.st_ino)" "$PAD_STATE" > "$J/.state-root"
  git --git-dir="$PAD_GIT" rev-parse HEAD~1 > "$J/.base-sha" 2>/dev/null || printf 'unborn' > "$J/.base-sha"
  # A fixture that never produced a second commit stamps "unborn", the guard
  # correctly declines to act on it, and the assertion below would then read as a
  # product failure. Report the base explicitly so a broken PROBE is visible as a
  # broken probe.
  printf '%s|%s|%s' \
    "$(cat "$J/.base-sha" 2>/dev/null)" \
    "$(sp_session_registry_journal_rollback "$J" "sid-g6" >/dev/null 2>&1; grep -c 'COMMITTED-BY-OTHER-WRITER' "$PAD_MD" 2>/dev/null)" \
    "$(grep -c 'ZZSTALEZZ' "$PAD_MD" 2>/dev/null)"
)"
g6_base="$(printf '%s' "$G6_OUT" | cut -d'|' -f1)"
g6_survived="$(printf '%s' "$G6_OUT" | cut -d'|' -f2)"
g6_clobbered="$(printf '%s' "$G6_OUT" | cut -d'|' -f3)"
if [ -z "$g6_base" ] || [ "$g6_base" = "unborn" ]; then
  bad "G6 INVALID PROBE: fixture has no prior commit to stamp (.base-sha='$g6_base') — nothing was actually tested"
elif [ "${g6_survived:-0}" -ge 1 ] 2>/dev/null && [ "$g6_clobbered" = "0" ]; then
  ok "G6: rollback refused to rewind a pad whose HEAD advanced — committed work kept"
else
  bad "G6: rollback destroyed committed work (survived=$g6_survived clobbered=$g6_clobbered)"
fi

_f1_cleanup

# ── Verdict ──────────────────────────────────────────────────────────────
echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
fi
echo "All $pass empty-lock-reclaim gates PASSED"
exit 0
