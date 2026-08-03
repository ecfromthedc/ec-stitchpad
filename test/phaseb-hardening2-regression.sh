#!/usr/bin/env bash
# phaseb-hardening2-regression.sh — R1-R4 hardening round 2 regression tests
#
# Proves the four confirmed defects from flash's re-attack
# (flash-reattack-phaseb-88ce8ca.md) are fixed:
#
#   R1: cross-seat corruption — recovery uses STAMPED sid, not caller's
#   R2: anonymous recovery — crashed markers restored via stamped sid
#   R3: stale-restore SEVERE — recovery REFUSES when HEAD advanced past base
#   R4: fresh-regular-dir swap — unreachable journal branch fails CLOSED
#
# Each test reproduces flash's attack shape then asserts the fix.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
STITCHPAD="$ROOT/tool/bin/stitchpad"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

# ── helpers (mirrors phaseb-hardening-regression.sh) ─────────────────────

make_pad() {
  local dir="$1" name="${2:-test-pad}"
  mkdir -p "$dir/.stitchpad/.state/sessions" "$dir/.stitchpad/.state/claims"
  cat > "$dir/.stitchpad/stitchpad.md" <<'EOPAD'
```roster
alice | claude | pull | -
bob   | ocean  | push | target-123
```
EOPAD
  local gd="$dir/.stitchpad/stitchpad-git"
  mkdir -p "$gd"
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" init -q
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" config user.email "test@test.com"
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" config user.name "Test"
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" add stitchpad.md
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" commit -q -m "initial"
  touch "$dir/.stitchpad/.state/session-registry.jsonl"
}

setup_sources() {
  source "$ROOT/tool/bin/lib.sh"
  source "$ROOT/tool/bin/date-divider.sh"
  source "$ROOT/tool/bin/session-registry.sh"
}

echo "=== phaseb-hardening2-regression tests ==="
echo ""

# ============================================================================
# R1: Cross-Seat Corruption — Recovery Uses STAMPED Sid
# ============================================================================
echo "--- R1: cross-seat corruption (stamped sid) ---"

R1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-hard2-r1.XXXXXX")"
trap 'rm -rf "$R1_WORK" "$R2_WORK" "$R3_WORK" "$R4_WORK"' EXIT

make_pad "$R1_WORK/test-pad" "r1-pad"
R1_PAD_DIR="$R1_WORK/test-pad/.stitchpad"
R1_PAD_MD="$R1_PAD_DIR/stitchpad.md"
R1_PAD_STATE="$R1_PAD_DIR/.state"

export STITCHPAD_PAD_DIR="$R1_PAD_DIR"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export HOME="$R1_WORK/home"
mkdir -p "$HOME"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

R1_SID_A="r1-alice-001"
R1_SID_B="r1-bob-002"
printf 'alice' > "$R1_PAD_STATE/sessions/$R1_SID_A"
printf 'bob' > "$R1_PAD_STATE/sessions/$R1_SID_B"

setup_sources
PAD_DIR="$R1_PAD_DIR"
PAD_MD="$R1_PAD_MD"
PAD_STATE="$R1_PAD_STATE"

# Create marker files for BOTH seats
printf '111111' > "$R1_PAD_STATE/session-start.$R1_SID_A"
printf '222222' > "$R1_PAD_STATE/session-start.$R1_SID_B"
printf '333333' > "$R1_PAD_STATE/session-activity.$R1_SID_A"
printf '444444' > "$R1_PAD_STATE/session-activity.$R1_SID_B"

# Create a REAL orphan journal under SID A — stamps SID A's identity
R1_ORPHAN="$(STITCHPAD_SESSION="$R1_SID_A" sp_session_registry_journal_begin "$R1_SID_A")"
[ -n "$R1_ORPHAN" ] && [ -d "$R1_ORPHAN" ] || { bad "R1_setup: could not create orphan journal"; exit 1; }

# Mutate SID A's marker (simulating mid-op crash)
printf '999999' > "$R1_PAD_STATE/session-activity.$R1_SID_A"

# Now recover under SID B (simulating: agent B runs next after agent A crashed)
STITCHPAD_SESSION="$R1_SID_B" sp_session_registry_journal_recover 2>/dev/null

# R1a: orphan must be consumed
[ ! -d "$R1_ORPHAN" ] && ok "R1a: orphan journal consumed after recovery" \
  || bad "R1a: orphan journal consumed after recovery (still present)"

# R1b: SID B's marker must NOT be corrupted
[ -f "$R1_PAD_STATE/session-start.$R1_SID_B" ] && \
  [ "$(cat "$R1_PAD_STATE/session-start.$R1_SID_B")" = "222222" ] && \
  ok "R1b: SID B session-start marker intact (no cross-seat corruption)" \
  || bad "R1b: SID B marker intact (corrupted: $(cat "$R1_PAD_STATE/session-start.$R1_SID_B" 2>/dev/null))"

# R1c: SID A's activity marker must be RESTORED to journaled pre-crash value
[ "$(cat "$R1_PAD_STATE/session-activity.$R1_SID_A")" = "333333" ] && \
  ok "R1c: SID A activity marker restored to pre-crash value" \
  || bad "R1c: SID A activity marker restored (got: $(cat "$R1_PAD_STATE/session-activity.$R1_SID_A" 2>/dev/null))"

# ============================================================================
# R2: Anonymous Recovery — No Sid in Env, Markers Still Restored
# ============================================================================
echo ""
echo "--- R2: anonymous recovery (no sid in env) ---"

R2_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-hard2-r2.XXXXXX")"

make_pad "$R2_WORK/test-pad" "r2-pad"
R2_PAD_DIR="$R2_WORK/test-pad/.stitchpad"
R2_PAD_MD="$R2_PAD_DIR/stitchpad.md"
R2_PAD_STATE="$R2_PAD_DIR/.state"

export STITCHPAD_PAD_DIR="$R2_PAD_DIR"

R2_SID="r2-alice-001"
printf 'alice' > "$R2_PAD_STATE/sessions/$R2_SID"

setup_sources
PAD_DIR="$R2_PAD_DIR"
PAD_MD="$R2_PAD_MD"
PAD_STATE="$R2_PAD_STATE"

# Set up markers for the seat
printf '555555' > "$R2_PAD_STATE/session-start.$R2_SID"
printf '666666' > "$R2_PAD_STATE/session-activity.$R2_SID"

# Create a REAL orphan journal under SID (stamps the sid)
R2_ORPHAN="$(STITCHPAD_SESSION="$R2_SID" sp_session_registry_journal_begin "$R2_SID")"
[ -n "$R2_ORPHAN" ] && [ -d "$R2_ORPHAN" ] || { bad "R2_setup: could not create orphan journal"; exit 1; }

# Crash mutation: corrupt the activity marker
printf '777777' > "$R2_PAD_STATE/session-activity.$R2_SID"

# Anonymous recovery: NO STITCHPAD_SESSION, NO CLAUDE_CODE_SESSION_ID, NO CODEX_SESSION_ID
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID
sp_session_registry_journal_recover 2>/dev/null

# R2a: orphan consumed
[ ! -d "$R2_ORPHAN" ] && ok "R2a: orphan journal consumed after anonymous recovery" \
  || bad "R2a: orphan journal consumed after anonymous recovery (still present)"

# R2b: activity marker RESTORED to pre-crash value via stamped sid
[ "$(cat "$R2_PAD_STATE/session-activity.$R2_SID")" = "666666" ] && \
  ok "R2b: crashed activity marker restored despite anonymous recovery" \
  || bad "R2b: crashed activity marker restored (got: $(cat "$R2_PAD_STATE/session-activity.$R2_SID" 2>/dev/null))"

# R2c: session-start marker also restored
[ "$(cat "$R2_PAD_STATE/session-start.$R2_SID")" = "555555" ] && \
  ok "R2c: crashed session-start marker restored despite anonymous recovery" \
  || bad "R2c: crashed session-start marker restored (got: $(cat "$R2_PAD_STATE/session-start.$R2_SID" 2>/dev/null))"

# ============================================================================
# R3: Stale-Restore SEVERE — Recovery REFUSES When HEAD Advanced
# ============================================================================
echo ""
echo "--- R3: stale-restore SEVERE (HEAD advanced past base) ---"

R3_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-hard2-r3.XXXXXX")"

make_pad "$R3_WORK/test-pad" "r3-pad"
R3_PAD_DIR="$R3_WORK/test-pad/.stitchpad"
R3_PAD_MD="$R3_PAD_DIR/stitchpad.md"
R3_PAD_STATE="$R3_PAD_DIR/.state"
R3_GIT="$R3_PAD_DIR/stitchpad-git"

export STITCHPAD_PAD_DIR="$R3_PAD_DIR"

R3_SID="r3-alice-001"
printf 'alice' > "$R3_PAD_STATE/sessions/$R3_SID"

setup_sources
PAD_DIR="$R3_PAD_DIR"
PAD_MD="$R3_PAD_MD"
PAD_STATE="$R3_PAD_STATE"

# Create a REAL orphan journal (stamps base SHA)
R3_ORPHAN="$(STITCHPAD_SESSION="$R3_SID" sp_session_registry_journal_begin "$R3_SID")"
[ -n "$R3_ORPHAN" ] && [ -d "$R3_ORPHAN" ] || { bad "R3_setup: could not create orphan journal"; exit 1; }

# Simulate crash: a different committed operation advances HEAD
echo "charlie was here" >> "$R3_PAD_MD"
git --git-dir="$R3_GIT" --work-tree="$R3_WORK/test-pad/.stitchpad" add stitchpad.md
git --git-dir="$R3_GIT" --work-tree="$R3_WORK/test-pad/.stitchpad" commit -q -m "charlie joined"

# Verify HEAD is now past the base SHA stamped in the orphan
R3_HEAD="$(git --git-dir="$R3_GIT" rev-parse HEAD)"
R3_BASE="$(cat "$R3_ORPHAN/.base-sha" 2>/dev/null)"
[ "$R3_HEAD" != "$R3_BASE" ] || { bad "R3_setup: HEAD did not advance past base"; exit 1; }

# Also add ghost content from the crashed say
echo "CRASHED SAY" >> "$R3_PAD_MD"

# Now recover — should REFUSE because HEAD advanced
R3_RECOVER_ERR="$(sp_session_registry_journal_recover 2>&1)"

# R3a: orphan MUST be PRESERVED (not consumed)
[ -d "$R3_ORPHAN" ] && ok "R3a: orphan preserved when HEAD advanced past base" \
  || bad "R3a: orphan preserved when HEAD advanced (consumed!)"

# R3b: loud diagnostic must mention the refusal reason
echo "$R3_RECOVER_ERR" | grep -qi "committed work would be reverted\|PRESERVED\|base SHA.*differs" && \
  ok "R3b: recovery reports refusal reason on stderr" \
  || bad "R3b: recovery reports refusal (got: $(printf '%s' "$R3_RECOVER_ERR" | head -c 200))"

# R3c: charlie's committed content must still be in the pad
grep -q "charlie was here" "$R3_PAD_MD" && ok "R3c: later committed content preserved (not reverted)" \
  || bad "R3c: later committed content preserved (reverted!)"

# R3d: ghost content from crashed say should still be in the live pad
grep -q "CRASHED SAY" "$R3_PAD_MD" && ok "R3d: live state not touched by refused recovery" \
  || bad "R3d: live state not touched (ghost content missing — recovery tampered?)"

# ============================================================================
# R4: Fresh-Directory Swap — Unreachable Journal Fails CLOSED
# ============================================================================
echo ""
echo "--- R4: fresh-directory swap (unreachable journal fails closed) ---"

R4_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-hard2-r4.XXXXXX")"

make_pad "$R4_WORK/test-pad" "r4-pad"
R4_PAD_DIR="$R4_WORK/test-pad/.stitchpad"
R4_PAD_MD="$R4_PAD_DIR/stitchpad.md"
R4_PAD_STATE="$R4_PAD_DIR/.state"

export STITCHPAD_PAD_DIR="$R4_PAD_DIR"

R4_SID="r4-alice-001"
printf 'alice' > "$R4_PAD_STATE/sessions/$R4_SID"

setup_sources
PAD_DIR="$R4_PAD_DIR"
PAD_MD="$R4_PAD_MD"
PAD_STATE="$R4_PAD_STATE"

# Create a journal
R4_JOURNAL="$(sp_session_registry_journal_begin "$R4_SID")"
[ -n "$R4_JOURNAL" ] && [ -d "$R4_JOURNAL" ] || { bad "R4_setup: could not create journal"; exit 1; }

# Swap: rename real state, create a FRESH regular directory in its place
mv "$R4_PAD_STATE" "$R4_WORK/real-state-saved"
mkdir "$R4_PAD_STATE"

# Attempt rollback — should FAIL CLOSED (rc != 0)
R4_ROLL_RC=0
R4_ROLL_OUT="$(sp_session_registry_journal_rollback "$R4_JOURNAL" "$R4_SID" 2>&1)" || R4_ROLL_RC=$?

# R4a: rollback must REFUSE (rc != 0)
[ "$R4_ROLL_RC" -ne 0 ] && ok "R4a: rollback refuses after fresh-dir swap (rc=$R4_ROLL_RC)" \
  || bad "R4a: rollback refuses after fresh-dir swap (got rc=0)"

# R4b: loud diagnostic must mention swap detection
echo "$R4_ROLL_OUT" | grep -qi "swap\|state.root\|unreachable\|journal unreachable" && \
  ok "R4b: rollback reports swap detection for fresh-dir case" \
  || bad "R4b: rollback reports swap detection (got: $(printf '%s' "$R4_ROLL_OUT" | head -c 200))"

# Restore state for cleanup
rm -rf "$R4_PAD_STATE"
mv "$R4_WORK/real-state-saved" "$R4_PAD_STATE"

# ============================================================================
# Results
# ============================================================================
echo ""
echo "=== RESULTS ==="
printf "Passed:  %d\n" "$pass"
printf "Failed:  %d\n" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '\nAll round-2 hardening gates PASSED.\n'
  exit 0
else
  printf '\nSome round-2 hardening gates FAILED.\n'
  exit 1
fi
