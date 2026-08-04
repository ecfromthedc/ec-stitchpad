#!/usr/bin/env bash
# artifact-contract-gate.sh — P3+P8: a seat that produces nothing is
# indistinguishable from one that is working — UNLESS the artifact contract
# is enforced.  This gate proves the contract functions and the lanes board.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1" >&2; }

cleanup() { rm -rf "$TMP"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/artifact-gate.XXXXXX")"
trap cleanup EXIT

# Run in the temp dir so stitchpad init creates the pad there
cd "$TMP"
export STITCHPAD_HOME="$ROOT/tool"
export PATH="$STITCHPAD_HOME/bin:$PATH"
unset HERDR_ HERDR_SURFACE HERDR_SESSION_ID HERDR_TOKEN HERDR_API
unset STITCHPAD_STEAL STITCHPAD_NAME STITCHPAD_PAD_DIR STITCHPAD_SESSION
export STITCHPAD_HEARTBEAT_AUTOSTART=0

# Initialise pad FIRST, then source lib and init paths
"$STITCHPAD_HOME/bin/stitchpad" init >/dev/null 2>&1 || true
source "$STITCHPAD_HOME/bin/lib.sh"
sp_init_paths

# =========================================================================
# G1: artifact primitives
# =========================================================================
echo "--- G1: artifact primitives ---"

# G1a: declare + verify missing
sp_artifact_declare test-seat "$TMP/nonexistent-file" 2>/dev/null
if sp_artifact_verify test-seat 2>/dev/null; then
  bad "G1a: verify returned 0 for missing artifact"
else
  ok "G1a: verify returns non-zero for missing artifact"
fi

# G1b: declare + create + verify present
REAL_FILE="$TMP/real-artifact.txt"
echo "done" > "$REAL_FILE"
sp_artifact_declare test-seat-2 "$REAL_FILE" 2>/dev/null
if sp_artifact_verify test-seat-2 2>/dev/null; then
  ok "G1b: verify returns 0 for present artifact"
else
  bad "G1b: verify returned non-zero for present artifact"
fi

# G1c: expected prints the path
EXPECTED="$(sp_artifact_expected test-seat-2)"
if echo "$EXPECTED" | grep -q "$REAL_FILE"; then
  ok "G1c: artifact_expected prints declared path"
else
  bad "G1c: artifact_expected did not print $REAL_FILE (got: $EXPECTED)"
fi

# G1d: clear removes claim
sp_artifact_clear test-seat
if [ -f "$PAD_STATE/artifact-expect.test-seat" ]; then
  bad "G1d: artifact_clear did not remove claim file"
else
  ok "G1d: artifact_clear removes claim file"
fi

# G1e: verify with no claim returns 0
sp_artifact_clear test-seat 2>/dev/null || true
if sp_artifact_verify test-seat 2>/dev/null; then
  ok "G1e: verify returns 0 when no claim exists (nothing to check)"
else
  bad "G1e: verify returned non-zero when no claim exists"
fi

# G1f: declare with no paths fails
if sp_artifact_declare empty-seat 2>/dev/null; then
  bad "G1f: declare with no paths should fail"
else
  ok "G1f: declare with no paths fails"
fi

# =========================================================================
# G2: lanes board integration
# =========================================================================
echo "--- G2: lanes board ---"

_now="$(date +%s)"
REG="$PAD_STATE/session-registry.jsonl"
mkdir -p "$PAD_STATE"

# Alice: terminal session, artifact declared but file does NOT exist
cat > "$REG" <<REGEOF
{"session_id":"sid-alice","name":"alice","provider":"openai","model":"gpt-4o","worktree":"$TMP/wt1","start":$_now,"last_activity":$((_now - 10)),"event":"terminal","request_count":5}
{"session_id":"sid-bob","name":"bob","provider":"anthropic","model":"claude-4","worktree":"$TMP/wt2","start":$_now,"last_activity":$_now,"event":"activity","request_count":3}
REGEOF

# Session-end marker for alice
mkdir -p "$PAD_STATE"
echo "completed" > "$PAD_STATE/session-end.sid-alice"

# Declare artifacts
sp_artifact_declare alice "$TMP/alice-should-exist.txt" 2>/dev/null
BOB_FILE="$TMP/bob-result.txt"
echo "bob's work" > "$BOB_FILE"
sp_artifact_declare bob "$BOB_FILE" 2>/dev/null

LANES_OUT="$("$STITCHPAD_HOME/bin/stitchpad" lanes 2>/dev/null || true)"

# G2a: alice terminal + missing artifact → FAILED
if echo "$LANES_OUT" | grep -q 'alice.*FAILED'; then
  ok "G2a: alice (terminal, missing artifact) shows FAILED"
else
  bad "G2a: alice should show FAILED — $(echo "$LANES_OUT" | grep alice || echo 'no alice row')"
fi

# G2b: bob active + present artifact → WORKING
if echo "$LANES_OUT" | grep -q 'bob.*WORKING'; then
  ok "G2b: bob (active, present artifact) shows WORKING"
else
  bad "G2b: bob should show WORKING — $(echo "$LANES_OUT" | grep bob || echo 'no bob row')"
fi

# G2c: bob artifact present = YES
if echo "$LANES_OUT" | grep -q 'bob.*YES'; then
  ok "G2c: bob artifact present = YES"
else
  bad "G2c: bob artifact present should be YES"
fi

# G2d: alice artifact present = NO
if echo "$LANES_OUT" | grep -q 'alice.*NO'; then
  ok "G2d: alice artifact present = NO"
else
  bad "G2d: alice artifact present should be NO"
fi

# =========================================================================
# G3: empty fleet
# =========================================================================
echo "--- G3: empty fleet ---"
rm -f "$REG" "$PAD_STATE"/artifact-expect.* "$PAD_STATE"/session-end.* 2>/dev/null || true
LANES_EMPTY="$("$STITCHPAD_HOME/bin/stitchpad" lanes 2>/dev/null || true)"
if echo "$LANES_EMPTY" | grep -qi 'no lanes\|empty roster'; then
  ok "G3a: empty fleet reported cleanly"
elif [ -z "${LANES_EMPTY##*LANE*}" ] && echo "$LANES_EMPTY" | grep -qv '[a-z]'; then
  # Header-only output with no data rows is also acceptable
  ok "G3a: empty fleet shows header only (no data rows)"
else
  bad "G3a: empty fleet handled — $(echo "$LANES_EMPTY" | head -3)"
fi

# =========================================================================
# MUTANT PROOF: sp_artifact_verify always returns 0
# =========================================================================
echo ""
echo "=== MUTANT PROOF ==="

LIB="$STITCHPAD_HOME/bin/lib.sh"
cp "$LIB" "$TMP/lib.sh.orig"

# Re-setup test data
_now="$(date +%s)"
cat > "$REG" <<REGEOF
{"session_id":"sid-alice","name":"alice","provider":"openai","model":"gpt-4o","worktree":"$TMP/wt1","start":$_now,"last_activity":$((_now - 10)),"event":"terminal","request_count":5}
REGEOF
echo "completed" > "$PAD_STATE/session-end.sid-alice"
sp_artifact_declare alice "$TMP/alice-should-exist.txt" 2>/dev/null

# Mutate: make sp_artifact_verify always return 0
python3 - "$LIB" << 'PYEOF'
import sys
text = open(sys.argv[1]).read()
old = '''sp_artifact_verify() {
  local name="${1:?usage: sp_artifact_verify <name>}" claim_file path missing=0
  claim_file="$PAD_STATE/artifact-expect.$name"
  [ -f "$claim_file" ] || return 0  # no claim = nothing to verify
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -e "$path" ]; then
      echo "  missing: $path" >&2
      missing=1
    fi
  done < "$claim_file"
  return "$missing"
}'''
new = '''sp_artifact_verify() {
  # MUTANT: always returns 0 — blindness re-introduced.
  # A seat that produces nothing is indistinguishable from one working.
  return 0
}'''
assert old in text, "MUTATION FAILED: sp_artifact_verify not found"
text2 = text.replace(old, new)
assert text2 != text, "MUTATION had no effect"
open(sys.argv[1], 'w').write(text2)
PYEOF

LANES_M="$("$STITCHPAD_HOME/bin/stitchpad" lanes 2>/dev/null || true)"

# Restore original
mv "$TMP/lib.sh.orig" "$LIB"

# The mutant MUST NOT show FAILED — it must show COMPLETE (blindness proved)
if echo "$LANES_M" | grep -q 'alice.*COMPLETE'; then
  ok "M1: mutant shows alice COMPLETE (blind) — PROVES BLIND"
else
  bad "M1: mutant did not show COMPLETE — $(echo "$LANES_M" | grep alice || echo 'no alice row')"
fi

if ! echo "$LANES_M" | grep -q 'alice.*FAILED'; then
  ok "M1: mutant does NOT show FAILED (blindness proven)"
else
  bad "M1: mutant still shows FAILED — gate is not detecting blindness"
fi

# =========================================================================
# VERDICT
# =========================================================================
echo ""
echo "=== RESULTS ==="
echo "Passed:  $PASSED"
echo "Failed:  $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
echo ""
echo "artifact-contract-gate: ALL GATES PASSED"
