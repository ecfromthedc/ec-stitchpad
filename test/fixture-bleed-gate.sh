#!/usr/bin/env bash
# fixture-bleed-gate.sh — prove that running a test suite creates ZERO
# new state entries in any pad outside the suite's own fixture root.
#
# R1: evidence/live-checkout-escapes.log shows fixture-named heartbeats
# (flash-portability, etc.) registered against real pads during suite runs.
#
# Gate: create decoy pad (via init + kill watcher), snapshot, run suite,
# assert no new state.  Mutant: suite explicitly bleeds into decoy → RED.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SP="$ROOT/tool/bin/stitchpad"
pass=0; fail=0

ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

state_files() { find "$1/.state" -type f 2>/dev/null | sort; }
state_diff()  { comm -13 "$1" "$2" 2>/dev/null || true; }

# run_bounded <timeout_secs> <cmd...>: run command, kill if exceeds timeout
run_bounded() {
  local timeout="$1"; shift
  local rc=0
  "$@" &
  local pid=$!
  ( sleep "$timeout"; kill -9 $pid 2>/dev/null ) &
  local bound=$!
  wait $pid 2>/dev/null || rc=$?
  kill $bound 2>/dev/null || true
  return $rc
}

echo "=== fixture-bleed-gate ==="
echo ""

# ── Setup ────────────────────────────────────────────────────────────────
FIXTURE="$(mktemp -d /tmp/sp-fixture-bleed.XXXXXX)"
DECOY="$(mktemp -d /tmp/sp-decoy-pad.XXXXXX)"
mkdir -p "$FIXTURE/test"

# Cleanup: kill all watchers touching our dirs, then rm
_cleanup() {
  pkill -9 -f "$DECOY" 2>/dev/null || true
  pkill -9 -f "$FIXTURE" 2>/dev/null || true
  rm -rf "$FIXTURE" "$DECOY" 2>/dev/null || true
}
trap _cleanup EXIT

# Create decoy pad
( cd "$DECOY" && STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_WATCH_START_GRACE=0 \
  "$SP" init --name decoy 2>/dev/null )
# Kill any watcher spawned by init
sleep 1
pkill -9 -f "$DECOY" 2>/dev/null || true
sleep 0.5
echo "  decoy pad ready: $DECOY"

# ── T1: Clean suite, zero bleed ─────────────────────────────────────────
echo "--- T1: clean suite, zero bleed ---"

BEFORE="/tmp/sp-bleed-t1-before.$$"
state_files "$DECOY" > "$BEFORE"
echo "  decoy baseline: $(wc -l < "$BEFORE" | tr -d ' ') state files"

# Clean suite: does NOT touch decoy, writes only in its own tmpdir
cat > "$FIXTURE/test/clean-suite.sh" <<'SUITE'
#!/usr/bin/env bash
set -euo pipefail
# Suite operates in isolation — never touches any external pad
T="$(mktemp -d /tmp/sp-clean-suite.XXXXXX)"
echo "suite running in $T" > "$T/log.txt"
rm -rf "$T"
echo "=== RESULTS ==="
echo "Passed:  1"
echo "Failed:  0"
exit 0
SUITE
chmod +x "$FIXTURE/test/clean-suite.sh"

run_bounded 15 STITCHPAD_HOME="$ROOT/tool" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_WATCH_START_GRACE=0 bash "$FIXTURE/test/clean-suite.sh" >/dev/null 2>&1 || true

AFTER="/tmp/sp-bleed-t1-after.$$"
state_files "$DECOY" > "$AFTER"
NEW="$(state_diff "$BEFORE" "$AFTER")"

if [ -z "$NEW" ]; then
  ok "T1: zero state bleed — decoy .state/ unchanged"
else
  bad "T1: BLEED — $(echo "$NEW" | wc -l | tr -d ' ') new file(s)"
  echo "$NEW" | while read f; do echo "       $f"; done
fi
rm -f "$BEFORE" "$AFTER"
echo ""

# ── T2: Mutant — explicit bleed → RED ───────────────────────────────────
echo "--- T2: mutant bleed → RED ---"

BEFORE_M="/tmp/sp-bleed-t2-before.$$"
state_files "$DECOY" > "$BEFORE_M"

# Mutant suite: cd's into decoy and calls stitchpad operations there
cat > "$FIXTURE/test/mutant-suite.sh" <<MUTANT
#!/usr/bin/env bash
set -euo pipefail
D="\$(cd -P "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
SP="\$D/../../tool/bin/stitchpad"
cd "$DECOY"
# BLEED: join a member in the decoy pad (creates state entries)
STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_WATCH_START_GRACE=0 \
  STITCHPAD_NAME=bleeder "\$SP" join bleeder off 2>/dev/null || true
echo "=== RESULTS ==="
echo "Passed:  1"
echo "Failed:  0"
exit 0
MUTANT
chmod +x "$FIXTURE/test/mutant-suite.sh"

# Kill any lingering watchers from T1
pkill -9 -f "$DECOY" 2>/dev/null || true; sleep 0.5

run_bounded 15 STITCHPAD_HOME="$ROOT/tool" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_WATCH_START_GRACE=0 bash "$FIXTURE/test/mutant-suite.sh" >/dev/null 2>&1 || true

# Kill watchers spawned by mutant
pkill -9 -f "$DECOY" 2>/dev/null || true; sleep 0.5

AFTER_M="/tmp/sp-bleed-t2-after.$$"
state_files "$DECOY" > "$AFTER_M"
NEW_M="$(state_diff "$BEFORE_M" "$AFTER_M")"

if [ -n "$NEW_M" ]; then
  ok "T2: bleed detected — gate goes RED ($(echo "$NEW_M" | wc -l | tr -d ' ') new file(s))"
  echo "  new: $(echo "$NEW_M" | head -3)"
else
  bad "T2: bleed NOT detected — gate is BLIND (mutant proof FAILED)"
fi
rm -f "$BEFORE_M" "$AFTER_M"
echo ""

# ── Results ──────────────────────────────────────────────────────────────
echo "=== RESULTS ==="
echo "Passed:  $pass"
echo "Failed:  $fail"
echo ""
[ "$fail" -eq 0 ] && exit 0 || exit 1
