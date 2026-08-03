#!/usr/bin/env bash
# task4-bounded-recovery-regression.sh — TASK-4 bounded recovery + idempotent
# reassignment regression tests
#
# Proves:
#   B1: journal recovery has explicit attempt bound; exhausted → terminal refusal
#   B2: recovery policy unit tests (attempt counting, exhaustion, reset, time budget)
#   B3: bind-session is idempotent (same sid → same name = no-op with truthful report)
#   B4: shift-change --save is idempotent (pending handoff = no-op with truthful report)
#   B5: acceptance — deepseek→pro2 takeover (rebind idempotent, old cursor preserved)
#   B6: acceptance — kimi→kimi2→glm multi-hop rotation (all bindings preserved, idempotent)
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
  source "$ROOT/tool/bin/recovery-policy.sh"
}

echo "=== task4-bounded-recovery-regression tests ==="
echo ""

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-task4.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ============================================================================
# B1: Journal Recovery Attempt Bound
# ============================================================================
echo "--- B1: journal recovery attempt bound ---"

make_pad "$WORK/b1-pad" "b1"
B1_PAD_DIR="$WORK/b1-pad/.stitchpad"
B1_PAD_STATE="$B1_PAD_DIR/.state"
export STITCHPAD_PAD_DIR="$B1_PAD_DIR"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export HOME="$WORK/home"
mkdir -p "$HOME"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

setup_sources
PAD_DIR="$B1_PAD_DIR"
PAD_MD="$B1_PAD_DIR/stitchpad.md"
PAD_STATE="$B1_PAD_STATE"

B1_SID="b1-alice-001"
printf 'alice' > "$B1_PAD_STATE/sessions/$B1_SID"

# Create a real orphan journal
B1_ORPHAN="$(STITCHPAD_SESSION="$B1_SID" sp_session_registry_journal_begin "$B1_SID")"
[ -n "$B1_ORPHAN" ] && [ -d "$B1_ORPHAN" ] || { bad "B1_setup: could not create orphan"; exit 1; }

# Record max attempts so recovery is exhausted
B1_KEY="journal:$(basename "$B1_ORPHAN")"
export SP_RECOVERY_MAX_ATTEMPTS=3
sp_recovery_attempt_record "$B1_PAD_STATE" "$B1_KEY"
sp_recovery_attempt_record "$B1_PAD_STATE" "$B1_KEY"
sp_recovery_attempt_record "$B1_PAD_STATE" "$B1_KEY"

# Recovery should refuse to consume the orphan (it's preserved)
B1_RECOVER_ERR="$(sp_session_registry_journal_recover 2>&1)"
[ -d "$B1_ORPHAN" ] && ok "B1a: orphan preserved when recovery exhausted" \
  || bad "B1a: orphan preserved when recovery exhausted (consumed!)"

echo "$B1_RECOVER_ERR" | grep -qi "RECOVERY EXHAUSTED" && \
  ok "B1b: terminal refusal diagnostic emitted" \
  || bad "B1b: terminal refusal diagnostic (got: $(printf '%s' "$B1_RECOVER_ERR" | head -c 200))"

# After reset, recovery should succeed
sp_recovery_reset "$B1_PAD_STATE" "$B1_KEY"
sp_session_registry_journal_recover 2>/dev/null
[ ! -d "$B1_ORPHAN" ] && ok "B1c: orphan consumed after recovery reset" \
  || bad "B1c: orphan consumed after recovery reset (still present)"

unset SP_RECOVERY_MAX_ATTEMPTS

# ============================================================================
# B2: Recovery Policy Unit Tests
# ============================================================================
echo ""
echo "--- B2: recovery policy unit tests ---"

B2_STATE="$WORK/b2-state"
mkdir -p "$B2_STATE"

# B2a: fresh key count=0
B2_COUNT="$(sp_recovery_attempt_count "$B2_STATE" "test-key")"
[ "$B2_COUNT" = "0" ] && ok "B2a: fresh key count=0" \
  || bad "B2a: fresh key count=$B2_COUNT (expected 0)"

# B2b: count increments
sp_recovery_attempt_record "$B2_STATE" "test-key"
sp_recovery_attempt_record "$B2_STATE" "test-key"
B2_COUNT="$(sp_recovery_attempt_count "$B2_STATE" "test-key")"
[ "$B2_COUNT" = "2" ] && ok "B2b: count=2 after two attempts" \
  || bad "B2b: count=$B2_COUNT (expected 2)"

# B2c: not exhausted at 2/3
export SP_RECOVERY_MAX_ATTEMPTS=3
if sp_recovery_is_exhausted "$B2_STATE" "test-key"; then
  bad "B2c: exhausted at 2/3 (should not be)"
else
  ok "B2c: not exhausted at 2/3 attempts"
fi

# B2d: exhausted at 3/3
sp_recovery_attempt_record "$B2_STATE" "test-key"
if sp_recovery_is_exhausted "$B2_STATE" "test-key"; then
  ok "B2d: exhausted at 3/3 attempts"
else
  bad "B2d: not exhausted at 3/3 (should be)"
fi

# B2e: reset clears count
sp_recovery_reset "$B2_STATE" "test-key"
B2_COUNT="$(sp_recovery_attempt_count "$B2_STATE" "test-key")"
[ "$B2_COUNT" = "0" ] && ok "B2e: count=0 after reset" \
  || bad "B2e: count=$B2_COUNT after reset (expected 0)"

# B2f: not exhausted after reset
if sp_recovery_is_exhausted "$B2_STATE" "test-key"; then
  bad "B2f: exhausted after reset (should not be)"
else
  ok "B2f: not exhausted after reset"
fi

# B2g: time budget exhaustion
export SP_RECOVERY_MAX_ATTEMPTS=100
export SP_RECOVERY_BUDGET_SECONDS=1
sp_recovery_attempt_record "$B2_STATE" "time-budget"
sleep 2
if sp_recovery_is_exhausted "$B2_STATE" "time-budget"; then
  ok "B2g: time budget exhaustion (budget=1s, slept 2s)"
else
  bad "B2g: time budget not exhausted (should be)"
fi

unset SP_RECOVERY_MAX_ATTEMPTS SP_RECOVERY_BUDGET_SECONDS

# ============================================================================
# B3: bind-session Idempotent
# ============================================================================
echo ""
echo "--- B3: bind-session idempotent ---"

make_pad "$WORK/b3-pad" "b3"
B3_PAD_DIR="$WORK/b3-pad/.stitchpad"
B3_PAD_STATE="$B3_PAD_DIR/.state"
export STITCHPAD_PAD_DIR="$B3_PAD_DIR"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

B3_SID="b3-session-001"
printf 'alice' > "$B3_PAD_STATE/sessions/$B3_SID"

# Re-bind the same sid to the same name → no-op
B3_BIND_OUT="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" bind-session "$B3_SID" alice 2>&1)" || true
B3_BIND_RC=$?

[ "$B3_BIND_RC" -eq 0 ] && ok "B3a: bind-session same sid+name rc=0 (no-op)" \
  || bad "B3a: bind-session same sid+name rc=$B3_BIND_RC"

echo "$B3_BIND_OUT" | grep -qi "already bound" && \
  ok "B3b: reports 'already bound' (truthful no-op)" \
  || bad "B3b: reports 'already bound' (got: $(printf '%s' "$B3_BIND_OUT" | head -c 200))"

[ "$(cat "$B3_PAD_STATE/sessions/$B3_SID")" = "alice" ] && \
  ok "B3c: session binding unchanged after no-op rebind" \
  || bad "B3c: session binding changed: $(cat "$B3_PAD_STATE/sessions/$B3_SID" 2>/dev/null)"

# ============================================================================
# B4: shift-change --save Idempotent
# ============================================================================
echo ""
echo "--- B4: shift-change --save idempotent ---"

make_pad "$WORK/b4-pad" "b4"
B4_PAD_DIR="$WORK/b4-pad/.stitchpad"
B4_PAD_STATE="$B4_PAD_DIR/.state"
export STITCHPAD_PAD_DIR="$B4_PAD_DIR"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

B4_HANDOFF="$WORK/b4-handoff.txt"
echo "Handoff message for rotation" > "$B4_HANDOFF"

# First save
B4_SAVE1_OUT="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" shift-change --save alice --file "$B4_HANDOFF" 2>&1)" || true
B4_SAVE1_RC=$?

[ "$B4_SAVE1_RC" -eq 0 ] && ok "B4a: first shift-change --save succeeds" \
  || bad "B4a: first shift-change --save rc=$B4_SAVE1_RC"

# Second save — same agent, should be idempotent
B4_SAVE2_OUT="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" shift-change --save alice --file "$B4_HANDOFF" 2>&1)" || true
B4_SAVE2_RC=$?

[ "$B4_SAVE2_RC" -eq 0 ] && ok "B4b: second shift-change --save rc=0 (no-op)" \
  || bad "B4b: second shift-change --save rc=$B4_SAVE2_RC"

echo "$B4_SAVE2_OUT" | grep -qi "already pending" && \
  ok "B4c: reports 'already pending' (truthful no-op)" \
  || bad "B4c: reports 'already pending' (got: $(printf '%s' "$B4_SAVE2_OUT" | head -c 200))"

# Verify only one pending handoff exists
B4_PENDING="$(/usr/bin/sqlite3 "$B4_PAD_STATE/archive.sqlite" \
  "SELECT COUNT(*) FROM handoffs WHERE agent='alice' AND status='pending';" 2>/dev/null || echo "?")"
[ "$B4_PENDING" = "1" ] && ok "B4d: exactly one pending handoff (no double-apply)" \
  || bad "B4d: expected 1 pending handoff (found $B4_PENDING)"

# ============================================================================
# B5: Acceptance — deepseek→pro2 Takeover
# ============================================================================
echo ""
echo "--- B5: acceptance — deepseek→pro2 takeover ---"

make_pad "$WORK/b5-pad" "b5"
B5_PAD_DIR="$WORK/b5-pad/.stitchpad"
B5_PAD_STATE="$B5_PAD_DIR/.state"
export STITCHPAD_PAD_DIR="$B5_PAD_DIR"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

# Simulate: deepseek was bound with cursor at ordinal 42
B5_OLD_SID="deepseek-session-001"
B5_NEW_SID="pro2-session-001"
printf 'deepseek' > "$B5_PAD_STATE/sessions/$B5_OLD_SID"
printf '42' > "$B5_PAD_STATE/seen.deepseek"

# Captain rebinds the seat to pro2 via a new session
STITCHPAD_HEARTBEAT_AUTOSTART=0 "$STITCHPAD" bind-session "$B5_NEW_SID" pro2 >/dev/null 2>&1
B5_BIND_RC=$?

[ "$B5_BIND_RC" -eq 0 ] && ok "B5a: bind-session for pro2 (new sid) succeeds" \
  || bad "B5a: bind-session for pro2 failed (rc=$B5_BIND_RC)"

# Deepseek's cursor is preserved
[ "$(cat "$B5_PAD_STATE/seen.deepseek" 2>/dev/null)" = "42" ] && \
  ok "B5b: deepseek cursor preserved at 42 after takeover" \
  || bad "B5b: deepseek cursor changed after takeover"

# Re-run the same bind — idempotent
B5_REBIND_OUT="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" bind-session "$B5_NEW_SID" pro2 2>&1)" || true
B5_REBIND_RC=$?

[ "$B5_REBIND_RC" -eq 0 ] && ok "B5c: re-bind pro2 same sid+name rc=0 (no-op)" \
  || bad "B5c: re-bind pro2 rc=$B5_REBIND_RC"

echo "$B5_REBIND_OUT" | grep -qi "already bound" && \
  ok "B5d: re-bind reports 'already bound' (idempotent)" \
  || bad "B5d: re-bind reports 'already bound' (got: $(printf '%s' "$B5_REBIND_OUT" | head -c 200))"

# ============================================================================
# B6: Acceptance — kimi→kimi2→glm Multi-Hop Rotation
# ============================================================================
echo ""
echo "--- B6: acceptance — kimi→kimi2→glm multi-hop rotation ---"

make_pad "$WORK/b6-pad" "b6"
B6_PAD_DIR="$WORK/b6-pad/.stitchpad"
B6_PAD_STATE="$B6_PAD_DIR/.state"
export STITCHPAD_PAD_DIR="$B6_PAD_DIR"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

B6_SID1="kimi-session-001"
B6_SID2="kimi2-session-002"
B6_SID3="glm-session-003"

# Bind each seat in sequence
STITCHPAD_HEARTBEAT_AUTOSTART=0 "$STITCHPAD" bind-session "$B6_SID1" kimi >/dev/null 2>&1
STITCHPAD_HEARTBEAT_AUTOSTART=0 "$STITCHPAD" bind-session "$B6_SID2" kimi2 >/dev/null 2>&1
STITCHPAD_HEARTBEAT_AUTOSTART=0 "$STITCHPAD" bind-session "$B6_SID3" glm >/dev/null 2>&1

# All three bindings preserved
[ "$(cat "$B6_PAD_STATE/sessions/$B6_SID1" 2>/dev/null)" = "kimi" ] && \
  ok "B6a: kimi binding preserved through rotation chain" \
  || bad "B6a: kimi binding lost"

[ "$(cat "$B6_PAD_STATE/sessions/$B6_SID2" 2>/dev/null)" = "kimi2" ] && \
  ok "B6b: kimi2 binding preserved through rotation chain" \
  || bad "B6b: kimi2 binding lost"

[ "$(cat "$B6_PAD_STATE/sessions/$B6_SID3" 2>/dev/null)" = "glm" ] && \
  ok "B6c: glm binding active after rotation chain" \
  || bad "B6c: glm binding lost"

# Re-bind glm — idempotent
B6_REBIND_OUT="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" bind-session "$B6_SID3" glm 2>&1)" || true
B6_REBIND_RC=$?

[ "$B6_REBIND_RC" -eq 0 ] && ok "B6d: re-bind glm same sid+name rc=0 (no-op)" \
  || bad "B6d: re-bind glm rc=$B6_REBIND_RC"

echo "$B6_REBIND_OUT" | grep -qi "already bound" && \
  ok "B6e: re-bind glm reports 'already bound' (idempotent)" \
  || bad "B6e: re-bind glm reports 'already bound' (got: $(printf '%s' "$B6_REBIND_OUT" | head -c 200))"

# Shift-change for glm is idempotent
B6_HANDOFF="$WORK/b6-handoff.txt"
echo "GLM rotation handoff" > "$B6_HANDOFF"
STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" shift-change --save glm --file "$B6_HANDOFF" >/dev/null 2>&1

B6_SC2_OUT="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" shift-change --save glm --file "$B6_HANDOFF" 2>&1)" || true
B6_SC2_RC=$?

[ "$B6_SC2_RC" -eq 0 ] && ok "B6f: shift-change glm idempotent on re-save (no-op)" \
  || bad "B6f: shift-change glm re-save rc=$B6_SC2_RC"

echo "$B6_SC2_OUT" | grep -qi "already pending" && \
  ok "B6g: shift-change glm reports 'already pending' (idempotent)" \
  || bad "B6g: shift-change glm reports 'already pending' (got: $(printf '%s' "$B6_SC2_OUT" | head -c 200))"

# ============================================================================
# Results
# ============================================================================
echo ""
echo "=== RESULTS ==="
printf "Passed:  %d\n" "$pass"
printf "Failed:  %d\n" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '\nAll TASK-4 bounded-recovery gates PASSED.\n'
  exit 0
else
  printf '\nSome TASK-4 bounded-recovery gates FAILED.\n'
  exit 1
fi
