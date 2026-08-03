#!/usr/bin/env bash
# recovery-round7-regression.sh — pro3 fixes for flash re-attack 5 (00c60c8)
#
# Proves:
#   C1: case-variant git-dir bypass BLOCKED.  A .paths entry using a different
#       case (Stitchpad-git/config) is refused by dev/inode comparison, which
#       catches all case variants on case-insensitive APFS.
#   C3: empty-commit detection.  A pre-commit hook that empties the index makes
#       git produce an empty commit (HEAD advances, index clean).  sp_commit
#       detects this via diff-tree and returns 1, not 0.
#   C4: broken-git-dir reachability.  rev-parse failure on a corrupt config is
#       no longer conflated with "no git dir" — it returns 1, not 0.
#
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."

# Hermetic — don't touch live ~/.stitchpad
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

make_pad() {
  local dir="$1"; mkdir -p "$dir/.stitchpad/.state/sessions" "$dir/.stitchpad/.state/claims"
  cat > "$dir/.stitchpad/stitchpad.md" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD
  local gd="$dir/.stitchpad/stitchpad-git"
  mkdir -p "$gd"
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" init -q
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" config user.email "test@test.com"
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" config user.name "Test"
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" add stitchpad.md
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" commit -q -m "initial"
}

echo "=== recovery-round7-regression tests (C1, C3, C4) ==="
echo ""

# ============================================================================
# C1: case-variant git-dir bypass BLOCKED on case-insensitive FS
# ============================================================================
echo "--- C1: case-variant git-dir bypass ---"

C1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-c1.XXXXXX")"
make_pad "$C1_WORK/test-pad" "c1-pad"

C1_PAD_DIR="$C1_WORK/test-pad/.stitchpad"
C1_PAD_MD="$C1_PAD_DIR/stitchpad.md"
C1_PAD_STATE="$C1_PAD_DIR/.state"

# Source the session registry for direct function testing
export STITCHPAD_PAD_DIR="$C1_PAD_DIR"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

source "$ROOT/tool/bin/lib.sh"
source "$ROOT/tool/bin/session-registry.sh"

PAD_DIR="$C1_PAD_DIR"
PAD_MD="$C1_PAD_MD"
PAD_STATE="$C1_PAD_STATE"

# C1a: canonical lower-case git-dir path — must be refused (original H1 works)
# Use printf because the function expects a path
LOWER="$(printf '%s/stitchpad-git/config' "$C1_PAD_DIR")"
if ! _sp_session_registry_journal_path_contained "$LOWER"; then
  ok "C1a: canonical path ($(basename "$C1_PAD_DIR")/stitchpad-git/config) refused"
else
  bad "C1a: canonical path NOT refused — H1 regression!"
fi

# C1b: CASE-VARIANT git-dir path — the C1 probe.  Must be refused by dev/inode.
UPPER="$(printf '%s/Stitchpad-git/config' "$C1_PAD_DIR")"
if ! _sp_session_registry_journal_path_contained "$UPPER"; then
  ok "C1b: case-variant path (Stitchpad-git/config) refused (C1 fixed)"
else
  bad "C1b: case-variant path NOT refused — C1 bypass on this FS!"
fi

# C1c: another variant — STITCHPAD-GIT
FULL_UPPER="$(printf '%s/STITCHPAD-GIT/config' "$C1_PAD_DIR")"
if ! _sp_session_registry_journal_path_contained "$FULL_UPPER"; then
  ok "C1c: all-caps variant (STITCHPAD-GIT/config) refused"
else
  bad "C1c: all-caps variant NOT refused — C1 bypass!"
fi

# C1d: hooks dir inside git dir — deep path check
HOOKS_PATH="$(printf '%s/stitchpad-git/hooks/pre-commit' "$C1_PAD_DIR")"
if ! _sp_session_registry_journal_path_contained "$HOOKS_PATH"; then
  ok "C1d: hooks/pre-commit inside git dir refused (RCE vector blocked)"
else
  bad "C1d: hooks/pre-commit inside git dir NOT refused — RCE vector!"
fi

# C1e: case-variant hooks
HOOKS_UPPER="$(printf '%s/Stitchpad-git/Hooks/pre-commit' "$C1_PAD_DIR")"
if ! _sp_session_registry_journal_path_contained "$HOOKS_UPPER"; then
  ok "C1e: case-variant Hooks/pre-commit refused (case-insensitive defense)"
else
  bad "C1e: case-variant Hooks/pre-commit NOT refused — case-insensitive check failed"
fi

# C1f: legitimate path inside PAD_STATE is allowed
LEGIT="$(printf '%s/session-start.legit-test' "$C1_PAD_STATE")"
if _sp_session_registry_journal_path_contained "$LEGIT"; then
  ok "C1f: legitimate PAD_STATE path allowed (not over-blocking)"
else
  bad "C1f: legitimate PAD_STATE path refused — over-blocking!"
fi

rm -rf "$C1_WORK"

# ============================================================================
# C3: empty-commit detection in sp_commit
# ============================================================================
echo ""
echo "--- C3: empty-commit detection (sp_commit) ---"

C3_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-c3.XXXXXX")"
make_pad "$C3_WORK/test-pad" "c3-pad"

C3_PAD_DIR="$C3_WORK/test-pad/.stitchpad"
C3_PAD_MD="$C3_PAD_DIR/stitchpad.md"
C3_PAD_GIT="$C3_PAD_DIR/stitchpad-git"

# Install a pre-commit hook that empties the index
mkdir -p "$C3_PAD_GIT/hooks"
cat > "$C3_PAD_GIT/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
git reset -q HEAD
exit 0
HOOK
chmod +x "$C3_PAD_GIT/hooks/pre-commit"

# Set up PAD variables for sp_commit
PAD_DIR="$C3_PAD_DIR"
PAD_MD="$C3_PAD_MD"
PAD_STATE="$C3_PAD_DIR/.state"
PAD_GIT="$C3_PAD_GIT"

# Create a legitimate staged change
echo "" >> "$C3_PAD_MD"
echo "C3 test write — this should be committed" >> "$C3_PAD_MD"

# Run sp_commit — this MUST detect the empty commit
C3_OUT="$(sp_commit "C3 test write" 2>&1)" || C3_RC=$?
if [ "${C3_RC:-0}" -ne 0 ]; then
  # Check the diagnostic message
  if echo "$C3_OUT" | grep -q "empty tree"; then
    ok "C3a: empty commit detected, diagnostic emitted (rc=$C3_RC)"
  else
    ok "C3a: commit failed as expected (rc=$C3_RC) — no empty-tree diagnostic (possibly HEAD didn't advance)"
  fi
else
  bad "C3a: empty commit NOT detected (sp_commit returned 0) — write was swallowed!"
fi

# Verify the write is NOT in HEAD
C3_HEAD_HAS="$(git --git-dir="$C3_PAD_GIT" --work-tree="$C3_WORK/test-pad/.stitchpad" show HEAD:stitchpad.md 2>/dev/null | grep "C3 test write" || true)"
if [ -z "$C3_HEAD_HAS" ]; then
  ok "C3b: write NOT in HEAD (empty commit prevented from claiming success)"
else
  bad "C3b: write IS in HEAD — but sp_commit exited non-zero? (ambiguous)"
fi

# C3c: normal commit (no hook) still works
rm -f "$C3_PAD_GIT/hooks/pre-commit"
echo "C3 normal write" >> "$C3_PAD_MD"
if sp_commit "C3 normal commit" >/dev/null 2>&1; then
  C3_NORMAL="$(git --git-dir="$C3_PAD_GIT" --work-tree="$C3_WORK/test-pad/.stitchpad" show HEAD:stitchpad.md 2>/dev/null | grep "C3 normal write" || true)"
  if [ -n "$C3_NORMAL" ]; then
    ok "C3c: normal commit (no hook) succeeds, write in HEAD"
  else
    bad "C3c: normal commit succeeded but write not in HEAD"
  fi
else
  bad "C3c: normal commit (no hook) failed — regression!"
fi

rm -rf "$C3_WORK"

# ============================================================================
# C4: broken-git-dir reachability — rev-parse failure returns 1, not 0
# ============================================================================
echo ""
echo "--- C4: broken-git-dir reachability ---"

C4_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-c4.XXXXXX")"
make_pad "$C4_WORK/test-pad" "c4-pad"

C4_PAD_DIR="$C4_WORK/test-pad/.stitchpad"
C4_PAD_MD="$C4_PAD_DIR/stitchpad.md"
C4_PAD_GIT="$C4_PAD_DIR/stitchpad-git"

PAD_DIR="$C4_PAD_DIR"
PAD_MD="$C4_PAD_MD"
PAD_STATE="$C4_PAD_DIR/.state"
PAD_GIT="$C4_PAD_GIT"

# C4a: absent git dir — sp_commit returns 0 (benign, no git)
C4_NODIR="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-c4a.XXXXXX")"
mkdir -p "$C4_NODIR/.stitchpad/.state/sessions"
cat > "$C4_NODIR/.stitchpad/stitchpad.md" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD
C4_NODIR_PAD="$C4_NODIR/.stitchpad/stitchpad.md"
# No git dir at all — sp_commit should return 0 cleanly
PAD_DIR="$C4_NODIR/.stitchpad" PAD_MD="$C4_NODIR_PAD" PAD_STATE="$C4_NODIR/.stitchpad/.state" PAD_GIT="$C4_NODIR/.stitchpad/stitchpad-git" sp_commit "noop" >/dev/null 2>&1
C4A_RC=$?
[ "$C4A_RC" -eq 0 ] && ok "C4a: absent git dir returns 0 (benign)" \
  || bad "C4a: absent git dir returned $C4A_RC (should be benign 0)"
rm -rf "$C4_NODIR"

# C4b: corrupt git config — rev-parse fails → sp_commit returns 1 (not 0!)
echo "GARBAGE[[[CORRUPT" >> "$C4_PAD_GIT/config"
echo "C4 write — should NOT commit" >> "$C4_PAD_MD"
C4B_OUT="$(sp_commit "C4 corrupt config" 2>&1)" || C4B_RC=$?
if [ "${C4B_RC:-0}" -ne 0 ]; then
  ok "C4b: corrupt git config returns non-zero (C4 fixed — rc=$C4B_RC)"
else
  bad "C4b: corrupt git config returned 0 — C4 regression (dead code)!"
fi

# Verify the error message is specific
if echo "$C4B_OUT" | grep -q "rev-parse failed\|broken"; then
  ok "C4c: corrupt config produces specific diagnostic"
else
  bad "C4c: no specific diagnostic for corrupt config (got: $(printf '%s' "$C4B_OUT" | head -c 120))"
fi

# C4d: verify the directory WAS present (the "absent" branch was not taken)
[ -d "$C4_PAD_GIT" ] && ok "C4d: git dir was present on disk (correctly detected as existing)" \
  || bad "C4d: git dir missing — test fixture broken"

rm -rf "$C4_WORK"

# ============================================================================
# Summary
# ============================================================================
echo ""
printf "${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
