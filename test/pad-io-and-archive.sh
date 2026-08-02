#!/usr/bin/env bash
# Regression test for the pad-IO fixes:
#   1. pad rewrites preserve the inode (a `tail -f` watcher must not replay history)
#   2. task cards live in tasks.md; legacy inline blocks still work
#   3. `stitchpad archive` trims the pad, keeps roster + tasks, leaves a pointer
#
#   bash test/pad-io-and-archive.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP="$HERE/../tool/bin/stitchpad"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-padio.XXXXXX")"
writer_pid=""
crash_pid=""
cleanup() {
  for pid in "$writer_pid" "$crash_pid"; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$WORK/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

inode() { stat -f %i "$1" 2>/dev/null || stat -c %i "$1" 2>/dev/null; }
ready_digest() {
  local f
  for f in "$PAD.ready"/*; do
    [ -f "$f" ] && cksum "$f"
  done | sort
}

export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
# Isolate the MACHINE-GLOBAL terminal registry ($HOME/.stitchpad-terminals) so a
# test run can neither be refused by, nor leak a claim into, the developer's
# real pads.
mkdir -p "$WORK/home"
cd "$WORK"
sp() {
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$WORK/.stitchpad" \
  STITCHPAD_NAME="${SPNAME:-tester}" "$SP" "$@"
}

echo "── pad: $WORK/.stitchpad"
sp init --name padio >/dev/null 2>&1
PAD="$WORK/.stitchpad/stitchpad.md"
TASKS="$WORK/.stitchpad/tasks.md"
[ -f "$PAD" ] && ok "init created the pad" || bad "init created the pad"
sp daemon stop >/dev/null 2>&1 || true

sp join tester claude pull - >/dev/null 2>&1
check "join added tester to the roster" "$(sp roster | cut -d'|' -f1 | tr '\n' ' ')" "tester "

for i in $(seq 1 12); do sp say "message $i @nobody" >/dev/null 2>&1; done
check "12 messages posted" "$(grep -c '^## @tester' "$PAD")" "12"

# ── 1. tasks live in tasks.md; ticket ops leave the pad alone ───────
echo "── task/message separation"
T1="$(sp task new "first task" --priority high 2>/dev/null | awk '{print $1}')"
[ -f "$TASKS" ] && ok "tasks.md created" || bad "tasks.md created"
check "new task card is in tasks.md" "$(grep -c "^\`\`\`task $T1\$" "$TASKS")" "1"
grep -q '<!-- tasks:file -->' "$PAD" && ok "pad carries a pointer to tasks.md" \
  || bad "pad carries a pointer to tasks.md"

padsum_before="$(cksum < "$PAD")"
T2="$(sp task new "second task" 2>/dev/null | awk '{print $1}')"
sp task move "$T2" done >/dev/null 2>&1
sp task edit "$T2" --to tester >/dev/null 2>&1
padsum_after="$(cksum < "$PAD")"
check "ticket ops no longer touch the conversation at all" "$padsum_before" "$padsum_after"

check "task list sees pad template + both new tasks" "$(sp task list | wc -l | tr -d ' ')" "3"
check "$T2 status" "$(sp task list | awk -F'|' -v t="$T2" '$1==t{print $3}')" "done"

# no-op guard: moving to the status it already has must not write or commit
tsum_before="$(cksum < "$TASKS")"
commits_before="$(git --git-dir="$WORK/.stitchpad/stitchpad-git" --work-tree="$WORK/.stitchpad" rev-list --count HEAD)"
sp task move "$T2" done >/dev/null 2>&1
tsum_after="$(cksum < "$TASKS")"
commits_after="$(git --git-dir="$WORK/.stitchpad/stitchpad-git" --work-tree="$WORK/.stitchpad" rev-list --count HEAD)"
check "no-op task move writes nothing" "$tsum_before" "$tsum_after"
check "no-op task move commits nothing" "$commits_before" "$commits_after"

sp task move TASK-999 done >/dev/null 2>&1 && bad "unknown task id should fail" || ok "unknown task id fails instead of rewriting the pad"

# ── 2. inode stability + no tail replay on a PAD rewrite ────────────
# The pad-rewriting ops that remain (join/leave/set-wake/rename/restore-roster)
# must not make a tail-based watcher replay history.
echo "── inode stability under a pad rewrite"

# Fatten the pad well past tail's 4 KB output buffer, so a replay is guaranteed
# to reach the log file and cannot hide as "buffered".
filler="$(head -c 400 < /dev/zero | tr '\0' 'x')"
for i in $(seq 1 40); do sp say "bulk $i $filler" >/dev/null 2>&1; done

# watch_pad <command...> → runs the command under a `tail -F` watcher, echoes
# how many times the FIRST message reappeared (i.e. how much history replayed).
watch_pad() {
  local out="$WORK/tail.$$.log" pid n
  tail -F "$PAD" > "$out" 2>/dev/null &
  pid=$!
  sleep 0.8
  : > "$out"                       # discard tail's opening window
  "$@" >/dev/null 2>&1
  sleep 1.2
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  n="$(grep -c 'message 1 @nobody' "$out" 2>/dev/null | head -1)"
  rm -f "$out"
  printf '%s' "${n:-0}"
}

# CONTROL: reproduce the ORIGINAL bug (awk > tmp && mv tmp pad). Content is
# byte-identical; only the inode changes. If this does not replay, the test is
# not actually measuring anything.
old_style_rewrite() { awk '{print}' "$PAD" > "$PAD.tmp" && mv "$PAD.tmp" "$PAD"; }
ctl_inode_before="$(inode "$PAD")"
ctl="$(watch_pad old_style_rewrite)"
[ "$ctl_inode_before" != "$(inode "$PAD")" ] \
  && ok "control: the old mv-based rewrite swaps the inode" \
  || bad "control: the old mv-based rewrite swaps the inode"
[ "$ctl" -ge 1 ] \
  && ok "control: the old mv-based rewrite DOES replay history (seen ${ctl}x)" \
  || bad "control: the old mv-based rewrite DOES replay history (seen ${ctl}x)"

# REAL: the same class of operation through the fixed code path.
before="$(inode "$PAD")"
fixed_rewrite() {
  sp join watcher-probe claude pull -     # rewrites the roster block
  sp set-wake watcher-probe pull -        # rewrites it again
}
replayed="$(watch_pad fixed_rewrite)"
after="$(inode "$PAD")"

check "pad inode is stable across a full-file rewrite" "$before" "$after"
check "tail -F did NOT replay history after the fixed rewrite" "$replayed" "0"
sp leave watcher-probe >/dev/null 2>&1

# ── 3. legacy inline task blocks keep working ───────────────────────
echo "── backward compatibility"
printf '\n```task TASK-77\ntitle: legacy inline\nstatus: todo\npriority: low\nassignee:\nlabels:\ncreated: 01-01 00:00\n---\nlegacy\n```\n' >> "$PAD"
check "legacy inline task is listed" "$(sp task list | awk -F'|' '$1=="TASK-77"{print $2}')" "legacy inline"
sp task move TASK-77 in_review >/dev/null 2>&1
check "legacy inline task can still be moved" "$(sp task list | awk -F'|' '$1=="TASK-77"{print $3}')" "in_review"
check "legacy move edited the pad, not tasks.md" "$(grep -c 'status: in_review' "$PAD")" "1"

ntasks="$(sp task list | wc -l | tr -d ' ')"
sp task migrate >/dev/null 2>&1
check "migrate emptied inline blocks from the pad" "$(grep -c '^```task ' "$PAD")" "0"
check "migrate preserved every task" "$(sp task list | wc -l | tr -d ' ')" "$ntasks"
check "TASK-77 survived migration" "$(sp task list | awk -F'|' '$1=="TASK-77"{print $3}')" "in_review"

# ── 4. archive ──────────────────────────────────────────────────────
echo "── archive"
for i in $(seq 13 40); do sp say "message $i" >/dev/null 2>&1; done
msgs_before="$(grep -c '^## @' "$PAD")"
size_before="$(wc -c < "$PAD" | tr -d ' ')"
arch_inode_before="$(inode "$PAD")"

sp archive --keep 10 >/dev/null 2>&1
arch="$WORK/.stitchpad/archive/$(date '+%Y-%m-%d')-conversation.md"

check "archive preserved the pad inode" "$arch_inode_before" "$(inode "$PAD")"
[ -f "$arch" ] && ok "archive file written" || bad "archive file written"
check "pad kept exactly --keep messages" "$(grep -c '^## @' "$PAD")" "10"
check "archive holds the rest" "$(grep -c '^## @' "$arch")" "$(( msgs_before - 10 ))"
[ "$(wc -c < "$PAD" | tr -d ' ')" -lt "$size_before" ] && ok "pad shrank" || bad "pad shrank"
grep -q '📦 \*\*Archived:\*\*' "$PAD" && ok "pointer line left in the pad" || bad "pointer line left in the pad"
check "roster survived archiving" "$(sp roster | cut -d'|' -f1 | tr '\n' ' ')" "tester "
check "task cards survived archiving" "$(sp task list | wc -l | tr -d ' ')" "$ntasks"
git --git-dir="$WORK/.stitchpad/stitchpad-git" --work-tree="$WORK/.stitchpad" \
  log --oneline -1 2>/dev/null | grep -q 'archive:' && ok "archive committed" || bad "archive committed"
git --git-dir="$WORK/.stitchpad/stitchpad-git" --work-tree="$WORK/.stitchpad" \
  ls-files 2>/dev/null | grep -q '^archive/' && ok "archive file is versioned" || bad "archive file is versioned"

sp archive --keep 500 2>&1 | grep -q 'nothing to archive' && ok "archive is a no-op when under --keep" \
  || bad "archive is a no-op when under --keep"

# ── 5. phone board contract: tasks.md cards reach the pushed doc ────
# The PWA kanban renders from the doc the bridge pushes (parseTasks over
# body.pad, last-wins by id). Cards that moved to tasks.md MUST still appear
# there, appended after the pad so a stale inline copy can never shadow them.
echo "── phone board contract (bridge doc)"
BR="$HERE/../tool/relay/bridge-push-once.sh"
brdoc() { STITCHPAD_RELAY=http://invalid.local STITCHPAD_TOKEN=x HOME="$WORK/home" \
          bash "$BR" "$WORK/.stitchpad" --doc; }
doc="$(brdoc)"
printf '%s\n' "$doc" | grep -q "^\`\`\`task $T1\$" && ok "tasks.md card reaches the phone doc" \
  || bad "tasks.md card reaches the phone doc"
printf '%s\n' "$doc" | grep -q "^\`\`\`task TASK-77\$" && ok "migrated card reaches the phone doc" \
  || bad "migrated card reaches the phone doc"
printf '\n```task TASK-88\ntitle: stale copy\nstatus: todo\npriority: low\nassignee:\nlabels:\ncreated: 01-01 00:00\n---\nstale\n```\n' >> "$PAD"
printf '\n```task TASK-88\ntitle: fresh copy\nstatus: done\npriority: low\nassignee:\nlabels:\ncreated: 01-01 00:00\n---\nfresh\n```\n' >> "$TASKS"
laststatus="$(brdoc | awk '/^```task TASK-88$/{inblk=1} inblk && /^status:/{s=$2} inblk && /^```$/{inblk=0} END{print s}')"
check "stale inline copy loses to the tasks.md copy (last wins)" "$laststatus" "done"

# ── 6. generation-owned crash recovery ──────────────────────────────
echo "── crash recovery"

# Pause writer A after it atomically promotes its complete generation while it
# still owns the mutation lock. Passive init/roster B must not recover, replace,
# or delete that live generation.
barrier="$WORK/active-promotion"
(
  trap - EXIT
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$WORK/.stitchpad" STITCHPAD_NAME=tester \
    STITCHPAD_WRITE_TEST_AFTER_PROMOTION_BARRIER="$barrier" \
    exec "$SP" join paused-writer claude pull -
) > "$WORK/paused-writer.out" 2>&1 &
writer_pid=$!
for _ in $(seq 1 100); do
  [ -f "$barrier.ready" ] && [ -d "$PAD.ready" ] && break
  sleep 0.02
done
if [ -f "$barrier.ready" ] && [ -d "$PAD.ready" ]; then
  ok "writer promoted an owned generation before pausing"
else
  bad "writer promoted an owned generation before pausing"
fi
ready_before="$(ready_digest)"
sp roster >/dev/null 2>&1
ready_after="$(ready_digest)"
check "passive init leaves the active .ready generation byte-exact" "$ready_after" "$ready_before"
kill -0 "$writer_pid" 2>/dev/null \
  && ok "passive init leaves the active writer running" \
  || bad "passive init leaves the active writer running"
touch "$barrier.release"
wait "$writer_pid" \
  && ok "paused writer completes after release" \
  || bad "paused writer completes after release"
writer_pid=""
[ ! -e "$PAD.ready" ] && ok "writer clears only its completed generation" \
  || bad "writer clears only its completed generation"
grep -q '^paused-writer[[:space:]]*|' "$PAD" \
  && ok "paused writer content reaches the pad" \
  || bad "paused writer content reaches the pad"

# Now kill a different writer after promotion. Its lock records an exact dead
# process and its .ready directory contains a checksummed generation. The next
# mutator may break that dead lock, replay the abandoned content in-place, and
# then apply its own mutation.
crash_barrier="$WORK/crash-promotion"
(
  trap - EXIT
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$WORK/.stitchpad" STITCHPAD_NAME=tester \
    STITCHPAD_WRITE_TEST_AFTER_PROMOTION_BARRIER="$crash_barrier" \
    exec "$SP" join crash-writer claude pull -
) > "$WORK/crash-writer.out" 2>&1 &
crash_pid=$!
for _ in $(seq 1 100); do
  [ -f "$crash_barrier.ready" ] && [ -d "$PAD.ready" ] && break
  sleep 0.02
done
if [ -f "$crash_barrier.ready" ] && [ -d "$PAD.ready" ]; then
  ok "crash fixture promoted a complete generation"
else
  bad "crash fixture promoted a complete generation"
fi
kill -KILL "$crash_pid" 2>/dev/null || true
wait "$crash_pid" 2>/dev/null || true
crash_pid=""
SP_LOCK_STALE=0 sp join recovery-trigger claude pull - >/dev/null 2>&1 \
  && ok "next mutator recovers an abandoned proven generation" \
  || bad "next mutator recovers an abandoned proven generation"
grep -q '^crash-writer[[:space:]]*|' "$PAD" \
  && ok "abandoned writer content survives recovery" \
  || bad "abandoned writer content survives recovery"
grep -q '^recovery-trigger[[:space:]]*|' "$PAD" \
  && ok "post-recovery mutation is serialized after replay" \
  || bad "post-recovery mutation is serialized after replay"
[ ! -e "$PAD.ready" ] && ok "recovery clears the exact abandoned generation" \
  || bad "recovery clears the exact abandoned generation"

# TERM must exit the writer before releasing its lock; it may not continue the
# copy after unlock. The proven generation remains recoverable by the next
# mutator, while the target itself is unchanged until that recovery acquires.
signal_barrier="$WORK/signal-promotion"
(
  trap - EXIT
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$WORK/.stitchpad" STITCHPAD_NAME=tester \
    STITCHPAD_WRITE_TEST_AFTER_PROMOTION_BARRIER="$signal_barrier" \
    exec "$SP" join signal-writer claude pull -
) > "$WORK/signal-writer.out" 2>&1 &
writer_pid=$!
for _ in $(seq 1 100); do
  [ -f "$signal_barrier.ready" ] && [ -d "$PAD.ready" ] && break
  sleep 0.02
done
kill -TERM "$writer_pid" 2>/dev/null || true
wait "$writer_pid" 2>/dev/null || true
writer_pid=""
[ ! -d "$WORK/.stitchpad/.state/.lock" ] \
  && ok "TERM exits before releasing its exact lock generation" \
  || bad "TERM exits before releasing its exact lock generation"
grep -q '^signal-writer[[:space:]]*|' "$PAD" \
  && bad "signaled writer continued mutation after unlock" \
  || ok "signaled writer does not mutate after unlock"
sp join signal-recovery claude pull - >/dev/null 2>&1 \
  && ok "next mutator recovers the signaled writer generation" \
  || bad "next mutator recovers the signaled writer generation"
grep -q '^signal-writer[[:space:]]*|' "$PAD" \
  && ok "signaled writer content survives owned recovery" \
  || bad "signaled writer content survives owned recovery"

# SIGKILL in the owner-publication window leaves only an empty canonical lock.
# With an immediate stale threshold, the next writer reclaims it without losing
# bytes or inheriting any old-generation publication temp.
lock_barrier="$WORK/lock-before-owner"
pad_before_lock_kill="$(cksum < "$PAD")"
(
  trap - EXIT
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$WORK/.stitchpad" STITCHPAD_NAME=tester \
    STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER="$lock_barrier" \
    exec "$SP" say 'killed before lock ownership'
) > "$WORK/lock-kill.out" 2>&1 &
writer_pid=$!
for _ in $(seq 1 100); do [ -f "$lock_barrier.ready" ] && break; sleep 0.02; done
[ -f "$lock_barrier.ready" ] && ok "lock crash seam reached before owner publication" \
  || bad "lock crash seam reached before owner publication"
kill -KILL "$writer_pid" 2>/dev/null || true; wait "$writer_pid" 2>/dev/null || true; writer_pid=""
check "pre-owner SIGKILL leaves target byte-exact" "$(cksum < "$PAD")" "$pad_before_lock_kill"
SP_LOCK_STALE=0 sp say 'writer after empty-lock crash' >/dev/null 2>&1 \
  && ok "next writer reclaims empty crashed lock at stale=0" \
  || bad "next writer reclaims empty crashed lock at stale=0"
grep -q 'writer after empty-lock crash' "$PAD" \
  && ok "post-lock-crash content reaches pad" || bad "post-lock-crash content reaches pad"
[ ! -d "$WORK/.stitchpad/.state/.lock" ] \
  && [ -z "$(find "$WORK/.stitchpad/.state" -maxdepth 1 \( -name '.lock-owner.*' -o -name '.pid-capture.*' \) -print -quit)" ] \
  && ok "lock crash leaves no canonical or publication residue" \
  || bad "lock crash leaves no canonical or publication residue"

# Once content has been copied, .ready is atomically retired before cleanup.
# A SIGKILL there leaves a non-blocking tombstone which the next locked mutator
# validates and removes; the applied content and successor mutation both remain.
retire_barrier="$WORK/after-ready-retire"
(
  trap - EXIT
  HOME="$WORK/home" STITCHPAD_PAD_DIR="$WORK/.stitchpad" STITCHPAD_NAME=tester \
    STITCHPAD_WRITE_TEST_AFTER_RETIRE_BARRIER="$retire_barrier" \
    exec "$SP" join retired-writer claude pull -
) > "$WORK/retired-writer.out" 2>&1 &
writer_pid=$!
for _ in $(seq 1 100); do [ -f "$retire_barrier.ready" ] && break; sleep 0.02; done
[ -f "$retire_barrier.ready" ] && [ ! -e "$PAD.ready" ] \
  && [ -n "$(find "$WORK/.stitchpad" -maxdepth 1 -name 'stitchpad.md.ready.applied.*' -print -quit)" ] \
  && ok "writer retires canonical ready before cleanup" \
  || bad "writer retires canonical ready before cleanup"
kill -KILL "$writer_pid" 2>/dev/null || true; wait "$writer_pid" 2>/dev/null || true; writer_pid=""
SP_LOCK_STALE=0 sp join after-retire claude pull - >/dev/null 2>&1 \
  && ok "next mutator crosses an applied-generation crash" \
  || bad "next mutator crosses an applied-generation crash"
grep -q '^retired-writer[[:space:]]*|' "$PAD" \
  && grep -q '^after-retire[[:space:]]*|' "$PAD" \
  && ok "retired and successor mutations both survive" \
  || bad "retired and successor mutations both survive"
[ ! -e "$PAD.ready" ] \
  && [ -z "$(find "$WORK/.stitchpad" -maxdepth 1 -name 'stitchpad.md.ready.applied.*' -print -quit)" ] \
  && ok "next mutator reaps exact applied tombstone" \
  || bad "next mutator reaps exact applied tombstone"

# Symlinked recovery components and targets are never followed by the writer.
outside_ready="$WORK/outside-ready"; mkdir "$outside_ready"
printf 'outside-content' > "$outside_ready/content"
ln -s "$outside_ready" "$PAD.ready"
outside_sum="$(cksum < "$outside_ready/content")"
if sp say 'must not follow ready symlink' >/dev/null 2>&1; then
  bad "symlinked ready directory should block mutation"
else
  ok "symlinked ready directory blocks mutation"
fi
check "ready symlink target remains byte-exact" "$(cksum < "$outside_ready/content")" "$outside_sum"
rm -f "$PAD.ready" "$outside_ready/content"; rmdir "$outside_ready"

# Manifest generations become part of the applied-tombstone pathname. Reject
# separators/traversal even when every other target/size/digest field is valid.
mkdir "$PAD.ready"
cp "$PAD" "$PAD.ready/content"
pad_canon="$(cd -P "$(dirname "$PAD")" && pwd)/$(basename "$PAD")"
python3 - "$PAD.ready/content" "$PAD.ready/owner" "$pad_canon" <<'PY'
import hashlib, json, os, sys
content, owner, target = sys.argv[1:]
with open(content, "rb") as handle:
    body = handle.read()
with open(owner, "w", encoding="utf-8") as handle:
    json.dump({"generation": "bad/../escape", "pid": 99999991,
               "processStart": "dead", "command": "dead", "target": target,
               "size": len(body), "sha256": hashlib.sha256(body).hexdigest()},
              handle, separators=(",", ":"))
PY
unsafe_ready_before="$(ready_digest)"
if SP_LOCK_STALE=0 sp say 'must not apply unsafe generation' >/dev/null 2>&1; then
  bad "unsafe ready generation should block mutation"
else
  ok "unsafe ready generation blocks mutation"
fi
check "unsafe ready generation evidence remains byte-exact" "$(ready_digest)" "$unsafe_ready_before"
rm -f "$PAD.ready/content" "$PAD.ready/owner"; rmdir "$PAD.ready"

mv "$TASKS" "$TASKS.real"
printf 'outside-task-target' > "$WORK/outside-tasks"
ln -s "$WORK/outside-tasks" "$TASKS"
outside_sum="$(cksum < "$WORK/outside-tasks")"
if sp task new 'must not follow task target' >/dev/null 2>&1; then
  bad "symlinked mutation target should be rejected"
else
  ok "symlinked mutation target is rejected"
fi
check "symlinked target remains byte-exact" "$(cksum < "$WORK/outside-tasks")" "$outside_sum"
rm -f "$TASKS" "$WORK/outside-tasks"; mv "$TASKS.real" "$TASKS"

mv "$PAD" "$WORK/outside-pad"
ln -s "$WORK/outside-pad" "$PAD"
outside_sum="$(cksum < "$WORK/outside-pad")"
if sp say 'must not follow pad target' >/dev/null 2>&1; then
  bad "symlinked pad target should be rejected"
else
  ok "symlinked pad target is rejected"
fi
check "symlinked pad target remains byte-exact" "$(cksum < "$WORK/outside-pad")" "$outside_sum"
rm -f "$PAD"; mv "$WORK/outside-pad" "$PAD"

mv "$TASKS" "$TASKS.real"
ln -s "$WORK/outside-tasks-missing" "$TASKS"
if sp task new 'must not create broken task target' >/dev/null 2>&1; then
  bad "broken tasks symlink should be rejected"
else
  ok "broken tasks symlink is rejected"
fi
[ ! -e "$WORK/outside-tasks-missing" ] \
  && ok "broken tasks symlink target is not created" \
  || bad "broken tasks symlink target is not created"
rm -f "$TASKS"; mv "$TASKS.real" "$TASKS"

# Legacy or malformed state lacks sufficient authority. Even with an immediate
# stale threshold, neither an unowned regular .ready nor an unknown lock owner
# may be consumed, replaced, or silently broken.
pad_before_fail_closed="$(cksum < "$PAD")"
printf 'legacy-unowned-content\n' > "$PAD.ready"
if SP_LOCK_STALE=0 sp say 'must not cross legacy ready' >/dev/null 2>&1; then
  bad "legacy unowned .ready should block mutation"
else
  ok "legacy unowned .ready blocks mutation"
fi
[ -f "$PAD.ready" ] && ok "legacy unowned .ready is preserved for repair" \
  || bad "legacy unowned .ready is preserved for repair"
check "legacy recovery refusal leaves target byte-exact" "$(cksum < "$PAD")" "$pad_before_fail_closed"
rm -f "$PAD.ready"

mkdir "$WORK/.stitchpad/.state/.lock"
printf 'malformed-owner' > "$WORK/.stitchpad/.state/.lock/owner"
if SP_LOCK_STALE=0 sp say 'must not cross malformed lock' >/dev/null 2>&1; then
  bad "malformed lock owner should fail closed"
else
  ok "malformed lock owner fails closed"
fi
check "malformed lock evidence remains exact" \
  "$(cat "$WORK/.stitchpad/.state/.lock/owner")" "malformed-owner"
check "malformed lock refusal leaves target byte-exact" "$(cksum < "$PAD")" "$pad_before_fail_closed"
rm -f "$WORK/.stitchpad/.state/.lock/owner"
rmdir "$WORK/.stitchpad/.state/.lock"
sp daemon stop >/dev/null 2>&1 || true

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
