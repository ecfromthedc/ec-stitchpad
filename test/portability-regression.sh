#!/usr/bin/env bash
# portability-regression.sh — pro3 portability fixes
# Covers: rc5 F1-F6 + fx4 F1-F2
#
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
STITCHPAD="$ROOT/tool/bin/stitchpad"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

echo "=== portability regression tests ==="
echo ""

# ============================================================================
# rc5 F1: tui.sh fractional read -t guarded for bash 3.2
# ============================================================================
echo "--- F1: fractional read -t guarded ---"
TUI="$ROOT/tool/bin/tui.sh"
grep -q 'BASH_VERSINFO' "$TUI" && ok "F1a: bash version guard present" || bad "F1a: missing"
grep -q 'read -r -t 1 ' "$TUI" && ok "F1b: integer read -t 1 fallback" || bad "F1b: missing"

# ============================================================================
# rc5 F2: stat -f %m has stat -c %Y GNU fallback
# ============================================================================
echo ""
echo "--- F2: stat GNU fallback ---"
grep -q 'stat -c %Y' "$TUI" && ok "F2a: tui.sh has stat -c %Y fallback" || bad "F2a: missing"
grep -q 'stat -c %Y' "$ROOT/tool/bin/stitchpad" && ok "F2b: stitchpad has stat -c %Y fallback" || bad "F2b: missing"

# ============================================================================
# rc5 F3: bridge date -j has date -d GNU fallback
# ============================================================================
echo ""
echo "--- F3: bridge date fallback ---"
for _br in "$ROOT/tool/relay/bridge.sh" "$ROOT/tool/relay/bridge-push-once.sh"; do
  _bn="$(basename "$_br")"
  grep -q 'date -d' "$_br" && ok "F3: $_bn has date -d fallback" || bad "F3: $_bn missing"
done

# ============================================================================
# rc5 F4: dm list date -r has date -d @epoch fallback
# ============================================================================
echo ""
echo "--- F4: dm list date fallback ---"
grep -q 'date -d "@' "$ROOT/tool/bin/stitchpad" && ok "F4: dm list has GNU date -d @epoch fallback" || bad "F4: missing"

# ============================================================================
# rc5 F5: sha256 fallback (sha256sum / openssl dgst)
# ============================================================================
echo ""
echo "--- F5: sha256 fallback ---"
grep -q 'sha256sum' "$ROOT/test/delivery-supervision-regression.sh" && ok "F5a: del-sup has sha256sum fallback" || bad "F5a: missing"
grep -q 'sha256sum\|openssl dgst' "$ROOT/test/heartbeat-races.sh" && ok "F5b: heartbeat-races has portable fallback" || bad "F5b: missing"

# ============================================================================
# rc5 F6: join empty _args[@] safe on bash 3.2 set -u
# ============================================================================
echo ""
echo "--- F6: join empty-array safe ---"
grep -q '${_args\[@\]:+${_args\[@\]}}' "$ROOT/tool/bin/stitchpad" && ok "F6a: guard present" || bad "F6a: missing"

# Behavioral: flags-only join must not crash
F6_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-f6.XXXXXX")"
mkdir -p "$F6_WORK/.stitchpad/.state/sessions" "$F6_WORK/.stitchpad/stitchpad-git"
cat > "$F6_WORK/.stitchpad/stitchpad.md" <<'EOPAD'
# test
```roster
```
EOPAD
git --git-dir="$F6_WORK/.stitchpad/stitchpad-git" --work-tree="$F6_WORK/.stitchpad" init -q
git --git-dir="$F6_WORK/.stitchpad/stitchpad-git" --work-tree="$F6_WORK/.stitchpad" config user.email "t@t"
git --git-dir="$F6_WORK/.stitchpad/stitchpad-git" --work-tree="$F6_WORK/.stitchpad" config user.name "t"
git --git-dir="$F6_WORK/.stitchpad/stitchpad-git" --work-tree="$F6_WORK/.stitchpad" add stitchpad.md
git --git-dir="$F6_WORK/.stitchpad/stitchpad-git" --work-tree="$F6_WORK/.stitchpad" commit -q -m "init"

OUT=$(HOME="$F6_WORK" STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$F6_WORK/.stitchpad" \
  STITCHPAD_NAME=alice STITCHPAD_TEST_MODE=1 STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_STEAL=1 "$STITCHPAD" join --role junior 2>&1) || true
echo "$OUT" | grep -q "usage" && ok "F6b: join flags-only prints usage" \
  || { echo "$OUT" | grep -q "unbound" && bad "F6b: join crashes (unbound variable)" || ok "F6b: join did not crash"; }
rm -rf "$F6_WORK"

# ============================================================================
# fx4 F1: journal recovery does NOT word-split on spaces in PAD_STATE path
#   Core fix: for→while IFS= read -r loop.  Test that the while/read pattern
#   correctly iterates paths with spaces (unlike bare `for f in $(...)`).
# ============================================================================
echo ""
echo "--- F7: while-read space-tolerant (fx4 F1) ---"

# Create a pad with spaces in the path
F7_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp port test ü.XXXXXX")"
F7_PD="$F7_WORK/.stitchpad"
mkdir -p "$F7_PD/.state/sessions" "$F7_PD/stitchpad-git"
cat > "$F7_PD/stitchpad.md" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD
git --git-dir="$F7_PD/stitchpad-git" --work-tree="$F7_PD" init -q
git --git-dir="$F7_PD/stitchpad-git" --work-tree="$F7_PD" config user.email "t@t"
git --git-dir="$F7_PD/stitchpad-git" --work-tree="$F7_PD" config user.name "t"
git --git-dir="$F7_PD/stitchpad-git" --work-tree="$F7_PD" add stitchpad.md
git --git-dir="$F7_PD/stitchpad-git" --work-tree="$F7_PD" commit -q -m "init"

# Create test orphan directories with spaces
mkdir -p "$F7_PD/.state/.registry-journal.orphan one" "$F7_PD/.state/.registry-journal.orphan two"

# Source to get the _sp_session_registry_journal_orphans and test
export STITCHPAD_PAD_DIR="$F7_PD"
source "$ROOT/tool/bin/session-registry.sh"

PAD_STATE="$F7_PD/.state"

# Old (broken) pattern: for-in with unquoted expansion
BROKEN_COUNT=0
for orphan in $(_sp_session_registry_journal_orphans 2>/dev/null); do
  BROKEN_COUNT=$((BROKEN_COUNT + 1))
done
# We created 2 orphans, but word-splitting would produce 4 tokens
if [ "$BROKEN_COUNT" -eq 2 ]; then
  ok "F7a: old for-in pattern not word-splitting on this path (TMPDIR may be clean)"
else
  # Word-splitting produced a different count — the fix IS needed
  ok "F7a: old for-in word-splits (got $BROKEN_COUNT, want 2) — the fix is necessary"
fi

# New (fixed) pattern: while IFS= read -r
NEW_COUNT=0
while IFS= read -r orphan; do
  [ -n "$orphan" ] || continue
  [ -d "$orphan" ] || continue
  NEW_COUNT=$((NEW_COUNT + 1))
done < <(_sp_session_registry_journal_orphans 2>/dev/null)

[ "$NEW_COUNT" -eq 2 ] && ok "F7b: while-read finds exactly 2 orphans (space-safe)" \
  || bad "F7b: while-read found $NEW_COUNT orphans (want 2)"

# Verify the fix is in the actual source file (no bare 'for' with unquoted expansion)
if grep -q 'while IFS= read -r orphan' "$ROOT/tool/bin/session-registry.sh"; then
  ok "F7c: session-registry.sh uses while-read (not bare for-in)"
else
  bad "F7c: session-registry.sh does NOT use while-read"
fi

rm -rf "$F7_WORK"

# ============================================================================
# fx4 F2: init with git absent from PATH fails loudly (rc != 0)
# ============================================================================
echo ""
echo "--- F8: init with git absent from PATH ---"

F8_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-f8.XXXXXX")"
F8_PATH="$(mktemp -d "${TMPDIR:-/tmp}/sp-f8-path.XXXXXX")"
for _bin in bash mkdir printf cat date grep sed awk python3 ps kill; do
  _loc="$(command -v "$_bin" 2>/dev/null || true)"
  [ -n "$_loc" ] && ln -sf "$_loc" "$F8_PATH/$_bin" 2>/dev/null || true
done
# NOTE: git deliberately excluded

cd "$F8_WORK"
F8_OUT="$(HOME="$F8_WORK" STITCHPAD_HOME="$ROOT/tool" PATH="$F8_PATH" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$STITCHPAD" init 2>&1)" || F8_RC=$?
if [ "${F8_RC:-0}" -ne 0 ]; then
  ok "F8a: init with git absent returns non-zero (rc=$F8_RC)"
else
  bad "F8a: init returned 0 — false success!"
fi
if echo "$F8_OUT" | grep -qi "git.*not found\|git.*PATH\|requires git"; then
  ok "F8b: init produces git-absent diagnostic"
else
  bad "F8b: no git-absent diagnostic"
fi
[ ! -d "$F8_WORK/.stitchpad/stitchpad-git" ] && ok "F8c: no stitchpad-git created" || bad "F8c: git dir exists without git"
cd "$ROOT"
rm -rf "$F8_WORK" "$F8_PATH"

# ============================================================================
echo ""
printf "${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
