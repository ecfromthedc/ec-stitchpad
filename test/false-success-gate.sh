#!/usr/bin/env bash
# false-success-gate.sh — GAP5: every durable-effect command fails honestly
# under read-only pad git. The 9 known false-success shapes from this build:
#   1. say printing '✓ posted' with zero commits
#   2. join printing '✓ joined' with zero commits
#   3. task new claiming creation with no durable card
#   4. task edit printing 'updated' with no commit
#   5. task move printing '→ new_status' with no commit
#   6. restore-roster printing '✓ roster restored' with no commit
#   7. init claiming success when git cannot persist
# Mutant proof: strip sp_commit_or_fail from ONE site → at least one liar.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_HOME="$ROOT/tool"
export STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_SURFACE=none
HERDR_URL="" HERDR_SECRET=""
export PATH="$ROOT/tool/bin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

# Track spawned PIDs — kill only our own
PIDS=""
spawn() { "$@" & PIDS="$PIDS $!"; }
kill_ours() { for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done; PIDS=""; }
trap 'kill_ours' EXIT

fixture_new_pad() {
  local d="$1" name="$2"
  local p="$d/.stitchpad"
  mkdir -p "$p/stitchpad-git/info" "$p/stitchpad-git/objects" "$p/stitchpad-git/refs/heads" "$p/.state/sessions"
  printf '# %s\n```roster\nalice | cli | pull | -\n```\n' "$name" > "$p/stitchpad.md"
  git --git-dir="$p/stitchpad-git" --work-tree="$p" init -q
  git --git-dir="$p/stitchpad-git" --work-tree="$p" add stitchpad.md
  git --git-dir="$p/stitchpad-git" --work-tree="$p" -c user.name=i -c user.email=i@l commit -qm init
}

fixture_pad_with_task() {
  local d="$1" name="$2"
  local p="$d/.stitchpad"
  mkdir -p "$p/stitchpad-git/info" "$p/stitchpad-git/objects" "$p/stitchpad-git/refs/heads" "$p/.state/sessions"
  printf '# %s\n```roster\nalice | cli | pull | -\n```\n\n```task TASK-1\ntitle: one\nstatus: todo\npriority: low\nassignee: alice\n---\n```\n' "$name" > "$p/stitchpad.md"
  git --git-dir="$p/stitchpad-git" --work-tree="$p" init -q
  git --git-dir="$p/stitchpad-git" --work-tree="$p" add stitchpad.md
  git --git-dir="$p/stitchpad-git" --work-tree="$p" -c user.name=i -c user.email=i@l commit -qm init
}

fixture_cleanup() { chmod -R u+w "$1" 2>/dev/null; rm -rf "$1" 2>/dev/null; }

echo "GAP5 false-success-gate — read-only pad git dir"
echo ""

# ── GATE 1: all seven commands honest ──────────────────────────────
echo "=== GATE 1: read-only git — all seven honest ==="
honest=0; liar=0
liar_list=""

# 1) say
D=$(mktemp -d /tmp/fsg-say.XXXXXX)
fixture_new_pad "$D" say
chmod -R a-w "$D/.stitchpad/stitchpad-git"
STITCHPAD_PAD_DIR="$D/.stitchpad" STITCHPAD_NAME=alice "$SP" say "fsg-probe" > "$D/out" 2>&1; rc=$?
if [ "$rc" != "0" ]; then honest=$((honest+1)); else liar=$((liar+1)); liar_list="$liar_list say($rc:'$(tail -1 "$D/out")')"; fi
fixture_cleanup "$D"

# 2) join
D=$(mktemp -d /tmp/fsg-join.XXXXXX)
fixture_new_pad "$D" join
chmod -R a-w "$D/.stitchpad/stitchpad-git"
STITCHPAD_PAD_DIR="$D/.stitchpad" STITCHPAD_NAME=bob "$SP" join bob cli pull - > "$D/out" 2>&1; rc=$?
if [ "$rc" != "0" ]; then honest=$((honest+1)); else liar=$((liar+1)); liar_list="$liar_list join($rc:'$(tail -1 "$D/out")')"; fi
fixture_cleanup "$D"

# 3) task new
D=$(mktemp -d /tmp/fsg-new.XXXXXX)
fixture_new_pad "$D" new
chmod -R a-w "$D/.stitchpad/stitchpad-git"
STITCHPAD_PAD_DIR="$D/.stitchpad" STITCHPAD_NAME=alice "$SP" task new 'title: gate-task' > "$D/out" 2>&1; rc=$?
if [ "$rc" != "0" ]; then honest=$((honest+1)); else liar=$((liar+1)); liar_list="$liar_list tasknew($rc:'$(tail -1 "$D/out")')"; fi
fixture_cleanup "$D"

# 4) task edit
D=$(mktemp -d /tmp/fsg-edit.XXXXXX)
fixture_pad_with_task "$D" edit
chmod -R a-w "$D/.stitchpad/stitchpad-git"
STITCHPAD_PAD_DIR="$D/.stitchpad" STITCHPAD_NAME=alice "$SP" task edit TASK-1 --priority high > "$D/out" 2>&1; rc=$?
if [ "$rc" != "0" ]; then honest=$((honest+1)); else liar=$((liar+1)); liar_list="$liar_list taskedit($rc:'$(tail -1 "$D/out")')"; fi
fixture_cleanup "$D"

# 5) task move
D=$(mktemp -d /tmp/fsg-move.XXXXXX)
fixture_pad_with_task "$D" move
chmod -R a-w "$D/.stitchpad/stitchpad-git"
STITCHPAD_PAD_DIR="$D/.stitchpad" STITCHPAD_NAME=alice "$SP" task move TASK-1 in_progress > "$D/out" 2>&1; rc=$?
if [ "$rc" != "0" ]; then honest=$((honest+1)); else liar=$((liar+1)); liar_list="$liar_list taskmove($rc:'$(tail -1 "$D/out")')"; fi
fixture_cleanup "$D"

# 6) restore-roster
D=$(mktemp -d /tmp/fsg-rr.XXXXXX)
P="$D/.stitchpad"
mkdir -p "$P/stitchpad-git/info" "$P/stitchpad-git/objects" "$P/stitchpad-git/refs/heads" "$P/.state/sessions"
printf '# rr\n\n(no roster)\n' > "$P/stitchpad.md"
git --git-dir="$P/stitchpad-git" --work-tree="$P" init -q
git --git-dir="$P/stitchpad-git" --work-tree="$P" add stitchpad.md
git --git-dir="$P/stitchpad-git" --work-tree="$P" -c user.name=i -c user.email=i@l commit -qm init
printf '```roster\nalice | cli | pull | -\n```\n' > "$D/roster.bak"
chmod -R a-w "$P/stitchpad-git"
STITCHPAD_PAD_DIR="$P" "$SP" restore-roster "$D/roster.bak" > "$D/out" 2>&1; rc=$?
if [ "$rc" != "0" ]; then honest=$((honest+1)); else liar=$((liar+1)); liar_list="$liar_list restore-roster($rc:'$(tail -1 "$D/out")')"; fi
fixture_cleanup "$D"

# 7) init
D=$(mktemp -d /tmp/fsg-init.XXXXXX)
mkdir -p "$D/.stitchpad/stitchpad-git"
chmod -R a-w "$D/.stitchpad/stitchpad-git"
( cd "$D" && STITCHPAD_PAD_DIR="$D/.stitchpad" "$SP" init --name fsg-test > "$D/out" 2>&1 ); rc=$?
if [ "$rc" != "0" ]; then honest=$((honest+1)); else liar=$((liar+1)); liar_list="$liar_list init($rc:'$(tail -1 "$D/out")')"; fi
fixture_cleanup "$D"

if [ "$honest" -eq 7 ] && [ "$liar" -eq 0 ]; then
  ok "G1: 7/7 honest (all exit !=0), 0 liars"
else
  [ -n "$liar_list" ] && echo "  LIARS: $liar_list"
  bad "G1: $honest honest, $liar liars"
fi

# ── GATE 2: mutant — one sp_commit_or_fail → sp_commit → RED ─────
echo ""
echo "=== GATE 2: mutant — task edit sp_commit_or_fail → sp_commit ==="

# Mutate the actual worktree binary for ONE call site, run the test,
# then restore. The gate records whether the mutation exposed a liar.
_save=$(mktemp /tmp/fsg-save.XXXXXX)
cp "$SP" "$_save"

# The mutation must actually REINTRODUCE the defect. Swapping sp_commit_or_fail for
# sp_commit is NOT enough: the guard is the surrounding `if ! ...; then exit 1; fi`,
# which survives that edit and still catches the failure — so the mutant produced no
# liar and this gate failed against CORRECT code. Neutralise the whole guard instead:
# run a bare unchecked commit, and turn the guard body into dead code (`if false`).
sed -i '' 's|if ! sp_commit_or_fail "task $id metadata updated" "$(basename "$tfile")"; then|sp_commit "task $id metadata updated" "$(basename "$tfile")" \|\| true; if false; then|' "$SP"
if grep -q 'if ! sp_commit_or_fail "task $id metadata updated"' "$SP"; then
  bad "G2 mutant: mutation did not apply (anchor missing) — gate cannot self-prove"
fi

D=$(mktemp -d /tmp/fsg-mut.XXXXXX)
fixture_pad_with_task "$D" mutant
chmod -R a-w "$D/.stitchpad/stitchpad-git"
STITCHPAD_PAD_DIR="$D/.stitchpad" STITCHPAD_NAME=alice "$SP" task edit TASK-1 --priority high > "$D/out" 2>&1; rc=$?

chmod -R u+w "$D/.stitchpad/stitchpad-git" 2>/dev/null
git --git-dir="$D/.stitchpad/stitchpad-git" --work-tree="$D/.stitchpad" \
  log --all -p 2>/dev/null | grep -qF "priority: high" && in_git=YES || in_git=NO

# Restore original binary IMMEDIATELY
cp "$_save" "$SP"; rm -f "$_save"

if [ "$rc" = "0" ]; then
  if [ "$in_git" = "NO" ]; then
    ok "G2 mutant: task edit exit=0 with no durable commit — GATE RED (liar exposed)"
  else
    bad "G2 mutant: task edit exit=0 but commit somehow landed (unexpected)"
  fi
else
  bad "G2 mutant: task edit exit=$rc — expected 0 (liar) after stripping sp_commit_or_fail"
fi
echo "  mutant output: $(tail -1 "$D/out")  durable-in-git=$in_git"

fixture_cleanup "$D"

# ── RESULTS ────────────────────────────────────────────────────────
echo ""
echo "RESULTS: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  echo "FINAL: FAILED"
  exit 1
fi
echo "FINAL: PASSED — false-success gate closed at b24cbe8"
exit 0
