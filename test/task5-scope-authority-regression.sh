#!/usr/bin/env bash
# task5-scope-authority-regression.sh — TASK-5 scope manifests + deployment
# authority regression tests
#
# Proves:
#   S1: scope manifest allows writes within manifest
#   S2: scope manifest refuses writes outside manifest (scope_violation sticky)
#   S3: pad-internal paths always allowed regardless of manifest
#   S4: no manifest = unrestricted (backward compat)
#   S5: scope violations are sticky and operator-clearable
#   S6: authority levels — read denied, write denied deploy, deploy + grant ok
#   S7: operator grant is one-time (consumed after use)
#   S8: a seat may NOT create its own operator grant (authority bypass guard)
#   S9: acceptance — deepseek creating coordination-safety.sh on wrong lineage
#   S10: acceptance — seats writing shared git config (authority violation)
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
deepseek | ocean | push | deepseek-target
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
  source "$ROOT/tool/bin/scope-authority.sh"
}

echo "=== task5-scope-authority-regression tests ==="
echo ""

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-task5.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ============================================================================
# S1+S2: Scope manifest allows/denies
# ============================================================================
echo "--- S1+S2: scope manifest allows/denies ---"

make_pad "$WORK/s1-pad" "s1"
S1_PAD_DIR="$WORK/s1-pad/.stitchpad"
S1_PAD_STATE="$S1_PAD_DIR/.state"
export STITCHPAD_PAD_DIR="$S1_PAD_DIR"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export HOME="$WORK/home"
mkdir -p "$HOME"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

setup_sources
PAD_DIR="$S1_PAD_DIR"
PAD_MD="$S1_PAD_DIR/stitchpad.md"
PAD_STATE="$S1_PAD_STATE"

# Set up a scope manifest for deepseek allowing only tool/bin/
printf 'tool/bin/*\n' > "$S1_PAD_STATE/scope.deepseek"

# S1: within manifest
if sp_scope_allows "deepseek" "tool/bin/stitchpad"; then
  ok "S1a: deepseek may write tool/bin/stitchpad (within manifest)"
else
  bad "S1a: deepseek denied tool/bin/stitchpad (should be allowed)"
fi

# S2: outside manifest
if sp_scope_allows "deepseek" "src/main.rs"; then
  bad "S2a: deepseek allowed src/main.rs (should be denied)"
else
  ok "S2a: deepseek denied src/main.rs (outside manifest)"
fi

# S2b: scope check records violation
sp_scope_check_write "src/main.rs" "deepseek" 2>/dev/null
[ $? -ne 0 ] && ok "S2b: scope_check_write returns nonzero for out-of-scope" \
  || bad "S2b: scope_check_write returned 0 for out-of-scope (should deny)"

[ -f "$S1_PAD_STATE/scope-violation.deepseek" ] && \
  ok "S2c: sticky violation recorded" \
  || bad "S2c: sticky violation file not created"

# Verify violation content
grep -q 'src/main.rs' "$S1_PAD_STATE/scope-violation.deepseek" && \
  ok "S2d: violation records the denied path" \
  || bad "S2d: violation does not record the denied path"

# ============================================================================
# S3: Pad-internal paths always allowed
# ============================================================================
echo ""
echo "--- S3: pad-internal paths always allowed ---"

if sp_scope_allows "deepseek" ".stitchpad/stitchpad.md"; then
  ok "S3a: pad-internal path .stitchpad/stitchpad.md always allowed"
else
  bad "S3a: pad-internal path denied (should always be allowed)"
fi

if sp_scope_allows "deepseek" ".state/scope.deepseek"; then
  ok "S3b: .state/ path always allowed"
else
  bad "S3b: .state/ path denied (should always be allowed)"
fi

if sp_scope_allows "deepseek" "tasks.md"; then
  ok "S3c: tasks.md always allowed"
else
  bad "S3c: tasks.md denied (should always be allowed)"
fi

# ============================================================================
# S4: No manifest = unrestricted
# ============================================================================
echo ""
echo "--- S4: no manifest = unrestricted ---"

if sp_scope_allows "alice" "any/random/path.rs"; then
  ok "S4a: alice (no manifest) unrestricted"
else
  bad "S4a: alice (no manifest) denied (should be unrestricted)"
fi

if sp_scope_allows "bob" "completely/unrelated.go"; then
  ok "S4b: bob (no manifest) unrestricted"
else
  bad "S4b: bob (no manifest) denied (should be unrestricted)"
fi

# ============================================================================
# S5: Violations are sticky and operator-clearable
# ============================================================================
echo ""
echo "--- S5: violations sticky + clearable ---"

# S2 already created a violation for deepseek
[ -f "$S1_PAD_STATE/scope-violation.deepseek" ] && \
  ok "S5a: violation persists (sticky)" \
  || bad "S5a: violation disappeared (not sticky)"

# Clear via CLI
STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=operator \
  "$STITCHPAD" scope clear-violation deepseek >/dev/null 2>&1
[ ! -f "$S1_PAD_STATE/scope-violation.deepseek" ] && \
  ok "S5b: violation cleared by operator" \
  || bad "S5b: violation not cleared"

[ -f "$S1_PAD_STATE/scope-cleared.deepseek" ] && \
  ok "S5c: clearance record created" \
  || bad "S5c: clearance record not created"

# ============================================================================
# S6: Authority levels
# ============================================================================
echo ""
echo "--- S6: authority levels ---"

# Set alice to read-only
printf 'read' > "$S1_PAD_STATE/authority.alice"

# Read level: denied for deploy ops
sp_authority_check_deploy "alice" "push" 2>/dev/null
[ $? -ne 0 ] && ok "S6a: read authority denied for push" \
  || bad "S6a: read authority allowed push (should deny)"

# Set bob to write level
printf 'write' > "$S1_PAD_STATE/authority.bob"

sp_authority_check_deploy "bob" "publish" 2>/dev/null
[ $? -ne 0 ] && ok "S6b: write authority denied for publish" \
  || bad "S6b: write authority allowed publish (should deny)"

# Set deepseek to deploy level
printf 'deploy' > "$S1_PAD_STATE/authority.deepseek"

# Deploy without grant = denied
sp_authority_check_deploy "deepseek" "push" 2>/dev/null
[ $? -ne 0 ] && ok "S6c: deploy authority denied without grant" \
  || bad "S6c: deploy authority allowed without grant (should deny)"

# Create operator grant
printf 'operator 2026-08-02T23:00:00\n' > "$S1_PAD_STATE/operator-grant.deepseek.push"

# Deploy with grant = allowed
sp_authority_check_deploy "deepseek" "push" 2>/dev/null
[ $? -eq 0 ] && ok "S6d: deploy authority allowed with grant" \
  || bad "S6d: deploy authority denied with grant (should allow)"

# Default (no authority file) = write
S6_DEFAULT="$(sp_authority_level "nobody")"
[ "$S6_DEFAULT" = "write" ] && ok "S6e: default authority is write (backward compat)" \
  || bad "S6e: default authority is '$S6_DEFAULT' (expected write)"

# ============================================================================
# S7: Operator grant is one-time (consumed)
# ============================================================================
echo ""
echo "--- S7: grant consumed after use ---"

# Grant still exists from S6
[ -f "$S1_PAD_STATE/operator-grant.deepseek.push" ] && \
  ok "S7a: grant exists before consume" \
  || bad "S7a: grant missing before consume"

sp_authority_consume_grant "deepseek" "push"

[ ! -f "$S1_PAD_STATE/operator-grant.deepseek.push" ] && \
  ok "S7b: grant consumed (deleted)" \
  || bad "S7b: grant not consumed (still exists)"

# Now deploy should be denied again
sp_authority_check_deploy "deepseek" "push" 2>/dev/null
[ $? -ne 0 ] && ok "S7c: deploy denied after grant consumed" \
  || bad "S7c: deploy allowed after grant consumed (should deny)"

# ============================================================================
# S8: Seat may not create own operator grant
# ============================================================================
echo ""
echo "--- S8: seat may not create own grant ---"

# The guard function: seats cannot write operator-grant paths
sp_authority_guard_grant_write "deepseek" "operator-grant.deepseek.push"
[ $? -ne 0 ] && ok "S8a: guard refuses seat-created grant file" \
  || bad "S8a: guard allowed seat-created grant file"

sp_authority_guard_grant_write "deepseek" ".state/operator-grant.bob.publish"
[ $? -ne 0 ] && ok "S8b: guard refuses with .state/ prefix" \
  || bad "S8b: guard allowed with .state/ prefix"

# CLI grant command: a roster seat is refused
S8_GRANT_OUT="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=deepseek \
  "$STITCHPAD" authority grant deepseek push 2>&1)"; S8_GRANT_RC=$?

[ "$S8_GRANT_RC" -ne 0 ] && ok "S8c: CLI grant refused for roster seat" \
  || bad "S8c: CLI grant allowed for roster seat (should deny)"

echo "$S8_GRANT_OUT" | grep -qi "AUTHORITY VIOLATION" && \
  ok "S8d: CLI grant reports AUTHORITY VIOLATION" \
  || bad "S8d: CLI grant does not report AUTHORITY VIOLATION"

# CLI grant command: a non-roster operator is allowed
S8_OP_GRANT_OUT="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=eric \
  "$STITCHPAD" authority grant deepseek push 2>&1)" || true

echo "$S8_OP_GRANT_OUT" | grep -qi "operator grant created" && \
  ok "S8e: CLI grant succeeds for non-roster operator" \
  || bad "S8e: CLI grant failed for non-roster operator: $(printf '%s' "$S8_OP_GRANT_OUT" | head -c 200)"

[ -f "$S1_PAD_STATE/operator-grant.deepseek.push" ] && \
  ok "S8f: grant file created by operator" \
  || bad "S8f: grant file not created"

# ============================================================================
# S9: Acceptance — deepseek creating coordination-safety.sh on wrong lineage
# ============================================================================
echo ""
echo "--- S9: acceptance — coordination-safety.sh on wrong lineage ---"

# Scenario: deepseek's scope manifest allows tool/bin/* but NOT coordination/
# deepseek tries to write coordination-safety.sh — REFUSED
printf 'tool/bin/*\ntest/*\n' > "$S1_PAD_STATE/scope.deepseek"

# Scope check for coordination-safety.sh
sp_scope_check_write "coordination-safety.sh" "deepseek" 2>/dev/null
S9_RC=$?
[ "$S9_RC" -ne 0 ] && ok "S9a: deepseek denied coordination-safety.sh (outside scope)" \
  || bad "S9a: deepseek allowed coordination-safety.sh (should deny)"

[ -f "$S1_PAD_STATE/scope-violation.deepseek" ] && \
  ok "S9b: violation recorded for coordination-safety.sh" \
  || bad "S9b: no violation recorded"

grep -q 'coordination-safety.sh' "$S1_PAD_STATE/scope-violation.deepseek" 2>/dev/null && \
  ok "S9c: violation names the exact wrong-lineage file" \
  || bad "S9c: violation does not name the file"

# But tool/bin/recovery-policy.sh IS in scope
sp_scope_check_write "tool/bin/recovery-policy.sh" 2>/dev/null
[ $? -eq 0 ] && ok "S9d: deepseek allowed tool/bin/recovery-policy.sh (in scope)" \
  || bad "S9d: deepseek denied tool/bin/recovery-policy.sh (should allow)"

# Clear the violation for cleanup
STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=operator \
  "$STITCHPAD" scope clear-violation deepseek >/dev/null 2>&1

# ============================================================================
# S10: Acceptance — seats writing shared git config
# ============================================================================
echo ""
echo "--- S10: acceptance — seats writing shared git config ---"

# Scenario: deepseek (write authority) tries to deploy (git push) without grant
# Reset from prior S6/S8 state
rm -f "$S1_PAD_STATE/operator-grant.deepseek.push"
printf 'write' > "$S1_PAD_STATE/authority.deepseek"

sp_authority_check_deploy "deepseek" "push" 2>/dev/null
S10_RC=$?
[ "$S10_RC" -ne 0 ] && ok "S10a: deepseek (write) denied push (needs deploy + grant)" \
  || bad "S10a: deepseek (write) allowed push (should deny)"

# Scenario: even a deploy-level seat cannot push without operator grant
printf 'deploy' > "$S1_PAD_STATE/authority.deepseek"
rm -f "$S1_PAD_STATE/operator-grant.deepseek.push"

sp_authority_check_deploy "deepseek" "push" 2>/dev/null
S10B_RC=$?
[ "$S10B_RC" -ne 0 ] && ok "S10b: deploy-level deepseek denied push without grant" \
  || bad "S10b: deploy-level deepseek allowed push without grant (should deny)"

# A seat trying to create its own grant is refused
sp_authority_guard_grant_write "deepseek" "operator-grant.deepseek.push"
[ $? -ne 0 ] && ok "S10c: deepseek cannot create own grant for push" \
  || bad "S10c: deepseek created own grant (authority bypass!)"

# Operator creates grant → push allowed → grant consumed
printf 'eric 2026-08-02T23:30:00\n' > "$S1_PAD_STATE/operator-grant.deepseek.push"
sp_authority_check_deploy "deepseek" "push" 2>/dev/null
[ $? -eq 0 ] && ok "S10d: push allowed with operator grant" \
  || bad "S10d: push denied even with operator grant"

sp_authority_consume_grant "deepseek" "push"
[ ! -f "$S1_PAD_STATE/operator-grant.deepseek.push" ] && \
  ok "S10e: grant consumed (one-time, cannot re-push)" \
  || bad "S10e: grant not consumed (can re-push = unsafe)"

# ============================================================================
# Results
# ============================================================================
echo ""
echo "=== RESULTS ==="
printf "Passed:  %d\n" "$pass"
printf "Failed:  %d\n" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '\nAll TASK-5 scope-authority gates PASSED.\n'
  exit 0
else
  printf '\nSome TASK-5 scope-authority gates FAILED.\n'
  exit 1
fi
