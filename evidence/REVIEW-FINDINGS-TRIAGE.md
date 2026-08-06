# Review findings — final disposition, 2026-08-06 (closed out)

Source: `evidence/reviews/2026-08-06-deepseek-review.md` (F1–F13) and
`evidence/reviews/2026-08-06-k3-review.md` (F0–F19). 33 findings.

**Every finding has a verdict, and the WONT-FIX-TODAY list is now EMPTY.**
Verdicts: **FIXED** · **ALREADY-FIXED** (on master before this work) ·
**NOT-A-DEFECT** (verified, the reported behaviour is correct).

Counts: 27 FIXED · 4 ALREADY-FIXED · 3 NOT-A-DEFECT · 0 deferred.

Two findings changed verdict in the close-out round, both on new evidence:
**k3 F15 and k3 F17 moved from NOT-A-DEFECT/UNPROVEN to FIXED** — see the
close-out table. Nothing was closed by re-reading; every entry below was
reproduced or refuted by execution.

---

## FIXED in the first round (15) — reproduced first, mutant verified for each

| # | Finding | Proof it was real | Gate |
|---|---|---|---|
| ds F1 | pad lock stolen from a LIVE writer; rollback rewound another writer's commit | barrier seam: pre-fix W2 posted and W1 lost its message; post-fix W2 refused, W1 kept it | `empty-lock-reclaim-gate.sh` G4–G6 (12→17) |
| ds F2 | `lanes` rendered a board and exited 0 on a pad with no git | rc=0 on destroyed git; roster/whoami correctly refused | `finish-round-gate.sh` R4/R4a |
| ds F3 / k3 F6 | seat-keeper counted tasks in `stitchpad.md`; `task new` writes `tasks.md` | same card: `stitchpad.md → 0`, `tasks.md → 1` | `seat-keeper.sh` G8/G8b/G8c (8→11) |
| ds F4 | unreachable `sp_narrate` below `return 1` in `sp_commit` | read the code; every success path returns earlier | dead code deleted; comment corrected |
| ds F8 | `rename` stranded `ocean-session.<old>` — renamed push seat starved | 3 state files left behind, no `.wrk2`, printed ✓ rc=0 | `rename-state-carry-gate.sh` (new, 15) |
| ds F9 | `amend`/`react` printed ✓ rc=0 on a FAILED commit | real failing pre-commit hook: rc=0 + ✓, commit count unchanged | `commit-fail-postcondition-gate.sh` |
| ds F10 | concurrent `task new` minted COLLIDING ids | fixed by the F1 lock repair, as the finding predicted. 6 concurrent creates × 3 runs: 6 cards, 6 distinct ids | covered by F1's gate |
| ds F11 | `task new --to` posted the assignment notice TWICE, second copy post-unlock and unchecked | 2 notice blocks in the pad | `finish-round-gate.sh` R1/R1b |
| ds F12 | `lanes --json` wrote `local: can only be used in a function` to stderr twice per call | stderr 2 lines → 0 | `artifact-contract-gate.sh` G6/G6b/G6c (18→21) |
| k3 F3 | `health` printed `summary: error` and exited 0 | `health && echo healthy` printed healthy | `health-strict-exit-gate.sh` (new, 7) |
| k3 F8 | seat-keeper switched itself off in silence when the heartbeat binary was missing | stderr-only + exit 0; keeper.log empty | `finish-round-gate.sh` R6/R6b |
| k3 F10 | wake hook failed open with NO trace when the CLI was missing | every claude/codex seat goes deaf while heartbeat keeps them "alive" | `finish-round-gate.sh` R7/R7b/R7c |
| k3 F12 | `pads` used `-maxdepth 4`; a deeper pad was invisible | 6-level pad not listed | `finish-round-gate.sh` R3 |
| k3 F19 | `join` accepted a 241-char handle | accepted rc=0 | `finish-round-gate.sh` R2/R2b |
| **new** | a seat whose ocean turn ERRORED could never be removed | `leave codex` refused forever while its state said `errored` | `finish-round-gate.sh` R5/R5b |

Two further defects were found by running the gate and the fleet, not from the
reviews, and are fixed and gated: the tripwire scoring a suite CRASHED whenever
the OS handed it a pid below 10000 (`tripwire-gate.sh` 34→38), and a dead
watcher lock wedging a pad permanently while every surface said WORKING
(`watcher-singleton-gate.sh` 6→9). The second had both live pads deaf for ~11
hours.

## FIXED in the close-out round (12) — the former WONT-FIX-TODAY list, plus F15/F17

| # | Finding | Reproduced (before the fix) | Commit · Gate |
|---|---|---|---|
| k3 F16 | installer printed `✓ multi-agent collaboration is wired` with rc=0 after three tracebacks wired nothing | trailing comma in `settings.json` → 3 × JSONDecodeError, zero hooks written, banner printed, RC=0 | `652d32a` · `install-wiring-gate.sh` (new, 13) |
| ds F13 | `compact`/`archive` deleted every `seen.*` cursor and rewrote the pad BEFORE the commit check, then printed "cursors untouched" | `seen.bob` 15 → gone, pad sha changed, and the next successful `say` committed the failed compact | `4349007` · `commit-fail-postcondition-gate.sh` (8→18) |
| k3 F4 | third-party `wake` on a PULL seat — **the local path was ALREADY FIXED**; the guard exempted `--relay`, which kept the whole defect on `seen.relay.<padkey>.<name>` | local: refused, cursor unmoved (verified). relay: `boss wake dale --relay` sailed through | `e379169` · `p43-wake-push-misdirect-gate.sh` (8→12) |
| k3 F18 | two concurrent session starts both adopt one handle | 5/5 paired rounds: 2 bindings, 2 hooks printing "you are @fable". After: 0/15 | `c619759` · `session-start-identity-claim-gate.sh` (new, 7) |
| ds F5 / k3 F14 | busy-seat retry unbounded — a notification with sound every ~2.5s forever | adapter called until killed; state stuck `busy`; ~34k log lines/day/seat | `d93e7ce` · `busy-retry-bound-gate.sh` (new, 14) |
| k3 F13 | `ocean.sh` idle-guard failed OPEN on an unanswerable probe | unparseable body → rc=0 wake FIRED; dead daemon → rc=0 wake FIRED | `943dd06` · `ocean-idle-guard-gate.sh` (new, 7) |
| ds F6 | duplicate roster row — consumers disagreed about one seat; no repair path existed | `sp_wake_mode_for` answered "pull" for a seat delivered over push; `heal-roster` said "nothing to heal" | `67c7c7b` · `roster-duplicate-gate.sh` (new, 14) |
| k3 F0 | a keeper-quarantined seat read WORKING on `lanes`; `lanes --json` hid it entirely | 3 strikes + live heartbeat → `WORKING`; the seat absent from `--json` | `4b97717` · `lanes-quarantine-gate.sh` (new, 9) |
| k3 F1 | the watcher logged "exiting for supervisor restart" unconditionally — true under `daemon start`, a lie under `ensure_watcher` | killing fswatch killed the watcher; with no supervisor the pad went deaf until someone ran a command | `9eafe26` + `13ce124` · `watcher-fswatch-restart-gate.sh` (new, 8) |
| ds F7 | a fresh pad's `say` sent the operator to `heal-roster`, which cannot repair a fresh pad | both commands rc=1; the actual fix (`join`) was never named | `6fd9c3d` · `finish-round-gate.sh` (14→19) |
| k3 F17 | the Claude MCP server was registered into a file Claude does not read | two isolated HOMEs: entry in `settings.json` → "No MCP servers configured"; entry in `~/.claude.json` → listed | `27edcc1` · `install-wiring-gate.sh` G6/G6b |
| k3 F15 | untrusted pad text with live shell metacharacters typed into a raw pty | `$(id)`, backtick, `;`, `|`, `&&`, `>` all survived the sanitizer; a shell ran the second command | `27edcc1` · `herdr-nudge-sanitize-gate.sh` (new, 6) |

### Where a finding's own claim did not survive contact

Recorded rather than quietly dropped, because a review's wrong half matters as
much as its right half:

- **k3 F4** — the pull-path defect it describes is already fixed on master, with
  k3's own reproduction quoted in the code comment. What was left was the relay
  exemption. Fixed.
- **ds F6** — predicted that a duplicate roster row makes the watcher dispatch
  one mention twice. It does not: `delivery_enqueue` is idempotent per
  (ordinal, message_id). Asserted as a property (`roster-duplicate-gate.sh` G8)
  with a mutant that breaks the identity check and makes the double-dispatch
  appear, so the reason it cannot happen is recorded rather than assumed.
- **k3 F15** — its second precondition (the pane is a shell, not an agent TUI)
  was never demonstrated and still has not been. The fix removes the dependency
  on it instead of arguing about it.
- **k3 F1** — "there is no supervisor" is FALSE for a watcher started by
  `stitchpad daemon start`: `tool/bin/daemon.sh` respawns watch.sh 2s after any
  exit, and `watcher-races.sh` pins that with an ownerless-restart-gap probe.
  I repeated the finding's claim in code and in this document before the
  full-tree gate caught it. The message was true in that mode and false in the
  `ensure_watcher` mode, and the fix is now conditional on which one is running.

## ALREADY-FIXED on master before this work (4)

- **k3 F5** — unknown-`@mention` warning exists at `stitchpad:2584-2598`, with a
  nearest-name suggestion. Terminal-only (`[ -t 2 ]`) on purpose: suites and
  adapters parse stderr. The message still posts, by design — prose legitimately
  contains @-shaped text.
- **k3 F7** — `task new --title "X"` now refuses with rc=2 and names the correct
  form. Verified by execution.
- **k3 F11** — `dnd on <name>` refuses with rc=2 and explains that DND applies to
  the caller. Verified by execution.
- **PR #6's pair** — claim-hook fail-open (`stitchpad:3670`) and seat-keeper
  strike gating (`seat-keeper.sh:248`).

## NOT-A-DEFECT — verified, the behaviour is correct (3)

- **k3 F2** — `lanes` and `health` disagree. They are different questions:
  `lanes` is a per-seat artifact board, `health` is a diagnostic roll-up. The
  real complaint (a dead seat reading WORKING) was the *watcher wedge*, now
  fixed — and the quarantine half of it is closed by k3 F0 above.
- **k3 F9** — `missing_adapter:cli.sh` for PULL seats. `health.py:960` classes
  `missing_adapter` as an error tier. A pull seat genuinely has no adapter
  script, so the flag is accurate; what was wrong was that it had no exit-code
  consequence, which `--strict` now supplies.
- **deepseek's E1-with-live-pid edge** (raised by the deepseek seat during
  verification, reported as BROKEN) — `kill -0 1` fails with **EPERM**, not
  ESRCH. Every stitchpad writer on a pad runs as the same uid, so EPERM proves
  the pid is *not* our writer and reclaiming is correct. Treating EPERM as
  "alive" would reintroduce a permanent wedge. Behaviour kept deliberately.

## Open for the next session — found here, not fixed here

Three things this close-out established but did not fix. Each is written up so
the next session starts from evidence rather than rediscovery.

1. **`watcher-races.sh` is load-sensitive, and the fragility is in the product,
   not the suite.** It passes 5/5 standalone and fails inside a full tripwire
   run and under synthetic CPU load, at
   `fail "ensure-watcher cancelled or replaced the live supervisor gap"`.
   Measured on the PRISTINE pre-session tree (b8509a4) under the same load: it
   fails identically. So a concurrent `stitchpad` command can cancel a live
   supervisor's generation during the daemon's 2-second restart gap when the
   machine is busy — the liveness evidence stops being readable fast enough and
   a live supervisor reads as dead. Do NOT widen the suite's budget to hide it;
   the assertion is correct and the race is real.

2. **`set-wake` prints "failed to bind" after successfully binding.** Observed
   live re-pointing @glm: `set-wake glm push <sid>` printed
   `stitchpad: failed to bind Ocean session ... to @glm`, and an immediate
   `bind-session` answered `already bound (no-op)` — the bind HAD happened. A
   false FAILURE report, the mirror image of the false-success class this build
   has been closing, and it makes an operator retry an operation that already
   worked.

3. **`delivery_start_worker` has a 5s ownerless-lock grace that returns WITHOUT
   spawning.** A brand-new delivery generation landing in that window waits for
   the next enqueue. In production the watcher enqueues on every pad event so it
   recovers; with no further pad writes the mention sits. Surfaced by the
   busy-retry fixture (the give-up path reaches this window more often), and the
   fixture now models production rather than relying on one lucky call.

RESOLVED BY EVIDENCE (was: unproven `say` rollback warning under contention).
The exit code is established: **rc=0 — a wording-class problem, not a
false-failure report.** Three independent lines of evidence, all from the live
record of the 02:18 PM incident on `#campaign-hub-rust-rebuild`:

1. **Pad-git forensics.** The four copies of the ping are four separate `say`
   runs (each run appends exactly once — the operator retried). Copies 1–2
   were swept into the watcher's `update` auto-commits (14:18:24, 14:18:33,
   authored as kimi) — the documented JH4 benign race, where `say`'s own
   commit then finds its bytes already in HEAD and sp_commit returns 0.
   Copies 3–4 committed normally as captain (14:18:37, 14:18:42).
2. **Say telemetry.** The runs in the window recorded `outcome=posted` — that
   record is written only on the success path, immediately before the
   `✓ posted` line, so those runs exited 0. There are ZERO `outcome=failed`
   records in the window; the failure paths (`_say_record failed`) all record
   before their `exit 1`, and the one genuine failure that day (deepseek,
   14:56Z) proves the failed path does record.
3. **Synthetic contention.** 20 contended attempts (watcher-shaped sp_lock'd
   committer at 50ms cadence + a second seat racing every post;
   `../repro/say-contention-rc.sh`): 20 clean, 0 false failures, 0 warnings,
   0 duplicates.

So the message landed and `say` reported success every time; the duplicates
were the operator's retries, each of which also landed and said so. The exact
warning text remains unidentified (only first lines were captured live) — if
it recurs, capture full stderr AND `$?` before acting on it; the repro script
above is the harness for that.

## Method

Every FIXED entry was reproduced on a throwaway pad with an isolated `HOME`
before any code changed, and each carries a mutant that was checked to actually
APPLY — a mutant that does not apply is INCONCLUSIVE, never a pass. No bare
`pkill` anywhere; the suites that spawn processes kill only pids they captured
and identified. The live install was never used as a test target. Where a
review's verdict was wrong, it is recorded above with the reasoning rather than
quietly dropped.

Three things the gates caught in the close-out round that would otherwise have
shipped, and which are the reason the mutant discipline exists:

1. The F14 give-up notice named the seat a second time as " @name" — a MENTION —
   so announcing the end of delivery minted a new generation and restarted the
   retry, with a pad write per round. The cure was worse than the disease for
   one iteration.
2. The F15 truncation suffix put `(` and `)` back into the pty *after*
   sanitising. The metacharacter assertion went red on the fix, not the mutant.
3. An F15 mutant "survived" for a reason that had nothing to do with the code
   under test: the length cap truncated inside an unbalanced backquote, so the
   shell refused to parse the line. A mutant that passes for an unintended
   reason is the same false-success class as the bugs being fixed.

And three more that only the FULL-TREE run could find, all in my own work
(`13ce124`): a wrong premise about the supervisor (above); a constant changed
without updating the suite that is its contract; and a fixture running two
delivery workers, which overshoots a bound that a single worker respects
because the adapter fires before the attempt is counted. The last one also
surfaced a pre-existing hole worth its own session: delivery_start_worker has a
5s ownerless-lock grace that returns WITHOUT spawning, so a brand-new generation
landing in that window waits for the next enqueue.
