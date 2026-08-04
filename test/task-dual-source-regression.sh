#!/usr/bin/env bash
# task-dual-source-regression.sh — pro8: task dual-source consistency
# Covers: DS1 (show uses tasks.md precedence, not first-match),
#         DS2 (list and show agree on every field),
#         DS3 (edit warns about cross-file duplicate),
#         DS4 (move warns about cross-file duplicate),
#         DS5 (no false divergence after edit).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  FAIL %s: %s\n' "$1" "${2:-}" >&2; }

cleanup() { rm -rf "$TMP"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-ds.XXXXXX")"
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export STITCHPAD_HOME="$ROOT/tool"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID

# Helper: inject an inline ghost task block into the pad
inject_inline_ghost() {
  local pad_md="$1" tid="$2" title="$3" status="$4" priority="$5" assignee="$6"
  python3 - "$pad_md" "$tid" "$title" "$status" "$priority" "$assignee" << 'PYEOF'
import sys
with open(sys.argv[1], 'a') as f:
    f.write('\n```task ' + sys.argv[2] + '\n')
    f.write('title: ' + sys.argv[3] + '\n')
    f.write('status: ' + sys.argv[4] + '\n')
    f.write('priority: ' + sys.argv[5] + '\n')
    f.write('assignee: ' + sys.argv[6] + '\n')
    f.write('labels:\ncreated: 01-01 00:00\n---\nINLINE GHOST COPY — NOT AUTHORITATIVE\n```\n')
PYEOF
}

# Helper: extract a field from task list output
# stitchpad task list prints: TASK-N|title|status|priority|assignee|labels|created|desc
task_field() {
  local tid="$1" field="$2"
  local idx=1
  case "$field" in
    title) idx=2 ;; status) idx=3 ;; priority) idx=4 ;; assignee) idx=5 ;;
  esac
  "$SP" task list | awk -F'|' -v tid="$tid" -v idx="$idx" '$1==tid{print $idx}'
}

# ===========================================================================
# DS1: task show uses tasks.md precedence (not first-match)
# ===========================================================================
echo "=== DS1: show uses tasks.md precedence ==="
echo ""

DS1_WORK="$TMP/ds1"; mkdir -p "$DS1_WORK"; cd "$DS1_WORK"

"$SP" init --name ds1 >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" task new "auth fix" --assignee carol --priority high >/dev/null 2>&1

# Inject a ghost with DIFFERENT fields
inject_inline_ghost "$DS1_WORK/.stitchpad/stitchpad.md" "TASK-2" \
  "auth fix (INLINE GHOST)" "done" "low" "bob"
git --git-dir="$DS1_WORK/.stitchpad/stitchpad-git" --work-tree="$DS1_WORK/.stitchpad" \
  add stitchpad.md && git --git-dir="$DS1_WORK/.stitchpad/stitchpad-git" \
  --work-tree="$DS1_WORK/.stitchpad" commit -q -m "inject ghost"

# DS1a: show must return tasks.md content, not pad ghost
DS1A_OUT="$("$SP" task show TASK-2 2>&1)"
if echo "$DS1A_OUT" | grep -q 'auth fix$'; then
  ok "DS1a: show returns tasks.md title (no ghost suffix)"
elif echo "$DS1A_OUT" | grep -q 'GHOST'; then
  bad "DS1a: show returned INLINE GHOST — first-match bug!" "$DS1A_OUT"
else
  bad "DS1a: unexpected show output" "$(printf '%s' "$DS1A_OUT" | head -c 120)"
fi

# DS1b: show must NOT return ghost fields
if echo "$DS1A_OUT" | grep -q 'status: todo'; then
  ok "DS1b: show returns tasks.md status (todo, not done from ghost)"
elif echo "$DS1A_OUT" | grep -q 'status: done'; then
  bad "DS1b: show returned ghost status 'done'"
else
  bad "DS1b: status ambiguous" "$DS1A_OUT"
fi

# DS1c: show must return carol (tasks.md assignee), not bob (ghost assignee)
if echo "$DS1A_OUT" | grep -q 'assignee: carol'; then
  ok "DS1c: show returns tasks.md assignee (carol)"
elif echo "$DS1A_OUT" | grep -q 'assignee: bob'; then
  bad "DS1c: show returned ghost assignee 'bob'"
else
  bad "DS1c: assignee ambiguous" "$DS1A_OUT"
fi

cd "$ROOT"

# ===========================================================================
# DS2: list and show agree on every field
# ===========================================================================
echo ""
echo "=== DS2: list and show agree ==="
echo ""

DS2_WORK="$TMP/ds2"; mkdir -p "$DS2_WORK"; cd "$DS2_WORK"

"$SP" init --name ds2 >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" task new "agree test" --assignee dave --priority medium >/dev/null 2>&1

inject_inline_ghost "$DS2_WORK/.stitchpad/stitchpad.md" "TASK-2" \
  "agree test (INLINE GHOST)" "in_progress" "urgent" "ghost"
git --git-dir="$DS2_WORK/.stitchpad/stitchpad-git" --work-tree="$DS2_WORK/.stitchpad" \
  add stitchpad.md && git --git-dir="$DS2_WORK/.stitchpad/stitchpad-git" \
  --work-tree="$DS2_WORK/.stitchpad" commit -q -m "inject ghost"

# Extract fields from list
_list_assignee="$(task_field TASK-2 assignee)"
_list_status="$(task_field TASK-2 status)"

# Extract same fields from show
_show_out="$("$SP" task show TASK-2 2>&1)"
_show_assignee="$(echo "$_show_out" | grep '^assignee:' | sed 's/^assignee: *//')"
_show_status="$(echo "$_show_out" | grep '^status:' | sed 's/^status: *//')"

if [ "$_list_assignee" = "$_show_assignee" ]; then
  ok "DS2a: list assignee ($_list_assignee) = show assignee ($_show_assignee)"
else
  bad "DS2a: list assignee ($_list_assignee) != show assignee ($_show_assignee) — DIVERGENT!"
fi

if [ "$_list_status" = "$_show_status" ]; then
  ok "DS2b: list status ($_list_status) = show status ($_show_status)"
else
  bad "DS2b: list status ($_list_status) != show status ($_show_status) — DIVERGENT!"
fi

cd "$ROOT"

# ===========================================================================
# DS3: edit warns about cross-file duplicate
# ===========================================================================
echo ""
echo "=== DS3: edit warns about duplicate ==="
echo ""

DS3_WORK="$TMP/ds3"; mkdir -p "$DS3_WORK"; cd "$DS3_WORK"

"$SP" init --name ds3 >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" task new "warn test" --assignee carol >/dev/null 2>&1

inject_inline_ghost "$DS3_WORK/.stitchpad/stitchpad.md" "TASK-2" \
  "warn test (GHOST)" "backlog" "none" "nobody"
git --git-dir="$DS3_WORK/.stitchpad/stitchpad-git" --work-tree="$DS3_WORK/.stitchpad" \
  add stitchpad.md && git --git-dir="$DS3_WORK/.stitchpad/stitchpad-git" \
  --work-tree="$DS3_WORK/.stitchpad" commit -q -m "inject ghost"

# DS3a: edit must emit duplicate warning
DS3A_OUT="$(STITCHPAD_NAME=alice "$SP" task edit TASK-2 --assignee bob 2>&1)" || DS3A_RC=$?
if [ "${DS3A_RC:-0}" -eq 0 ]; then ok "DS3a: task edit succeeds (rc=0)"
else bad "DS3a: task edit failed" "$DS3A_OUT"; fi

if echo "$DS3A_OUT" | grep -qi 'WARNING.*exists in both\|TASK-2 exists in BOTH'; then
  ok "DS3b: edit warns about cross-file duplicate"
else
  bad "DS3b: edit did NOT warn about duplicate" "$DS3A_OUT"
fi

# DS3c: after edit, show must display the new assignee (bob) from tasks.md
DS3C_OUT="$("$SP" task show TASK-2 2>&1)"
if echo "$DS3C_OUT" | grep -q 'assignee: bob'; then
  ok "DS3c: after edit, show displays new assignee (bob)"
else
  bad "DS3c: after edit, show does NOT display bob" "$DS3C_OUT"
fi

# DS3d: after edit, list must also show bob
_list_assignee_after="$(task_field TASK-2 assignee)"
if [ "$_list_assignee_after" = "bob" ]; then
  ok "DS3d: after edit, list shows new assignee (bob)"
else
  bad "DS3d: after edit, list shows [$_list_assignee_after] instead of bob"
fi

cd "$ROOT"

# ===========================================================================
# DS4: move warns about cross-file duplicate
# ===========================================================================
echo ""
echo "=== DS4: move warns about duplicate ==="
echo ""

DS4_WORK="$TMP/ds4"; mkdir -p "$DS4_WORK"; cd "$DS4_WORK"

"$SP" init --name ds4 >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" task new "move warn" >/dev/null 2>&1

inject_inline_ghost "$DS4_WORK/.stitchpad/stitchpad.md" "TASK-2" \
  "move warn (GHOST)" "backlog" "none" "nobody"
git --git-dir="$DS4_WORK/.stitchpad/stitchpad-git" --work-tree="$DS4_WORK/.stitchpad" \
  add stitchpad.md && git --git-dir="$DS4_WORK/.stitchpad/stitchpad-git" \
  --work-tree="$DS4_WORK/.stitchpad" commit -q -m "inject ghost"

DS4A_OUT="$(STITCHPAD_NAME=alice "$SP" task move TASK-2 in_progress 2>&1)" || DS4A_RC=$?
if [ "${DS4A_RC:-0}" -eq 0 ]; then ok "DS4a: task move succeeds"
else bad "DS4a: task move failed" "$DS4A_OUT"; fi

if echo "$DS4A_OUT" | grep -qi 'WARNING.*exists in both\|TASK-2 exists in BOTH'; then
  ok "DS4b: move warns about cross-file duplicate"
else
  bad "DS4b: move did NOT warn about duplicate" "$DS4A_OUT"
fi

# DS4c: after move, show must display in_progress from tasks.md
DS4C_OUT="$("$SP" task show TASK-2 2>&1)"
if echo "$DS4C_OUT" | grep -q 'status: in_progress'; then
  ok "DS4c: after move, show displays in_progress (tasks.md authoritative)"
else
  bad "DS4c: after move, show does NOT show in_progress" "$DS4C_OUT"
fi

cd "$ROOT"

# ===========================================================================
# DS5: list warns about cross-file duplicate (sp_tasks)
# ===========================================================================
echo ""
echo "=== DS5: list warns about duplicate ==="
echo ""

DS5_WORK="$TMP/ds5"; mkdir -p "$DS5_WORK"; cd "$DS5_WORK"

"$SP" init --name ds5 >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" task new "list warn" --assignee eve >/dev/null 2>&1

inject_inline_ghost "$DS5_WORK/.stitchpad/stitchpad.md" "TASK-2" \
  "list warn (GHOST)" "backlog" "none" "nobody"
git --git-dir="$DS5_WORK/.stitchpad/stitchpad-git" --work-tree="$DS5_WORK/.stitchpad" \
  add stitchpad.md && git --git-dir="$DS5_WORK/.stitchpad/stitchpad-git" \
  --work-tree="$DS5_WORK/.stitchpad" commit -q -m "inject ghost"

# task list sends duplicate warnings to stderr — capture both
DS5_OUT="$(STITCHPAD_NAME=alice "$SP" task list 2>&1 || true)"
if echo "$DS5_OUT" | grep -qi 'WARNING.*exists in both\|TASK-2 exists in BOTH'; then
  ok "DS5a: task list warns about cross-file duplicate"
else
  bad "DS5a: task list did NOT warn about duplicate (stderr could be separated)"
fi

# DS5b: even with duplicate, list reports eve (tasks.md), not nobody (ghost)
_list_assignee="$(echo "$DS5_OUT" | grep '^TASK-2|' | awk -F'|' '{print $5}')"
if [ "$_list_assignee" = "eve" ]; then
  ok "DS5b: list shows tasks.md assignee (eve) despite ghost"
else
  bad "DS5b: list shows [$_list_assignee] instead of eve — ghost polluted list"
fi

cd "$ROOT"

# ===========================================================================
printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll task-dual-source gates PASSED.\n'; exit 0; }
printf '\nSome task-dual-source gates FAILED.\n'; exit 1
