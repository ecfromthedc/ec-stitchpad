#!/usr/bin/env bash
# task26-mutant.sh — prove TASK-26 parse_tasks dual-file fix
# MUT10: revert parse_tasks_merged to single-source → 3 dual-file tests go RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SRC="$ROOT/tool/tui-rs/src/widgets/tasks.rs"
TD="$ROOT/tool/tui-rs"
# A PER-RUN backup path. This was a FIXED /tmp filename, and the combination of
# that, a cleanup that `rm -f`s it, and a restore that swallowed its own failure
# left a live mutant in the working tree:
#
#     for s in [pad_str] { // MUT10: tasks.md IGNORED
#
# found committed-adjacent in tool/tui-rs/src/widgets/tasks.rs after a suite
# run. Two runs sharing one backup path is all it takes — the first run's
# cleanup deletes the file, the second's `cp ... 2>/dev/null || true` finds
# nothing, succeeds silently, and the tree keeps the mutation. Anyone running
# the TUI from that tree afterwards silently loses tasks.md, and a blanket
# `git add -A` would commit it.
#
# A red-proof harness that can leave the tree mutated is the worst possible
# place for this bug: every proof this project trusts runs through one.
BACKUP="$(mktemp "${TMPDIR:-/tmp}/task26-backup.XXXXXX.rs")"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Snapshot current source (which has the fix + tests)
cp "$SRC" "$BACKUP" || { echo "task26-mutant: cannot snapshot $SRC — refusing to mutate" >&2; exit 1; }

# Restore LOUDLY. A harness that cannot put the tree back must say so and fail,
# never exit 0 having left a mutant behind.
restore_src() {
  if [ ! -s "$BACKUP" ]; then
    echo "task26-mutant: BACKUP $BACKUP is missing or empty — CANNOT RESTORE $SRC" >&2
    return 1
  fi
  cp "$BACKUP" "$SRC" || { echo "task26-mutant: restore of $SRC FAILED" >&2; return 1; }
  if grep -q 'MUT10: tasks.md IGNORED' "$SRC"; then
    echo "task26-mutant: $SRC STILL CARRIES THE MUT10 MUTANT after restore" >&2
    return 1
  fi
  return 0
}

cleanup() {
  local rc=$?
  if ! restore_src; then
    echo "task26-mutant: THE WORKING TREE IS LEFT MUTATED — restore $SRC by hand (git checkout -- $SRC)" >&2
    rm -f "$BACKUP"
    exit 1
  fi
  rm -f "$BACKUP"
  exit "$rc"
}
# INT/TERM as well as EXIT: a killed run is exactly when a mutant gets stranded.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── RED: apply mutation ──
echo "=== RED: MUT10 single-source revert ==="
python3 "$HERE/_mut10_singlefile.py" "$SRC"
echo ""
red_out="$(cd "$TD" && cargo test 2>&1)" || true
echo "$red_out" | grep -E 'test result' | head -5
echo ""
echo "$red_out" | grep -E 'tasks_from_tasksmd_only|dedup_task_1_last_wins|merge_preserves_first_seen' | head -10

# Did any of the dual-file tests fail?
if echo "$red_out" | grep -qE 'tasks_from_tasksmd_only.*FAILED|dedup_task_1_last_wins.*FAILED|merge_preserves_first_seen.*FAILED'; then
    echo "  ${RED}>>> KILLED (tasks.md tests fail)${NC}"
    red_killed=1
elif echo "$red_out" | grep -q 'FAILED'; then
    echo "  ${RED}>>> KILLED (some tests FAILED)${NC}"
    red_killed=1
else
    echo "  ${YELLOW}>>> SURVIVED (no dual-file test failed)${NC}"
    red_killed=0
fi

# ── GREEN: restore fix ──
restore_src || { echo "task26-mutant: cannot restore before the GREEN phase" >&2; exit 1; }
echo ""
echo "=== GREEN: dual-file fix restored ==="
green_out="$(cd "$TD" && cargo test 2>&1)" || true
echo "$green_out" | grep -E 'test result' | head -5

if echo "$green_out" | grep -q 'FAILED'; then
    echo "  ${RED}>>> STILL FAILS${NC}"; green_ok=0
else
    echo "  ${GREEN}>>> PASSES${NC}"; green_ok=1
fi

echo ""
echo "=== TASK-26 RESULT ==="
echo "RED killed=$red_killed  GREEN pass=$green_ok"
if [ "$red_killed" -eq 1 ] && [ "$green_ok" -eq 1 ]; then
    echo "KILLED ✓"
else
    echo "NOT KILLED ✗"
    exit 1
fi
