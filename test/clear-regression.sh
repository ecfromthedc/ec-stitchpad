#!/usr/bin/env bash
# clear-regression.sh — flash2 F1: clear guards against dataloss on legacy pads
# Sealed 2026-08-03 (pro4, bounce-fix). Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sp-clear.XXXXXX")"
cleanup() {
  for n in probe alice bob; do
    STITCHPAD_PAD_DIR="$tmp/legacy-pad/.stitchpad" "$SP" heartbeat --stop "$n" >/dev/null 2>&1 || true
    STITCHPAD_PAD_DIR="$tmp/migrated-pad/.stitchpad" "$SP" heartbeat --stop "$n" >/dev/null 2>&1 || true
  done
  STITCHPAD_PAD_DIR="$tmp/legacy-pad/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  STITCHPAD_PAD_DIR="$tmp/migrated-pad/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
export HOME="$tmp"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
export STITCHPAD_HEARTBEAT_AUTOSTART=0

PASSED=0; FAILED=0; GATE=1
ok()   { PASSED=$((PASSED + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
check_ge(){ if [ "$2" -ge "$3" ] 2>/dev/null; then ok "$1"; else bad "$1: expected at least [$3] got [$2]"; fi; }

printf '\n=== clear regression tests (flash2 F1) ===\n'

# ── G1: clear refuses legacy pad ────────────────────────────────
printf '\n--- G1: clear refuses legacy pad ---\n'

mkdir -p "$tmp/legacy-pad"
( cd "$tmp/legacy-pad" && "$SP" init --name g1 >/dev/null 2>&1 && "$SP" daemon stop >/dev/null 2>&1 || true )
( cd "$tmp/legacy-pad" && "$SP" join probe codex pull - >/dev/null && "$SP" join alice codex pull - >/dev/null )
( cd "$tmp/legacy-pad" && "$SP" heartbeat --stop probe >/dev/null 2>&1 || true )
( cd "$tmp/legacy-pad" && "$SP" heartbeat --stop alice >/dev/null 2>&1 || true )

# Snapshot: count inline task blocks before our synthetic append
_before="$(grep -c '^```task' "$tmp/legacy-pad/.stitchpad/stitchpad.md" 2>/dev/null || echo 0)"

# Add a synthetic inline task block (simulates a legacy pad with real task cards)
cat >> "$tmp/legacy-pad/.stitchpad/stitchpad.md" << 'TASKEOF'
## @probe · 2026-08-03

@alice check task TASK-2 status please

```task TASK-2
title: bounce guard tests
status: in_progress
```
TASKEOF

# G1a: inline task cards are present (at least the one we just added)
_after="$(grep -c '^```task' "$tmp/legacy-pad/.stitchpad/stitchpad.md")"
check_ge 'G1a: inline task cards present in legacy pad' "$_after" '1'

# G1b: clear refuses
rc=0
( cd "$tmp/legacy-pad" && "$SP" clear 2>&1 >/dev/null ) || rc=$?
check 'G1b: clear refused legacy pad (rc=1)' '1' "$rc"

# G1c: refusal mentions REFUSED + migration
out="$(cd "$tmp/legacy-pad" && "$SP" clear 2>&1)"
check 'G1c: clear says REFUSED and suggests migration' '1' \
  "$(printf '%s' "$out" | grep -ciE 'REFUSED|refused')"

# G1d: task blocks survived the refused clear (count unchanged)
_after_refusal="$(grep -c '^```task' "$tmp/legacy-pad/.stitchpad/stitchpad.md")"
check 'G1d: inline tasks survived refused clear' "$_after" "$_after_refusal"

# ── G2: clear succeeds on migrated pad ──────────────────────────
printf '\n--- G2: clear succeeds on migrated pad ---\n'

mkdir -p "$tmp/migrated-pad"
( cd "$tmp/migrated-pad" && "$SP" init --name g2 >/dev/null 2>&1 && "$SP" daemon stop >/dev/null 2>&1 || true )
( cd "$tmp/migrated-pad" && "$SP" join probe codex pull - >/dev/null && "$SP" join bob codex pull - >/dev/null )
( cd "$tmp/migrated-pad" && "$SP" heartbeat --stop probe >/dev/null 2>&1 || true )
( cd "$tmp/migrated-pad" && "$SP" heartbeat --stop bob >/dev/null 2>&1 || true )

# Add an inline task block then migrate
cat >> "$tmp/migrated-pad/.stitchpad/stitchpad.md" << 'TASKEOF'
## @probe · 2026-08-03

@bob check task TASK-3

```task TASK-3
title: migration target
status: todo
```
TASKEOF

# G2a: migrate tasks to tasks.md
out="$(cd "$tmp/migrated-pad" && "$SP" task migrate 2>&1)"
_migrated_count="$(grep -c '^```task' "$tmp/migrated-pad/.stitchpad/tasks.md" 2>/dev/null || echo 0)"
check_ge 'G2a: tasks migrated to tasks.md' "$_migrated_count" '1'

# G2b: clear succeeds on migrated pad
rc=1
( cd "$tmp/migrated-pad" && "$SP" clear 2>&1 >/dev/null ) && rc=0
check 'G2b: clear succeeded on migrated pad' '0' "$rc"

# G2c: task cards survived clear in tasks.md (count unchanged)
_post_clear_tasks="$(grep -c '^```task' "$tmp/migrated-pad/.stitchpad/tasks.md")"
check 'G2c: task cards survived clear in tasks.md' "$_migrated_count" "$_post_clear_tasks"

# G2d: pad file trimmed — no stale inline tasks after clear + migration
_post_clear_pad="$(grep -c '^```task' "$tmp/migrated-pad/.stitchpad/stitchpad.md" 2>/dev/null)"
_post_clear_pad="${_post_clear_pad:-0}"
check 'G2d: pad file trimmed (no stale inline tasks)' '0' "$_post_clear_pad"

# ── G3: reverse gate (guard present in shipped code) ────────────
printf '\n--- G3: reverse gate (guard present in shipped code) ---\n'

check 'G3: dataloss guard present in shipped code' '1' \
  "$(grep -c "_clear_has_inline_tasks=0" "$SP")"

printf '\n\033[0;32mALL %s GATES PASSED\033[0m\n' "$PASSED"
[ "$FAILED" -eq 0 ] && exit 0
printf '\n\033[0;31m%s GATES FAILED\033[0m\n' "$FAILED"
exit 1
