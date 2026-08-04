# kimi-evidence-and-freshop — P7 evidence verdict + fresh-operator pass (round 2)

- Seat: @kimi (only non-deepseek eye), 2026-08-04
- Worktree: /Users/ecfromthedc/dev/agents/stitchpad-wt/kimi-p7 @ 49d97cf + commits 13de5cd (P7) and cfd5c52 (RP-2 re-land)
- Scratch pad (removed after the run): /tmp/kimi-freshop2.3jqxbkEe — sandboxed HOME, no worktree pads, no bare pkill, no shipped trees touched.

## HEADLINE

**Dogfooding caught the release silently un-fixing itself: my absorbed RP-2
fix was rolled back by the lib.sh restore (03e68ba) — its gate sat in the
tree UNBASELINED, so the tripwire could not see the revert. A fresh-pad
`archive` at 49d97cf lies again exactly as before. Re-landed (cfd5c52),
this time with the baseline in the same commit as the fix.** Separately,
P7: `evidence verify` could never fail — counters in a pipeline subshell,
always rc=0. Fixed (13de5cd), mutant-proven, baselined.

## LANE 1 — P7: evidence canonical home + verify verdict

State found at 49d97cf: the verb existed (list|verify|seal) and the canonical
home is the pad's `.stitchpad/evidence/` (seal copies in + writes sidecar).
But `verify` was a PRINTER, not a verdict:
- counters sat in a `find | while` pipeline subshell — every increment lost;
  they were also never read. verify ALWAYS exited 0;
- an unsealed artifact (no .sha256) printed MISS and changed nothing;
- an orphan sidecar (artifact deleted) was silently ignored.

Fix (13de5cd): in-shell counting via process substitution; summary line
("verify: N OK, M STALE, K MISSING"); orphan sidecars reported as MISSING;
exit 1 + reseal hint on any STALE/MISSING; absent dir stays rc=0 with the
seal hint; list uses injection-safe relativisation.

Gate: test/evidence-verify-gate.sh — 8 assertions, baselined
(`evidence-verify-gate.sh 8 0`): absent-dir hint, seal→OK verify, tamper→
STALE+rc!=0 (P7 core), re-seal recovery, missing sidecar→MISS+rc!=0,
orphan sidecar named+rc!=0, MUTANT (neutered failure exit → tampered
artifact verifies rc=0; mutant-not-applied = INCONCLUSIVE = red).

## LANE 2 — fresh-operator pass (round 2, tip 49d97cf)

Round 1 (b06cc54, sealed in kimi-fresh-operator.md, absorbed) filed
TASK-16..20: RP-2 archive lie, refusals-exit-0, unvalidated enums, silent
empty roster, demo card on fresh boards. Round 2 re-ran the loop on the new
tip and probed the new verbs:

| probe | result |
|---|---|
| `archive --keep 2` on fresh pad | **REGRESSION — P19 back** (see headline); re-landed + re-verified in this worktree |
| `lanes` | works; live table (LANE/STATUS/AGE/ARTIFACT/PRESENT/VERDICT). New-operator note: a pull-seat lane shows VERDICT=WORKING with ARTIFACT=- — "working on what?" is still a guess for a brand-new operator, but this is the P3 surface and a huge improvement |
| `evidence seal` + `verify` | works end-to-end (post-fix): sealed → "verify: 1 OK, 0 STALE, 0 MISSING" rc=0 |
| `task new` / `task move` | happy path fine; invalid-status refusal from round 1 (TASK-18) still open — `task move X doing` still accepted at 49d97cf |
| `reconcile` | idempotent, clear message |
| `roster`, `read --new` | fine; empty-roster silence (TASK-19) still open |

New friction this round (added to the ledger view, not re-filed):
1. P-numbering collision across seats: my TASK-17..20 carry P20..P23 while
   the captain's ledger assigns the same P-numbers to different pains. Cards
   are unambiguous (TASK-ids), prose is not. Category fix: ledger P-numbers
   issued by one owner (the captain) or namespaced per seat.
2. command-dispatch-gate baseline drift: suite reports 71, baseline says 70
   at 49d97cf — pre-existing, reproduced with my changes stashed. Flagged
   for the captain's release-gate pass (I did not touch the tripwire).

## PROCESS FINDING (the one EC will care about)

The absorb→restore sequence (b2c0ba1 → 03e68ba) reverted a committed fix
because the restore target predated the absorb, and the gate that would have
caught it was unregistered. Two cheap invariants would make this class
impossible: (a) a fix and its baseline entry land in ONE commit, never two;
(b) the absorb-completeness meta-gate refuses any test/*.sh without a
baseline line — it exists, so either it didn't run between b2c0ba1 and
32f237a or it tolerates the gap; worth the captain checking which.

## VERIFICATION

- evidence-verify-gate.sh 8/0 (mutant bites)
- rp2-directory-pathspec-gate.sh 4/5 RED against the reverted lib (proving
  the gate detects exactly this regression), 10/0 after re-land
- commit-fail-postcondition-gate 6/0, date-session-atomicity 30/0,
  command-dispatch-gate 71/0 (pre-existing baseline drift noted above)
- scratch pad removed; no .stitchpad in the worktree; ~/dev/tools/stitchpad-md
  and ~/.stitchpad untouched; no bare pkill
