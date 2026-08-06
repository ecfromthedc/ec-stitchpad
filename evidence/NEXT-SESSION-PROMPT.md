# ec-stitchpad — where the build actually is

The finish session took the OPEN list to zero. Read
`evidence/REVIEW-FINDINGS-TRIAGE.md` FIRST: all 33 review findings have
verdicts, the four carried-forward OPEN items are closed with evidence
(`evidence/SESSION-LOG-2026-08-06-FINISH.md` has the session narrative), and
nothing is left open. Do not re-litigate NOT-A-DEFECT entries without new
evidence — two were once PROMOTED to real defects on new evidence, so the
reverse is also fair game.

## The rules, unchanged — every one is a scar

- **Never `git add -A`.** `tool/keeper.conf`, `tool/relay/state/`,
  `wrangler.*.toml` are machine-local and some carry credential-shaped lines.
- **Never check out a different branch in `/Users/ecfromthedc/dev/tools/stitchpad-md`.**
  That tree is the live install; a launchd job runs the keeper from it every
  120s. Fast-forward the SAME branch only. Work in a `git worktree` elsewhere.
- **Never bare `pkill`.** Kill only pids you captured and identified.
- **No stray `test/*.sh`** — an unregistered suite fails the ENTIRE gate.
- **Do not edit `tool/` or `test/` while the tripwire is running.** It reads the
  working tree directly. Each full run is ~20 minutes.
- Run verification under `/bin/bash`; the interactive shell is zsh and mangles
  `git push fork "$b:$b"`, heredocs containing parentheses, and `PIPESTATUS`
  (zsh spells it `pipestatus`, 1-indexed).
- `git --git-dir=<live>/.git status` from another cwd reads YOUR cwd as the
  work tree and reports phantom modifications. `cd` into the tree first — this
  session nearly diagnosed a clean live install as dirty that way.
- macOS has no `timeout`. Cap waits with `perl -e 'select(undef,undef,undef,N)'`.
- `$?` after a pipeline is the LAST command's status.

## METHOD — it kept earning its keep this session

1. **Prove by execution.** An unrun claim is a hypothesis.
2. **Measure the base rate before calling anything broken.** 5+ runs for
   anything intermittent, and state the rate.
3. **Never weaken an assertion to make a gate pass. Fix the simulation.** The
   delivery-supervision `hold_worker` fixture was an ownerless lock — exactly
   the shape the OPEN #3 fix reclaims — so the fixture, not the assertion, was
   rebuilt (a live decoy worker, which is what a held singleton really is).
4. **A mutation that does not APPLY is INCONCLUSIVE, never a pass.** Every fix
   this session carries a mutant that was checked to apply and to re-create
   the defect.
5. **"Reports success while doing nothing" is the top bug class** — and its
   mirror, reporting FAILURE while succeeding, is just as expensive: both
   set-wake (OPEN #2) and the say warning (OPEN #4) were that mirror.
6. **Check a finding's premise, not just its symptom.** A review's root-cause
   claim for the delivery-supervision crash (heredoc function call) was real
   but NOT the trigger — the trigger was the fixture/product interaction.
   Both got fixed; only execution could tell them apart.
7. **A model's reply text is not evidence of which model ran.** glm-5.2
   answers "Claude (Anthropic)", deepseek answers "deepseek-chat". The
   daemon-side resolved config (TASK-1 pin telemetry) is the authority.

## OPEN — nothing

All four items from the previous handover are closed, each with a repro, a
fix or an evidence-based resolution, and a gate:

1. **watcher-races load fragility** → `83821fe`. A live supervisor is never
   scored dead on one stale wall-clock observation; no-progress needs two
   observations a full restart-grace apart with the same heartbeat stamp.
   watcher-races 5/5 GREEN under 6-way synthetic CPU load (the pristine tree
   failed under the same load). Gate: `watcher-live-lease-gate.sh` (9).
2. **set-wake false "failed to bind"** → `474d024`. The heartbeat-autostart
   tail no longer owns bind-session's exit status.
   Gate: `setwake-bind-truth-gate.sh` (7).
3. **delivery_start_worker ownerless-grace strand** → `565ca48`. The grace
   waits the window out and reclaims a dead starter in the same call; a live
   starter that publishes still wins. Gate: `delivery-grace-spawn-gate.sh` (6).
4. **say-under-contention rc** → `82e20f7`. Established rc=0 (wording class)
   from the live pad-git + telemetry forensics; duplicates were operator
   retries that each landed. Repro harness: `../repro/say-contention-rc.sh`.

## Fleet state

The ocean daemon died with the machine (it was hand-launched; the supervised
LaunchAgent was never installed) and was hand-relaunched this session —
neutral cwd, `OCEAN_YOLO=1`, log at `~/Library/Logs/ocean-daemon-hand.log`.
Every seat on both live pads then woke AND answered, verified by execution:

- **codex** — gpt-5.6-sol, session `c33c4ffd`, now pinned at SESSION scope.
- **glm** — glm-5.2, session `b51969e5`, now pinned at SESSION scope.
- **deepseek** — deepseek-v4-pro on both pads (was already session-pinned).
- **kimi** — k3 (subscription endpoint; the metered `kimi-k3`/`k2.*` models
  are ready=false at the daemon and the seat must NOT be repinned to them).
- **fable / captain** — herdr/manual seats; posting verified by this session.

**Why codex and glm had drifted to k3:** the running daemon binary (built
Jul 31 12:28) predates the `ocean-heartbeat wake --model` per-turn pin
(landed Jul 31 22:25), so sessions rode the daemon's GLOBAL model. The pin
telemetry caught it (`model-mismatch.{glm,codex}` fired); the session-scope
pins clear it and are robust against global flips. **Ocean-os ops items:**
install the supervised daemon (`ops/install-ocean-daemon.sh`, needs a clean
main checkout — the tree currently carries local modifications, operator's
call) and rebuild from main to get per-turn `--model`.

## DONE means — status at handover

1. `/bin/bash tool/bin/regression-tripwire` exits 0, 0 quarantined — run 1
   (pre-fix tree) was 101/102 with the one CRASH root-caused and fixed;
   final-run result recorded below by the session that ships this.
2. Every finding in `REVIEW-FINDINGS-TRIAGE.md` has a verdict; OPEN list is
   empty. ✓
3. Every seat on every live pad wakes and answers. ✓ (see Fleet state)
4. `master`, `fix/macos-arena`, `captain-dogfood-v4` identical, pushed, live
   install fast-forwarded to that sha.
5. First-run from an empty directory works via the LIVE install.

End with **GREEN** or **NOT GREEN**. If NOT GREEN, name the single blocking
item in one sentence.
