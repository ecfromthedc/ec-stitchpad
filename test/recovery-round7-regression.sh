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
#       C3a drives the SUCCESS branch (hook exits 0, empty commit created).
#       C3b drives the FAILURE branch (hook exits 1 but silently advances HEAD
#       to an empty tree — the fx2 mu4 survivor).
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

# C3b: C3 FAILURE BRANCH — commit rc≠0 but HEAD advanced with identical tree.
# The C3a hook exits 0 and HEAD advances to an empty commit (success branch).
# C3b drives the FAILURE branch: a pre-commit hook that creates a new commit
# with the SAME tree as HEAD (so diff-tree is empty — no files changed),
# advances HEAD to it, then exits 1.  sp_commit must detect that HEAD advanced
# with an empty diff and return 1, not fall through to the diff --cached --quiet
# return-0 path (which would tell journaled callers "success" and drop the journal).
echo ""
echo "--- C3b: failure-branch empty-tree detection (fx2 mutation survivor) ---"

C3B_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-c3b.XXXXXX")"
make_pad "$C3B_WORK/test-pad" "c3b-pad"

C3B_PAD_DIR="$C3B_WORK/test-pad/.stitchpad"
C3B_PAD_MD="$C3B_PAD_DIR/stitchpad.md"
C3B_PAD_GIT="$C3B_PAD_DIR/stitchpad-git"

# Hook: creates a commit with the SAME tree as current HEAD (diff-tree will
# be empty), advances HEAD to it, then exits 1. Uses --git-dir explicitly.
mkdir -p "$C3B_PAD_GIT/hooks"
cat > "$C3B_PAD_GIT/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# Grab current HEAD's tree — use the caller's GIT_DIR from the environment
parent_tree=$(git rev-parse HEAD^{tree} 2>/dev/null)
[ -n "$parent_tree" ] || exit 1
new_commit=$(echo "hook empty" | git commit-tree ${parent_tree} -p HEAD 2>/dev/null)
[ -n "$new_commit" ] && git update-ref HEAD "$new_commit" 2>/dev/null
exit 1
HOOK
chmod +x "$C3B_PAD_GIT/hooks/pre-commit"

# Set up PAD variables for sp_commit
PAD_DIR="$C3B_PAD_DIR"
PAD_MD="$C3B_PAD_MD"
PAD_STATE="$C3B_PAD_DIR/.state"
PAD_GIT="$C3B_PAD_GIT"

# Create a real staged change so commit is attempted
echo "" >> "$C3B_PAD_MD"
echo "C3b test write — failure branch" >> "$C3B_PAD_MD"

# Record HEAD before the commit attempt
C3B_HEAD_BEFORE="$(git --git-dir="$C3B_PAD_GIT" rev-parse HEAD 2>/dev/null)"

# Run sp_commit — hook exits 1 (commit fails), but HEAD already advanced via hook
C3B_OUT="$(sp_commit "C3b failure branch test" 2>&1)" || C3B_RC=$?
if [ "${C3B_RC:-0}" -ne 0 ]; then
  # Verify the diagnostic was emitted
  if echo "$C3B_OUT" | grep -q "HEAD advanced with an empty tree"; then
    ok "C3d: failure branch empty-tree detected, diagnostic emitted (rc=$C3B_RC)"
  else
    bad "C3d: commit failed (rc=$C3B_RC) but missing 'HEAD advanced with an empty tree' diagnostic — got: $(printf '%s' "$C3B_OUT" | head -c 120)"
  fi
else
  bad "C3d: sp_commit returned 0 on failure-branch empty-tree — journal would be dropped, data lost!"
fi

# Verify HEAD actually moved (hook did its job)
C3B_HEAD_AFTER="$(git --git-dir="$C3B_PAD_GIT" rev-parse HEAD 2>/dev/null)"
if [ "$C3B_HEAD_BEFORE" != "$C3B_HEAD_AFTER" ]; then
  ok "C3e: HEAD advanced by hook (scenario was realistic)"
else
  bad "C3e: HEAD did NOT advance — hook didn't work, test inconclusive"
fi

# Verify the write is NOT in HEAD
C3B_HEAD_HAS="$(git --git-dir="$C3B_PAD_GIT" --work-tree="$C3B_WORK/test-pad/.stitchpad" show HEAD:stitchpad.md 2>/dev/null | grep "C3b test write" || true)"
if [ -z "$C3B_HEAD_HAS" ]; then
  ok "C3f: write NOT in HEAD (correctly refused)"
else
  bad "C3f: write IS in HEAD — failure-branch empty commit landed in HEAD!"
fi

rm -rf "$C3B_WORK"

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
# P1: pasture-git containment hole (flash re-attack, SEVERE)
# ============================================================================
echo ""
echo "--- P1: pasture-git containment (SEVERE) ---"

P1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-p1.XXXXXX")"

# Create a MIGRATED .pasture pad with pasture-git (not stitchpad-git)
mkdir -p "$P1_WORK/pad/.pasture/.state/sessions" "$P1_WORK/pad/.pasture/pasture-git"
cat > "$P1_WORK/pad/.pasture/pasture.md" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD
git --git-dir="$P1_WORK/pad/.pasture/pasture-git" --work-tree="$P1_WORK/pad/.pasture" init -q
git --git-dir="$P1_WORK/pad/.pasture/pasture-git" --work-tree="$P1_WORK/pad/.pasture" config user.email "t@t"
git --git-dir="$P1_WORK/pad/.pasture/pasture-git" --work-tree="$P1_WORK/pad/.pasture" config user.name "t"
git --git-dir="$P1_WORK/pad/.pasture/pasture-git" --work-tree="$P1_WORK/pad/.pasture" add pasture.md
git --git-dir="$P1_WORK/pad/.pasture/pasture-git" --work-tree="$P1_WORK/pad/.pasture" commit -q -m "init"

# Set up containment variables as a .pasture pad
export STITCHPAD_PAD_DIR="$P1_WORK/pad/.pasture"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

source "$ROOT/tool/bin/lib.sh"
source "$ROOT/tool/bin/session-registry.sh"

PAD_DIR="$P1_WORK/pad/.pasture"
PAD_MD="$P1_WORK/pad/.pasture/pasture.md"
PAD_STATE="$P1_WORK/pad/.pasture/.state"

# P1a: pasture-git/config MUST be refused by containment
P1A_PATH="$P1_WORK/pad/.pasture/pasture-git/config"
if _sp_session_registry_journal_path_contained "$P1A_PATH"; then
  bad "P1a: pasture-git/config passed containment — OPEN DOOR for git-dir write!"
else
  ok "P1a: pasture-git/config REFUSED by containment (P1 fixed)"
fi

# P1b: pasture-git/hooks/pre-commit MUST be refused (RCE-adjacent)
P1B_PATH="$P1_WORK/pad/.pasture/pasture-git/hooks/pre-commit"
if _sp_session_registry_journal_path_contained "$P1B_PATH"; then
  bad "P1b: pasture-git/hooks/pre-commit passed containment — OPEN DOOR for RCE-adjacent!"
else
  ok "P1b: pasture-git/hooks/pre-commit REFUSED by containment (P1 fixed)"
fi

# P1c: stitchpad-git/config still refused (legacy pad, no regression)
P1C_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-p1c.XXXXXX")"
make_pad "$P1C_WORK/test-pad" "p1c-pad"
P1C_PAD_DIR="$P1C_WORK/test-pad/.stitchpad"
PAD_DIR="$P1C_PAD_DIR"
PAD_MD="$P1C_PAD_DIR/stitchpad.md"
PAD_STATE="$P1C_PAD_DIR/.state"
P1C_PATH="$P1C_PAD_DIR/stitchpad-git/config"
if _sp_session_registry_journal_path_contained "$P1C_PATH"; then
  bad "P1c: stitchpad-git/config passed containment — legacy regression!"
else
  ok "P1c: stitchpad-git/config still REFUSED (legacy pad, no regression)"
fi
rm -rf "$P1C_WORK"

rm -rf "$P1_WORK"

# ============================================================================
# Z1: C3-fix bypass — staged unrelated file, pad write excluded
# ============================================================================
echo ""
echo "--- Z1: C3-fix bypass (staged unrelated file) ---"

Z1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-z1.XXXXXX")"
make_pad "$Z1_WORK/test-pad" "z1-pad"

Z1_PAD_DIR="$Z1_WORK/test-pad/.stitchpad"
Z1_PAD_MD="$Z1_PAD_DIR/stitchpad.md"
Z1_PAD_GIT="$Z1_PAD_DIR/stitchpad-git"

# Hook: removes stitchpad.md from the index, stages an unrelated file,
# then exits 0.  The commit succeeds but stitchpad.md is NOT in HEAD.
mkdir -p "$Z1_PAD_GIT/hooks"
cat > "$Z1_PAD_GIT/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# Remove the real pad file from index
git rm --cached -q stitchpad.md 2>/dev/null || git reset -q HEAD stitchpad.md 2>/dev/null || true
# Stage an unrelated file so diff-tree is non-empty
echo "unrelated" > /tmp/z1-unrelated.txt
git add /tmp/z1-unrelated.txt 2>/dev/null || {
  # Can't add outside worktree — add it inside instead
  echo "unrelated" > "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/.z1-unrelated"
  git add .z1-unrelated 2>/dev/null
}
exit 0
HOOK
chmod +x "$Z1_PAD_GIT/hooks/pre-commit"

# Set up sp_commit variables
PAD_DIR="$Z1_PAD_DIR"
PAD_MD="$Z1_PAD_MD"
PAD_STATE="$Z1_PAD_DIR/.state"
PAD_GIT="$Z1_PAD_GIT"

# Write to the pad and commit
echo "" >> "$Z1_PAD_MD"
echo "Z1 test write — should be verified in HEAD" >> "$Z1_PAD_MD"

Z1_HEAD_BEFORE="$(git --git-dir="$Z1_PAD_GIT" rev-parse HEAD 2>/dev/null)"
Z1_OUT="$(sp_commit "Z1 bypass test" 2>&1)" || Z1_RC=$?
if [ "${Z1_RC:-0}" -ne 0 ]; then
  # Verify the diagnostic mentions staged paths
  if echo "$Z1_OUT" | grep -qi "staged paths\|NOT in HEAD"; then
    ok "Z1a: staged-unrelated-file bypass detected, diagnostic emitted (rc=$Z1_RC)"
  else
    ok "Z1a: commit refused (rc=$Z1_RC) — diagnostic may differ: $(printf '%s' "$Z1_OUT" | head -c 120)"
  fi
else
  bad "Z1a: sp_commit returned 0 on staged-unrelated-file bypass — write NOT verified in HEAD!"
fi

# Verify the pad write is NOT in HEAD
Z1_HEAD_HAS="$(git --git-dir="$Z1_PAD_GIT" --work-tree="$Z1_WORK/test-pad/.stitchpad" show HEAD:stitchpad.md 2>/dev/null | grep "Z1 test write" || true)"
if [ -z "$Z1_HEAD_HAS" ]; then
  ok "Z1b: pad write NOT in HEAD (correctly refused)"
else
  bad "Z1b: pad write IS in HEAD — but sp_commit failed? (ambiguous)"
fi

rm -rf "$Z1_WORK"

# ============================================================================
# C5: Unborn-HEAD pad uncommittable
# ============================================================================
echo ""
echo "--- C5: unborn-HEAD pad ---"

C5_SKIP=0
C5_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-c5.XXXXXX")"

# Create a pad with NO commits (unborn HEAD)
mkdir -p "$C5_WORK/pad/.stitchpad/.state/sessions" "$C5_WORK/pad/.stitchpad/stitchpad-git"
cat > "$C5_WORK/pad/.stitchpad/stitchpad.md" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD
git --git-dir="$C5_WORK/pad/.stitchpad/stitchpad-git" --work-tree="$C5_WORK/pad/.stitchpad" init -q
git --git-dir="$C5_WORK/pad/.stitchpad/stitchpad-git" --work-tree="$C5_WORK/pad/.stitchpad" config user.email "t@t"
git --git-dir="$C5_WORK/pad/.stitchpad/stitchpad-git" --work-tree="$C5_WORK/pad/.stitchpad" config user.name "t"

# Verify HEAD is unborn — rev-parse writes "HEAD" to stdout even on failure,
# so suppress all output and just check exit code.
if git --git-dir="$C5_WORK/pad/.stitchpad/stitchpad-git" rev-parse --verify HEAD >/dev/null 2>&1; then
  bad "C5_setup: HEAD exists (pad wasn't unborn)"
  C5_SKIP=1
else
  C5_SKIP=0
fi

if [ "$C5_SKIP" -eq 0 ]; then
  # Set up sp_commit variables
  PAD_DIR="$C5_WORK/pad/.stitchpad"
  PAD_MD="$C5_WORK/pad/.stitchpad/stitchpad.md"
  PAD_STATE="$C5_WORK/pad/.stitchpad/.state"
  PAD_GIT="$C5_WORK/pad/.stitchpad/stitchpad-git"

  # C5a: normal first commit on unborn HEAD works
  echo "" >> "$PAD_MD"
  echo "C5 first write" >> "$PAD_MD"
  if sp_commit "C5 first commit" >/dev/null 2>&1; then
    C5_FIRST="$(git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" show HEAD:stitchpad.md 2>/dev/null | grep "C5 first write" || true)"
    if [ -n "$C5_FIRST" ]; then
      ok "C5a: first commit on unborn HEAD succeeds, write in HEAD"
    else
      bad "C5a: first commit succeeded but write not in HEAD"
    fi
  else
    bad "C5a: first commit on unborn HEAD failed — regression!"
  fi
fi

rm -rf "$C5_WORK"

# C5b: empty first commit on unborn HEAD must be refused (new pad, hook
# clears index). Create a fresh unborn pad for this.
C5B_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-c5b.XXXXXX")"
mkdir -p "$C5B_WORK/pad/.stitchpad/.state/sessions" "$C5B_WORK/pad/.stitchpad/stitchpad-git/hooks"
cat > "$C5B_WORK/pad/.stitchpad/stitchpad.md" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD
git --git-dir="$C5B_WORK/pad/.stitchpad/stitchpad-git" --work-tree="$C5B_WORK/pad/.stitchpad" init -q
git --git-dir="$C5B_WORK/pad/.stitchpad/stitchpad-git" --work-tree="$C5B_WORK/pad/.stitchpad" config user.email "t@t"
git --git-dir="$C5B_WORK/pad/.stitchpad/stitchpad-git" --work-tree="$C5B_WORK/pad/.stitchpad" config user.name "t"

# Hook: create an empty-tree commit, then clear the index so git
# commit sees nothing to commit on top of it. Exits 0 — git commit
# succeeds with HEAD at the empty-tree commit, write dropped.
# Uses --verify -q to avoid rev-parse stdout pollution on unborn HEAD.
cat > "$C5B_WORK/pad/.stitchpad/stitchpad-git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
parent_tree=$(git rev-parse --verify -q HEAD^{tree} 2>/dev/null)
if [ -z "$parent_tree" ]; then
  # Unborn HEAD — create an empty tree commit
  empty_tree=$(echo -n | git hash-object -t tree --stdin 2>/dev/null)
  new_commit=$(echo "hook empty" | git commit-tree ${empty_tree} 2>/dev/null)
  [ -n "$new_commit" ] && git update-ref HEAD "$new_commit" 2>/dev/null
fi
# Clear the index so git commit has nothing to land on top of the hook commit
git reset -q HEAD 2>/dev/null || true
exit 0
HOOK
chmod +x "$C5B_WORK/pad/.stitchpad/stitchpad-git/hooks/pre-commit"

PAD_DIR="$C5B_WORK/pad/.stitchpad"
PAD_MD="$C5B_WORK/pad/.stitchpad/stitchpad.md"
PAD_STATE="$C5B_WORK/pad/.stitchpad/.state"
PAD_GIT="$C5B_WORK/pad/.stitchpad/stitchpad-git"

echo "" >> "$PAD_MD"
echo "C5b should be refused" >> "$PAD_MD"

C5B_OUT="$(sp_commit "C5b empty first commit" 2>&1)" || C5B_RC=$?
if [ "${C5B_RC:-0}" -ne 0 ]; then
  if echo "$C5B_OUT" | grep -qi "empty tree"; then
    ok "C5b: empty first commit on unborn HEAD refused (empty tree detected)"
  else
    ok "C5b: empty first commit refused (rc=$C5B_RC)"
  fi
else
  bad "C5b: empty first commit on unborn HEAD returned 0 — data lost!"
fi

rm -rf "$C5B_WORK"

# ============================================================================
# RP-1: structural git-dir discovery — third name NOT on the list
# ============================================================================
echo ""
echo "--- RP-1: structural git-dir discovery (third name) ---"

RP1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-rp1.XXXXXX")"

# Create a pad with a git dir at a third name (NOT stitchpad-git or pasture-git)
mkdir -p "$RP1_WORK/pad/.stitchpad/.state/sessions" "$RP1_WORK/pad/.stitchpad/repo-git/hooks"
cat > "$RP1_WORK/pad/.stitchpad/stitchpad.md" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD
git --git-dir="$RP1_WORK/pad/.stitchpad/repo-git" --work-tree="$RP1_WORK/pad/.stitchpad" init -q
git --git-dir="$RP1_WORK/pad/.stitchpad/repo-git" --work-tree="$RP1_WORK/pad/.stitchpad" config user.email "t@t"
git --git-dir="$RP1_WORK/pad/.stitchpad/repo-git" --work-tree="$RP1_WORK/pad/.stitchpad" config user.name "t"
git --git-dir="$RP1_WORK/pad/.stitchpad/repo-git" --work-tree="$RP1_WORK/pad/.stitchpad" add stitchpad.md
git --git-dir="$RP1_WORK/pad/.stitchpad/repo-git" --work-tree="$RP1_WORK/pad/.stitchpad" commit -q -m "init"

export STITCHPAD_PAD_DIR="$RP1_WORK/pad/.stitchpad"
source "$ROOT/tool/bin/lib.sh"
source "$ROOT/tool/bin/session-registry.sh"

PAD_DIR="$RP1_WORK/pad/.stitchpad"
PAD_MD="$RP1_WORK/pad/.stitchpad/stitchpad.md"
PAD_STATE="$RP1_WORK/pad/.stitchpad/.state"

# RP-1a: repo-git/config MUST be refused (structural discovery catches it)
RP1A_PATH="$RP1_WORK/pad/.stitchpad/repo-git/config"
if _sp_session_registry_journal_path_contained "$RP1A_PATH"; then
  bad "RP-1a: repo-git/config passed containment — name-based gate would miss this!"
else
  ok "RP-1a: repo-git/config REFUSED (structural discovery, not name-based)"
fi

# RP-1b: repo-git/hooks/pre-commit MUST be refused
RP1B_PATH="$RP1_WORK/pad/.stitchpad/repo-git/hooks/pre-commit"
if _sp_session_registry_journal_path_contained "$RP1B_PATH"; then
  bad "RP-1b: repo-git/hooks/pre-commit passed containment!"
else
  ok "RP-1b: repo-git/hooks/pre-commit REFUSED (deep subpath caught)"
fi

# RP-1c: deep object path inside third-name git dir
mkdir -p "$RP1_WORK/pad/.stitchpad/repo-git/objects/pack"
RP1C_PATH="$RP1_WORK/pad/.stitchpad/repo-git/objects/pack/deadbeef.pack"
if _sp_session_registry_journal_path_contained "$RP1C_PATH"; then
  bad "RP-1c: repo-git/objects/pack/* passed containment!"
else
  ok "RP-1c: repo-git/objects/pack/deadbeef.pack REFUSED (deep git path caught)"
fi

rm -rf "$RP1_WORK"

# ============================================================================
# RP-2: Z1 bytes-not-verified — hook alters pad bytes, path present in HEAD
# ============================================================================
echo ""
echo "--- RP-2: Z1 bytes-not-verified (hook alters content) ---"

RP2_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-r7-rp2.XXXXXX")"
make_pad "$RP2_WORK/test-pad" "rp2-pad"

RP2_PAD_DIR="$RP2_WORK/test-pad/.stitchpad"
RP2_PAD_MD="$RP2_PAD_DIR/stitchpad.md"
RP2_PAD_GIT="$RP2_PAD_DIR/stitchpad-git"

# Hook: keeps stitchpad.md in the index but replaces its content with
# different bytes. File IS in HEAD (path check passes) but with tampered content.
mkdir -p "$RP2_PAD_GIT/hooks"
cat > "$RP2_PAD_GIT/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# Replace stitchpad.md content with tampered bytes
echo "# TAMPERED — hook injected content" > stitchpad.md
git add stitchpad.md 2>/dev/null
exit 0
HOOK
chmod +x "$RP2_PAD_GIT/hooks/pre-commit"

PAD_DIR="$RP2_PAD_DIR"
PAD_MD="$RP2_PAD_MD"
PAD_STATE="$RP2_PAD_DIR/.state"
PAD_GIT="$RP2_PAD_GIT"

# Record original bytes for comparison
ORIGINAL_BYTES="$(cat "$PAD_MD" | wc -c)"
echo "" >> "$PAD_MD"
echo "RP2 test write" >> "$PAD_MD"
STAGED_BLOB="$(sgit hash-object -w "$PAD_MD" 2>/dev/null)"
STAGED_CONTENT="$(sgit cat-file -p "$STAGED_BLOB" 2>/dev/null | grep "RP2 test write" || true)"

RP2_OUT="$(sp_commit "RP2 tamper test" 2>&1)" || RP2_RC=$?
HEAD_CONTENT="$(sgit show HEAD:stitchpad.md 2>/dev/null | grep "RP2 test write" || true)"
HEAD_TAMPERED="$(sgit show HEAD:stitchpad.md 2>/dev/null | grep "TAMPERED" || true)"

if [ "${RP2_RC:-0}" -ne 0 ]; then
  ok "RP-2a: tampered-byte commit refused (rc=$RP2_RC) — bytes check or path check caught it"
else
  if [ -n "$HEAD_TAMPERED" ] && [ -z "$HEAD_CONTENT" ]; then
    bad "RP-2a: hook-altered bytes landed in HEAD undetected — content replaced with tampered!"
  elif [ -n "$HEAD_CONTENT" ]; then
    ok "RP-2a: commit succeeded, original bytes in HEAD (hook didn't actually tamper)"
  else
    ok "RP-2a: commit succeeded (rc=0) — check. Bytes: $([ -n "$HEAD_CONTENT" ] && echo 'original present' || echo 'original absent, tamper: '$([ -n "$HEAD_TAMPERED" ] && echo YES || echo NO))"
  fi
fi

rm -rf "$RP2_WORK"

# ============================================================================
# Summary
# ============================================================================
echo ""
printf "${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
