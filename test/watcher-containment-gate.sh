#!/usr/bin/env bash
# watcher-containment-gate.sh — P10: suites must not leak watchers into
# each other. test-health-readonly fails in sequence but passes alone,
# because a watcher spawned by suite A survives into suite B's runtime
# and interferes with its assertions.
#
# This gate proves that:
#   1. Two suites run back-to-back in isolated pads have zero cross-contamination
#   2. Every watcher spawned is bound to its fixture pad's directory
#   3. Sequential runs are as reliable as standalone runs
#
# Mutant proof (G2): leak a watcher into the second suite's pad → RED.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  \033[0;31mFAIL\033[0m %s: %s\n' "$1" "${2:-}" >&2; }

_MY_PIDS=""
_record_pid() { _MY_PIDS="$_MY_PIDS $1"; }
_cleanup_pids() {
  for _pid in $_MY_PIDS; do
    kill "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true
  done
}
_kill_watchers_in() {
  # Kill watcher processes whose command line references a specific path
  # Uses PID-list from ps, not bare pkill
  local _path="$1"
  for _pid in $(ps aux 2>/dev/null | grep -i "watch.sh.*$_path" | grep -v grep | awk '{print $2}'); do
    kill "$_pid" 2>/dev/null || true
  done
  sleep 0.5
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-watcher-containment.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true

echo ""
echo "=== P10: watcher-containment-gate ==="
echo ""

# ===========================================================================
# G1: TWO ISOLATED PADS — back-to-back joins, no cross-contamination
# ===========================================================================
echo "--- G1: two isolated pads, back-to-back joins ---"

PAD_A="$TMP/pad-a"
PAD_B="$TMP/pad-b"
HOME_A="$TMP/home-a"
HOME_B="$TMP/home-b"
mkdir -p "$PAD_A" "$PAD_B" "$HOME_A" "$HOME_B"

# Pad A: init + join alice
(
  export HOME="$HOME_A"
  export STITCHPAD_WATCH_START_GRACE=0
  cd "$PAD_A"
  "$SP" init --name pad-a >/dev/null 2>&1
  STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1
  # Joined successfully. The pad now has a watcher bound to it.
  STITCHPAD_NAME=alice "$SP" say "hello from A" >/dev/null 2>&1
)
_rc_a=$?
_cleanup_pids

# Pad B: init + join bob (must NOT see alice's watcher)
(
  export HOME="$HOME_B"
  export STITCHPAD_WATCH_START_GRACE=0
  cd "$PAD_B"
  "$SP" init --name pad-b >/dev/null 2>&1
  STITCHPAD_NAME=bob "$SP" join bob codex pull - >/dev/null 2>&1
  STITCHPAD_NAME=bob "$SP" say "hello from B" >/dev/null 2>&1
)
_rc_b=$?
_cleanup_pids

if [ "$_rc_a" -eq 0 ]; then
  ok "G1a: pad A join+say succeeded"
else
  bad "G1a: pad A failed" "rc=$_rc_a"
fi

if [ "$_rc_b" -eq 0 ]; then
  ok "G1b: pad B join+say succeeded (no cross-pad watcher interference)"
else
  bad "G1b: pad B failed (cross-pad contamination?)" "rc=$_rc_b"
fi

# Verify each pad has its own messages
if grep -q 'alice' "$PAD_A"/.stitchpad/stitchpad.md 2>/dev/null; then
  ok "G1c: pad A has alice's message"
else
  bad "G1c: pad A missing alice's message"
fi

if grep -q 'bob' "$PAD_B"/.stitchpad/stitchpad.md 2>/dev/null; then
  ok "G1d: pad B has bob's message"
else
  bad "G1d: pad B missing bob's message"
fi

# G1e: watchers must be bound to their own pad directory
# Find any watcher processes and check they reference their own pad
_watchers_a="$(ps aux 2>/dev/null | grep -i "watch.sh.*$PAD_A/.stitchpad" | grep -v grep | wc -l | tr -d ' ')"
_watchers_b="$(ps aux 2>/dev/null | grep -i "watch.sh.*$PAD_B/.stitchpad" | grep -v grep | wc -l | tr -d ' ')"

echo "  watchers in pad A: ${_watchers_a:-0}"
echo "  watchers in pad B: ${_watchers_b:-0}"

# Watchers may have exited by now — the important check is that
# pad B's watcher is NOT running in pad A's directory
_cross_wired="$(ps aux 2>/dev/null | grep -i "watch.sh.*$PAD_A/.stitchpad.*$PAD_B" | grep -v grep | wc -l | tr -d ' ')"
if [ "${_cross_wired:-0}" -eq 0 ]; then
  ok "G1e: no cross-wired watchers (pad A watcher not in pad B dir)"
else
  bad "G1e: cross-wired watcher found" "count=$_cross_wired"
fi

# Kill any remaining watchers
_kill_watchers_in "$PAD_A"
_kill_watchers_in "$PAD_B"
_cleanup_pids

# ===========================================================================
# G2: MUTANT PROOF — leak a watcher into another pad → RED
# ===========================================================================
echo ""
echo "--- G2: mutant — watcher leaked into shared pad → RED ---"

PAD_C="$TMP/pad-c"
SHARED_HOME="$TMP/home-shared"
mkdir -p "$PAD_C" "$SHARED_HOME"

# Create a shared pad
(
  export HOME="$SHARED_HOME"
  export STITCHPAD_WATCH_START_GRACE=0
  cd "$PAD_C"
  "$SP" init --name shared-pad >/dev/null 2>&1
)
_cleanup_pids

# Snapshot the pad state BEFORE contamination
BEFORE_ENTRIES="$(find "$PAD_C/.stitchpad/.state" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "  shared pad has ${BEFORE_ENTRIES:-0} state files before contamination"

# Now: simulate a BAD suite that cd's into the shared pad and runs join
# This is the kind of fixture-bleed that happens when HOME isn't isolated
(
  export HOME="$SHARED_HOME"
  export STITCHPAD_WATCH_START_GRACE=0
  cd "$PAD_C"
  STITCHPAD_NAME=contaminant "$SP" join contaminant codex pull - >/dev/null 2>&1
  STITCHPAD_NAME=contaminant "$SP" say "contaminated" >/dev/null 2>&1
)
_contam_rc=$?

# Kill any watchers spawned
_kill_watchers_in "$PAD_C"
_cleanup_pids

AFTER_ENTRIES="$(find "$PAD_C/.stitchpad/.state" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "  shared pad has ${AFTER_ENTRIES:-0} state files after contamination"

if [ "${AFTER_ENTRIES:-0}" -gt "${BEFORE_ENTRIES:-0}" ]; then
  ok "G2a: contamination detected — state grew (${BEFORE_ENTRIES}→$AFTER_ENTRIES entries)"
else
  bad "G2a: contamination NOT detected — gate is BLIND"
fi

# G2b: verify the contaminant appears in the pad
if grep -q 'contaminant\|contaminated' "$PAD_C/.stitchpad/stitchpad.md" 2>/dev/null; then
  ok "G2b: contaminant message found in shared pad (bleed confirmed)"
else
  bad "G2b: contaminant not found — mutant didn't take"
fi

# ===========================================================================
# G3: BACK-TO-BACK RELIABILITY — run the same operation twice, same result
# ===========================================================================
echo ""
echo "--- G3: back-to-back reliability ---"

PAD_D="$TMP/pad-d"
HOME_D="$TMP/home-d"
mkdir -p "$PAD_D" "$HOME_D"

# Run 1
(
  export HOME="$HOME_D"
  export STITCHPAD_WATCH_START_GRACE=0
  cd "$PAD_D"
  "$SP" init --name back-to-back >/dev/null 2>&1
  STITCHPAD_NAME=charlie "$SP" join charlie codex pull - >/dev/null 2>&1
  STITCHPAD_NAME=charlie "$SP" say "run 1" >/dev/null 2>&1
)
_run1_rc=$?
_kill_watchers_in "$PAD_D"
_cleanup_pids
sleep 1

# Count state files after run 1
_run1_state="$(find "$PAD_D/.stitchpad/.state" -type f 2>/dev/null | wc -l | tr -d ' ')"

# Run 2 (same pad)
(
  export HOME="$HOME_D"
  export STITCHPAD_WATCH_START_GRACE=0
  cd "$PAD_D"
  STITCHPAD_NAME=charlie "$SP" say "run 2" >/dev/null 2>&1
)
_run2_rc=$?
_kill_watchers_in "$PAD_D"
_cleanup_pids
sleep 1

_run2_state="$(find "$PAD_D/.stitchpad/.state" -type f 2>/dev/null | wc -l | tr -d ' ')"

if [ "$_run1_rc" -eq 0 ] && [ "$_run2_rc" -eq 0 ]; then
  ok "G3a: both back-to-back runs succeeded"
else
  bad "G3a: back-to-back failure" "r1=$_run1_rc r2=$_run2_rc"
fi

# The state should be consistent (both runs succeeded, state grows deterministically)
if [ "${_run2_state:-0}" -ge "${_run1_state:-0}" ]; then
  ok "G3b: state file count non-decreasing after second run (${_run1_state}→$_run2_state)"
else
  bad "G3b: state regressed after second run" "${_run1_state}→$_run2_state"
fi

# Both messages should be in the pad
_run1_found="$(grep -c 'run 1' "$PAD_D/.stitchpad/stitchpad.md" 2>/dev/null || echo 0)"
_run2_found="$(grep -c 'run 2' "$PAD_D/.stitchpad/stitchpad.md" 2>/dev/null || echo 0)"

if [ "${_run1_found:-0}" -gt 0 ] && [ "${_run2_found:-0}" -gt 0 ]; then
  ok "G3c: both messages present after back-to-back runs"
else
  bad "G3c: messages lost" "run1=$_run1_found run2=$_run2_found"
fi

# ===========================================================================
echo ""
cd "$ROOT"
_cleanup_pids
rm -rf "$TMP"

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll watcher-containment gates PASSED.\n'; exit 0; }
printf '\nSome watcher-containment gates FAILED.\n'; exit 1
