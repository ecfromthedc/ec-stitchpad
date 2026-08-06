# Review findings — triage, 2026-08-06

Source: `evidence/reviews/2026-08-06-deepseek-review.md` (F1–F13) and
`evidence/reviews/2026-08-06-k3-review.md` (F0–F19). 33 findings.

**Scope honesty first: I did not verify all 33.** I verified and closed six, and
confirmed two more as already fixed on master. Everything under OPEN below means
*not re-verified by me* — it does **not** mean *confirmed real*. The seats are
useful but not always right, and an unverified finding is a hypothesis in either
direction. Nobody should treat this list as a backlog of known-true bugs.

## Closed this session

Each was reproduced on a throwaway pad with an isolated `HOME` **before** any
code changed, and each fix carries a mutant that was checked to actually APPLY.
A mutant that changes nothing is inconclusive, not a pass.

| Finding | How it was proven real | Gate |
|---|---|---|
| **deepseek F8** — `rename` strands `ocean-session.<old>`; the renamed push seat starves | After `rename wkr wrk2`: `ocean-session.wkr`, `seat-model.wkr`, `keeper-strike.wkr` all still present, no `ocean-session.wrk2`, and it printed `✓ … bindings` rc=0 | `test/rename-state-carry-gate.sh` (new, 15). Mutant = pre-fix code; 12 of 15 go red, incl. "keeper binding disagrees with roster row" |
| **deepseek F3 / k3 F6** — seat-keeper counts tasks in `stitchpad.md`; `task new` writes `tasks.md` | Same card, measured per file: `stitchpad.md → 0`, `tasks.md → 1` | `test/seat-keeper.sh` G8/G8b/G8c (8→11). G8b mutant returns 0 |
| **k3 F3** — `health` prints `summary: error` and exits 0 | `rc=0` on an error summary; `health && echo healthy` printed healthy | `test/health-strict-exit-gate.sh` (new, 7). S0 proves the fixture is non-vacuous; S5 pins the deliberate default |
| **deepseek F9** — `amend`/`react` print `✓` rc=0 when the commit FAILS | Real failing pre-commit hook: pre-fix rc=0 + `✓`, commit count unchanged | `test/commit-fail-postcondition-gate.sh` (6→8). Mutant: "amend: FALSE SUCCESS — exited 0 with the commit forced to fail" |
| **deepseek F12** — `lanes --json` writes `local: can only be used in a function` to stderr twice per call | stderr byte count 2 lines → 0 after fix; stdout unchanged | `test/artifact-contract-gate.sh` G6/G6b/G6c (18→21). Under the mutant G6/G6b go red and G6c stays green — the finding's exact signature |
| **(not in the reviews — found by running the gate)** the tripwire scored `watcher-races.sh` CRASHED whenever the OS handed it a pid < 10000 | 1 red in 5 standalone runs; bash right-aligns the pid in a 5-char field so the guard's single space only matched 5-digit pids | `test/tripwire-gate.sh` (34→38) incl. an assertion that the SHIPPED classifier is width-tolerant, so the gate's private copy cannot drift again |

One more defect was found and fixed in the harness itself:
`test/test-health-readonly.sh` gave a fresh `python3` **2 seconds** to boot and
bind a socket. Standalone that is plenty; inside a 91-suite run it is not, and
the failure landed before the suite printed its RESULTS line, so the release gate
read PARSE_ERR/CRASHED. Measured 5/5 clean standalone, red in the full run;
diagnosis proven by forcing the wait to one iteration and reproducing the exact
signature. Budget raised to 15s, message now names the fixture and the timeout,
and a genuine no-start still fails loudly. No assertion was weakened — how fast
python starts is not one of that suite's claims.

## Verified as ALREADY FIXED on master — no action needed

- **k3 F5 / deepseek F-series** — a mention of a non-roster name. Master warns:
  `⚠ @<name> is not on the roster — nobody was woken`, with a nearest-name
  suggestion (`tool/bin/stitchpad:2584-2598`). Terminal-only (`[ -t 2 ]`),
  deliberately, because suites and adapters parse stderr. The message still
  posts — that is by design, since prose legitimately contains @-shaped text.
- **PR #6's two fixes** — claim-hook fail-open (`stitchpad:3670`) and the
  seat-keeper strike gating (`seat-keeper.sh:248`). See the PR #6 merge commit.

## OPEN — NOT re-verified by me

Listed so silence is not mistaken for "fine".

**The one I would take next, and why it is bigger than it looks:**

- **deepseek F1** — concurrent `say` loses a committed, acknowledged message.
  The lock reclaim (`lib.sh` E1/F2) can steal from a live writer, and the live
  journal-rollback path has no HEAD-advanced guard, so it rewinds work another
  writer already committed. Reported reproduced 2 of 3 runs at 8-way contention.
  This is also the stated root cause of **deepseek F10** (concurrent `task new`
  minting colliding ids), so the two should be taken together. The fix has two
  independent halves — publish lock ownership using only bash builtins so the
  empty-lock window is microseconds, and give the live rollback the same
  base-sha guard the orphan-recovery path already has. Wants its own session.

**Other LOSES-WORK, unverified:** deepseek F13 (`compact`/`archive` delete every
`seen.*` cursor and rewrite the pad BEFORE the commit check, then print "cursors
untouched" — the claim is false in both), k3 F0 (a keeper-quarantined seat reads
healthy on every surface — the review's thesis, photographed in production),
k3 F16 (corrupt `settings.json` → wake-less install wearing a `✓ installed`
banner), k3 F14 (mention to an idle claude-TUI seat = a desktop notification
every ~2.5s forever, no backoff, no bound), k3 F13 (`ocean.sh` idle-guard fails
OPEN on an unanswerable probe), k3 F18 (session-start orphan-rescue TOCTOU),
k3 F4 (third-party `wake <pull-seat>` prints to the wrong stdout and burns the
cursor), k3 F2 (`lanes` and `health` disagree; the board is the optimistic one —
now documented in the README's honest list, not fixed), k3 F1/F8/F10 (watcher
and keeper failures that are stderr-only or entirely silent).

**Lower severity, unverified:** deepseek F2, F4, F5, F6, F7 (first-run dead end:
a fresh pad's `say` suggests `heal-roster`, which cannot fix a fresh pad),
F11; k3 F7, F9, F11, F12, F19.

**Treat as leads, not findings:** k3 F15 and F17 are marked UNPROVEN by their
own author.

## Method note

No part of this used the live install. Every reproduction ran in a scratch
directory with an isolated `HOME`; no bare `pkill` was used anywhere, and the two
new suites start no watcher or ticker at all.
