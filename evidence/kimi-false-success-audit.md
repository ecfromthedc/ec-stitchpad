# kimi-false-success-audit — cross-family review of the "false success" class

- Reviewer: @kimi (outside eye; non-deepseek family)
- Target: /Users/ecfromthedc/dev/agents/stitchpad-wt/fix @ 1485fb304ef285e2f13f6923c2ad113bbcb63c6f
  (12 commits on frozen b24cbe8; full range b24cbe8..1485fb3 reviewed via `git log -p`)
- Date: 2026-08-04
- Method: full diff review + call-site inventory of every sp_commit/sp_commit_or_fail
  caller in tool/bin/stitchpad + LIVE repros in an isolated mktemp pad
  (/private/tmp/kimi-false-success.xc5hr2tL, HOME sandboxed; shipped trees untouched).

## Headline

**The false-success family is NOT closed.** The captain's three fixes (init, join
rejoin, join claim-ordering) are correct, and seven commands now verify their
post-condition — but FIVE commands still print ✓ and exit 0 after an UNCHECKED
bare `sp_commit`, and two of them additionally corrupt read cursors when the
commit fails. Three of the five were proven live at 1485fb3; no suite gates any
of the five.

## Verified CLOSED (checked call sites, correct pattern)

| command | site | mechanism |
|---|---|---|
| say | stitchpad:1895-1908 | commit rc captured; fail-closed journal rollback; exit 1 "message NOT posted" |
| join (roster add) | stitchpad:386 | `if ! sp_commit ... exit 1` |
| join (rejoin) | stitchpad:353-363 | fixed in 7bfb907/e08a154: ponytail context emitted; terminal claimed BEFORE duplicate short-circuit |
| task new | stitchpad:3874 | sp_commit_or_fail |
| task move | stitchpad:3955 | sp_commit_or_fail |
| task edit | stitchpad:3998 | sp_commit_or_fail |
| restore-roster | stitchpad:232 | sp_commit_or_fail |
| heal-roster | stitchpad:314-321 | sp_commit + sp_verify_commit_landed, fail path exits 1 |
| clear | stitchpad:1524 | checked, exit 1 on failure |
| leave | stitchpad:1596 | checked, journal rollback |
| init | stitchpad:114-190 | fixed in b1945bb + 1485fb3: positional honored, shape-disambiguated (path vs name), unknown options exit 2; "already exists" exit 0 is genuinely idempotent (pad IS present) |

The lib.sh infrastructure is right: sp_commit fails loudly on broken git dirs
(lib.sh:1272-1320), sp_commit_or_fail / sp_verify_commit_landed exist
(lib.sh:1217-1242). The five laggards simply never adopted it.

## OPEN — ranked by severity

### S1 (HIGH) compact — unchecked commit + readref stamped onto the WRONG history
- tool/bin/stitchpad:1073 `sp_commit "compact: gen $gen — ..."` — return ignored.
- stitchpad:1074-1075 then stamps every `.state/readref.*` with `sgit rev-parse
  HEAD`. If the commit failed, HEAD is the PRE-compact commit: every agent's
  read cursor is anchored to a history that does not contain the compaction it
  just lived through. False success compounds into cursor/history corruption.
- stitchpad:1079 prints `✓ compact gen $gen: ...` unconditionally; exit 0.

### S2 (HIGH) archive — identical compound defect
- tool/bin/stitchpad:1164 unchecked `sp_commit "archive: ..."`.
- stitchpad:1165-1166 same readref stamping onto possibly-stale HEAD.
- stitchpad:1169 prints `✓ archived $arch_count messages → $arch_file`; exit 0.

### S3 (HIGH) rename — unchecked commit; full identity rewrite unrecorded
- tool/bin/stitchpad:567 `sp_commit "roster: ~ $old renamed to $new"` — ignored.
- Pad bytes, per-agent state files, delivery artifacts, session bindings and
  terminal locks are all rewritten/moved on disk (stitchpad:519-566) with NO
  durable record; stitchpad:573 prints `✓ @$old → @$new (...)`; exit 0.
- LIVE PROOF (PROOF 4, REAL read-only pad git — chmod -R a-w, no test hook):
  `stitchpad rename alice2 alice` → rc=0, "✓ @alice2 → @alice (roster, cursors,
  heartbeat, bindings, locks)", rev-list count 3 → 3 (unchanged). Roster bytes
  on disk changed; pad history did not.

### S4 (MED) set-wake — unchecked commit
- tool/bin/stitchpad:476 `sp_commit "roster: ~ $who wake=$wake target=$target"`
  — ignored; stitchpad:489 prints `✓ $who wake=$wake target=$target`; exit 0.
- LIVE PROOF (PROOF 3, REAL read-only pad git): `set-wake alice2 push -`
  (pull→push, real state change) → rc=0, "✓ alice2 wake=push target=-",
  rev-list count 3 → 3. Roster on disk says push; pad git never recorded it.

### S5 (MED) task migrate — unchecked commit; bytes MOVED between files
- tool/bin/stitchpad:4032-4033 `sp_commit "tasks: migrated ..." \ ...` — ignored;
  stitchpad:4035 prints `✓ migrated $n_inline task block(s) → $PAD_TASKS`; exit 0.
- LIVE PROOF (PROOF 5, STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 —
  the repo's own sanctioned hook, lib.sh:1310): `task migrate` → rc=0,
  "✓ migrated 2 task block(s) → .../tasks.md", rev-list count 4 → 4. tasks.md
  exists on disk and the inline blocks are GONE from stitchpad.md — a two-file
  durable move with zero commits.

## Gate gap (this is how the family survives)

test/date-session-atomicity.sh exercises the commit-fail hook only for `say`
and `leave` (lines 130-181, 271). No suite drives set-wake / rename / compact /
archive / task-migrate under commit failure, so these five can rot indefinitely
even with all 58 suites green. Recommended: one commit-fail case per command in
date-session-atomicity.sh (the hook + rev-list-count pattern is already there).

## Minimal fix pattern (for whoever owns the patch)

Each site becomes `sp_commit_or_fail "<msg>" [paths...] || { sp_unlock; echo
"... NOT recorded" >&2; exit 1; }`. For compact/archive the readref stamping
must run ONLY after the commit is verified landed — otherwise cursors anchor to
a pre-mutation HEAD (S1/S2's second wound).

## What I checked (completeness statement)

- `git log -p b24cbe8..1485fb3` in full (all 12 commits).
- Every sp_commit/sp_commit_or_fail/sp_verify_commit_landed call site in
  tool/bin/stitchpad (19 sites, enumerated above).
- The captain's 3 product fixes read line-by-line; all three judged CORRECT
  (see verified-closed table; join reordering closes the claim bypass without
  refusing legitimate same-terminal rejoins).
- Live repros in an isolated mktemp pad with sandboxed HOME: control
  (no-op set-wake, benign), PROOF 1 (hook), PROOFS 3-4 (real read-only git),
  PROOF 5 (hook). Fixture kept at /private/tmp/kimi-false-success.xc5hr2tL.
- Lane discipline: no shipped code edited; no destructive commands; no suites
  run against shipped checkouts; ~/dev/tools/stitchpad-md and ~/.stitchpad
  untouched.

## Verdict

Family NOT closed: 5 commands remain false-success prone (2 with cursor
corruption). The 3 captain fixes are sound. Fix pattern is mechanical
(sp_commit_or_fail exists and is proven by 7 adopters); the gate gap must be
closed in the same pass or the family will rot back.
