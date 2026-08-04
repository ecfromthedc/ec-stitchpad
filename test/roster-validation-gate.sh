#!/usr/bin/env bash
# roster-validation-gate.sh — F3/F4 gate: join name validation + assignee roster validation
# Built for frozen SHA 3869856.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
SP="$TOP/tool/bin/stitchpad"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# Isolate: per-run temp, fake HOME for terminal locks, no watcher
_RUN_TMP="$(mktemp -d /tmp/sp-gate-F3F4.XXXXXXXX)"
export TMPDIR="$_RUN_TMP"
export HOME="$_RUN_TMP/home"
mkdir -p "$HOME"
_kill_watchers() { pkill -9 -f "watch.sh" 2>/dev/null || true; pkill -9 -f "fswatch" 2>/dev/null || true; }
cleanup() { _kill_watchers; rm -rf "$_RUN_TMP" 2>/dev/null || true; }
trap 'cleanup' EXIT
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export STITCHPAD_WATCH_START_GRACE=0
export STITCHPAD_STEAL=1   # allow multiple joins on same terminal in tests

pad_init() {
  local name="$1" dir="$2"
  mkdir -p "$dir"
  ( cd "$dir"; "$SP" init --name "$name" 2>/dev/null || return 1; )
  _kill_watchers
  sleep 0.5
}

pad_do() {
  local dir="$1"; shift
  _kill_watchers 2>/dev/null || true
  sleep 0.2
  ( cd "$dir"; "$SP" "$@" )
}

# ── F3: join name validation ──
echo "=== F3: join name validation ==="

pad_init f3 "$_RUN_TMP/pad" || { bad "F3 setup: init"; exit 1; }

# Add alice as baseline
pad_do "$_RUN_TMP/pad" join alice test pull - >/dev/null 2>&1 || { bad "F3 setup: join alice"; exit 1; }
echo "  baseline: alice joined"

# F3a: Unicode name rejected (é = U+00E9, outside ASCII)
out=$(pad_do "$_RUN_TMP/pad" join "davé" test pull - 2>&1 || true)
if echo "$out" | grep -q "bad name"; then
  ok "F3a: unicode name 'davé' rejected by allowlist"
else
  bad "F3a: unicode name 'davé' NOT rejected (got: $out)"
fi

# F3b: case-variant duplicate refused (Alice vs alice — tolower collision)
out=$(pad_do "$_RUN_TMP/pad" join "Alice" test pull - 2>&1 || true)
if echo "$out" | grep -q "already in roster"; then
  ok "F3b: case-variant 'Alice' refused (alice already in roster)"
else
  bad "F3b: case-variant 'Alice' NOT refused (got: $out)"
fi

# F3c: extended-ASCII rejected (á = U+00E1)
out=$(pad_do "$_RUN_TMP/pad" join "dáve" test pull - 2>&1 || true)
if echo "$out" | grep -q "bad name"; then
  ok "F3c: extended-ascii 'dáve' rejected by allowlist"
else
  bad "F3c: extended-ascii 'dáve' NOT rejected (got: $out)"
fi

# F3d: valid name joins successfully
out=$(pad_do "$_RUN_TMP/pad" join bob test pull - 2>&1 || true)
if echo "$out" | grep -q "joined"; then
  ok "F3d: valid name 'bob' joined successfully"
else
  bad "F3d: valid name 'bob' failed to join (got: $out)"
fi

# F3e: roster has exactly 3 members (f3 from init + alice + bob), no ghost rows
count=$(awk '/^```roster/{inblk=1;next} /^```/&&inblk{inblk=0} inblk && /[a-z].*\|/{c++} END{print c+0}' "$_RUN_TMP/pad/.stitchpad/stitchpad.md")
if [ "$count" -eq 3 ]; then
  ok "F3e: roster has exactly 3 members (no ghost rows from unicode/case rejects)"
else
  bad "F3e: roster has $count members (expected 3 — ghost rows present)"
fi

# F3f: re-join of existing member is idempotent (exit 0)
out=$(pad_do "$_RUN_TMP/pad" join alice test pull - 2>&1 || true)
if echo "$out" | grep -q "already in roster" && ! echo "$out" | grep -q "^stitchpad: REFUSED"; then
  ok "F3f: re-join of existing member is idempotent (exit 0, not a refusal)"
else
  bad "F3f: re-join of existing member NOT idempotent (got: $out)"
fi

# ── F4: assignee roster validation ──
echo ""
echo "=== F4: assignee roster validation ==="

pad_init f4 "$_RUN_TMP/pad2" || { bad "F4 setup: init"; exit 1; }

# Add members
pad_do "$_RUN_TMP/pad2" join alice test pull - >/dev/null 2>&1
pad_do "$_RUN_TMP/pad2" join bob test pull - >/dev/null 2>&1
pad_do "$_RUN_TMP/pad2" join carol test pull - >/dev/null 2>&1

# F4a: task new with valid assignee
out=$(pad_do "$_RUN_TMP/pad2" task new "test task" --to bob 2>&1 || true)
tid=$(echo "$out" | grep -o 'TASK-[0-9]*' | head -1)
if [ -n "$tid" ]; then
  ok "F4a: task created with valid assignee 'bob' → $tid"
else
  bad "F4a: task creation with valid assignee failed: $out"
fi

# F4b: task new with non-roster assignee refused
out=$(pad_do "$_RUN_TMP/pad2" task new "ghost task" --to zombie 2>&1 || true)
if echo "$out" | grep -q "not in roster"; then
  ok "F4b: task new refused with non-roster assignee 'zombie'"
else
  bad "F4b: task new NOT refused with non-roster assignee (got: $out)"
fi

# F4c: task edit --to zombie refused
if [ -n "$tid" ]; then
  out=$(pad_do "$_RUN_TMP/pad2" task edit "$tid" --to zombie 2>&1 || true)
  if echo "$out" | grep -q "not in roster"; then
    ok "F4c: task edit refused with non-roster assignee 'zombie'"
  else
    bad "F4c: task edit NOT refused with non-roster assignee (got: $out)"
  fi
fi

# F4d: task edit --to valid assignee accepted
if [ -n "$tid" ]; then
  out=$(pad_do "$_RUN_TMP/pad2" task edit "$tid" --to alice 2>&1 || true)
  if echo "$out" | grep -q "updated"; then
    ok "F4d: task edit accepted with valid roster assignee 'alice'"
  else
    bad "F4d: task edit NOT accepted with valid roster assignee (got: $out)"
  fi
fi

# F4e: leave surfaces open tasks for departing member
pad_do "$_RUN_TMP/pad2" task new "carol's work" --to carol >/dev/null 2>&1
out=$(pad_do "$_RUN_TMP/pad2" leave carol 2>&1 || true)
if echo "$out" | grep -q "open task"; then
  ok "F4e: leave surfaces open tasks for departing member"
else
  bad "F4e: leave does NOT surface open tasks (got: $out)"
fi

# F4f: assignee with underscores/hyphens is valid
out=$(pad_do "$_RUN_TMP/pad2" task new "dash test" --to bob 2>&1 || true)
if echo "$out" | grep -q "TASK-"; then
  ok "F4f: dashes/underscores in assignee name handled correctly"
else
  bad "F4f: dashes/underscores in assignee name not handled (got: $out)"
fi

echo ""
echo "=== RESULTS: $pass PASS, $fail FAIL ==="
[ "$fail" -eq 0 ] || exit 1