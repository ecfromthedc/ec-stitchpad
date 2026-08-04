#!/usr/bin/env bash
# fixture-bleed-gate.sh — P11: a suite must create ZERO entities outside
# its own fixture root. Captured `heartbeat --touch flash-portability`
# was written into REAL pad state while a test ran — a fixture-named
# heartbeat bleeding into the operator's pad.
#
# Gate: create decoy pad, snapshot state, run suite, assert zero new state.
# Bleed = any new file in a .state/, .stitchpad/, .pasture/, or
# .stitchpad-terminals/ directory NOT under the suite's declared fixture root.
#
# Mutant proof (G2): suite explicitly joins into decoy pad → RED.
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
_kill_path() {
  # Kill processes whose args reference a path — via PID-list, never bare pkill
  local _path="$1"
  for _pid in $(ps aux 2>/dev/null | grep "$_path" | grep -v grep | awk '{print $2}'); do
    kill "$_pid" 2>/dev/null || true
  done
  sleep 0.5
}

state_snapshot() {
  # Snapshot all state-holding directories under a pad root
  local _pad="$1" _out="$2"
  {
    find "$_pad" -path '*/.state/*' -type f 2>/dev/null || true
    find "$_pad" -path '*/.stitchpad-terminals/*' -type f 2>/dev/null || true
    find "$_pad" -path '*/.pasture-terminals/*' -type f 2>/dev/null || true
  } | sort > "$_out"
}

state_diff() { comm -13 "$1" "$2" 2>/dev/null || true; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-bleed-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true

echo ""
echo "=== P11: fixture-bleed-gate ==="
echo ""

# ===========================================================================
# G1: CLEAN SUITE — zero bleed into decoy pad
# ===========================================================================
echo "--- G1: clean suite (isolated HOME), zero bleed ---"

DECOY="$TMP/decoy-pad"
CLEAN_HOME="$TMP/clean-home"
FIXTURE="$TMP/fixture-suite"
mkdir -p "$DECOY" "$CLEAN_HOME" "$FIXTURE"

# Create decoy pad with isolated HOME
(
  export HOME="$CLEAN_HOME"
  cd "$DECOY"
  "$SP" init --name decoy-pad >/dev/null 2>&1
)
# Kill any watcher spawned by init
_kill_path "$DECOY"
sleep 0.5
_cleanup_pids

# Snapshot BEFORE
BEFORE="/tmp/sp-bleed-before.$$"
rm -f "$BEFORE"
state_snapshot "$DECOY" "$BEFORE"
_before_count="$(wc -l < "$BEFORE" 2>/dev/null | tr -d ' ')"
echo "  decoy baseline: ${_before_count:-0} state entries"

# Run a clean suite — operates only in its own fixture dir, isolated HOME
cat > "$FIXTURE/clean-suite.sh" << 'SUITE'
#!/usr/bin/env bash
set -euo pipefail
T="$(mktemp -d /tmp/sp-clean-fixture.XXXXXX)"
echo "clean suite in $T" > "$T/log.txt"
sleep 0.5
rm -rf "$T"
SUITE
chmod +x "$FIXTURE/clean-suite.sh"

(
  export HOME="$CLEAN_HOME"
  bash "$FIXTURE/clean-suite.sh" >/dev/null 2>&1
)
_cleanup_pids
_kill_path "$DECOY"
sleep 0.5

# Snapshot AFTER
AFTER="/tmp/sp-bleed-after.$$"
rm -f "$AFTER"
state_snapshot "$DECOY" "$AFTER"
_after_count="$(wc -l < "$AFTER" 2>/dev/null | tr -d ' ')"

# Compute diff
NEW="$(state_diff "$BEFORE" "$AFTER")"
_new_count="$(echo "$NEW" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

if [ "${_new_count:-0}" -eq 0 ]; then
  ok "G1a: zero bleed — decoy state unchanged ($_before_count entries)"
else
  bad "G1a: BLEED — $_new_count new entries in decoy pad"
  echo "$NEW" | head -5 | while read f; do echo "       NEW: $f"; done
fi

rm -f "$BEFORE" "$AFTER"

# ===========================================================================
# G2: MUTANT PROOF — explicit bleed into decoy → RED
# ===========================================================================
echo ""
echo "--- G2: mutant — explicit join into decoy → RED ---"

MUTANT_HOME="$TMP/mutant-home"
mkdir -p "$MUTANT_HOME"

BEFORE_M="/tmp/sp-bleed-m-before.$$"
rm -f "$BEFORE_M"
state_snapshot "$DECOY" "$BEFORE_M"
_before_m="$(wc -l < "$BEFORE_M" 2>/dev/null | tr -d ' ')"
echo "  pre-mutant decoy state: ${_before_m:-0} entries"

# Mutant: suite joins into the decoy pad directly
(
  export HOME="$MUTANT_HOME"
  cd "$DECOY"
  STITCHPAD_NAME=bleeder "$SP" join bleeder off >/dev/null 2>&1 || true
  STITCHPAD_NAME=bleeder "$SP" say "I leaked into the decoy pad" >/dev/null 2>&1 || true
)
_kill_path "$DECOY"
sleep 0.5
_cleanup_pids

AFTER_M="/tmp/sp-bleed-m-after.$$"
rm -f "$AFTER_M"
state_snapshot "$DECOY" "$AFTER_M"
_after_m="$(wc -l < "$AFTER_M" 2>/dev/null | tr -d ' ')"

NEW_M="$(state_diff "$BEFORE_M" "$AFTER_M")"
_new_m="$(echo "$NEW_M" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

echo "  post-mutant decoy state: ${_after_m:-0} entries"
echo "  new entries: ${_new_m:-0}"

if [ "${_new_m:-0}" -gt 0 ]; then
  ok "G2a: bleed detected — $_new_m new entries in decoy after mutant join"
else
  bad "G2a: bleed NOT detected — gate is BLIND to explicit join"
fi

if grep -q 'bleeder\|leaked' "$DECOY/.stitchpad/stitchpad.md" 2>/dev/null; then
  ok "G2b: bleeder message found in decoy pad (contamination confirmed)"
else
  bad "G2b: bleeder message NOT found — join didn't take"
fi

rm -f "$BEFORE_M" "$AFTER_M"

# ===========================================================================
# G3: TERMINAL CLAIM BLEED — suite must not create terminal claims
#      outside its isolated HOME
# ===========================================================================
echo ""
echo "--- G3: terminal claim bleed ---"

ISO_HOME="$TMP/iso-home"
mkdir -p "$ISO_HOME"

# Count terminal claims before
_before_terms="$(find "$ISO_HOME/.stitchpad-terminals" -type f -not -name '.mutex.*' -not -name '.byname.*' 2>/dev/null | wc -l | tr -d ' ')"
echo "  terminal claims before: ${_before_terms:-0}"

# Run a stitchpad operation with this HOME — it creates claims inside HOME
PAD_G3="$TMP/pad-g3"
mkdir -p "$PAD_G3"

(
  export HOME="$ISO_HOME"
  export STITCHPAD_TERMINAL_NAMESPACE="bleed-gate-$$"
  cd "$PAD_G3"
  "$SP" init --name g3-pad >/dev/null 2>&1
  STITCHPAD_NAME=charlie "$SP" join charlie codex pull - >/dev/null 2>&1
)
_kill_path "$PAD_G3"
_cleanup_pids
sleep 0.5

_after_terms="$(find "$ISO_HOME/.stitchpad-terminals" -type f -not -name '.mutex.*' -not -name '.byname.*' 2>/dev/null | wc -l | tr -d ' ')"

if [ "${_after_terms:-0}" -gt 0 ]; then
  ok "G3a: terminal claims created inside isolated HOME (expected — ${_after_terms} claims)"
else
  bad "G3a: no terminal claims created (join may have failed silently)"
fi

# But the claim must NOT be in the REAL operator home
_real_home_count="$(find "$HOME/.stitchpad-terminals" -type f -name "*bleed-gate*" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${_real_home_count:-0}" -eq 0 ]; then
  ok "G3b: zero terminal claims in real HOME (no fixture bleed into operator state)"
else
  bad "G3b: BLEED — $_real_home_count fixture claims in real HOME/.stitchpad-terminals"
  find "$HOME/.stitchpad-terminals" -type f -name "*bleed-gate*" 2>/dev/null | head -3 | while read f; do
    echo "       BLEED: $f"
  done
fi

# ===========================================================================
echo ""
cd "$ROOT"
_cleanup_pids
rm -f "/tmp/sp-bleed-before.$$" "/tmp/sp-bleed-after.$$" "/tmp/sp-bleed-m-before.$$" "/tmp/sp-bleed-m-after.$$" 2>/dev/null || true

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll fixture-bleed gates PASSED.\n'; exit 0; }
printf '\nSome fixture-bleed gates FAILED.\n'; exit 1
