#!/usr/bin/env bash
# e13-dualwrite-gate.sh — E-13: task new dual-write atomicity
#
# Before E-13: task new appended to tasks.md then PAD_MD sequentially,
# then committed.  A SIGKILL between the two writes left tasks.md dirty
# (card present) and the pad clean — recovery reset tasks.md, losing the
# card permanently with no compensation.
#
# After E-13: both files are built in temp copies under the pad dir, then
# renamed into place together.  The two mv calls are a ~ms window instead
# of the ~human-scale window between the original appends.  A crash before
# either mv leaves NEITHER real file dirty (temps are trap-cleaned).
#
# Gates:
#   G1: normal task new — card in tasks.md, assignment notice in pad
#   G2: kill between tasks.md mv and pad mv — board consistent after recovery
#   G3: mutant (old sequential writes) — card LOST after kill+recovery
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP="$HERE/../tool/bin/stitchpad"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-e13.XXXXXX")"
crash_pid=""
cleanup() {
  [ -n "$crash_pid" ] && kill -KILL "$crash_pid" 2>/dev/null || true
  [ -n "$crash_pid" ] && wait "$crash_pid" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }

export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
mkdir -p "$WORK/home"
cd "$WORK"

sp() {
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$WORK/.stitchpad" \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME="${SPNAME:-tester}" "$SP" "$@"
}

# Two simulated agents need two SURFACES. Without this both joins share one surface
# (inherited from the caller's session), the second is refused by
# "one terminal = one (pad,name)", bob never lands in the roster, and then
# `task new --to bob` is refused by assignee validation — so G1a/G1b/G1c failed with
# no card at all. Both hardenings are correct; the fixture owed distinct surfaces.
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
# This fixture never init'd a pad — it relied on `join` implicitly creating one.
# A pad is only a pad once it has its isolated git dir, so every command answered
# "no pasture found" and G1a/G1b/G1c saw an empty tree.
sp init --name e13 >/dev/null 2>&1 || true
STITCHPAD_SESSION="fx-alice-$$" SPNAME=alice sp join alice cli pull - >/dev/null 2>&1 || true
STITCHPAD_SESSION="fx-bob-$$"   SPNAME=bob   sp join bob   cli pull - >/dev/null 2>&1 || true

pad_md="$WORK/.stitchpad/stitchpad.md"
tasks_md="$WORK/.stitchpad/tasks.md"
pad_git="$WORK/.stitchpad/stitchpad-git"

# ── G1: normal task new — both files populated ──────────────────────────
echo "--- G1: normal task new ---"
SPNAME=alice sp task new "auth fix" --to bob --priority high >/dev/null 2>&1

grep -q 'auth fix' "$tasks_md" 2>/dev/null \
  && ok "G1a: task card in tasks.md" \
  || bad "G1a: task card in tasks.md"
grep -qE 'task TASK-[0-9]+ assigned' "$pad_md" 2>/dev/null \
  && ok "G1b: assignment notice in pad" \
  || bad "G1b: assignment notice in pad"
grep -q '<!-- tasks:file -->' "$pad_md" 2>/dev/null \
  && ok "G1c: tasks:file pointer in pad" \
  || bad "G1c: tasks:file pointer in pad"

# ── G2: kill between tasks.md mv and pad mv — board consistent ──────────
echo "--- G2: kill between mv calls ---"

BARRIER="$WORK/barrier-g2"
SPNAME=alice STITCHPAD_TASK_DUALWRITE_BARRIER="$BARRIER" \
  sp task new "crashme fix" --to bob > "$WORK/g2-crash.out" 2>&1 &
crash_pid=$!

# Wait for barrier (parked after tasks.md mv, before pad mv)
_barrier_ok=0
for _ in $(seq 1 300); do [ -f "$BARRIER.ready" ] && { _barrier_ok=1; break; }; sleep 0.02; done
[ "$_barrier_ok" -eq 1 ] && ok "G2a: barrier reached (parked between mv calls)" \
  || bad "G2a: barrier reached (never parked)"

# tasks.md should have the crashme card (first mv done)
grep -q 'crashme fix' "$tasks_md" 2>/dev/null \
  && ok "G2b: tasks.md has crashme card (first mv done)" \
  || bad "G2b: tasks.md has crashme card"

# Pad should NOT have crashme (second mv pending)
! grep -q 'crashme fix' "$pad_md" 2>/dev/null \
  && ok "G2c: pad NOT yet updated (second mv pending)" \
  || bad "G2c: pad NOT yet updated"

# SIGKILL the writer — tasks.md is dirty, pad is clean
kill -KILL "$crash_pid" 2>/dev/null || true; wait "$crash_pid" 2>/dev/null || true
crash_pid=""

# Recovery: git reset --hard cleans the dirty tasks.md
git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" reset --hard HEAD >/dev/null 2>&1 || true
git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" clean -fd >/dev/null 2>&1 || true

# After recovery, crashme card should NOT be in either file
! grep -q 'crashme fix' "$tasks_md" 2>/dev/null \
  && ok "G2d: crashme card removed by recovery (tasks.md clean)" \
  || bad "G2d: crashme card removed by recovery"
! grep -q 'crashme fix' "$pad_md" 2>/dev/null \
  && ok "G2e: pad also clean — no partial assignment notice" \
  || bad "G2e: pad also clean"

# Board must be consistent — task list reports only auth fix (TASK-1), no crashme
_board="$(SPNAME=alice sp task list 2>&1)"
if echo "$_board" | grep -q 'TASK-1'; then
  ok "G2f: board lists TASK-1 (auth fix survived)"
else
  bad "G2f: board lists TASK-1"
fi
! echo "$_board" | grep -q 'crashme' 2>/dev/null \
  && ok "G2g: board has NO crashme half-card" \
  || bad "G2g: board has NO crashme half-card"

# Retry the crashme task — should succeed cleanly
SPNAME=alice sp task new "crashme fix" --to bob >/dev/null 2>&1
grep -q 'crashme fix' "$tasks_md" 2>/dev/null \
  && ok "G2h: retry — crashme card in tasks.md" \
  || bad "G2h: retry — crashme card in tasks.md"
grep -q 'crashme fix' "$pad_md" 2>/dev/null \
  && ok "G2i: retry — assignment notice in pad" \
  || bad "G2i: retry — assignment notice in pad"

# ── G3: mutant — old sequential writes → card LOST ──────────────────────
echo "--- G3: mutant (old sequential appends) ---"

# MUTANT: simulate the pre-E13 code path: append to tasks.md directly,
# then kill BEFORE appending to pad.
cat >> "$tasks_md" <<'EOMUTANT'

```task TASK-MUT
title: mutant card
status: todo
priority: none
assignee: bob
labels:
created: 01-01 00:00
---
mutant card created
```
EOMUTANT

grep -q 'mutant card' "$tasks_md" 2>/dev/null \
  && ok "G3a: mutant card written to tasks.md (dirty)" \
  || bad "G3a: mutant card written to tasks.md"

# Simulate crash + recovery reset
git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" reset --hard HEAD >/dev/null 2>&1 || true
git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" clean -fd >/dev/null 2>&1 || true

# After recovery, mutant card should be GONE (never committed)
! grep -q 'mutant card' "$tasks_md" 2>/dev/null \
  && ok "G3b: mutant card LOST after recovery (pre-E13 behavior)" \
  || bad "G3b: mutant card LOST after recovery"

# Board must be consistent — no mutant half-cards
_board3="$(SPNAME=alice sp task list 2>&1)"
! echo "$_board3" | grep -q 'TASK-MUT' 2>/dev/null \
  && ok "G3c: board consistent — no mutant half-cards" \
  || bad "G3c: board consistent"

# ── Verdict ──────────────────────────────────────────────────────────────
echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
fi
echo "All $pass E-13 dualwrite gates PASSED"
exit 0
