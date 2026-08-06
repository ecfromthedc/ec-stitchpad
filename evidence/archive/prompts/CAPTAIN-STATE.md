# CAPTAIN LOOP — PHASE 2: OPERATOR EXPERIENCE.  Tip: /Users/ecfromthedc/dev/agents/stitchpad-wt/fix @ 49d97cf
# This file IS the loop prompt. Run these steps IN ORDER every cycle. STOP when done.

## WHERE WE ARE
DURABILITY/CORRECTNESS LAYER: **DONE** — 12 of 25 ledger points fixed AND gated
(P5,P6,P8,P9,P10,P11,P12,P13,P14,P15,P16,P17). 26 gates, 70 baselined suites,
enforcement went 4-of-58 -> all 75 registered.
OPERATOR-EXPERIENCE LAYER: **THE REMAINING WORK.** This is what turns a test harness
into an arena, and it is the half EC actually feels.
  RED GATE, code landed, NOT done: P18 P19 P20 P21 P22
  NOT BUILT:                        P1 P2 P3 P4 P7 P23 P24 P25 P26

## "NO MORE HOLES IN THE BOAT" — THE ACCEPTANCE RULE (EC, non-negotiable)
A lane is DONE only when ALL SIX are true. Five of six is NOT done:
  1. the product change exists in the tree
  2. its gate runs GREEN
  3. **the captain personally mutant-proved it** — reintroduce the defect, gate goes RED.
     A mutation that does not APPLY is INCONCLUSIVE, never a pass.
  4. it has a test/suite-baseline.txt entry (the tripwire refuses unregistered suites)
  5. it is COMMITTED (uncommitted work does not exist — we nearly lost 7 gates that way)
  6. it is ABSORBED into /Users/ecfromthedc/dev/agents/stitchpad-wt/fix and posted to the pad
**Nobody's word counts, including mine.** Every "done" I reported this build that was not
personally verified turned out wrong: kimi "produced nothing" (28 commits), the sidebar
"cleared 18->0" (channels live on the RELAY), five lanes "waiting on absorb" (already
committed 39-82 min earlier).

## STEP 0 — SELF-HOST
export STITCHPAD_HOME=/Users/ecfromthedc/dev/agents/stitchpad-wt/fix/tool ; export PATH=/Users/ecfromthedc/dev/agents/stitchpad-wt/fix/tool/bin:$PATH
NEVER ~/.stitchpad/bin/stitchpad. A pad command misbehaving under the fixed tree is a
regression we just shipped — that outranks every lane.

## STEP 1 — ABSORB FIRST (the captain's #1 bottleneck, measured)
Builders finish, commit, go idle, and WAIT. Five lanes sat 39-82 minutes today while the
pad looked dead. Before anything else: cherry-pick every worktree commit not in /Users/ecfromthedc/dev/agents/stitchpad-wt/fix;
commit any uncommitted work yourself; post ONE line naming what was absorbed.
⚠️ CHECK DELETIONS ON EVERY CHERRY-PICK. r1's absorb net-deleted 245 lines of lib.sh and
broke a pillar; my own edit once deleted 833 lines and NINE command arms. Read the diff.

## STEP 2 — VERIFY (measurement runs ALONE, never while editing)
Run every test/*.sh. Any RED is stop-work: a real defect, or a gate that lies.
NEVER weaken an assertion to make a gate pass. Fix the simulation, not the assertion.
If a suite looks unmeasurable, FIX THE MEASUREMENT — quarantining working suites deletes
real coverage (that mistake nearly took us from 70 baselined to 39).

## STEP 3 — CLOSE THE LEDGER (25 points; 12 done)
Work the OPERATOR-EXPERIENCE points. Apply the six-part acceptance rule to each.
Deferrals must be EXPLICIT on the pad and in the PR — silent carry-over is banned.

## STEP 4 — SHIP
tripwire exits 0 · freeze SHA · rails x3 in a quiet window · push · PR with the honest
scorecard (fixed+gated / deferred+why / coverage as a FRACTION) · ready-for-review ·
**STOP THE LOOP.**

## HARD RULES (every one is a scar)
- NEVER bare-pkill; kill only PIDs you recorded (it SIGKILLed the captain 3x, 137/143).
- NEVER touch  or ~/.stitchpad.
- NEVER leave a .stitchpad in a worktree — it becomes a junk channel in EC's sidebar.
- Guards go at the CALL SITE, not shared init (that broke a pillar + security).
- BISECT, do not guess. Guessing cost an hour; the bisect took four minutes.
- Read the WHOLE failure set before fixing any of it (three 15-min runs vs one 10-sec dump).
- Post on every absorb, landing and deferral. EC must never have to ask.

## MODELS
deepseek-v4-pro (build) · deepseek-v4-flash (attack/verify) · k3 (Kimi — the only outside eye)
DEAD: codex/gpt-5.6-* (ready=true, produces nothing) · glm (out of tokens) · kimi-k3 (ready=false)
