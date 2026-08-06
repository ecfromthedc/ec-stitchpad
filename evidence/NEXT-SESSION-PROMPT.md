# Close out ec-stitchpad — the last ten, and nothing left on the list

You are finishing a build that is already shipped and green. The operator has
been on it for days and wants the remaining list at zero. Do not re-do finished
work; do not pad the report. Ten real defects remain, each already verified as
real and deliberately deferred, plus one operator-side seat restoration.

## Where you are starting

- Repo: **github.com/ecfromthedc/ec-stitchpad** (fork, you have push access).
  Upstream `Risingtides-dev/pasture` is READ-ONLY — pushing there 403s.
- `master` = `fix/macos-arena` = `captain-dogfood-v4` = **7ea96d4**, all pushed,
  and the live install is fast-forwarded to the same sha.
- Gate: `/bin/bash tool/bin/regression-tripwire` → **PASSED, 82 enforced suites,
  exit 0, 0 quarantined.** 92 suite files, 92 baselined.
- **The LIVE install is `~/.pasture` → `/Users/ecfromthedc/dev/tools/stitchpad-md/tool`,
  branch `fix/macos-arena`.** A launchd job runs the keeper from it every 120s
  and a live fleet executes those files continuously.
- Read `evidence/REVIEW-FINDINGS-TRIAGE.md` FIRST. All 33 review findings already
  have verdicts. The ten below are the ones marked WONT-FIX-TODAY. Do not
  re-litigate the ones marked NOT-A-DEFECT without new evidence.

## HARD RULES — every one is a scar

- **Never `git add -A`.** `tool/keeper.conf`, `tool/relay/state/`,
  `wrangler.*.toml` are machine-local and some carry credential-shaped lines.
  Add by path.
- **Never check out a different branch in `/Users/ecfromthedc/dev/tools/stitchpad-md`.**
  Fast-forward the SAME branch only (`git merge --ff-only <sha>`). Work in a
  `git worktree` elsewhere.
- **Never bare `pkill`.** Kill only pids you captured yourself.
- **No stray `test/*.sh`** — an unregistered suite fails the ENTIRE gate. Every
  new suite goes into `test/suite-baseline.txt` with its measured counts.
- **Do not edit `tool/` or `test/` while the tripwire is running.** It reads the
  working tree directly; a mid-run edit makes the result meaningless. Each full
  run is ~25 minutes — plan around one run, not five.
- Run verification under `/bin/bash` explicitly. The interactive shell is zsh and
  will mangle things like `git push fork "$b:$b"` via its `:r` modifier, and it
  breaks heredocs containing parentheses.
- macOS has no `timeout`. Cap waits with `perl -e 'select(undef,undef,undef,N)'`.
- `$?` after a pipeline is the LAST command's status. `cmd | tail` then `$?`
  measures `tail`. This produced two false readings last session.

## METHOD — non-negotiable, and it caught real damage last time

1. **Prove by execution.** Paste the command and its real output. An unrun claim
   is a hypothesis.
2. **Measure the base rate before calling anything broken.** 5+ runs for anything
   intermittent, and state the rate. A suite that is clean 5/5 standalone can
   still be red under full-run contention — that is a real signal, not noise.
3. **Never weaken an assertion to make a gate pass. Fix the simulation.**
4. **A mutation that does not APPLY is INCONCLUSIVE, never a pass.** Every fix
   needs a mutant proving its gate can actually fail. Last session two gates
   passed under their own mutants and were therefore testing nothing — one
   checked for a file the replacement process immediately recreated, the other
   treated `read`'s EOF status as failure so the guard never fired at all.
5. **"Reports success while doing nothing" is the top bug class** — including
   your own guards. Verify the guard FIRES, not that it exists.
6. Each fix ships in its own commit with the reproduction in the message.

## THE TEN

Ranked. Do them in this order; stop and ship whenever the gate is green rather
than batching everything into one risky push.

### 1. k3 F16 — installer produces a wake-less install wearing a success banner
`tool/install.sh:138` prints `✓ stitchpad installed — multi-agent collaboration
is wired.` unconditionally. With a corrupt `~/.claude/settings.json`
(`tool/install.sh:48`) — a trailing comma, the commonest JSON wound — the hook
wiring raises tracebacks, NOTHING is wired, and the banner still claims success
with rc=0. **Highest value on this list**: it is the first-run path, it only
bites a NEW machine, and F1/F10 then guarantee the resulting silence is never
diagnosed. Fix: validate the JSON, refuse or repair loudly, and never print the
success banner for a step that did not happen.

### 2. deepseek F13 — `compact`/`archive` destroy cursors then claim they didn't
`tool/bin/stitchpad:1696` and `:1794` do `rm -f "$PAD_STATE"/seen.*` BEFORE the
commit check; the failure messages at `:1703` and `:1799` then say
`pad unchanged, cursors untouched` and `cursors untouched`. Both claims are
false. The next successful `say` commits the rewritten pad, so a "failed"
operation becomes durable truth. Same all-or-nothing shape as the journal work
in `faa3229` — read that commit first; the pattern is already established.

### 3. k3 F4 — third-party `wake <pull-seat>` burns the seat's cursor
P43 fixed the PUSH path (`tool/bin/stitchpad:3569-3588`, `_wake_record
push_misdirect`). The pull path still renders to the caller's stdout and advances
`seen.<name>`, so the message is consumed and the agent never sees it. Extend the
same guard and gate it.

### 4. k3 F18 — session-start orphan-rescue TOCTOU
`tool/bin/session-registry.sh:792` (`_sp_session_registry_journal_orphans`).
Two concurrent starts with a stale heartbeat can BOTH adopt one handle: identity
duplicates and mention consumption becomes a race. The guard exists because of
the "02:53 fable incident". Use the same barrier discipline as the pad-lock fix
in `faa3229` — publish ownership with a builtin before anything forks.

### 5. deepseek F5 / k3 F14 — busy-seat retry has no bound
A mention to an idle claude-TUI seat re-posts and re-notifies roughly every 2.5s
forever (`claude.sh` always exits 3, the busy path has no backoff and no terminal
state). Unbounded desktop notifications and unbounded delivery-log growth.
**Be careful:** a wrong fix turns a noisy seat into a silent one, which is worse.
The retry needs backoff AND a terminal state that is announced on the pad.

### 6. k3 F13 — `ocean.sh` idle-guard fails OPEN
`tool/adapters/ocean.sh:64-68` probes the session and prints `busy` only when
`active_turn` is set; garbage or a timeout falls through to "idle" and the wake
fires into a possibly mid-turn session, where it is queued as stale pending
input. Make it three-state (busy | idle | unknown) exactly like
`tool/bin/seat-keeper.sh`'s probe, and never wake on `unknown`.

### 7. deepseek F6 — duplicate roster row defeats the misdirection guard
A repeated name in the ```roster block lets a wake print on the operator's
terminal and burn the push seat's cursor. Needs uniqueness enforced at `join`
AND a repair path for pads that already carry duplicates (`heal-roster` is the
natural home).

### 8. k3 F0 — a quarantined seat still reads healthy on `lanes`
Partly closed: `seat-keeper --report` shows quarantine and `health --strict` now
has a real exit code. Remaining: `lanes` — the operator's primary board — does
not surface `keeper-strike.<name>`. The state files are listed at
`tool/bin/stitchpad:1038`. A seat the watchdog has given up on must not render
as WORKING.

### 9. k3 F1 — the watcher promises a restart that never comes
`tool/bin/watch.sh:1350` logs `fswatch died on a live pad — exiting for
supervisor restart`. There is no supervisor. `watch start` now refuses loudly
when fswatch is absent (that half is done), but a watcher that dies mid-life
still leaves a log line promising recovery that will not happen. Either build the
restart or stop claiming it.

### 10. k3 F15 / F17 — promote or dismiss
Both are marked UNPROVEN by their own author. F15: `herdr.sh` strips control
bytes but not shell metacharacters before typing pad-derived text into a raw pty
— establish whether both preconditions can hold together. F17: the installer
registers the MCP server into `settings.json` while its own comment says
`~/.claude.json`. Produce a verdict with evidence either way; "unproven" is not
a resting state.

## ALSO — restore the codex seat

codex was REMOVED from the `campaign-hub-rust-rebuild` roster last session. Its
model `gpt-5.6-sol` is `ready=true`; its SESSION (Aug 3, 200 turns) accepted
wakes and then errored every turn — proven from `delivery.codex.state`
(`state=errored`, `error_code=turn_errored`). stitchpad behaved correctly
throughout. To restore, the operator opens ocean, starts a fresh session on
`gpt-5.6-sol` with cwd that repo, then:

    stitchpad join codex ocean push <new-session-id>
    printf %s <new-session-id> > .stitchpad/.state/ocean-session.codex

Then PROVE it fires: post a one-line liveness ping and confirm a reply lands on
the pad. Do not mark it done on the basis of the join succeeding.

## Fleet notes you will need

- Working seats, verified by execution: **kimi (k3)**, **deepseek
  (deepseek-v4-pro)**, **glm (glm-5.2)**. `fable` is a herdr terminal seat and
  only fires with a pane open — that is expected, not a fault.
- `kimi` only works because `.state/ocean-session.kimi` now exists. The watcher
  indexes seats by the ROSTER; the keeper indexes them by that FILE. If you add a
  seat, write both or the watchdog cannot see it.
- **You cannot read what a dispatched agent said** — the daemon's turn objects
  expose only `finished_at, id, prompt, session_id, started_at, status`. Verified
  this session. The artifact contract is your only observable; `spawn --artifact`
  plus `supervise` exist for exactly this.
- The fleet models are not reliable collaborators yet. Last session a seat
  reported the same test HOLDS then BROKEN in consecutive rounds, and returned
  one confidently wrong verdict. If you dispatch, verify everything they claim.
  Doing it yourself is usually faster.

## DONE means

1. `/bin/bash tool/bin/regression-tripwire` exits 0, 0 quarantined.
2. All ten above are FIXED or have a written WONT-FIX with a stated risk — and
   `evidence/REVIEW-FINDINGS-TRIAGE.md` is updated so no entry is left open.
3. Every seat on every live pad wakes and answers, or is off the roster with the
   reason recorded.
4. `master`, `fix/macos-arena`, `captain-dogfood-v4` identical, pushed, and the
   live install fast-forwarded to that sha.
5. First-run from an empty directory works via the LIVE install: `init`, `join`,
   `say`, `read`, `lanes`, `watch start`, clean `watch stop`, no leaked watcher.

End with **GREEN** or **NOT GREEN**. If NOT GREEN, name the single blocking item
in one sentence. Report honestly: if something is not done, say so and say why.
