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

---

## PART 2 — delegation contract, dispatch honesty, blind-spot sweep

### Landed and gated since the last entry

**e780866 / 4a09aef — P42 sub-agent spawning under an enforced contract**
EC: *"they also need the ability to spawn their own sub-agents if they need to,
all within this context ... and it should always be following the orchestrator's
request."*

- `stitchpad spawn <name> --brief <text> --artifact <path>...`
  `--artifact` is MANDATORY. Spawning is the easy half; the contract is the
  point. An unconstrained spawn recreates, one level down, the most expensive
  defect of this build — a seat producing nothing looking exactly like a seat
  that is working.
- Lineage is durable (`.state/spawn.<child>.{parent,brief,at}`), so a silent seat
  is attributable to whoever asked for it.
- Depth (`STITCHPAD_SPAWN_MAX_DEPTH`, default 3) and fan-out
  (`STITCHPAD_SPAWN_MAX_CHILDREN`, default 5) are bounded. An agent that can
  spawn agents can fork-bomb the operator's laptop.
- Delegation cycles and anonymous spawns refused; every refusal names the fix.
- **Dispatch REUSES the mention → watcher → `fire_adapter` path.** Deliberate and
  load-bearing: that is the path proven to deliver. This command must never grow
  a second private dispatch path with its own bugs.
- `stitchpad directive <text>` — the orchestrator's standing order, copied
  VERBATIM into every spawn brief at every depth and marked as OUTRANKING the
  parent's brief. This is what "always following the orchestrator's request" is
  made of: depth cannot dilute the original ask.
- `stitchpad spawn --tree` renders lineage + each seat's contract. Verified live
  to depth 2 (lead → auditor → prober).

**join: a push seat no longer claims the caller's terminal.**
ONE TERMINAL = ONE PAD is for seats that OCCUPY a terminal. A push seat is
daemon-driven; its target is an Ocean session, not a surface. The old fallback
meant an operator sitting in their own joined terminal could not enrol a push
seat at all — which blocked spawning outright. Pull seats unchanged and still
refused (gate G12). terminal-isolation, websec, identity-survival, p33, p29-p30,
empty-lock-reclaim all stay GREEN.

**4d7a9a8 — P43 `wake` must not swallow a push seat's message**
The single most expensive shape in this system, and the one EC keeps hitting as
"the agents aren't deploying". Measured on the live pad: an orchestrator ran
`stitchpad wake kimi`; the command rendered the message to the ORCHESTRATOR's
terminal, advanced `.state/seen.kimi` to 5, and exited 0 — while the daemon
showed no turn on that session since the previous DAY. Cursor moved, so it was
never retried. **It looks exactly like success.**
`wake` now refuses when the target is a push seat and the caller is not that
seat, does not touch the cursor, and names the command that works. Self-wake and
all `--peek`/`--peek-ordinal` inspection untouched.
Note for whoever reads this next: the guard was FIRST written above the
definition of `_wake_record`, so it fell through and did nothing — the exact
"looks fine, does nothing" shape it exists to prevent. Its own gate caught it.
`wake-regression` case10's two `wake agent` calls were fixture-only cursor
drivers; they now name the seat, as every real caller does. **No assertion was
weakened — the simulation was made realistic.** Suite GREEN.

**P41 — regression-tripwire, both findings from kimi-adv, both proved by execution**
- Crash detection matched an ENUMERATED message list, so a suite dying on
  `x=$((1/0))` printed a bash diagnostic, continued with a wrong value and exited
  0 — scored GREEN. Now matches the bash fatal-diagnostic SHAPE (`: line <N>: `),
  which catches every diagnostic nobody thought to enumerate.
- The VOID path printed `TRIPWIRE: PASSED` and then exited 2. A run that could
  not be measured is not a pass. Now says INCONCLUSIVE and keeps exit 2.

New gates, both registered in `test/suite-baseline.txt`:
  `p42-subagent-spawn-gate.sh 12 0`   `p43-wake-push-misdirect-gate.sh 7 0`
Both mutant-proved.

### Blind-spot sweep (EC: "find any gap that is not gluing this machine together")
Prompt at `/tmp/blindspot/PROMPT.md`. Three seats dispatched against
`/private/tmp/wt-integrate`: `kimi-blind` (k3, whole system), `ds-dispatch`
(flash, dispatch-only lens), `ds-writepath` (flash, state/write-target lens).

**The sweep immediately reproduced the defect it was hunting.** Both DeepSeek
seats returned **rc=0 and produced no artifact at all**. Kimi obeyed the
"start writing the file EARLY" instruction and its file exists.

Two conclusions, both load-bearing:
1. **rc=0 from a dispatch means "the turn completed", NOT "the work happened."**
   Any orchestration that treats exit code as success will silently lose work.
   This is precisely why the P42 artifact contract is mandatory rather than
   advisory.
2. **An orchestrator cannot read what an agent said.** The daemon exposes
   id/session_id/prompt/status/started_at/finished_at; `/messages` returns 405,
   `/transcript` and `/output` 404. If the agent does not write to a path the
   orchestrator chose, the work is unrecoverable. Dispatch prompts must state the
   artifact path FIRST and treat chat output as discarded.

### Still open
- Full 83-suite tripwire run in a quiet window (targeted suites are green;
  watcher-singleton and p29-p30 not yet re-run after P43).
- Consolidate all four lineages onto fork `ecfromthedc/pasture`, resolve the 18
  conflict blocks across 7 files, run the full gate, push, open ONE PR upstream.
- `git add -A` remains BANNED in this repo (untracked credential-shaped
  wrangler.*.toml, relay state, machine-local keeper.conf). Add by explicit path.

### End-to-end proof that the board now tells the truth

Two sub-agents spawned under contract. One delivered real content; one left an
empty stub — the exact behaviour three live model seats exhibited earlier today.

```
LANE         STATUS          AGE ARTIFACT             PRESENT      VERDICT
lead         active           1s -                    -            WORKING
worker1      unknown          ?s /var/folders/5j/y... NO           FAILED
worker2      unknown          ?s /var/folders/5j/y... YES          DONE
```

`worker1` wrote a file and still reads **FAILED**, because an empty artifact is
not a produced artifact. Before this session it would have read present/DONE and
been indistinguishable from `worker2`. That difference is the entire point of the
work: an orchestrator can now see which seats actually delivered without reading
any agent's mind, which is the one thing the daemon cannot tell them (P45).

---

## PART 3 — the merge, P46, P48, and the overnight fleet

**Everything below is on fork `ecfromthedc/pasture`, both `master` and
`fix/macos-arena`, and on the live install at `~/.pasture` → this tree.**

### The merge that had to happen first
Pointing the install at the hardening branch would have DELETED 16 commits of
live work (the shed, the ui timeline + `stitchpad run`, message ids with threads
and reactions, PWA media, per-seat model, a bash-3.2 `start` fix). So it became a
merge: 17 conflict blocks across 7 files, each decided by checking a fact rather
than picking a side. The decisive one: production runs the keeper **bare** through
launchd every 120s, and the hardening branch's keeper answers a bare invocation
with usage + exit 2 — shipping it would have switched the fleet's watchdog off
silently. So the live keeper (v2, mention-oracle) ships; its telemetry was ported
and it finally has a gate.

### P46 — a dispatch is no longer one-shot
`stitchpad supervise <name>|--all [--max N]`. Produced → DONE. Missing or empty →
a continuation is posted and a strike recorded. Strikes exhausted → FAILED, said
out loud, never woken again. The continuation says "CONTINUE from where you
stopped, do NOT start over" — without that a re-woken agent rewrites its stub
every round and the loop never converges. 12 assertions, mutant-proved.

### P48 — watchers outliving their pads: FIXED BY k3
219 live watchers, every one on a pad that no longer existed, ~10 leaked per test
run. The loop `fswatch | while read` has no tick, so a deleted pad means no more
events and `react()` — which holds every liveness check — never runs again.

**I failed this twice** (a check in `react()` is a no-op; a sentinel just gets the
worker respawned by watch.sh's own launcher, and one attempt spawned a whole new
watcher tree). k3 fixed it on the first turn when dispatched **under supervision**
— same session each round, "continue, don't start over". The insight I missed:

    exec 9<>"$WATCH_EVENT_FIFO"     # read-WRITE

Opening the FIFO RDWR means the open never blocks and the fd never reports EOF if
fswatch dies; my `exec 3<` hit EOF instantly and killed the watcher at startup.
With the fd held open a timed read gives the loop a tick, the loop stays in the
MAIN shell so `exit` runs `watcher_cleanup`, and the launcher then stands down on
its own when it sees the lock gone — no signals. Machine went 219 watchers → 0.

Then k3 reviewed its OWN fix and found the next bug: without fswatch on PATH the
watcher started, took its lock, and both `watch start` and `watch status`
reported success while nothing was ever delivered. Preflight added in both places.

### Corrections I had to make to my own claims
- I wrote that the operator-conduct failure rate "tracks" the watcher count,
  implying causation. With the leak fixed and watchers flat it STILL fails 4-of-6.
  Correlation. That suite is quarantined with cause UNKNOWN — the only quarantined
  suite, printed loudly in every tripwire report.
- I twice built a "regression" story on five green runs of a suite that is a coin
  flip. The base rate is what settled it, three times in one session.
- My first supervision loop treated `wake` rc=3 ("turn still running") as
  "stopped" and fired three continuations that the daemon rejected 409 — I
  interrupted Kimi mid-work. Fixed: it waits while a turn is in flight.

### `lanes` no longer lies about a fresh seat
A joined, heartbeating cli/pull seat read `unknown / UNKNOWN` because `lanes` used
only the Ocean session registry. Same producer/consumer-disagree shape as P44 and
the help truncation. Now falls back to the 90s heartbeat rule the rest of the tool
uses: reads `alive / 3s / WORKING`.

### Overnight fleet (running as of this entry)
Three supervised seats on durable keepers (`/tmp/blindspot/keep-cooking.sh`),
each relaunched when its loop ends, bounded at 6 cycles so it cannot spin:
  · `kimi-review`  (k3)                — end-to-end adversarial, outside-eye lens
  · `ds-review`    (deepseek-v4-flash) — attacker lens
  · `flake2`       (deepseek-v4-pro)   — the operator-conduct flake, cause unknown
Artifacts: `/tmp/blindspot/REVIEW-kimi.md`, `REVIEW-ds.md`, `FLAKE2.md`.
The review prompt they share is `/tmp/blindspot/REVIEW-PROMPT.md`.

### NOT done, deliberately
EC asked to strip the tests and leave a tool-only repo once everything is green.
Not done yet, and when it is it should be a SEPARATE tool-only branch with the
full tree kept intact — "super clean" must not also mean "no safety net". The
28k lines of tests are what make the silence class detectable at all.
