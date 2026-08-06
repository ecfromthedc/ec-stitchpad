# <seat> review

(started)

## F1 — concurrent `say` loses committed, acknowledged messages: the pad-lock steal + journal-rollback wipes another writer's commit
SEVERITY: LOSES-WORK
FILE: tool/bin/lib.sh:806-820 (E1/F2 lock reclaim), tool/bin/session-registry.sh:1240-1339 (sp_session_registry_journal_rollback has NO HEAD-advanced guard)
WHAT HAPPENS: under 8-way concurrent `say` contention (2/3 runs reproduced), a message that was committed to pad git AND acknowledged to its agent ("✓ posted as @X (#m-…)", rc=0) is absent from the final pad and from git HEAD. Two writers end up inside the pad's critical section at once because the mkdir lock's reclaim paths can remove a LIVE writer's lock:
  · E1 (lib.sh:806): an EMPTY lock older than SP_LOCK_EMPTY_RECLAIM (default 1s) is reclaimed without any liveness check — a live but slow mkdir winner (owner not yet published) loses its lock.
  · F2 (lib.sh:798): a valid-owner lock is reclaimed when sp_lock_owner_is_live fails — that probe is python3/ps-based and can false-negative under load.
The robbed writer's `sp_write_inplace` then refuses ("refusing unlocked in-place write of stitchpad.md"), its `say` fails, and its `sp_session_registry_journal_rollback` restores the journaled PRE-SAY snapshot — wiping messages the OTHER writer appended+committed in between. The surviving writer's `git add -A` + commit then records the wiped state as HEAD, so the lost message is not even in HEAD (only in an older commit). The live rollback path (unlike the orphan-recovery path at session-registry.sh:948) has NO check that HEAD advanced past the journaled .base-sha, so it destroys committed work without protest.
PROOF:
  (fresh pad, members dale+larry, 8 simultaneous `say` commands, 4 per member)
  $ for i in 1 2 3 4; do (STITCHPAD_TERMINAL_NAMESPACE=t3-a STITCHPAD_NAME=dale $SP say "A$i" >/tmp/o3-a$i.out 2>&1; echo $? >/tmp/o3-a$i.rc) & (STITCHPAD_TERMINAL_NAMESPACE=t3-b STITCHPAD_NAME=larry $SP say "B$i" >/tmp/o3-b$i.out 2>&1; echo $? >/tmp/o3-b$i.rc) & done; wait
  (run 3 result: 7 of 8 says returned rc=0, one rc=1; final pad contains B1 A2 B2 A4 B3 B4 — A1 and A3 are GONE)
  $ cat /tmp/o3-a1.out; cat /tmp/o3-a1.rc
  ✓ posted as @dale (#m-e83c22)
  0
  $ git --git-dir=$PAD_GIT log --all --oneline | while read h m; do git --git-dir=$PAD_GIT show $h:stitchpad.md 2>/dev/null | grep -q '^A1$' && echo "$h $m HAS A1"; done
  cf46b27 dale: A1 HAS A1        <- A1 WAS committed
  $ git --git-dir=$PAD_GIT show HEAD:stitchpad.md | grep -c '^A1$'
  0                              <- but HEAD does NOT contain it
  $ grep -c '^A1$' .stitchpad/stitchpad.md
  0                              <- and the working pad does NOT contain it
  (run 2 also lost A3 with the same "refusing unlocked in-place write" error. The E1 steal is separately PROVEN deterministically with the STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER seam: W1 held the empty lock >1s, W2's say stole it and posted, W1 then failed "could not publish pad-lock ownership".)
FIX: two independent guards, both needed:
  1. Never reclaim from a live writer. Publish the lock owner IMMEDIATELY after mkdir using only bash builtins (capture $PPID via bash's builtin, write the owner file with printf — no /bin/sh fork, no python3, no ps in between), so the empty-lock window is a few microseconds instead of ~3 forks. If the window cannot be shrunk to near-zero, raise SP_LOCK_EMPTY_RECLAIM and make the owner file the FIRST write after mkdir.
  2. Give the LIVE rollback path the same guard the orphan path has: before restoring the pad file, compare current HEAD against the journaled .base-sha; if HEAD advanced past it (someone else committed), REFUSE the pad-file restore, log loudly, and preserve the journal for manual recovery — never silently rewind committed work.

## F2 — `stitchpad lanes` reports a WORKING fleet (rc=0) on a pad whose git history is destroyed
SEVERITY: WASTES-TIME
FILE: tool/bin/stitchpad:5236-5280 (lanes arm never calls sp_assert_pad_git_usable) + tool/bin/lib.sh:185-190 (silent git self-heal)
WHAT HAPPENS: `roster`/`whoami` refuse loudly (rc=1) when .stitchpad/stitchpad-git is missing (P5 gate), but `lanes` — the operator's primary per-seat status board — prints a table of seats all marked "WORKING" and exits 0. The board claims the fleet is healthy on a pad whose durability layer is gone. Worse: the next WRITE command silently re-initializes an EMPTY git history ("bootstrap: pad git (re)initialized", all `|| true`) and `say` prints "✓ posted" rc=0, so every prior commit (read --new delta bases, heal-roster history, `log`, compaction audit trail) is destroyed without one word to the operator.
PROOF:
  $ rm -rf .stitchpad/stitchpad-git
  $ stitchpad lanes ; echo rc=$?
  LANE         STATUS          AGE ARTIFACT             PRESENT      VERDICT
  ------------ ------------ ------ -------------------- ------------ ----------------
  bob          alive           30s -                    -            WORKING
  dale         alive           31s -                    -            WORKING
  larry        active          17s -                    -            WORKING
  rc=0
  $ stitchpad whoami ; echo rc=$?     # same broken pad — this one DOES refuse
  stitchpad: pad git is missing — this pad is broken, not empty
  ...
  rc=1
  $ stitchpad say "is this durable?" ; echo rc=$?
  ✓ posted as @dale (#m-55d55b)
  rc=0
  $ stitchpad log
  a75ac99 dale: is this durable?
  5bf2d86 bootstrap: pad git (re)initialized     <- whole prior history silently replaced
FIX: call sp_assert_pad_git_usable at the top of the lanes arm (and sessions), same as roster. And make the self-heal in sp_init_paths LOUD when it is re-initializing an EXISTING pad (a prior .state/registry exists): print "pad git was missing — re-initialized EMPTY history; prior commits are gone" to stderr and fail the write, or at minimum warn.

## F3 — seat-keeper's idle-with-open-task wake reads the WRONG file: tasks live in tasks.md, the keeper scans only stitchpad.md
SEVERITY: WASTES-TIME
FILE: tool/bin/seat-keeper.sh:180-189 (seat_tasks) and :197 (PADFILE)
WHAT HAPPENS: `stitchpad task new` writes cards to .stitchpad/tasks.md (PAD_TASKS, the sibling file — the modern location; the pad file keeps only a pointer). seat-keeper's seat_tasks() scans only $repo/.stitchpad/stitchpad.md (the legacy inline location), so "idle with N open pad task(s)" never fires for a seat whose open cards live in tasks.md. The anti-starvation watchdog that exists to keep seats working silently stops doing its primary job — a seat with open tasks idles forever with zero log lines. Same producer/consumer-mismatch class that shipped twice before.
PROOF:
  (fixture: mock daemon answering /health + idle session on 127.0.0.1:4899; TASK-2 "keep me busy" assignee=dale status=todo created via `stitchpad task new` → lands in .stitchpad/tasks.md; stitchpad.md contains NO task blocks)
  $ /bin/bash tool/bin/seat-keeper.sh --report --dry-run   (SEAT_KEEPER_QUEUE_MIN_S=0 SEAT_KEEPER_DRAIN_MIN_S=0)
  SEAT         STATE    PENDING              STRIKES  DECISION
  dale         idle     none                 0        idle, nothing due
  (expected: "WOULD WAKE — idle with 1 open pad task(s)")
FIX: make seat_tasks read the same set sp_tasks reads (pad + tasks.md): scan "tasks.md" first, then stitchpad.md, or call the CLI oracle `"$SP" task list` and count status=todo/in_progress rows assigned to the seat. Diff:
  seat_tasks() {
    local pad="$1" who="$2"
    [ -f "$pad" ] || { echo 0; return; }
    + local tasks="$(dirname "$pad")/tasks.md"
    + awk -v who="$who" '...' "$pad" "$tasks" ...
  }

## F4 — dead code: sp_commit's P19 auto-narration line is unreachable (after `return`)
SEVERITY: COSMETIC
FILE: tool/bin/lib.sh:1534-1538
WHAT HAPPENS: every successful/failed return in sp_commit precedes `sp_narrate "commit: $1"` — the P19 "progress appears on the pad BY DEFAULT" narration never runs. The comment block says "every durable commit emits a pad line" but no commit ever does. (P19 is only satisfied by the explicit narration calls at join/task sites.) Unreachable code in the durability path is a hazard: the next editor may rely on it.
PROOF:
  $ sed -n '1530,1540p' tool/bin/lib.sh
  if [ -n "$_head_after" ] && sgit diff --quiet HEAD -- "${paths[@]}" 2>/dev/null; then
    return 0
  fi
  # H5b: HEAD didn't move and our bytes are not in HEAD — real failure.
  return 1
  # P19 auto-narration: every durable commit emits a pad line ...
  sp_narrate "commit: $1" 2>/dev/null || true
  }
  (there is no reachable path from the body to line 1538 — both branches return)
FIX: move the narration into the two success returns (or a dedicated wrapper) — e.g. `sp_commit_and_narrate() { sp_commit "$@" && { sp_narrate "commit: $1" 2>/dev/null || true; }; }` and call that from say/task paths, or delete the dead line with a comment saying commit-narration is deliberately not done.

## F5 — busy-seat retry is UNBOUNDED and re-posts the "queued" ack on EVERY retry: 39 identical pad blocks from one mention
SEVERITY: WASTES-TIME
FILE: tool/bin/watch.sh:864-893 (rc=3 busy branch), 1156-1177 (_busy_ack_stage/_busy_ack_post_pending)
WHAT HAPPENS: when an adapter exits 3 (busy/deferred), the delivery worker loops `sleep 2; continue` with NO iteration bound and NO strike/quarantine. A permanently-busy seat (focus-guarded herdr pane, DND-not-using-this-branch, an agent that never frees) is re-invoked every ~2s FOREVER — each retry also re-runs `_busy_ack_stage` + `_busy_ack_post_pending`, and because `_busy_ack_post_pending` DELETES the marker after posting, the next retry stages it again. The code comment says "Only ack once per ordinal — retries of the same busy generation do not re-post" — that is FALSE: the marker is per-(name,ordinal) but is removed after each post, so every retry re-creates it and appends a fresh "## @operator ... @wkr is mid-lane; your message is queued" block to the pad.
PROOF:
  (fixture: push seat wkr with an adapter that always exits 3; one @wkr mention)
  $ sleep 8; grep -c 'mid-lane' .stitchpad/stitchpad.md; grep -c '^=== invocation' /tmp/dsrev-busy2/invocations.log
  39
  39
  (39 IDENTICAL ack blocks appended to the pad in ~100s from ONE mention, one per retry)
  $ tail -5 .stitchpad/.state/delivery.wkr.log
  [stitchpad] adapter busy for @wkr → exit 3 (not consuming gate)
  ... (repeats every 2s, unbounded)
FIX: (a) bound the busy loop — after N consecutive busy results for the same generation, write state=busy_exhausted and stop retrying (surface on `lanes`), or reuse the keeper's strike pattern; (b) make the ack truly once-per-ordinal: keep a separate "posted" sentinel (e.g. .busy-ack-posted.$name.$ordinal) that _busy_ack_post_pending does NOT delete, and have _busy_ack_stage check both.

## F6 — duplicate roster row defeats the PUSH-seat misdirection guard: wake prints on the operator's terminal and burns the push seat's cursor
SEVERITY: WASTES-TIME
FILE: tool/bin/lib.sh:3467-3476 (sp_wake_mode_for takes FIRST row) vs tool/bin/watch.sh:1226-1238 (react() iterates ALL rows)
WHAT HAPPENS: the roster is hand-editable (or bridge-writable) and nothing rejects an EXACT-duplicate name row. With two `dale` rows (one pull, one push), sp_wake_mode_for reads only the first row → "pull", so the push-misdirection guard in `stitchpad wake` (stitchpad:3424-3433) is bypassed: an operator running `wake dale` gets the message printed in THEIR terminal AND seen.dale advances — the push seat (second row, target sess-999) never receives it and the watcher also enqueues it (react iterates both rows), producing one consumed cursor and one double-dispatched delivery. This is exactly the "silent loss" shape the guard exists to prevent, defeated by an unvalidated duplicate.
PROOF:
  (roster hand-edited to: dale|cli|pull|-  and  dale|cli|push|sess-999)
  $ stitchpad roster
  dale|cli|pull|-
  dale|cli|push|sess-999
  $ STITCHPAD_NAME=larry stitchpad say "@dale hello duplicate" >/dev/null 2>&1
  $ STITCHPAD_NAME=larry stitchpad wake dale ; echo rc=$?
  pasture: NEW from @larry — @dale hello duplicate — reply with @larry (context: ...)
  rc=0
  $ cat .stitchpad/.state/seen.dale
  2                    <- the push seat's cursor was advanced by the wrong-terminal wake
FIX: make the ambiguity fail closed. Either (a) sp_wake_mode_for returns "push" (or a new "ambiguous" value) when any row for the name is push, or (b) a read-time duplicate check in the wake path refuses when the name has >1 roster row: `[ "$(sp_roster | grep -c '^dale|')" -gt 1 ]` → refuse with "duplicate roster rows for @dale — disambiguate first". Also make react()/delivery_enqueue dedupe names so the double-enqueue cannot happen.

## F7 — first-run dead end: fresh pad `say` says "run 'stitchpad heal-roster'", but heal-roster CANNOT fix a fresh pad
SEVERITY: CONFUSING
FILE: tool/bin/stitchpad:2395-2400 (empty-roster refusal message) / tool/bin/stitchpad:542-544 (heal-roster failure on fresh pad)
WHAT HAPPENS: on a freshly `init`'d pad, `say` refuses with "pad roster is EMPTY — refusing to post; run 'stitchpad heal-roster' to recover the roster from pad history". But a fresh pad has NO historic roster with members (the initial commit's roster is empty too), so heal-roster exits 1 with "no historic roster with members found in pad git — cannot heal". The operator is sent to a command that cannot succeed; the real fix is `stitchpad join`. Dead-end guidance in the very first command a new operator runs.
PROOF:
  $ stitchpad init --name fresh2 ; STITCHPAD_NAME=bob stitchpad say "first words"
  stitchpad: pad roster is EMPTY — refusing to post; run 'stitchpad heal-roster' to recover the roster from pad history
  rc=1
  $ stitchpad heal-roster
  stitchpad: no historic roster with members found in pad git — cannot heal; re-init or restore-roster from a backup
  rc=1
  $ STITCHPAD_NAME=bob stitchpad join bob cli pull -   (the actual fix)
  ✓ bob joined ...
FIX: distinguish "empty because never joined" from "empty because lost": when PAD_GIT has ≤1 commit (nothing but the bootstrap), tell the operator to `stitchpad join <name> <adapter>` instead of heal-roster. e.g.:
  if [ "$_say_roster_count" -eq 0 ]; then
    if [ "$(sp_commit_count)" -le 1 ]; then
      echo "stitchpad: pad roster is EMPTY (nobody has joined yet) — run 'stitchpad join <name> <adapter>' first" >&2
    else
      echo "stitchpad: pad roster is EMPTY — refusing to post; run 'stitchpad heal-roster'..." >&2
    fi
    ...

## Clean categories (checked, no finding)
- read --new cursor: verified advance-on-read + "(nothing new since your last read)" + delta-only output (F1's corruption aside). CLEAN.
- watch start/stop/status lifecycle on a live pad: correct messages, correct rc (verified watcher started, delivered a mention E2E via a recorder adapter, seen cursor advanced exactly once, delivery state completed). CLEAN.
- init inside a git worktree: refuses without --scratch/--force, scratch pad excluded from `pads` listing (P18 gate). CLEAN.
- push-misdirection guard for a NORMAL single-row push seat: refuses, rc=1, cursor untouched. CLEAN (broken only by the F6 duplicate row).
- destroyed-pad guard on roster/whoami/read: loud rc=1 (P5). CLEAN (broken only on lanes/sessions — F2).
- @all expansion operator-precedence: verified the `|| ... &&` skip DOES run for operator/human roles (left-assoc). NOT a bug.
- busy adapter on a NORMAL seat: cursor not advanced while busy (seen.wkr absent), delivery state=busy — the not-consuming behavior is correct. (The defect is only the unbounded retry + ack flood — F5.)


## F8 — `stitchpad rename` claims "bindings" but leaves ocean-session.<old> stale: the renamed push seat silently starves
SEVERITY: LOSES-WORK
FILE: tool/bin/stitchpad:1044-1046 (rename state-file loop misses ocean-session.*, seat-model.*, resolved-model.*, keeper-*.*) + tool/bin/seat-keeper.sh:200-204 (keeper iterates ocean-session.*)
WHAT HAPPENS: `rename` moves only seen/count/alive/role/level/runtime/forcewake/dnd/delivered_no_reply + delivery.* artifacts, then prints "✓ @old → @new (roster, cursors, heartbeat, bindings, locks)". The seat-keeper's binding file `.state/ocean-session.<old>` is NOT moved and no `ocean-session.<new>` is created. After the rename the keeper iterates ocean-session.wkr (stale), finds no roster row for wkr, and logs "SEAT NOT ON ROSTER" forever; the real seat wrk2 has no binding file so the keeper never considers it — the anti-starvation watchdog silently stops covering the renamed seat (the exact failure the keeper exists to prevent). Model pins (seat-model/resolved-model) and keeper strike/obs/last files are likewise stranded under the old name.
PROOF:
  $ printf 'sess-abc' > .stitchpad/.state/ocean-session.wkr
  $ stitchpad rename wkr wrk2
  ✓ @wkr → @wrk2 (roster, cursors, heartbeat, bindings, locks)
  rc=0
  $ ls .stitchpad/.state/ocean-session.*
  ocean-session.wkr          <- STALE, never renamed
  $ ls .stitchpad/.state/ocean-session.wrk2 2>&1
  ls: ...: No such file or directory   <- MISSING, seat now invisible to the keeper
  $ stitchpad roster
  wrk2|ocean|push|sess-abc   <- roster row IS renamed
FIX: extend the rename loop to also move the name-keyed binding/pin/keeper files:
  for _pfx in seen seen.relay count alive role level runtime forcewake dnd delivered_no_reply ocean-session seat-model resolved-model keeper-strike keeper-obs keeper-last supervise-strikes artifact-expect authority scope scope-violation scope-cleared model; do ...
  (skip files whose content is a path/JSON that embeds the name — verify each; ocean-session content is just the session id, safe to move.)
  And have rename VERIFY the loop's post-conditions (no .state/<pfx>.<old> remains, .state/<pfx>.<new> exists) before printing "bindings" — a claim it can prove.

## F9 — `amend` and `react` print "✓" (rc=0) when their git commit FAILS: working pad silently diverges from history
SEVERITY: LOSES-WORK
FILE: tool/bin/stitchpad:2566 (amend: `0) sp_commit ...; sp_unlock; echo "✓ amended"` — commit result unchecked) and :2702-2710 (react: both toggle branches `sp_commit` unchecked)
WHAT HAPPENS: both commands mutate the pad and then call sp_commit WITHOUT checking its exit status. When the commit fails (read-only pad git, git hook failure, disk full), they still print "✓" and exit 0 — and the working pad now contains edits that git HEAD does not have. The divergence is invisible until the next successful writer's `git add -A` accidentally makes the edit durable (or `read --new`, diff-based, reports the amendment as a NEW message to every agent). Same unchecked-commit class as the sealed rename/set-wake/task-migrate findings — but amend/react are NEW instances, and this one is worse: it is the ONLY way the canonical pad file and its history disagree without any error.
PROOF:
  $ chmod -R a-w .stitchpad/stitchpad-git
  $ stitchpad amend m-308b95 "edited AGAIN" ; echo rc=$?
  ✓ amended #m-308b95
  rc=0
  $ grep -n 'edited' .stitchpad/stitchpad.md
  43:edited AGAIN                        <- working pad has it
  $ git --git-dir=.stitchpad/stitchpad-git show HEAD:stitchpad.md | grep -n 'edited'
  43:edited words                        <- git HEAD does NOT (diverged)
  $ stitchpad react #m-0f60aa thumbsup ; echo rc=$?
  ✓ reacted thumbsup to #m-0f60aa
  rc=0
  $ grep -c 'reacted thumbsup' .stitchpad/stitchpad.md; git --git-dir=.stitchpad/stitchpad-git show HEAD:stitchpad.md | grep -c 'reacted thumbsup'
  1        <- working pad
  0        <- git HEAD
FIX: check sp_commit's rc in both commands, like say does:
  if ! sp_commit "amend: $from #$target"; then
    sp_unlock; echo "stitchpad: amend NOT durable — commit failed; pad left edited but uncommitted" >&2; exit 1
  fi
  (same for both react branches). Optionally roll the pad back on commit failure to keep the pad==HEAD invariant, exactly as the say path's journal does.

## F10 — concurrent `task new` mints COLLIDING ids: one card is silently shadowed while BOTH creators print "TASK-N created" rc=0
SEVERITY: LOSES-WORK
FILE: tool/bin/stitchpad:4784-4792 (id computed under sp_lock) — same F1 lock-steal root cause
WHAT HAPPENS: under concurrent `task new` (6 simultaneous), two creators end up inside the pad's critical section at once (the F1 lock-steal), both compute the same next id from the same tasks.md snapshot, both write a ```task TASK-N block, and the last rename wins. The loser's card is shadowed: sp_tasks (and every consumer — task list, keeper seat_tasks, wake ticket-discipline) keeps only the last TASK-N block, so the other card is invisible while both invocations printed "<id> created" rc=0. Reproduced 1/3 runs (a duplicate ```task TASK-3 block in tasks.md with "task number 6" shadowed by "task number 1"). Permanently confusing: `task move/edit TASK-3` will act on the surviving card; the lost card's text sits orphaned in tasks.md forever.
PROOF:
  $ for i in 1 2 3 4 5 6; do (STITCHPAD_NAME=dale stitchpad task new "task number $i" --to dale --desc "desc $i" >/tmp/tk-$i.out 2>&1) & done; wait
  (all six rc=0, e.g. "TASK-3 created")
  $ grep -oE '^```task TASK-[0-9]+' .stitchpad/tasks.md | sort | uniq -d
  TASK-3        <- TWO creators both minted TASK-3
  $ stitchpad task list | grep -c 'task number 6'
  0             <- "task number 6" (created rc=0) is invisible to every consumer
  $ grep -c 'task number 6' .stitchpad/tasks.md
  1             <- but the bytes are still there, orphaned
FIX: the id computation must be serialized against the FILE STATE, not just the lock: recompute `existing` from the temp copy right before appending (inside the critical section the temp IS the state), or make the id mint atomic — e.g. write the card to a unique `tasks.md.new` name and let the LAST rename win per-id with a re-check loop: if another TASK-N appeared since compute, bump. Root fix is F1 (the lock steal that admits two writers); without it, add a post-compute recheck: after cp, count TASK ids in the temp; if the max changed, recompute id from the temp before appending.

## F11 — `task new --to <assignee>` posts the assignment notice TWICE, and the second append+commit is OUTSIDE the lock and unchecked
SEVERITY: WASTES-TIME
FILE: tool/bin/stitchpad:4862-4864 (notice #1 inside the dual-write) + :4896-4902 (notice #2 appended to the REAL pad after sp_unlock, raw `>>`, sp_commit unchecked)
WHAT HAPPENS: when an assignee is set, the dual-write already stamps the assignment notice into the pad (with a plain `## @assignee · HH:MM` header). After sp_unlock, lines 4900-4901 append a SECOND notice (now with a #m- id) to the live pad with a bare `>>` — no lock, no sp_write_inplace, no journal — and commit it UNCHECKED. Result: every assigned task produces TWO assignment messages to the assignee (a wake is fired for each), and the second write races any other pad writer (another say/task/watcher commit can land between the append and the commit, producing a torn or lost record). Under read-only git it prints nothing and the notice is non-durable (F9 class).
PROOF:
  $ grep -o 'task TASK-[0-9]* assigned' .stitchpad/stitchpad.md | sort | uniq -c
      2 task TASK-2 assigned      <- every assigned task: notice appears TWICE
      4 task TASK-3 assigned      <- the collided task: four copies
      2 task TASK-4 assigned
      ...
FIX: delete the duplicate site — the dual-write notice at 4862-4864 already carries the assignment into the committed pad. If the post-unlock id-stamped notice is desired, move it INTO the dual-write temp (add the #m- id there) so there is exactly one notice, under the lock, in the one commit. At minimum, re-lock before the append and check sp_commit's rc.

## F12 — `stitchpad lanes --json` emits `local: can only be used in a function` to stderr on EVERY run (healthy or broken pad)
SEVERITY: COSMETIC
FILE: tool/bin/stitchpad:5251,5255 — `local` used at top-level of the `lanes)` case arm (outside any function); bash rejects `local` outside functions
WHAT HAPPENS: the `--json` branch declares `local _names …` and `local _first=1` directly in the case arm. Bash 3.2 (macOS system bash) errors `local: can only be used in a function` for each — twice per invocation — but the script does not abort (no set -e at that scope), so the variables silently become globals and the JSON still prints. Every cron/CI/daemon that captures stderr of `lanes --json` logs two garbage lines per call, and the "json is clean" contract is violated on stderr even though stdout parses.
PROOF:
  $ stitchpad lanes --json 2>/tmp/lj.err; cat /tmp/lj.err
  /private/tmp/wt-merge/tool/bin/stitchpad: line 5251: local: can only be used in a function
  /private/tmp/wt-merge/tool/bin/stitchpad: line 5255: local: can only be used in a function
  (reproduces on a HEALTHY pad and on a destroyed-git pad alike; rc=0 both times)
FIX: wrap the json branch in a function (`sp_lanes_json() { local …; … }`) or drop the `local` keywords (the names are already unique enough at command scope). Also worth a stderr-redirect regression test asserting `lanes --json` writes nothing to stderr.

## F13 — `compact`/`archive` failure is NOT atomic: they rewrite the working pad and DELETE every seen cursor BEFORE the commit check, then lie "cursors untouched"
SEVERITY: LOSES-WORK (recoverable but state-corrupting)
FILE: tool/bin/stitchpad:1610-1619 (compact) and :1705-1715 (archive — same pattern): sp_write_inplace's rc is short-circuited (`... && sp_write_inplace`), the `rm -f "$PAD_STATE"/seen.*` (compact:1611, archive:1709) runs BEFORE the commit verification, and the failure message claims the opposite of what those lines did
WHAT HAPPENS: when the compaction/archival commit fails (read-only git, hook failure), the command still (a) rewrites the working pad to the compacted/archived form, (b) deletes every seat's seen cursor, and (c) exits 1 with "…NOT recorded — pad unchanged, cursors untouched" (compact) / "…NOT recorded — cursors untouched" (archive) — the claims FALSE in both. The next successful `say` commits the rewritten working pad, so the "failed" operation silently becomes HEAD truth (verified for compact: HEAD went 59 → 32 lines with the compact:gen marker after one say). Every seat's cursor is gone, so the whole fleet re-reads everything; the operator who saw "NOT recorded" believes the pad is unchanged while the damage is quietly durable.
PROOF:
  $ echo "2" > .stitchpad/.state/seen.dale    # a real cursor, as the watcher writes it
  $ chmod -R a-w .stitchpad/stitchpad-git
  $ stitchpad compact --keep 1 ; echo rc=$?
  stitchpad: compact NOT recorded — pad unchanged, cursors untouched
  rc=1
  $ ls .stitchpad/.state/seen.dale ; echo "exit $?"
  ls: ...: No such file or directory          # the cursor WAS deleted — claim false
  $ grep -c 'compact:gen' .stitchpad/stitchpad.md
  1                                           # the pad WAS compacted — claim false
  $ git --git-dir=.stitchpad/stitchpad-git show HEAD:stitchpad.md | wc -l
  59                                          # HEAD still full (divergence)
  $ stitchpad say "post-compact"              # next writer
  ✓ posted as @dale (#m-…)
  $ git --git-dir=.stitchpad/stitchpad-git show HEAD:stitchpad.md | grep -c 'compact:gen'
  1                                           # the "failed" compaction is now HEAD
FIX: make the failure path atomic like the say path: verify the commit BEFORE touching the pad or cursors. Move `rm -f "$PAD_STATE"/seen.*` after the successful sp_commit_or_fail; check sp_write_inplace's rc (sp_commit_or_fail will fail anyway on the mismatch, but the pad rewrite must be rolled back — journal the pre-compact pad bytes and restore on commit failure). And fix the message: report exactly what failed ("compact NOT recorded — pad left compacted, seen cursors deleted; restore with: git --git-dir=.stitchpad/stitchpad-git checkout -- stitchpad.md").

## Additional clean checks (final pass)
- task edit / task move: use sp_commit_or_fail (checked), fail loudly with rc=1 on commit failure. CLEAN.
- task migrate: sp_commit_or_fail checked. CLEAN.
- compact/archive SUCCESS path: archive.sqlite written, commit verified before readref stamping (S1/S2 fixes present). CLEAN (failure path is F13).
- say commit path: journal + rollback, fail-closed both directions (registry write fail → rollback; commit fail → rollback), verified in code. CLEAN (modulo F1's lock-steal window).
- say --re reply suppression: an addressed reply closes the original mention (sp_engagement → 0 open). CLEAN.
- DND: dnd on defers wake without advancing cursor; dnd off --drain replays once. CLEAN.
- delivery worker: exactly ONE worker per seat generation (adapter saw one ppid). CLEAN.
- resume/redeliver validation: rejects ordinal 0, non-roster, non-pull seats, already-answered mentions. CLEAN.
- lanes/roster/read P5 destroyed-pad gates on the commands that matter (lanes/sessions are F2).

TOTAL: 13 findings (F1-F13), 13 proved by execution.
