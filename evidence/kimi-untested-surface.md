# kimi-untested-surface — Lane C: which hardened paths have NO test at all

- Reviewer: @kimi (outside eye, non-deepseek family)
- Target: /Users/ecfromthedc/dev/agents/stitchpad-wt/fix @ bc64aaad2d31769c26dd2094acd56d80a781ea80
  (15 commits on frozen b24cbe8; range b24cbe8..bc64aaa reviewed)
- Date: 2026-08-04
- Method: for each shipped hardening, located the guard in tool/bin, enumerated
  every command/call site flowing through it, then searched all 77 test/ files
  for a suite that drives that path. READ-ONLY on shipped code; no mutants run
  (mutations below are stated as the exact edit that would prove blindness).

## Headline

**The R7 live-journal protection — the code that stops crash-recovery from
destroying a CONCURRENT live operation — is gated only by a test that tests a
copy of itself.** Three more hardened paths have no gate at all: set-wake's
terminal claim, heal-roster's post-condition, and the watcher-side lock
reclaims. Four gates; each has a one-line mutation that keeps all suites green
while breaking production.

## The table (ranked by user impact)

| # | Hardening / guard | Command/path gated | Suite | If blind/absent: what breaks, how a user notices |
|---|---|---|---|---|
| 1 | R7 journal liveness — skip orphan-recovery for journals whose owner pid is alive (tool/bin/session-registry.sh:800-803; .alive stamped at :1090) | sp_session_registry_journal_begin → recover (session-registry.sh:1070), i.e. every journaled op: say (stitchpad:1861), leave, heartbeat lifecycle | **NONE through the shipped path.** test/recover-migrated-pad.sh Proof 15 (:848-895) creates live/dead journals but asserts against a bash RE-IMPLEMENTATION of the enumeration loop inline in the test (:855-863) — it never calls journal_recover with a live owner. All 8 real-call sites first `rm -f "$J/.alive"` (phaseb-hardening:132/166, phaseb-hardening2:97/155/210, task4-bounded-recovery:86, recovery-hardening3:167/231/290) | Mutation: delete or invert `kill -0 "$_alive_pid"` at session-registry.sh:802 → all suites green (Proof 15 tests its own copy). In prod, every say/leave begins by rolling back any CONCURRENT live operation's journaled bytes: a second agent's in-flight say is silently unwritten. User notices: posts vanish, interleaved lost messages, "I replied but it's gone" |
| 2 | 'One terminal = one (pad,name)' on retarget — sp_term_lock_claim (lib.sh:2147) called by set-wake (stitchpad:549) | `set-wake <name> push <target>` — the only retarget path after join | **NONE.** set-wake appears in 4 suites but only for post-condition (commit-fail-postcondition-gate:60) and delivery semantics (delivery-supervision:594-599,819-827); no suite claims a terminal in pad A then retargets it from pad B | Mutation: delete stitchpad:549 → all suites green. In prod, set-wake re-points a seat at a terminal live-bound to another pad: two pads drive one terminal. User notices: a foreign pad's agent starts waking on their pane; deliveries land in the wrong project |
| 3 | heal-roster post-condition — sp_commit + sp_verify_commit_landed (stitchpad:406-414), success line "✓ roster healed from commit …" (:416) | heal-roster — the roster-recovery path itself | **NONE.** heal-roster-regression.sh has zero commit-failure injection; false-success-gate.sh and commit-fail-postcondition-gate.sh probe 12 commands but not heal-roster | Mutation: revert :406-414 to a bare `sp_commit` (last month's shape) → all suites green. In prod, heal-roster prints ✓ with no durable commit: the roster is "healed" in the working file only, the next crash re-wedges the pad. User notices: heal-roster "worked" yesterday, today the roster is gone again |
| 4 | Watcher-side lock reclaims — sp_watch_empty_lock_reclaim (lib.sh:2616) and sp_watch_generation_only_lock_reclaim (lib.sh:2632), consumed by sp_watcher_alive (:2649) and watcher ensure (:2858-2863) | watcher admission/liveness: watch.sh ensure, auto-watcher start/stop (stitchpad:1728), doctor/status liveness | **NONE.** No test names either helper; watcher-ordering-gate covers the PAD lock interleave (af72d78), watcher-races covers .watch-generation/.watch-launcher STAGE-file reaping (:122-143) — a different mechanism from the watch.lock.d reclaim branches | Mutation A: make the generation-only reclaim always fail → suites green; a crashed watcher's lock is never reclaimed, the watcher never restarts, agents silently stop being woken. Mutation B: reclaim inside the startup grace → a live starting watcher is evicted, duplicate watchers double-wake every mention |
| 5 | Empty-roster refusal (say, stitchpad:1928-1936; missing-roster :1923-1927) | say (direct + best-effort internal callers, e.g. claim auto-ping :1955) | COVERED: roster-recovery-guard-regression.sh R2c/R4 (:94-113, populated→EMPTY stays refused; empty fence refused), heal-roster-regression.sh H2b/H2c/H2i (refusal names heal-roster; works after heal) | — |
| 6 | Assignee validation (task new :3886-3889, task edit :4090-4093) | task new --to, task edit --to | COVERED: roster-validation-gate.sh F4a-F4d (:109-138) — valid accepted, ghost 'zombie' refused, for BOTH new and edit | — |
| 7 | Terminal claim on join + claim-before-duplicate ordering (stitchpad:452-363) and say cross-pad/MP-2 fail-closed (:1857-1871) | join, say | COVERED: multipad-isolation.sh P7b (de_DE steal attempt on live owner), P3b-P3g (session-surface, env-cleared byname fail-closed, pane fallback, unclaimed-name permissive, routing-label documented, owning-pad allowed); terminal-isolation-gate.sh; identity-survival-under-join.sh | — |
| 8 | CLI empty-lock reclaim E1 (lib.sh:793-801, SP_LOCK_EMPTY_RECLAIM=1s) in sp_lock's shared wait loop | every sp_lock caller: say, join, leave, set-wake, rename, compact, archive, clear, task new/move/edit/migrate, heal/restore-roster, bind-session | COVERED at mechanism level: empty-lock-reclaim-gate.sh G1 (crash-seamed empty lock reclaimed, post lands <5s), G2 (two writers never both acquire), G3 (self-proving mutant: strip reclaim → "pad busy" gate red). Mechanism is shared, so say-driven coverage generalizes | — |
| 9 | Post-condition verification (sp_commit_or_fail / sp_verify_commit_landed, lib.sh:1217-1242) | say, join, leave, clear, task new/move/edit/migrate, restore-roster, set-wake, rename, compact, archive, init | COVERED except #3: false-success-gate.sh (read-only git: say/join/task new/task edit/task move/restore-roster/init + G2 strip-one-site mutant), commit-fail-postcondition-gate.sh (hook: set-wake/rename/task migrate/compact/archive + compact readref-stamp), date-session-atomicity.sh (say/leave), phaseb-hardening-regression.sh C3 (clear; hook inert without TEST_MODE) | — |

## Notes on method

- Rows 1-4 are the deliverable: hardened paths with NO effective gate.
- Row 1 is the worst shape EC has been fighting: the suite is GREEN, the
  assertion LOOKS like it covers R7 ("P15 — live journal SKIPPED"), but the
  code under test is a copy pasted into the test file. This is blindness by
  re-implementation, not by fixture.
- Row 2's claim ordering fix (e08a154) IS covered for join (multipad P7b);
  the SAME invariant on the set-wake retarget path was never given a fixture.
- Row 3 means my previous audit's family still has one ungated survivor; the
  two new gates cover 12 commands, and heal-roster (the 13th durable command)
  fell between them.
- Minimal gate additions: (1) a live-owner case in phaseb-hardening2 that calls
  the REAL sp_session_registry_journal_recover with .alive intact and asserts
  the journal and pad bytes survive; (2) a multipad case: claim terminal in
  pad A, `set-wake` retarget from pad B must refuse; (3) heal-roster probe in
  commit-fail-postcondition-gate.sh (identical probe() pattern); (4) a
  watcher-races case planting a generation-only watch.lock.d with a dead
  launcher and asserting reclaim after grace.

## What I checked (completeness)

- git log -p b24cbe8..bc64aaa (all 15 commits; the 3 new since my last audit:
  6510fa7 false-success x5, 1312bce init x2 + false-success-gate mutant,
  bc64aaa absorb/enforcement).
- Guard sites: stitchpad:452-453/549 (claims), :1857-1871 (say cross-pad),
  :1923-1936 (roster guards), :3886/:4090 (assignee), :262/:314-321/:386/:566/
  :663/:1176/:1272/:3985/:4066/:4109/:4145 (post-conditions); lib.sh:770-815
  (sp_lock loop), :2147 (term claim), :2616/:2632/:2649/:2858-2863 (watch
  reclaim), :1217-1242 (verify helpers); session-registry.sh:792-810/:1065-1090
  (R7).
- All 77 test/ files grepped for each guard's behavioral signature
  ('roster is EMPTY', 'not in roster — assignee', REFUSED cross-pad, set-wake,
  TEST_COMMIT_FAIL per command, .alive handling, watch reclaim helpers).
- Read the full bodies of: false-success-gate.sh, commit-fail-postcondition-
  gate.sh, roster-validation-gate.sh (F4), roster-recovery-guard-regression.sh,
  heal-roster-regression.sh, empty-lock-reclaim-gate.sh, multipad-isolation.sh
  (P3/P7), recover-migrated-pad.sh (Proof 15), phaseb-hardening{,2}, task4,
  recovery-hardening3, watcher-ordering-gate.sh, watcher-races.sh,
  delivery-supervision-regression.sh (set-wake sites).
- No shipped code edited; no suites run this pass (static coverage audit);
  ~/dev/tools/stitchpad-md and ~/.stitchpad untouched; no bare pkill.

## Verdict

Four hardened paths are ungated: R7 live-skip (asserted only by a
self-referential test), set-wake terminal claim, heal-roster post-condition,
watcher-side lock reclaims. Everything else on the hardening list is genuinely
gated, including self-proving mutants for the empty-lock reclaim and the
false-success gate.
