#!/usr/bin/env bash
# pro3-f4-gate.sh — F4: assignee roster validation + leave open-task warning
# Frozen SHA: 3869856
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
SP="$TOP/tool/bin/stitchpad"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

_RUN_TMP="$(mktemp -d /tmp/sp-gate-F4.XXXXXXXX)"
export TMPDIR="$_RUN_TMP"
export HOME="$_RUN_TMP/home"
mkdir -p "$HOME"
_kill_watchers() { pkill -9 -f "watch.sh" 2>/dev/null || true; pkill -9 -f "fswatch" 2>/dev/null || true; }
cleanup() { _kill_watchers; rm -rf "$_RUN_TMP" 2>/dev/null || true; }
trap 'cleanup' EXIT
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export STITCHPAD_WATCH_START_GRACE=0
export STITCHPAD_STEAL=1

pad_init() {
  local name="$1" dir="$2"
  mkdir -p "$dir"
  ( cd "$dir"; "$SP" init --name "$name" 2>/dev/null || return 1; )
  _kill_watchers; sleep 0.5
}

pad_do() {
  local dir="$1"; shift
  _kill_watchers 2>/dev/null || true; sleep 0.2
  ( cd "$dir"; "$SP" "$@" )
}

echo "=== F4: assignee roster validation ==="

pad_init f4 "$_RUN_TMP/pad" || { bad "setup: init"; exit 1; }

# Add members
pad_do "$_RUN_TMP/pad" join alice test pull - >/dev/null 2>&1
pad_do "$_RUN_TMP/pad" join bob test pull - >/dev/null 2>&1
pad_do "$_RUN_TMP/pad" join carol test pull - >/dev/null 2>&1

# F4a: task new with valid assignee
out=$(pad_do "$_RUN_TMP/pad" task new "test task" --to bob 2>&1 || true)
tid=$(echo "$out" | grep -o 'TASK-[0-9]*' | head -1)
[ -n "$tid" ] && ok "F4a: task created with valid assignee 'bob' → $tid" \
  || bad "F4a: task creation with valid assignee failed: $out"

# F4b: task new with non-roster assignee refused
out=$(pad_do "$_RUN_TMP/pad" task new "ghost task" --to zombie 2>&1 || true)
echo "$out" | grep -q "not in roster" \
  && ok "F4b: task new refused with non-roster assignee 'zombie'" \
  || bad "F4b: task new NOT refused with non-roster assignee (got: $out)"

# F4c: task edit --to zombie refused
if [ -n "$tid" ]; then
  out=$(pad_do "$_RUN_TMP/pad" task edit "$tid" --to zombie 2>&1 || true)
  echo "$out" | grep -q "not in roster" \
    && ok "F4c: task edit refused with non-roster assignee 'zombie'" \
    || bad "F4c: task edit NOT refused with non-roster assignee (got: $out)"
fi

# F4d: task edit --to valid assignee accepted
if [ -n "$tid" ]; then
  out=$(pad_do "$_RUN_TMP/pad" task edit "$tid" --to alice 2>&1 || true)
  echo "$out" | grep -q "updated" \
    && ok "F4d: task edit accepted with valid roster assignee 'alice'" \
    || bad "F4d: task edit NOT accepted with valid roster assignee (got: $out)"
fi

# F4e: leave surfaces open tasks — THE REPRO: assign card to carol, then leave
pad_do "$_RUN_TMP/pad" task new "carol's work" --to carol >/dev/null 2>&1
out=$(pad_do "$_RUN_TMP/pad" leave carol 2>&1 || true)
echo "$out" | grep -q "open task" \
  && ok "F4e: leave surfaces open tasks for departing member" \
  || bad "F4e: leave does NOT surface open tasks (got: $out)"

# F4f: leave warning names the card (not just a count)
echo "$out" | grep -q "TASK-" \
  && ok "F4f: leave warning names the specific open card(s)" \
  || bad "F4f: leave warning does NOT name specific cards (got: $out)"

# F4g: task card stays assigned to departed member (known-open; verify it's visible)
pad_do "$_RUN_TMP/pad" join dave test pull - >/dev/null 2>&1
out=$(pad_do "$_RUN_TMP/pad" task new "dave's work" --to dave 2>&1 || true)
tid2=$(echo "$out" | grep -o 'TASK-[0-9]*' | head -1)
pad_do "$_RUN_TMP/pad" leave dave 2>&1 || true
# Verify the card still shows dave as assignee (the assignment didn't silently change)
out=$(pad_do "$_RUN_TMP/pad" task show "$tid2" 2>&1 || true)
echo "$out" | grep -q "dave" \
  && ok "F4g: card retains departed assignee name (operator can see it and reassign)" \
  || bad "F4g: card lost departed assignee name (got: $out)"

echo ""
echo "=== RESULTS: $pass PASS, $fail FAIL ==="
[ "$fail" -eq 0 ] || exit 1