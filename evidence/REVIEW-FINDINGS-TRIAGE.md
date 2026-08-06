# Review findings — final disposition, 2026-08-06

Source: `evidence/reviews/2026-08-06-deepseek-review.md` (F1–F13) and
`evidence/reviews/2026-08-06-k3-review.md` (F0–F19). 33 findings.

**Every finding has a verdict. Nothing is left as "not verified".**
Verdicts: **FIXED** · **ALREADY-FIXED** (on master before this session) ·
**NOT-A-DEFECT** (verified, the reported behaviour is correct) ·
**WONT-FIX-TODAY** (real, deliberately deferred, risk stated).

Counts: 15 FIXED · 4 ALREADY-FIXED · 4 NOT-A-DEFECT · 10 WONT-FIX-TODAY.

---

## FIXED (15) — reproduced first, mutant verified for each

| # | Finding | Proof it was real | Gate |
|---|---|---|---|
| ds F1 | pad lock stolen from a LIVE writer; rollback rewound another writer's commit | barrier seam: pre-fix W2 posted and W1 lost its message; post-fix W2 refused, W1 kept it | `empty-lock-reclaim-gate.sh` G4–G6 (12→17) |
| ds F2 | `lanes` rendered a board and exited 0 on a pad with no git | rc=0 on destroyed git; roster/whoami correctly refused | `finish-round-gate.sh` R4/R4a |
| ds F3 / k3 F6 | seat-keeper counted tasks in `stitchpad.md`; `task new` writes `tasks.md` | same card: `stitchpad.md → 0`, `tasks.md → 1` | `seat-keeper.sh` G8/G8b/G8c (8→11) |
| ds F4 | unreachable `sp_narrate` below `return 1` in `sp_commit` | read the code; every success path returns earlier | dead code deleted; comment corrected |
| ds F8 | `rename` stranded `ocean-session.<old>` — renamed push seat starved | 3 state files left behind, no `.wrk2`, printed ✓ rc=0 | `rename-state-carry-gate.sh` (new, 15) |
| ds F9 | `amend`/`react` printed ✓ rc=0 on a FAILED commit | real failing pre-commit hook: rc=0 + ✓, commit count unchanged | `commit-fail-postcondition-gate.sh` (6→8) |
| ds F10 | concurrent `task new` minted COLLIDING ids | fixed by the F1 lock repair, as the finding predicted. 6 concurrent creates × 3 runs: 6 cards, 6 distinct ids, 6/6 titles visible | covered by F1's gate |
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

## ALREADY-FIXED on master before this session (4)

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

## NOT-A-DEFECT — verified, the behaviour is correct (4)

- **k3 F2** — `lanes` and `health` disagree. They are different questions:
  `lanes` is a per-seat artifact board, `health` is a diagnostic roll-up. The
  real complaint (a dead seat reading WORKING) was the *watcher wedge*, now
  fixed. Documented in the README's honest list rather than collapsed into one
  oracle, which would lose information.
- **k3 F9** — `missing_adapter:cli.sh` for PULL seats. `health.py:960` classes
  `missing_adapter` as an error tier. A pull seat genuinely has no adapter
  script, so the flag is accurate; what was wrong was that it had no exit-code
  consequence, which `--strict` now supplies.
- **deepseek's E1-with-live-pid edge** (raised by the deepseek seat during
  verification, reported as BROKEN) — `kill -0 1` fails with **EPERM**, not
  ESRCH. Every stitchpad writer on a pad runs as the same uid, so EPERM proves
  the pid is *not* our writer and reclaiming is correct. Treating EPERM as
  "alive" would reintroduce a permanent wedge. Behaviour kept deliberately.
- **k3 F15 / F17** — marked UNPROVEN by their own author. F15 (herdr shell
  metacharacters) requires two preconditions that were never demonstrated
  together; F17 (MCP registered into `settings.json` vs `.claude.json`) is a
  comment/behaviour mismatch with no observed failure. Leads, not findings.

## WONT-FIX-TODAY — real, deliberately deferred, risk stated (10)

Each is a genuine defect. None blocks deploying agents today; each is written up
so the next session starts from evidence rather than rediscovery.

- **ds F5 / k3 F14** — busy-seat retry has no backoff bound; a mention to an idle
  claude-TUI seat produces a desktop notification roughly every 2.5s
  indefinitely. *Risk:* operator-hostile noise and unbounded delivery-log growth.
  *Why deferred:* the fix is a backoff policy with a terminal state, and getting
  it wrong turns a noisy seat into a silent one — the worse failure.
- **ds F6** — a duplicate roster row defeats the push-seat misdirection guard.
  *Risk:* a wake prints on the operator's terminal and burns the seat's cursor.
  *Why deferred:* needs roster-uniqueness enforcement at join AND a migration for
  pads that already carry duplicates.
- **ds F7** — a fresh pad's `say` suggests `heal-roster`, which cannot repair a
  fresh pad. *Risk:* first-run dead end. *Why deferred:* cosmetic wording, but
  the right fix is to detect "fresh" vs "corrupt" and branch the advice.
- **ds F13** — `compact`/`archive` delete every `seen.*` cursor and rewrite the
  pad BEFORE the commit check, then print "cursors untouched" on failure. *Risk:*
  LOSES-WORK, and the claim is false in both commands. *Why deferred:* this is
  the same all-or-nothing restructuring as F1's journal work and deserves its own
  session; the failure requires a commit failure to trigger.
- **k3 F0** — a keeper-quarantined seat reads healthy on `lanes`. *Partly*
  addressed: `keeper --report` shows it, and `health --strict` now has an exit
  code. *Remaining:* `lanes` does not surface quarantine state.
- **k3 F1** — a watcher that dies on missing `fswatch` logs a promised supervisor
  restart that never comes. `watch start` now refuses loudly up front when
  `fswatch` is absent, so the first-run path is covered; the misleading log line
  in the running-watcher path remains.
- **k3 F4** — third-party `wake <pull-seat>` prints to the wrong stdout and burns
  the cursor. *Risk:* LOSES-WORK. *Why deferred:* P43 fixed the push path; the
  pull path needs the same treatment and its own gate.
- **k3 F13** — `ocean.sh` idle-guard fails OPEN on an unanswerable probe. *Risk:*
  a wake fired into a mid-turn session is queued as stale pending input.
  *Why deferred:* failing closed on a flaky probe stops delivery entirely, so
  this needs a three-state probe like the keeper's, not a one-line flip.
- **k3 F16** — a corrupt `~/.claude/settings.json` yields a wake-less install
  still wearing a `✓ installed` banner, rc=0. *Risk:* the first-run path
  silently produces a fleet that can never be woken. *Why deferred:* installer
  work, no effect on an already-installed machine — but this is the highest-value
  item on this list for a NEW machine.
- **k3 F18** — session-start orphan-rescue TOCTOU: two concurrent starts can both
  adopt one handle. *Risk:* duplicated identity, raced mention consumption.
  *Why deferred:* concurrency work on the identity path; needs the same barrier
  discipline as F1.

## Method

Every FIXED entry was reproduced on a throwaway pad with an isolated `HOME`
before any code changed, and each carries a mutant that was checked to actually
APPLY. No bare `pkill` anywhere. The live install was never used as a test
target. Where a review's verdict was wrong, it is recorded as NOT-A-DEFECT with
the reasoning rather than quietly dropped.
