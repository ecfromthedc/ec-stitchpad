#!/usr/bin/env bash
# Fixtures must not inherit the caller's ambient session identity: sp_this_surface()
# falls back to $CLAUDE_CODE_SESSION_ID/$CODEX_SESSION_ID, which makes every simulated
# agent in this suite share ONE surface and trip "one terminal = one (pad,name)".
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
# Regression test: identity-survival-under-join
#
# Verifies that when agent A joins, agent B joins, then agent A posts again,
# A's second post still lands as @A — not clobbered by B's join.
#
# Covers the whoami-collision bug where a session-capable runtime (codex/claude)
# that falls back to shared .state/whoami would have its identity overwritten
# by a later join.
#
# Authorship is checked via content-based ## @<name> block headers, not git
# subjects (which are unreliable due to daemon update-commit races).
#
# Usage: STITCHPAD_CWD=<project> bash test/regression/identity-survival-under-join.sh
#   STITCHPAD_CWD defaults to the directory containing .stitchpad/

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
owns_fixture=0

if [ -n "${STITCHPAD_CWD:-}" ]; then
  pad_dir="$STITCHPAD_CWD"
else
  pad_dir="$(mktemp -d)"
  owns_fixture=1
  mkdir -p "$pad_dir/home"
  export HOME="$pad_dir/home"
  unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
  cd "$pad_dir"
  "$SP" init --name identity-regtest >/dev/null
fi
PAD="${pad_dir}/.stitchpad/stitchpad.md"

cleanup() {
  for name in regtest-alpha regtest-bravo; do
    STITCHPAD_PAD_DIR="$pad_dir/.stitchpad" "$SP" heartbeat --stop "$name" >/dev/null 2>&1 || true
  done
  STITCHPAD_PAD_DIR="$pad_dir/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  [ "$owns_fixture" -eq 0 ] || rm -rf "$pad_dir"
}
trap cleanup EXIT

# ── helpers ────────────────────────────────────────────────────────────

stitchpad_cli() {
  STITCHPAD_CWD="$pad_dir" "$SP" "$@"
}

stitchpad_say_as() {
  local name="$1"
  local msg="$2"
  STITCHPAD_NAME="$name" stitchpad_cli say "$msg"
}

stitchpad_join_as() {
  local name="$1"
  local adapter="${2:-codex}"
  STITCHPAD_NAME="$name" stitchpad_cli join "$name" "$adapter"
}

latest_author() {
  # Return the @name from the newest ## @<name> block header in the pad.
  grep '^## @' "$PAD" | tail -1 | sed 's/^## @//; s/ .*//'
}

assert_latest_author_is() {
  local expected="$1"
  local label="${2:-}"
  local actual
  actual="$(latest_author)"
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label: newest ## @ header is @$expected"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label: expected @$expected, got @$actual"
    FAIL=$((FAIL + 1))
  fi
}

# ── setup ──────────────────────────────────────────────────────────────

echo "=== identity-survival-under-join ==="
echo "Pad: $PAD"
echo ""

if [ ! -x "$SP" ]; then
  echo -e "${RED}FATAL: checkout stitchpad CLI not executable at $SP${NC}"
  exit 1
fi

if [ ! -f "$PAD" ]; then
  echo -e "${RED}FATAL: pad not found at $PAD${NC}"
  exit 1
fi

# ── Phase 1: Agent A (codex) joins and posts ───────────────────────────

AGENT_A="regtest-alpha"
AGENT_B="regtest-bravo"

echo "Phase 1: $AGENT_A joins and posts"
stitchpad_join_as "$AGENT_A" codex
stitchpad_say_as "$AGENT_A" "regression test: $AGENT_A initial post — identity anchor"
assert_latest_author_is "$AGENT_A" "A's first post lands as @A"

# ── Phase 2: Agent B (codex) joins and posts ───────────────────────────

echo ""
echo "Phase 2: $AGENT_B joins and posts"
stitchpad_join_as "$AGENT_B" codex
stitchpad_say_as "$AGENT_B" "regression test: $AGENT_B post — establishing second identity"
assert_latest_author_is "$AGENT_B" "B's post lands as @B"

# ── Phase 3: Agent A posts again — CRITICAL ASSERTION ───────────────────

echo ""
echo "Phase 3: $AGENT_A posts again — identity must survive B's join"
stitchpad_say_as "$AGENT_A" "regression test: $AGENT_A second post — identity survival check"
assert_latest_author_is "$AGENT_A" "A's second post still lands as @A (post-B-join)"

# ── Phase 4: 2-codex impersonation case ────────────────────────────────

echo ""
echo "Phase 4: 2-codex impersonation — B posts, then A posts, both must be distinct"
stitchpad_say_as "$AGENT_B" "regression test: $AGENT_B — distinct from @$AGENT_A"
assert_latest_author_is "$AGENT_B" "B's post after A's survival check"
stitchpad_say_as "$AGENT_A" "regression test: $AGENT_A — still distinct from @$AGENT_B"
assert_latest_author_is "$AGENT_A" "A's post still distinct from B"

# ── Phase 5: Rapid back-and-forth (stress test) ────────────────────────

echo ""
echo "Phase 5: rapid back-and-forth — alternating posts, identity must not drift"
for i in 1 2 3; do
  stitchpad_say_as "$AGENT_A" "regression test: $AGENT_A round $i"
  assert_latest_author_is "$AGENT_A" "A round $i (alternating)"
  stitchpad_say_as "$AGENT_B" "regression test: $AGENT_B round $i"
  assert_latest_author_is "$AGENT_B" "B round $i (alternating)"
done

# ── summary ────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
