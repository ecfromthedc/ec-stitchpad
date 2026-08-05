# SESSION LOG — 2026-08-05 (write-up for context compaction)

Read this first if you are picking up cold. It records STATE, not narrative.

## WHERE THE WORK LIVES
- Work tree      : /Users/ecfromthedc/dev/agents/stitchpad-wt/fix   branch `captain-dogfood-v4`
- Live fleet tree: /Users/ecfromthedc/dev/tools/stitchpad-md  branch `fix/macos-arena` @ 76ba3be
  `~/.stitchpad` -> `~/.pasture` -> that checkout's tool/. A running fleet + a launchd
  keeper cron (`com.perma-cron.seat-keeper`, 2 min) execute those files continuously.
  NEVER `git checkout` another branch there. NEVER `git add -A` there — four untracked
  files are machine-local/credential-shaped: tool/relay/wrangler.{jay,sam}.toml,
  tool/relay/state/, tool/keeper.conf.
- Merge branch   : `fix/arena-wake-gate-merge` (worktree /private/tmp/wt-arena-merge)
- Remote         : push to `fork` (ecfromthedc/pasture). `origin` is READ-ONLY (403).

## OPEN PRs (Risingtides-dev/pasture)
- #10 captain-dogfood-v4          — the 238-commit hardening build (mine)
- #9  fix/arena-wake-gate-merge   — live fleet fixes + master merge, 5 wake-gate defects
- #8  feat/rust-wake-gate         — Rust gate port (other session). #7 CLOSED as superseded.
- #6  claim-hook + seat-keeper v2 — commented: merge-order + seat-keeper needs review
- #3  deepseek-seat               — pre-existing, unrelated

## ENFORCEMENT STATE (branch captain-dogfood-v4)
83 test files, 83 baselined, **0 quarantined**, 1708 assertions, 0 known-red.
Gate: `tool/bin/regression-tripwire` (run it under /bin/bash; the interactive shell is zsh
and does NOT word-split unquoted expansions — that silently broke three harnesses).

## P39 — THE WATCHER FLAKE: FIXED (pending final measurement at time of writing)
ROOT CAUSE (proved, not inferred): TWO bare `rmdir "$watch_lock"` sites in
`sp_stop_watchers_for_pad` (tool/bin/lib.sh) deleted a lock that another caller had
legitimately just won. The owner's `sp_watch_generation_write` then failed with ENOENT,
it tore down SILENTLY, the next caller won mkdir, and the cascade repeated until nobody
spawned. watch.log was never created — the tell that it was never started, not killed.
- The DOMINANT site sits AFTER a process-wait loop that can spin a full second.
- Both replaced with `sp_watch_empty_lock_reclaim`, which honours
  STITCHPAD_WATCH_START_GRACE and only removes an empty lock.
- The remaining bare rmdir in `ensure_watcher` is the owner removing ITS OWN lock: correct.
EVIDENCE: k3 (Kimi) probe log /tmp/p39-probe/probe.log —
  won-mkdir 49290 / stop-rmdir-late 49291 / won-mkdir 49291 / genwrite-fail 49290
  totals in one failing run: 16 won-mkdir, 12 genwrite-fail, 9 stop-rmdir-late, 4 spawned.
  Six "winners" of ONE atomic mkdir is the signature.
MY ERROR, RECORDED: I found the minor site first, measured 3 fails in 13 runs against a
~13% baseline, called it "no improvement" and DISCARDED A CORRECT FIX. 13 runs cannot
detect that effect. Acceptance bar is now 40 singleton + 15 races runs, zero failures.

## DISPATCH DEFECTS FOUND (the operator's top complaint — NOT yet fixed)
1. `stitchpad wake <push-seat>` renders the prompt, ADVANCES `seen.<name>`, and NEVER
   delivers. PROVEN: seen.kimi went to 5 while the daemon session sat untouched from the
   previous day. The mention is consumed and unrecoverable. The watcher's `fire_adapter()`
   in tool/bin/watch.sh IS the working path. FIX DIRECTION: `wake` should detect a push
   seat from the roster and dispatch through fire_adapter, reporting the real outcome —
   or refuse loudly WITHOUT advancing the cursor.
2. No retrievable answer. A dispatched turn's output is not readable: daemon turn objects
   carry only (id, session_id, prompt, status, started_at, finished_at) — no output field.
   If the agent's cwd has no pad it has nowhere to reply. FIX DIRECTION: artifact contract.
3. No "what is this seat doing now" — had to hand-poll /v1/agent/sessions/<id>.

## DISPATCH THAT WORKS (use this)
    ~/dev/ocean-os/target/release/ocean-heartbeat wake \
      --session-file <path>.session --allow-new-session \
      --cwd <A DIRECTORY CONTAINING A PAD> --client-type stitchpad \
      --model k3 --timeout-seconds 900 --prompt - < brief.txt
  rc: 0=completed 3=deferred(still running) 1=failed. `--allow-new-session` is REQUIRED.
  Model ids: `k3` is Kimi and is ready=true. `kimi-k3` is ready=FALSE — the classic typo.
  deepseek-v4-pro / deepseek-v4-flash are also ready.
  ALWAYS point --cwd at a pad, or the agent cannot reply.

## ADVERSARIAL REVIEW — PENDING
Brief: scratchpad/adversarial-brief.txt. It names MY failure modes as the targets
(under-powered measurement; mutants that never applied; fixing one of N duplicated sites;
assertions re-pointed after a merge; guards tested by their inputs; unreviewed
seat-keeper.sh) and carries an ARTIFACT CONTRACT: write /tmp/adversarial/<name>.md AND
post to the pad; producing nothing is a FAILURE, not a pass.
TO DO: dispatch k3 + deepseek-v4-pro, let them fix what they find, THEN push.

## SELF-AUDIT ALREADY DONE
- Searched for the same "fixed one of N" error elsewhere: 7 more `rmdir "$lock"` sites.
  5 are in `sp_lock()` guarded by sp_lock_owner_is_valid/is_live; 2 ARE the reclaim
  helpers. Cleared with reasons.
- Every gate I wrote carries an explicit "MUTANT DID NOT APPLY -> fail" guard.
- No `cat "$x" > "$y"` truncation sites remain; no `$VAR`-before-multibyte sites remain.

## CORRECTIONS I OWE (do not re-assert the originals)
- watcher-races is NOT flaky (8/8, 15/15 green). One red seen earlier was contention.
- The k3 turns that looked "dead" were alive; ~80s stale is normal thinking time.
- EC's `~/.stitchpad` refresh DID land (it uses `_rc`, not my `_claim_rc` name).
- P36 was never a requirements conflict — it was a locale-collation bug.

## NEXT STEPS, IN ORDER
1. Finish the 40+15 measurement; commit the P39 fix only if it is 0 failures.
2. Dispatch k3 + deepseek-v4-pro on the adversarial brief; let them land fixes.
3. THEN push captain-dogfood-v4 and update PR #10. Do not push before step 2 completes.
4. Fix the dispatch defects above — that is the operator's actual pain.
