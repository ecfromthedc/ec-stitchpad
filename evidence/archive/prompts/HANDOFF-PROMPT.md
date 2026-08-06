# Bring ec-stitchpad to a clean, shippable main

You are picking up a working multi-agent system mid-flight. Read this whole brief
before touching anything. Everything below was verified by execution; where a
number appears, it was measured, not estimated.

## What the thing is
A markdown file is the chat room. Agents are rows in a ```roster fenced block
inside it (`name | adapter | wake | target`). Someone writes `@dale do X`; a
watcher notices the file changed and pokes dale's AI session with that message;
dale writes back into the same file. `wake` is `pull` (the agent collects its own
messages) or `push` (a watcher dispatches to it). Every message is a commit in an
isolated git repo. Everything else is operations around that one idea.

## Exact current state — verify these before trusting them
- Fork (yours, push access):  **github.com/ecfromthedc/ec-stitchpad**
  (renamed today from `ecfromthedc/pasture`; still a fork of the upstream below)
- Upstream (READ-ONLY, admin=false, push=false): **github.com/Risingtides-dev/pasture**
  Pushing to upstream 403s. Everything goes to the fork; upstream gets PRs.
- Branches `master`, `fix/macos-arena`, `captain-dogfood-v4` are all identical at
  **aff6d9c**. Fork master is **0 behind / 293 ahead** of upstream master.
- Working tree used for the last session: `/private/tmp/wt-merge` (a git worktree).
- **The LIVE install is `~/.pasture` -> `/Users/ecfromthedc/dev/tools/stitchpad-md/tool`,
  branch `fix/macos-arena`, currently at aff6d9c.** `~/.stitchpad` -> `~/.pasture`.
  A launchd job (`com.perma-cron.seat-keeper.plist`) runs the keeper from that
  tree every 120 seconds, and a live fleet executes those files continuously.
- Gate: `tool/bin/regression-tripwire`. Last run: **PASSED — all 79 enforced
  suites green, 0 quarantined.** 89 suite files, all baselined.
- Repo is 235 tracked files. The ~189MB on disk is `node_modules` and Rust
  `target/`, both untracked and already gitignored.

## HARD RULES — every one of these is a scar
- **Never `git add -A` in this repo.** `tool/relay/wrangler.jay.toml`,
  `wrangler.sam.toml`, `tool/relay/state/` and `tool/keeper.conf` are untracked,
  machine-local, and some contain credential-shaped lines. Add files by path.
- **Never check out a different branch in `/Users/ecfromthedc/dev/tools/stitchpad-md`.**
  That swaps the running fleet's tooling mid-flight. Update it only by
  fast-forwarding the SAME branch (`git merge --ff-only <sha>`), or use
  `git worktree add` somewhere else.
- **Never bare `pkill`.** Kill only PIDs you captured yourself.
- **Never leave a `.stitchpad` directory, or a stray `test/*.sh`, in the tree.**
  A stray `test/*.sh` makes the release gate refuse the ENTIRE run as an
  unregistered suite. Scratch scripts go at `test/.zz-scratch.sh` (dot-prefixed)
  and get deleted.
- macOS: there is **no `timeout`**. Cap waits with `perl -e 'select(undef,undef,undef,N)'`.
- Run verification under `/bin/bash` explicitly (the interactive shell is zsh and
  does not word-split unquoted expansions).

## THE STANDARD — this is what the project is actually about
The expensive failure here is **silence**: a seat that produces nothing looks
identical to one that is working. Hold to these:
1. **Prove by execution.** Paste the command and its real output. An unrun claim
   is a hypothesis, and this project has lost hours to plausible-but-wrong ones.
2. **Measure the base rate before calling anything broken.** An intermittent
   failure needs 5+ runs. This exact mistake was made three times in one session,
   twice producing an entire false "regression" narrative.
3. **Never weaken an assertion to make a gate pass. Fix the simulation.** When a
   fixture is unrealistic, make it realistic — do not soften the claim.
4. **A mutation that does not APPLY is INCONCLUSIVE, never a pass.** Every gate
   needs a mutant that proves it can actually fail.
5. Anything that reports success while doing nothing is the top-priority bug
   class, above features.

## YOUR JOB
### 1. Decide the PRs (they are NOT in master yet)
Three open upstream PRs have commits genuinely absent from master:
  - `#9  fix/arena-wake-gate-merge`                       1 commit
  - `#8  feat/rust-wake-gate`                            13 commits (a typed Rust port)
  - `#6  fix/claim-hook-undecidable-and-seat-keeper-v2`   3 commits
  - `#3  deepseek-seat` — branch is not on the fork; check where it lives.
`#10 captain-dogfood-v4` is already this work and is current.
Fold them in **one at a time**, running the full tripwire after each, and stop at
the first red. Do not batch them. #8 is the risky one — a Rust port touching the
wake gate; treat it as its own exercise and be willing to leave it out with an
explicit note rather than ship it unverified.

### 2. Make main clean and readable — but keep the tests
The operator asked about stripping tests to make the repo "super clean". **My
recommendation, and the reasoning, so you can override it knowingly:** keep them.
The repo is 235 tracked files — it is not bloated. The 89 suites are the only
reason the silence-class bugs are findable at all; several this week were caught
by a gate turning red, not by reading code. "Clean" should mean *a top level a
newcomer can understand in 30 seconds*, not *no safety net*.
So do this instead:
  - Rewrite `README.md` as a real mission statement: what it is, the six commands
    that matter (`init`, `join`, `say`, `read`, `lanes`, `watch start`), plus
    `spawn` and `supervise` for the agent side, and an honest "what this does not
    do yet". The teammate who could not follow this project is the audience.
  - Tidy the top level; leave `tool/`, `test/`, `evidence/` where they are.
  - If the operator still wants a tool-only tree, produce it as a SEPARATE branch
    (`ship/tool-only`) and keep master complete. Never delete the tests from the
    branch the gate runs against.

### 3. Work the open findings
`evidence/reviews/` holds 33 adversarial findings from two model seats, each with
a file, an observable behaviour and a reproduction. Several are still open,
including some marked LOSES-WORK (concurrent `say` losing a committed message;
`rename` leaving a stale `ocean-session.<old>` so a renamed push seat starves;
concurrent `task new` minting colliding ids). Verify each yourself before fixing —
the seats are useful but not always right. `evidence/OPERATOR-PAIN-LEDGER.md` is
the running list of everything known (P1–P49); read it first so you do not
re-report something already fixed.

### 4. Leave it usable
The operator wants to deploy agents against this today. Before you finish:
  - `/bin/bash tool/bin/regression-tripwire` exits 0 with 0 quarantined.
  - The first-run path works from an empty directory: `init`, `join`, `say`,
    `read`, `lanes`, `watch start`. Actually run it.
  - Fast-forward the live install (`git merge --ff-only`, same branch) and confirm
    `~/.stitchpad/bin/stitchpad help` works and the keeper runs clean.
  - Push `master`, `fix/macos-arena` and `captain-dogfood-v4` to the fork, and
    update PR #10 so upstream sees the final state.

## Dispatching other models (this is load-bearing)
A wake turn executes a short explicit sequence and does **not** sustain
open-ended work — five dispatches returned rc=0 having written only a stub
header. What works, proven:
  - Give the artifact path in the FIRST five lines and say chat output is discarded.
  - Make step 0 a single concrete command that creates the file.
  - **Supervise**: same session each round, re-prompt with "continue from where you
    stopped, do NOT start over". Under supervision the same models produced 33
    findings and a working fix for a bug I had failed twice.
  - `wake` returns **3** when the turn is STILL RUNNING. Treat 3 as "working" and
    wait; re-prompting mid-turn gets 409 `session has an active operation` and
    interrupts real work.
  - `k3` is Kimi and works. `deepseek-v4-pro` / `deepseek-v4-flash` work.
    `kimi-k3` is a typo trap (ready=false). Codex/gpt-5.6-* are marked dead.
  - You cannot read what an agent said — the daemon exposes no output field
    (P45). The artifact contract is the only observable. `stitchpad supervise`
    exists for exactly this.

Report honestly. If something is not done, say so plainly and say why.
