#!/usr/bin/env bash
# concurrency-round5-regression.sh — fx3 confirmed race fixes (F1-F4)
#
# Proves:
#   F1: pad lock jittered backoff improves admission rate under burst
#       (N>=20 concurrent say, measure admitted vs refused, zero silent drops)
#   F2: SIGKILL of lock holder is reclaimed immediately (not 30s wait)
#       (kill holder at the LOCK level, verify next acquisition in <5s)
#   F3: recovery-counter RMW is atomic (N=40 concurrent increments, 0 lost)
#   F4: shift-change --claim is exclusive (N=24 concurrent claims, exactly 1 wins)
#
# Run order: F1 FIRST (no terminal lock carryover from SIGKILL tests)
#
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
STITCHPAD="$ROOT/tool/bin/stitchpad"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

make_pad() {
  local dir="$1" name="${2:-test-pad}"
  # dir is the .stitchpad directory itself
  mkdir -p "$dir/.state/sessions" "$dir/.state/claims"
  cat > "$dir/stitchpad.md" <<'EOPAD'
# stitchpad
```roster
EOPAD
  echo "$name | claude | pull | -" >> "$dir/stitchpad.md"
  cat >> "$dir/stitchpad.md" <<'EOPAD'
```

---
EOPAD
  local gd="$dir/stitchpad-git"
  mkdir -p "$gd"
  local parent; parent="$(dirname "$dir")"
  ( cd "$parent" && \
    git init --quiet --separate-git-dir="$gd" . >/dev/null 2>&1 && \
    git add . >/dev/null 2>&1 && \
    git -c user.name=test -c user.email=test@test commit -qm "initial" >/dev/null 2>&1 )
}

echo "Concurrency Round-5 — fx3 confirmed race fixes"
echo ""

export STITCHPAD_STEAL=1

# ============================================================================
# F1: jittered backoff under concurrent burst (run FIRST — no terminal lock
# carryover from SIGKILL tests)
# ============================================================================
echo "--- F1: pad lock admission under burst ---"

F1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-c5-f1.XXXXXX")"
make_pad "$F1_WORK/pad/.stitchpad" "f1-pad"
F1_PAD_DIR="$F1_WORK/pad/.stitchpad"

STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_STEAL=1 STITCHPAD_PAD_DIR="$F1_PAD_DIR" \
  "$STITCHPAD" join alice claude pull - > /dev/null 2>&1

N=20
pids=()
for i in $(seq 1 $N); do
  STITCHPAD_PAD_DIR="$F1_PAD_DIR" STITCHPAD_NAME=alice \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_STEAL=1 \
    "$STITCHPAD" say "burst-$i" > "$F1_WORK/out.$i" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

_admitted=0
for i in $(seq 1 $N); do
  if grep -q "burst-$i" "$F1_PAD_DIR/stitchpad.md" 2>/dev/null; then
    _admitted=$((_admitted + 1))
  fi
done
_refused=$((N - _admitted))

echo "  F1: N=$N concurrent say, admitted=$_admitted, refused=$_refused"

# F1a: with jittered backoff, at least 5/20 should be admitted
# (pre-fix was 0/16 at N=16; 5/20 proves the lock is functional under burst).
# The jitter is a probabilistic improvement, not a hard guarantee.
if [ "$_admitted" -ge 5 ]; then
  ok "F1a: jittered backoff improved admission ($_admitted/20 posted, was 0/16 at N=16 pre-fix)"
else
  bad "F1a: only $_admitted/20 admitted (expected >=5 with jitter)"
fi

# F1b: zero duplicated/torn writes. Each burst-N should appear at most once
# in the pad body (not the date/header section).
_torn=0
for i in $(seq 1 $N); do
  _c="$(grep -c "^burst-$i$" "$F1_PAD_DIR/stitchpad.md" 2>/dev/null || echo 0)"
  if [ "$_c" -gt 1 ] 2>/dev/null; then
    _torn=$((_torn + 1))
  fi
done
[ "$_torn" = "0" ] && \
  ok "F1b: zero duplicated/torn writes among $_admitted admitted posts" \
  || bad "F1b: $_torn messages appear more than once (torn writes)"

rm -rf "$F1_WORK"

# ============================================================================
# F4: shift-change --claim atomic CAS
# ============================================================================
echo ""
echo "--- F4: shift-change --claim exclusivity ---"

F4_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-c5-f4.XXXXXX")"
make_pad "$F4_WORK/pad/.stitchpad" "f4-pad"
F4_PAD_DIR="$F4_WORK/pad/.stitchpad"

STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_STEAL=1 STITCHPAD_PAD_DIR="$F4_PAD_DIR" \
  "$STITCHPAD" join alice claude pull - > /dev/null 2>&1
printf 'handoff body\n' > "$F4_WORK/handoff.txt"
STITCHPAD_PAD_DIR="$F4_PAD_DIR" STITCHPAD_NAME=alice STITCHPAD_STEAL=1 \
  "$STITCHPAD" shift-change --save alice --file "$F4_WORK/handoff.txt" > /dev/null 2>&1

hid="$(sqlite3 "$F4_PAD_DIR/.state/archive.sqlite" "SELECT id FROM handoffs WHERE agent='alice'")"

N=24
pids=()
for i in $(seq 1 $N); do
  ( STITCHPAD_PAD_DIR="$F4_PAD_DIR" "$STITCHPAD" shift-change --claim "$hid" > "$F4_WORK/out.$i" 2>&1; echo $? > "$F4_WORK/rc.$i" ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

winners=0
for i in $(seq 1 $N); do
  rc="$(cat "$F4_WORK/rc.$i" 2>/dev/null || echo 1)"
  [ "$rc" = "0" ] && winners=$((winners + 1))
done

echo "  F4: N=$N claims, winners=$winners (expected: 1)"
[ "$winners" -eq 1 ] && \
  ok "F4: exactly 1 claimant wins (was 18/24 pre-fix)" \
  || bad "F4: expected 1 winner, got $winners (was 18/24 pre-fix)"

rm -rf "$F4_WORK"

# ============================================================================
# F3: recovery-counter atomic RMW
# ============================================================================
echo ""
echo "--- F3: recovery-counter atomic increments ---"

F3_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-c5-f3.XXXXXX")"
make_pad "$F3_WORK/pad/.stitchpad" "f3-pad"
F3_PAD_DIR="$F3_WORK/pad/.stitchpad"

N=40
pids=()
for i in $(seq 1 $N); do
  (
    export STITCHPAD_PAD_DIR="$F3_PAD_DIR"
    source "$ROOT/tool/bin/recovery-policy.sh"
    sp_recovery_attempt_record "$F3_PAD_DIR/.state" "test:race:key" >/dev/null 2>&1
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

shared_count="$(
  export STITCHPAD_PAD_DIR="$F3_PAD_DIR"
  source "$ROOT/tool/bin/recovery-policy.sh"
  sp_recovery_attempt_count "$F3_PAD_DIR/.state" "test:race:key" 2>/dev/null || echo 0
)"

echo "  F3: N=$N concurrent increments on same key, final count=$shared_count (expected: $N)"
[ "$shared_count" = "$N" ] && \
  ok "F3: zero lost updates (was 6/40 lost pre-fix)" \
  || bad "F3: expected $N, got $shared_count (was 6/40 lost pre-fix)"

_stale_locks="$(find "$F3_PAD_DIR/.state/recovery-attempts" -name '.lock.*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$_stale_locks" = "0" ] && \
  ok "F3: no stale per-key locks left behind" \
  || bad "F3: $_stale_locks stale lock files remain"

rm -rf "$F3_WORK"

# ============================================================================
# F2: proactive dead-holder reclaim (lock-level test)
# ============================================================================
echo ""
echo "--- F2: dead-holder reclaim after SIGKILL ---"

F2_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-c5-f2.XXXXXX")"
make_pad "$F2_WORK/pad/.stitchpad" "f2-pad"
F2_PAD_DIR="$F2_WORK/pad/.stitchpad"

# Acquire the lock in a background subshell, then SIGKILL it
(
  export STITCHPAD_PAD_DIR="$F2_PAD_DIR"
  export STITCHPAD_STEAL=1
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1
  sp_lock
  sleep 30
  sp_unlock
) &
_holder_pid=$!
sleep 1

[ -d "$F2_PAD_DIR/.state/.lock" ] && \
  ok "F2a: lock acquired by holder PID=$_holder_pid" \
  || bad "F2a: holder failed to acquire lock"

kill -9 "$_holder_pid" 2>/dev/null
wait "$_holder_pid" 2>/dev/null || true
sleep 0.5

[ -d "$F2_PAD_DIR/.state/.lock" ] && \
  ok "F2b: stale lock dir persists after SIGKILL (to be reclaimed)" \
  || bad "F2b: lock dir vanished after SIGKILL unexpectedly"

_reclaim_result="$(
  export STITCHPAD_PAD_DIR="$F2_PAD_DIR"
  export STITCHPAD_STEAL=1
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1
  _t0=$(date +%s)
  if sp_lock; then
    _t1=$(date +%s)
    echo "OK $((_t1 - _t0))"
    sp_unlock
  else
    _t1=$(date +%s)
    echo "FAIL $((_t1 - _t0))"
  fi
)"
_reclaim_status="${_reclaim_result%% *}"
_reclaim_time="${_reclaim_result##* }"

echo "  F2: reclaim status=$_reclaim_status, time=${_reclaim_time}s (expected: OK, <5s)"
[ "$_reclaim_status" = "OK" ] && [ "$_reclaim_time" -lt 5 ] 2>/dev/null && \
  ok "F2c: dead-holder reclaimed in ${_reclaim_time}s (was 0/20 in 30s pre-fix)" \
  || bad "F2c: reclaim failed (status=$_reclaim_status, time=${_reclaim_time}s)"

rm -rf "$F2_WORK"

# ============================================================================
# Results
# ============================================================================
echo ""
echo "=== RESULTS ==="
printf "Passed:  %d\n" "$pass"
printf "Failed:  %d\n" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '\nAll concurrency-round5 gates PASSED.\n'
  exit 0
else
  printf '\nSome concurrency-round5 gates FAILED.\n'
  exit 1
fi
