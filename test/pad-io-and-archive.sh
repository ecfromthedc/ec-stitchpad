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
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

inode() { stat -f %i "$1" 2>/dev/null || stat -c %i "$1" 2>/dev/null; }

export STITCHPAD_HEARTBEAT_AUTOSTART=0
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

# ── 6. crash recovery ───────────────────────────────────────────────
echo "── crash recovery"
cp "$PAD" "$WORK/expected.md"
printf 'RECOVERED PAD CONTENT\n' > "$PAD.ready"     # simulate a write killed mid-copy
: > "$PAD"                                          # ...leaving the pad truncated
sp roster >/dev/null 2>&1
# a FRESH .ready may belong to a live writer mid-copy — it must NOT be replayed
# (recovery runs outside the lock; see sp_recover_inplace)
check "fresh .ready is left for its writer (no replay)" "$(cat "$PAD")" ""
[ -f "$PAD.ready" ] && ok "fresh .ready is kept, not consumed" || bad "fresh .ready is kept, not consumed"
touch -t 202001010000 "$PAD.ready"                  # now provably abandoned
sp roster >/dev/null 2>&1                           # any command triggers recovery
check "interrupted write is replayed on next command" "$(cat "$PAD")" "RECOVERED PAD CONTENT"
[ -f "$PAD.ready" ] && bad "recovery cleared its .ready file" || ok "recovery cleared its .ready file"
cp "$WORK/expected.md" "$PAD"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
