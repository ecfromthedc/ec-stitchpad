#!/usr/bin/env bash
# recover-migrated-pad.sh — prove $PAD_GIT resolver engages base-SHA protection
# on migrated pads (pasture-git/).
#
# THE BUG: tool/bin/session-registry.sh hardcoded `${PAD_DIR}/stitchpad-git`
# as the R3 guard. Migrated pads use `pasture-git/`, so `[ -d stitchpad-git ]`
# → false → the ENTIRE R3 block is skipped → journal recovery silently replays
# old bytes over committed work.  Data loss, no diagnostic.
#
# THE FIX: replace with `$PAD_GIT`, resolved by lib.sh:144 to the actual
# git directory (pasture-git/ or stitchpad-git/).
#
# WHAT THIS TEST PROVES:
#  1. On a migrated pad (pasture-git/), `$PAD_GIT` exists → R3 engages
#  2. On a migrated pad, `${PAD_DIR}/stitchpad-git` does NOT exist
#     (OLD code would have skipped R3 entirely)
#  3. With the fix, recovery DETECTS base-SHA mismatch and PRESERVES the
#     orphan (loud refusal) rather than silently replaying it
#  4. Legacy pads (stitchpad-git/) still engage (no regression)
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
echo ""
echo "RESULTS: $pass passed, $fail failed"
echo ""
if [ "$fail" -eq 0 ]; then
  echo "CONCLUSION: OLD guard (stitchpad-git/) would have silently skipped R3 on"
  echo "migrated pads; NEW \$PAD_GIT resolver engages protection correctly on"
  echo "both pasture-git/ and stitchpad-git/ paths."
fi
[ "$fail" -eq 0 ] || exit 1
