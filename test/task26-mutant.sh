#!/usr/bin/env bash
# task26-mutant.sh — prove TASK-26 parse_tasks dual-file fix
# MUT10: revert parse_tasks_merged to single-source → 3 dual-file tests go RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SRC="$ROOT/tool/tui-rs/src/widgets/tasks.rs"
TD="$ROOT/tool/tui-rs"
BACKUP="/tmp/task26-secure-backup.rs"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Snapshot current source (which has the fix + tests)
cp "$SRC" "$BACKUP"
cleanup() { cp "$BACKUP" "$SRC" 2>/dev/null || true; rm -f "$BACKUP"; }
trap cleanup EXIT

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
cp "$BACKUP" "$SRC"
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
