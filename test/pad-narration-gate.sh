#!/usr/bin/env bash
# pad-narration-gate.sh — P19: the pad must narrate itself
#
# An agent that NEVER calls `say` must still produce visible progress
# on the pad: lane taken (join), commit landed (task create), card
# closed (task move → done).
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SP="$ROOT/tool/bin/stitchpad"
SHDIR="$ROOT/tool"
LIB="$ROOT/tool/bin/lib.sh"
export STITCHPAD_HOME="$SHDIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-pnar.XXXXXX")"
cleanup() {
  [ -f "$WORK/pad/.stitchpad/watch.lock.d/pid" ] && { read -r opid < "$WORK/pad/.stitchpad/watch.lock.d/pid" 2>/dev/null; [ -n "$opid" ] && kill -KILL "$opid" 2>/dev/null || true; }
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

_grep_count() { grep -c "$1" "$2" 2>/dev/null; true; }

export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

mkdir -p "$WORK/home"
export HOME="$WORK/home"

nop() {
  HOME="$WORK/home" STITCHPAD_NAME=nar-bot STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_HOME="$SHDIR" "$SP" "$@"
}

echo "── pad: $WORK/pad/.stitchpad"

# ═══════════════  FIX PROOF  ═══════════════

mkdir -p "$WORK/pad" && cd "$WORK/pad"
nop init --name p19-gate >/dev/null 2>&1

echo "--- G1: agent joins (lane taken) ---"
nop join nar-bot cli pull - >/dev/null 2>&1
grep -q '### @nar-bot.*roster.*nar-bot' "$WORK/pad/.stitchpad/stitchpad.md" \
  && ok "G1: lane taken — pad shows @nar-bot joined" \
  || bad "G1: lane taken — narration missing from pad"

echo "--- G2: agent creates a task (commit landed) ---"
nop task new "prove P19 gate" --priority high >/dev/null 2>&1
TASK_ID=$(nop task list 2>&1 | grep '^TASK-2|' | sed 's/|.*//')
[ -n "$TASK_ID" ] && ok "G2a: task created (id=$TASK_ID)" \
  || bad "G2a: task created — id not found"

grep -q "### @nar-bot.*task.*${TASK_ID}" "$WORK/pad/.stitchpad/stitchpad.md" \
  && ok "G2b: commit landed — pad shows task creation" \
  || bad "G2b: commit landed — task narration missing"

echo "--- G3: agent moves card to done (card closed) ---"
nop task move "$TASK_ID" done >/dev/null 2>&1
grep -q "### @nar-bot.*${TASK_ID}.*done" "$WORK/pad/.stitchpad/stitchpad.md" \
  && ok "G3: card closed — pad shows task → done" \
  || bad "G3: card closed — done narration missing"

echo "--- G4: agent NEVER called say — zero conversation lines ---"
_conv=$(_grep_count '^## @nar-bot ' "$WORK/pad/.stitchpad/stitchpad.md")
[ "$_conv" -eq 0 ] && ok "G4: zero say lines — agent never called say" \
  || bad "G4: zero say lines — found $_conv (agent called say)"

echo "--- G5: lanes command shows nar-bot ---"
LANES_OUT=$(nop lanes 2>&1 || true)
echo "$LANES_OUT" | grep -q 'nar-bot' \
  && ok "G5: lanes shows nar-bot activity" \
  || bad "G5: lanes shows nar-bot (got: $LANES_OUT)"

echo "--- G6: total narration lines ≥ 3 ---"
NAR_TOT=$(_grep_count '^### @nar-bot' "$WORK/pad/.stitchpad/stitchpad.md")
[ "$NAR_TOT" -ge 3 ] && ok "G6: $NAR_TOT narration lines (≥3)" \
  || bad "G6: $NAR_TOT narration lines (<3 — pad looks idle)"

echo "--- G7: narration must not look like a mention (no wake loop) ---"
# Narration writes `### @nar-bot ...`. The mention scanner matched `(^|[ \t])@name`
# anywhere in a block buffer, so every narrated lane became a PHANTOM MENTION of
# the agent that had just acted, and the Stop hook replayed a closed recovery
# forever (reset-recovery.sh went RED the moment narration landed). Nobody
# addressed @nar-bot here, so nothing may be queued for it.
# The phantom mention only forms INSIDE a conversation block: `### @name` is not
# a block start (`^## @`), so it is appended to whatever block precedes it. The
# first version of this check had no block at all, so it passed even with the
# scanner exclusion removed — an inconclusive mutant that proved nothing. Give it
# a real block from a DIFFERENT author, then let nar-bot narrate into it.
opsay() { HOME="$WORK/home" STITCHPAD_NAME=operator STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_TERMINAL_NAMESPACE=p19-operator STITCHPAD_HOME="$SHDIR" "$SP" "$@"; }
opsay say 'starting the review, no addresses here' >/dev/null 2>&1
nop task new "narration lands inside the operator block" >/dev/null 2>&1
NAR_PEEK="$(nop wake nar-bot --peek 2>&1 || true)"
if printf '%s' "$NAR_PEEK" | grep -q 'NEW from @'; then
  bad "G7: narration queued a phantom mention for @nar-bot — wake loop: $(printf '%s' "$NAR_PEEK" | head -1)"
else
  ok "G7: narration created no phantom mention (no wake loop)"
fi

echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
fi
echo "All $pass P19 pad-narration gates PASSED"
exit 0
