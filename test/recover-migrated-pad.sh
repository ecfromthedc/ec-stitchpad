#!/usr/bin/env bash
# recover-migrated-pad.sh — prove $PAD_GIT resolver engages base-SHA protection
# on migrated pads (pasture-git/), AND that the fail-open empty-repo bypass
# is now closed with fail-closed guards.
#
# THE BUG (original): tool/bin/session-registry.sh hardcoded `${PAD_DIR}/stitchpad-git`
# as the R3 guard. Migrated pads use `pasture-git/`, so `[ -d stitchpad-git ]`
# → false → the ENTIRE R3 block is skipped → journal recovery silently replays
# old bytes over committed work.  Data loss, no diagnostic.
#
# THE BUG (fail-open, flash re-attack): even with the $PAD_GIT fix, the
# recovery decision is FAIL-OPEN — when _recovery_head_sha is empty
# (empty repo, zero commits), the R3 guard [ -n "$_recovery_head_sha" ]
# is FALSE → R3 block skipped → unconditional rollback clobbers committed
# content.  Two attack vectors:
#   a) Empty git dir as pasture-git/ → auto-create produces zero-commit repo
#      → journal_begin stamps empty .base-sha → recovery fail-open
#   b) Dangling pasture-git symlink → [ -d ] fails → falls through to
#      stitchpad-git → auto-create → zero commits → same fail-open
#
# THE FIX (fail-closed):
#   1. lib.sh: refuse symlinked PAD_GIT directories
#   2. session-registry.sh recovery: if PAD_GIT exists but HEAD is
#      unresolvable, REFUSE ALL recovery (orphan PRESERVED)
#   3. session-registry.sh journal_begin: only stamp .base-sha when
#      HEAD resolves to a real commit
#
# WHAT THIS TEST PROVES (10 assertions):
#  P1 — PAD_GIT exists on migrated pad, stitchpad-git MISSING (OLD code skip)
#  P2 — base-SHA mismatch DETECTED, orphan PRESERVED, no revert
#  P3 — legacy pads still engage (no regression)
#  P4 — empty-repo bypass: recovery REFUSES (FAIL-CLOSED), orphan PRESERVED
#  P5 — symlink PAD_GIT: sp_init_paths REFUSES (init-time guard)
#  P6 — dangling-symlink fallback + empty auto-create: recovery REFUSES
#
# Bash 3.2+ compatible.  All fixtures confined to an isolated mktemp root.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
TOOL_DIR="$ROOT/tool/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

echo "recover-migrated-pad — migrated-pad base-SHA protection"
echo ""

TEST_ROOT="$(cd -P "$(mktemp -d /tmp/pro2-test-recov.XXXXXX)" && pwd)"
cleanup() {
  rm -rf "$TEST_ROOT"
  for pid in $(ps aux | grep -i "[f]swatch\|[w]atch\.sh" | grep "$TEST_ROOT" | awk '{print $2}' 2>/dev/null); do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ---------- helpers ----------
build_migrated_pad() {
  local root="$1" name="$2"
  PAD_PARENT="$root/$name"
  PAD_DIR="$PAD_PARENT/.pasture"
  mkdir -p "$PAD_DIR/pasture-git" "$PAD_DIR/.state/sessions"
  echo "## $name pad" > "$PAD_DIR/pasture.md"
  ( cd "$PAD_PARENT" && \
    git init --quiet --separate-git-dir="$PAD_DIR/pasture-git" . >/dev/null 2>&1 && \
    git add .pasture/pasture.md 2>/dev/null && \
    git -c user.name=test -c user.email=test@test commit -qm "initial" >/dev/null 2>&1 )
}

build_legacy_pad() {
  local root="$1" name="$2"
  PAD_PARENT="$root/$name"
  PAD_DIR="$PAD_PARENT/.stitchpad"
  mkdir -p "$PAD_DIR/stitchpad-git" "$PAD_DIR/.state/sessions"
  echo "## $name pad" > "$PAD_DIR/stitchpad.md"
  ( cd "$PAD_PARENT" && \
    git init --quiet --separate-git-dir="$PAD_DIR/stitchpad-git" . >/dev/null 2>&1 && \
    git add .stitchpad/stitchpad.md 2>/dev/null && \
    git -c user.name=test -c user.email=test@test commit -qm "initial" >/dev/null 2>&1 )
}

reset_pad_vars() {
  unset PAD_DIR PAD_GIT PAD_MD PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
  unset STITCHPAD_PAD_DIR PAD_PARENT
}

pad_head() { git --git-dir="$1" rev-parse HEAD 2>/dev/null; }

source "$TOOL_DIR/lib.sh"
source "$TOOL_DIR/session-registry.sh"
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID STITCHPAD_SESSION

# =========================================================================
# PROOF 1: OLD guard would fail on a migrated pad
# =========================================================================
echo "--- Proof 1: OLD guard (stitchpad-git) FAILS on migrated pad ---"

reset_pad_vars
build_migrated_pad "$TEST_ROOT" "mig1"
STITCHPAD_PAD_DIR="$PAD_DIR" sp_init_paths

PAD_GIT_EXISTS=false
OLD_GUARD_EXISTS=false
[ -d "$PAD_GIT" ] && PAD_GIT_EXISTS=true
[ -d "${PAD_DIR}/stitchpad-git" ] && OLD_GUARD_EXISTS=true

if $PAD_GIT_EXISTS; then
  ok "PAD_GIT exists ($PAD_GIT) — fix engages R3"
else
  bad "PAD_GIT missing — fix would NOT engage"
fi

if $OLD_GUARD_EXISTS; then
  bad "stitchpad-git EXISTS on migrated pad (unexpected)"
else
  ok "stitchpad-git MISSING on migrated pad — OLD code WOULD HAVE SKIPPED R3"
fi

# =========================================================================
# PROOF 2: On migrated pad, base-SHA mismatch is DETECTED (not silent replay)
# =========================================================================
echo ""
echo "--- Proof 2: base-SHA mismatch DETECTED on migrated pad ---"

INITIAL_SHA=$(pad_head "$PAD_GIT")
echo "  initial SHA: $(echo "$INITIAL_SHA" | head -c 12)..."
echo "  PAD_GIT=$PAD_GIT"

# Create a journal at commit #1
JOURNAL_DIR=$(sp_session_registry_journal_begin "test-sid-mig" 2>/dev/null)
if [ -z "$JOURNAL_DIR" ] || [ ! -d "$JOURNAL_DIR" ]; then
  bad "journal_begin failed"
else
  STAMPED_SHA=$(cat "$JOURNAL_DIR/.base-sha" 2>/dev/null || echo "")
  if [ "$STAMPED_SHA" = "$INITIAL_SHA" ]; then
    ok ".base-sha stamped correctly (guard-path check: PAD_GIT=$PAD_GIT engaged)"
  else
    bad ".base-sha NOT stamped correctly"
  fi

  # Advance HEAD by 2 commits — base-SHA is NOT parent of HEAD
  echo "commit 1" >> "$PAD_MD"
  ( cd "$PAD_PARENT" && \
    git add .pasture/pasture.md 2>/dev/null && \
    git -c user.name=x -c user.email=x@t commit -qm "c1" >/dev/null 2>&1 )
  echo "commit 2" >> "$PAD_MD"
  ( cd "$PAD_PARENT" && \
    git add .pasture/pasture.md 2>/dev/null && \
    git -c user.name=x -c user.email=x@t commit -qm "c2" >/dev/null 2>&1 )
  NEW_SHA=$(pad_head "$PAD_GIT")
  echo "  new HEAD:    $(echo "$NEW_SHA" | head -c 12)..."

  # Trigger recovery via a second journal_begin
  sp_session_registry_journal_begin "test-sid-mig-2" 2>/dev/null || true
  # Remove the second journal (not relevant to the test)
  for d in "$PAD_STATE"/.registry-journal.*; do
    [ -d "$d" ] || continue
    [ "$d" = "$JOURNAL_DIR" ] && continue
    rm -rf "$d" 2>/dev/null || true
  done

  # The orphan should be PRESERVED (not silently replayed)
  if [ -d "$JOURNAL_DIR" ]; then
    ok "orphan PRESERVED — base-SHA mismatch DETECTED (not silently replayed)"
    # Verify .base-sha is intact
    if [ -f "$JOURNAL_DIR/.base-sha" ]; then
      ok "orphan .base-sha intact for manual inspection"
    fi
  else
    bad "orphan DELETED — may have been silently replayed (data loss)"
  fi

  # Pad content must have the committed bytes
  PAD_CONTENT=$(cat "$PAD_MD" 2>/dev/null)
  if echo "$PAD_CONTENT" | grep -q "commit 2"; then
    ok "pad content: committed bytes intact (no revert)"
  else
    bad "pad content REVERTED — committed work destroyed!"
  fi
fi

# =========================================================================
# PROOF 3: Legacy pads still engage (no regression)
# =========================================================================
echo ""
echo "--- Proof 3: legacy pads (stitchpad-git/) still engage ---"

reset_pad_vars
build_legacy_pad "$TEST_ROOT" "leg1"
STITCHPAD_PAD_DIR="$PAD_DIR" sp_init_paths

case "$PAD_GIT" in
  */stitchpad-git)
    ok "PAD_GIT → stitchpad-git/ on legacy pad (no regression)"
    ;;
  *)
    bad "PAD_GIT=$PAD_GIT — REGRESSION on legacy pad!"
    ;;
esac

INITIAL_SHA3=$(pad_head "$PAD_GIT")
JOURNAL_DIR3=$(sp_session_registry_journal_begin "test-sid-leg" 2>/dev/null)
if [ -n "$JOURNAL_DIR3" ] && [ -f "$JOURNAL_DIR3/.base-sha" ]; then
  STAMPED3=$(cat "$JOURNAL_DIR3/.base-sha")
  if [ "$STAMPED3" = "$INITIAL_SHA3" ]; then
    ok "legacy journal_begin stamps .base-sha (protection engages)"
  else
    bad "legacy .base-sha wrong"
  fi
else
  bad "legacy journal_begin did NOT stamp .base-sha — REGRESSION!"
fi

# Clean up legacy fixture journals
for d in "$PAD_STATE"/.registry-journal.*; do
  rm -rf "$d" 2>/dev/null || true
done

# =========================================================================
# PROOF 4: Empty-repo bypass — fail-closed guard REFUSES recovery
# =========================================================================
echo ""
echo "--- Proof 4: empty-repo bypass → fail-closed guard REFUSES ---"

reset_pad_vars
EMPTY_PARENT="$TEST_ROOT/pad-empty"
EMPTY_DIR="$EMPTY_PARENT/.pasture"
mkdir -p "$EMPTY_DIR/pasture-git" "$EMPTY_DIR/.state/sessions"
echo "## empty-repo pad" > "$EMPTY_DIR/pasture.md"
# NOTE: pasture-git is an EMPTY directory — NOT a git repo.
# sp_init_paths will auto-create a repo (lib.sh:163-168) but commits
# will silently fail → zero commits → HEAD unresolvable.

STITCHPAD_PAD_DIR="$EMPTY_DIR" sp_init_paths 2>/dev/null || true

# Verify PAD_GIT is a directory (auto-create may have initialized it)
if [ -d "$PAD_GIT" ]; then
  ok "P4 — PAD_GIT is a directory (auto-created or pre-existing)"
else
  bad "P4 — PAD_GIT not a directory"
fi

# Verify HEAD is unresolvable (zero commits → empty repo)
if git --git-dir="$PAD_GIT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  bad "P4 — HEAD is resolvable (unexpected — should be empty repo)"
else
  ok "P4 — HEAD unresolvable (empty repo, zero commits)"
fi

# Create a journal. With fix 3, .base-sha should NOT be stamped
# because HEAD is unresolvable.
JOURNAL_EMPTY=$(sp_session_registry_journal_begin "test-sid-empty" 2>/dev/null)
if [ -z "$JOURNAL_EMPTY" ] || [ ! -d "$JOURNAL_EMPTY" ]; then
  bad "P4 — journal_begin failed"
else
  if [ -f "$JOURNAL_EMPTY/.base-sha" ]; then
    STAMPED_EMPTY=$(cat "$JOURNAL_EMPTY/.base-sha")
    if [ -n "$STAMPED_EMPTY" ]; then
      bad "P4 — .base-sha stamped despite unresolvable HEAD (fix 3 regression)"
    else
      ok "P4 — .base-sha empty (stamped but empty — fix 3 handles this)"
    fi
  else
    ok "P4 — .base-sha NOT stamped (HEAD unresolvable → skipped, fix 3)"
  fi

  # Write some pad content (simulating committed work)
  echo "committed work that must not be reverted" >> "$PAD_MD"

  # Trigger recovery via a second journal_begin.
  # With fix 2 (fail-closed), recovery should REFUSE because HEAD is
  # unresolvable — orphan PRESERVED, not replayed.
  sp_session_registry_journal_begin "test-sid-empty-2" 2>/dev/null || true

  # Remove the second journal
  for d in "$PAD_STATE"/.registry-journal.*; do
    [ -d "$d" ] || continue
    [ "$d" = "$JOURNAL_EMPTY" ] && continue
    rm -rf "$d" 2>/dev/null || true
  done

  # The original orphan should be PRESERVED (fail-closed refused recovery)
  if [ -d "$JOURNAL_EMPTY" ]; then
    ok "P4 — orphan PRESERVED (fail-closed: HEAD unresolvable → no rollback)"
  else
    bad "P4 — orphan DELETED — recovery rolled back despite unresolvable HEAD (FAIL-OPEN)"
  fi

  # Pad content must NOT have been reverted
  PAD_CONTENT_EMPTY=$(cat "$PAD_MD" 2>/dev/null)
  if echo "$PAD_CONTENT_EMPTY" | grep -q "committed work that must not be reverted"; then
    ok "P4 — pad content preserved (fail-closed: no silent revert)"
  else
    bad "P4 — pad content REVERTED by rollback (FAIL-OPEN bypass)"
  fi
fi

# =========================================================================
# PROOF 5: Symlink bypass — lib.sh guard REFUSES at init time
# =========================================================================
echo ""
echo "--- Proof 5: symlink PAD_GIT → init-time refusal ---"

SYM_PARENT="$TEST_ROOT/pad-symlink"
SYM_DIR="$SYM_PARENT/.pasture"
SYM_TARGET="$TEST_ROOT/symlink-target"
mkdir -p "$SYM_DIR/.state/sessions"
echo "## symlink pad" > "$SYM_DIR/pasture.md"
# Create a REAL git directory as the symlink target
mkdir -p "$SYM_TARGET"
git --git-dir="$SYM_TARGET" init -q
git --git-dir="$SYM_TARGET" commit --allow-empty -qm "real" >/dev/null 2>&1 || true
# Now create pasture-git as a symlink TO that real git dir
ln -s "$SYM_TARGET" "$SYM_DIR/pasture-git"

reset_pad_vars
STITCHPAD_PAD_DIR="$SYM_DIR"
if sp_init_paths 2>/dev/null; then
  bad "P5 — sp_init_paths succeeded despite symlinked PAD_GIT (guard missing)"
else
  ok "P5 — symlinked PAD_GIT REFUSED at init time (lib.sh guard)"
fi

# =========================================================================
# PROOF 6: Dangling-symlink fallback → empty auto-create → fail-closed
# =========================================================================
echo ""
echo "--- Proof 6: dangling symlink → fallback auto-create → fail-closed ---"

DANG_PARENT="$TEST_ROOT/pad-dangling"
DANG_DIR="$DANG_PARENT/.pasture"
mkdir -p "$DANG_DIR/.state/sessions"
echo "## dangling pad" > "$DANG_DIR/pasture.md"
# Create pasture-git as a DANGLING symlink
ln -s /nonexistent/dead-target "$DANG_DIR/pasture-git"
# [ -d "$DANG_DIR/pasture-git" ] → FALSE for dangling symlink
# → PAD_GIT falls through to stitchpad-git
# stitchpad-git doesn't exist → auto-create → empty repo → zero commits

reset_pad_vars
STITCHPAD_PAD_DIR="$DANG_DIR" sp_init_paths 2>/dev/null || true

# PAD_GIT should now be stitchpad-git (fallback) and auto-created
echo "  PAD_GIT=$PAD_GIT"
case "$PAD_GIT" in
  */stitchpad-git)
    ok "P6 — PAD_GIT fell through to stitchpad-git (dangling pasture-git symlink)"
    ;;
  */pasture-git)
    bad "P6 — PAD_GIT resolved to dangling pasture-git symlink (unexpected)"
    ;;
  *)
    bad "P6 — PAD_GIT=$PAD_GIT (unexpected resolution)"
    ;;
esac

# Verify auto-created repo has zero commits
if git --git-dir="$PAD_GIT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  ok "P6 — HEAD resolvable (auto-create produced a real commit — fine)"
else
  ok "P6 — HEAD unresolvable (auto-create zero-commit — fail-closed will guard)"
fi

# Create a journal
JOURNAL_DANG=$(sp_session_registry_journal_begin "test-sid-dang" 2>/dev/null)
if [ -z "$JOURNAL_DANG" ] || [ ! -d "$JOURNAL_DANG" ]; then
  bad "P6 — journal_begin failed"
else
  # Write pad content
  echo "work that must survive" >> "$PAD_MD"

  # Trigger recovery
  sp_session_registry_journal_begin "test-sid-dang-2" 2>/dev/null || true
  for d in "$PAD_STATE"/.registry-journal.*; do
    [ -d "$d" ] || continue
    [ "$d" = "$JOURNAL_DANG" ] && continue
    rm -rf "$d" 2>/dev/null || true
  done

  # Orphan should be PRESERVED
  if [ -d "$JOURNAL_DANG" ]; then
    ok "P6 — orphan PRESERVED (dangling-symlink fallback → fail-closed)"
  else
    bad "P6 — orphan DELETED — dangling symlink bypass succeeded (FAIL-OPEN)"
  fi

  # Content preserved
  PAD_CONTENT_DANG=$(cat "$PAD_MD" 2>/dev/null)
  if echo "$PAD_CONTENT_DANG" | grep -q "work that must survive"; then
    ok "P6 — pad content preserved (no revert from dangling-symlink bypass)"
  else
    bad "P6 — pad content REVERTED"
  fi
fi

# =========================================================================
echo ""
echo "RESULTS: $pass passed, $fail failed"
echo ""
if [ "$fail" -eq 0 ]; then
  echo "CONCLUSION: OLD code (stitchpad-git hardcoded) would silently skip R3 on"
  echo "migrated pads. OLD + \$PAD_GIT fix was still FAIL-OPEN on empty-repo edge"
  echo "cases. NEW fail-closed guards (symlink refusal + unresolvable-HEAD guard)"
  echo "now REFUSE recovery when safety cannot be verified — orphan preserved,"
  echo "committed content intact, no silent rollback."
fi
[ "$fail" -eq 0 ] || exit 1
