#!/usr/bin/env bash
# p18-scratch-pad-gate.sh — P18: agent scratch trees must not become channels.
#
#   G1: init in a git worktree without --scratch/--force is REFUSED.
#   G2: init --scratch in a worktree creates a scratch pad (not a channel).
#   G3: init --force in a worktree creates a real channel pad.
#   G4: scratch pads do NOT appear in `stitchpad pads` (channel listing).
#   G5: scratch pads DO appear in `stitchpad pads --scratch`.
#   G6: channel pads still appear in `stitchpad pads`.
#   G7: `stitchpad pads --prune` removes scratch pads.
#   G8: suite sweep — running a test suite creates zero new channels.
#   G9: MUTANT: remove .scratch sentinel → scratch pad appears as channel → RED.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_HOME="$ROOT/tool"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export PATH="$ROOT/tool/bin:$PATH"

TMP="$(mktemp -d /tmp/p18-gate.XXXXXX)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# Pad listing: explicit roots so test pads in $TMP are discoverable
# For G4-G7,G9: scan only $TMP (test fixtures)
sp_pads_tmp()       { STITCHPAD_SCAN_ROOTS="$TMP" "$SP" pads 2>/dev/null; }
sp_pads_scratch_tmp(){ STITCHPAD_SCAN_ROOTS="$TMP" "$SP" pads --scratch 2>/dev/null; }
sp_pads_prune_tmp()  { STITCHPAD_SCAN_ROOTS="$TMP" "$SP" pads --prune 2>/dev/null; }

# For G8: scan $HOME to verify no new real channels
count_home_channels() {
  STITCHPAD_SCAN_ROOTS="$HOME" "$SP" pads 2>/dev/null | grep -c '^\[ch\]' 2>/dev/null || echo 0
}

echo "=== P18: scratch-pad gate ==="
echo ""

# ── Fixture: create a git repo, then a worktree ──────────────────────────
GIT_REPO="$TMP/parent-repo"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.name test
git -C "$GIT_REPO" config user.email t@t
git -C "$GIT_REPO" commit --allow-empty -q -m "init"
GIT_REPO="$(cd -P "$GIT_REPO" && pwd)"

WORKTREE="$TMP/wt-scratch"
git -C "$GIT_REPO" worktree add --detach "$WORKTREE" HEAD >/dev/null 2>&1

# ── G1: init in worktree without flag → REFUSED ──────────────────────────
G1_OUT="$(cd "$WORKTREE" && "$SP" init --name g1-junk 2>&1)" && G1_RC=0 || G1_RC=$?
if [ "$G1_RC" -ne 0 ] && echo "$G1_OUT" | grep -q "worktree"; then
  ok "G1: init in worktree without flag REFUSED"
else
  bad "G1: init in worktree without flag REFUSED (rc=$G1_RC out=$G1_OUT)"
fi
[ ! -d "$WORKTREE/.stitchpad" ] && ok "G1b: no .stitchpad created on refusal" \
  || bad "G1b: no .stitchpad created on refusal"

# ── G2: init --scratch in worktree → scratch pad ─────────────────────────
G2_OUT="$(cd "$WORKTREE" && "$SP" init --scratch --name g2-scratch 2>&1)" || { bad "G2 setup: init --scratch failed"; }
[ -f "$WORKTREE/.stitchpad/.scratch" ] && ok "G2: scratch sentinel exists" \
  || bad "G2: scratch sentinel exists"
echo "$G2_OUT" | grep -q "NOT a channel" && ok "G2b: output says NOT a channel" \
  || bad "G2b: output says NOT a channel"

# ── G3: init --force in worktree → real channel ──────────────────────────
WORKTREE2="$TMP/wt-channel"
git -C "$GIT_REPO" worktree add --detach "$WORKTREE2" HEAD >/dev/null 2>&1
G3_OUT="$(cd "$WORKTREE2" && "$SP" init --force --name g3-channel 2>&1)" || { bad "G3 setup: init --force failed"; }
[ ! -f "$WORKTREE2/.stitchpad/.scratch" ] && ok "G3: no scratch sentinel for --force pad" \
  || bad "G3: no scratch sentinel for --force pad"

# ── G4: scratch pad NOT in channel listing ───────────────────────────────
if sp_pads_tmp | grep -q "wt-scratch"; then
  bad "G4: scratch pad wt-scratch appears in channel listing"
else
  ok "G4: scratch pad NOT in channel listing"
fi

# ── G5: scratch pad IS in --scratch listing ──────────────────────────────
if sp_pads_scratch_tmp | grep -q "wt-scratch"; then
  ok "G5: scratch pad appears in --scratch listing"
else
  bad "G5: scratch pad appears in --scratch listing"
fi

# ── G6: channel pad appears in normal listing ────────────────────────────
if sp_pads_tmp | grep -q "wt-channel"; then
  ok "G6: channel pad (--force) appears in normal listing"
else
  bad "G6: channel pad (--force) appears in normal listing"
fi

# ── G7: pads --prune removes scratch pads ────────────────────────────────
G7_OUT="$(sp_pads_prune_tmp 2>&1)" || true
if echo "$G7_OUT" | grep -q "pruned"; then
  if [ ! -d "$WORKTREE/.stitchpad" ]; then
    ok "G7: pads --prune removed scratch pad"
  else
    bad "G7: pads --prune removed scratch pad (still present)"
  fi
else
  bad "G7: pads --prune (no prune output: $G7_OUT)"
fi

# Clean up channel pad
rm -rf "$WORKTREE2/.stitchpad" 2>/dev/null || true

# ── G8: suite sweep — ZERO new channels after running tests ──────────────
echo ""
echo "--- G8: suite sweep channel invasion ---"
_channels_pre_sweep="$(count_home_channels)"

# Create a worktree-like scenario: test init inside a temp dir
SUITE_TMP="$TMP/suite-fixture"
mkdir -p "$SUITE_TMP"
( cd "$SUITE_TMP" && "$SP" init --scratch --name fixture-pad >/dev/null 2>&1 ) || true
# Join an agent (common test pattern — should not create a channel)
STITCHPAD_NAME=test STITCHPAD_PAD_DIR="$SUITE_TMP/.stitchpad" STITCHPAD_STEAL=1 \
  "$SP" join test cli pull - >/dev/null 2>&1 || true
# Post a message
STITCHPAD_NAME=test STITCHPAD_PAD_DIR="$SUITE_TMP/.stitchpad" \
  "$SP" say "sweep test message" >/dev/null 2>&1 || true

_channels_post_sweep="$(count_home_channels)"
if [ "$_channels_pre_sweep" = "$_channels_post_sweep" ]; then
  ok "G8: suite sweep created ZERO new channels ($_channels_pre_sweep before = $_channels_post_sweep after)"
else
  bad "G8: suite sweep created ZERO new channels ($_channels_pre_sweep before → $_channels_post_sweep after)"
fi

# ── G9: MUTANT — remove .scratch sentinel → scratch pad becomes channel ──
echo ""
echo "--- G9: mutant (remove .scratch → channel breach) ---"
MUT_TMP="$TMP/mutant-wt"
git -C "$GIT_REPO" worktree add --detach "$MUT_TMP" HEAD >/dev/null 2>&1
( cd "$MUT_TMP" && "$SP" init --scratch --name g9-mutant >/dev/null 2>&1 ) || { bad "G9 setup: init --scratch failed"; }
if sp_pads_tmp | grep -q "mutant-wt"; then
  bad "G9 pre: scratch pad leaked into channel listing (pre-mutation)"
else
  ok "G9 pre: scratch pad hidden (correct)"
fi
rm -f "$MUT_TMP/.stitchpad/.scratch" 2>/dev/null || true
if sp_pads_tmp | grep -q "mutant-wt"; then
  ok "G9 mutant: removing .scratch exposes pad as channel — GATE RED (the sentinel is the ONLY barrier)"
else
  bad "G9 mutant: removing .scratch exposes pad as channel (sentinel removal had no effect)"
fi

# Cleanup worktrees
git -C "$GIT_REPO" worktree remove "$WORKTREE" --force 2>/dev/null || true
git -C "$GIT_REPO" worktree remove "$WORKTREE2" --force 2>/dev/null || true
git -C "$GIT_REPO" worktree remove "$MUT_TMP" --force 2>/dev/null || true
rm -rf "$SUITE_TMP" 2>/dev/null || true

echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
fi
echo "All $pass P18 scratch-pad gates PASSED"
exit 0
