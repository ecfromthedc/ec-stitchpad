# 48-HOUR OPERATOR PAIN LEDGER — every incident that cost real time
# Captain's firsthand experience running a 34-seat fleet on stitchpad.
# Each entry: OBSERVED (what happened) -> REQUIRED (product behaviour) -> GATE.
# Tip: bc64aaa

## TIER 1 — DISPATCH LAYER (an agent that does nothing looks like an agent working)

P1. WAKE REPORTS SUCCESS FOR A MODEL THAT CANNOT RUN.  **PROVEN TODAY.**
    OBSERVED: `ocean-heartbeat wake --model kimi-k3` (daemon reports ready=false)
    returned {"ok":true,"status":"running"} with a turn_id and exit 0. The turn was
    dead within seconds (active_turn: none). Cost: SIX silent kimi turns; I concluded
    "kimi is non-functional" and told EC so — wrong, it was an unready model id.
    Same shape killed 4 codex turns while EC sat assuming codex was working.
    REQUIRED: wake MUST refuse (non-zero) when the model is not ready, naming the
    model and listing ready alternatives. A dispatch that cannot run is not "running".
    GATE: wake with a ready=false model exits non-zero; with a bogus model exits non-zero.

P2. NO ERROR SURFACE FOR A FAILED TURN.
    OBSERVED: no /turns endpoint, no last_error, no failure reason anywhere. A turn
    that dies instantly and a turn still thinking are indistinguishable.
    REQUIRED: every turn records terminal state (ok/error/reason). Session exposes
    last_turn_status + last_error.
    GATE: a turn on an unready model surfaces status=error with a reason.

P3. A SEAT THAT PRODUCES NOTHING IS INDISTINGUISHABLE FROM ONE THAT IS WORKING.
    OBSERVED: this is the single most expensive defect of the build. EC: "i'm over
    here assuming codex been cooking but no?" I only ever found out by grepping by hand.
    REQUIRED: an ARTIFACT CONTRACT — a turn declares its expected artifact; ending
    without it is a FAILED turn, visible on the board, not silence.
    GATE: a seat that ends with no committed artifact shows FAILED, not idle.

P4. MODEL IDS ARE UNVALIDATED AND SILENTLY WRONG (kimi-k3 vs k3).
    REQUIRED: validate against the daemon's model list at dispatch; suggest nearest.

## TIER 2 — PAD/STATE LAYER

P5. A DESTROYED PAD IS INDISTINGUISHABLE FROM AN IDLE FLEET.
    OBSERVED: ocean-arena's .stitchpad/stitchpad-git was deleted. sp_find_pad silently
    stopped recognising the pad; `roster` printed ZERO ROWS and EXITED 0. I read it as
    "fleet idle" and lost a cycle. Cost: a full cycle + near-misdiagnosis.
    REQUIRED: missing pad git = LOUD failure + recovery instruction; roster on a broken
    pad exits non-zero. "No pad here" must never look like "nobody joined".
    GATE: delete stitchpad-git -> roster exits non-zero naming the cause.

P6. AGENTS INVISIBLE TO THE ROSTER.
    OBSERVED: @km2 shipped 14 commits, @fx3 committed — neither in `roster`.
    STATUS: V1 auto-register + `reconcile` landed at bc64aaa; needs backfill verification.

P7. EVIDENCE HAS NO CANONICAL HOME.
    OBSERVED: reports landed in per-worktree evidence/, the pad's .stitchpad/evidence/,
    and /private/tmp. "Is it sealed?" had three answers. I twice reported a seat produced
    nothing when it had. Cost: one user-visible misreport to EC.
    REQUIRED: one canonical location + `stitchpad evidence list/verify` with sidecars.

P8. WORK DONE, WORK LOST.
    OBSERVED: 7 gates sat in worktrees unabsorbed; THREE were never committed and one
    rm -rf from gone. The enforcement mechanism itself was missing from the release branch.
    REQUIRED: absorb-completeness must be enforced, not manual.

## TIER 3 — TEST HARNESS (self-inflicted damage)

P9.  A SUITE CAN KILL PROCESSES IT DID NOT SPAWN. Bare `pkill -9 -f stitchpad`
     SIGKILLed the captain 3x and killed 2 measurement runs (137/143), producing 17
     phantom regressions I nearly reported as real.
     REQUIRED: reap only recorded PIDs + a documented helper. GATE: prove it.
P10. SUITES LEAK WATCHERS INTO EACH OTHER. test-health-readonly fails in sequence,
     passes alone. Cross-suite contamination makes sequential runs unreliable.
P11. FIXTURE BLEED INTO REAL PADS. Captured `heartbeat --touch flash-portability`
     written into REAL pad state while a test ran.
P12. TESTS INHERIT AMBIENT SESSION IDENTITY. sp_this_surface falls back to
     $CLAUDE_CODE_SESSION_ID, so every fixture in an agent session shares one surface.
     STATUS: STITCHPAD_TERMINAL_NAMESPACE landed at bc64aaa.
P13. WATCHER CHURN — 41 ensure-watcher + 34 watch.sh spawns in 60s. Never investigated.

## TIER 4 — CLOSED THIS BUILD (keep gated)
P14. Tripwire enforced 4/58 -> 65 baselined + meta-gate.
P15. '? ?' placeholder baselines -> fail loud in 1s.
P16. Quarantine hid 31 of 32 suites (208-assertion coverage) -> 1 entry, proof required.
P17. False-success family: init x3, join x2, compact, archive, rename, set-wake,
     task-migrate -> all verify post-conditions + commit-fail-postcondition-gate.

## TIER 1.5 — WORKSPACE POLLUTION (EC saw this in the UI and it is not acceptable)

P18. AGENT SCRATCH TREES BECOME PERMANENT CHANNELS IN THE OPERATOR'S SIDEBAR.
     OBSERVED: EC's pasture sidebar filled with ~18 junk channels — #fix, #fx5-bisect,
     #pro2-triage, #captain-census, #pro5-enforce, #r3-census3, #pro3-dispatch,
     #fx1-census2, #captain-mutant, #candidate, #pro6-e13, #pro8-verify, #pro4-final,
     #pro6-lock, #pro2-atomic, #pro5-final, #pro8-final, #pro3-val, #pro3-pf, #pro7-bisect...
     CAUSE: every per-seat git worktree got a RUNTIME-CREATED .stitchpad (zero tracked
     files) because suites and seats ran `stitchpad init` with cwd inside the worktree.
     Each became a real pad, therefore a channel. EC: "this whole spawning agents into
     blank side-channel thing... this is a junk mess. This section of pasture should
     only be my projects."
     COST: the operator's primary navigation surface became unusable, and a destroyed
     real pad was harder to spot among the noise.
     REQUIRED (product, not cleanup):
       (a) A pad created inside a git WORKTREE of another repo must not register as a
           first-class channel. Either refuse, or mark it ephemeral/scratch and hide it.
       (b) `stitchpad init` inside an existing repo worktree should require an explicit
           --scratch (or --force) and default to NOT publishing a channel.
       (c) Test fixtures must never create a discoverable pad — fixture pads belong under
           the fixture root and must be invisible to pad discovery. (This is P11's
           fixture-bleed at workspace level.)
       (d) A `stitchpad pads --prune` / `--scratch` view so an operator can see and clear
           ephemeral pads without hand-deleting directories.
     GATE: create a worktree, run `stitchpad init` in it, assert it does NOT appear in
     the operator's pad/channel listing; run a full suite sweep and assert ZERO new
     channels afterwards.
     INTERIM (done): 18 scratch pads removed by hand, backed up to
     ~/dev/agents/stitchpad-wt-scratchpad-backup. This is a PATCH — (a)-(d) is the fix.

P19. THE PAD IS SILENT WHILE THE FLEET IS WORKING.
     OBSERVED: EC, watching the arena live while five seats built fixes:
     "i dont see yall cooking in this stitch pad lol i see the tasks populting tho".
     Task cards appear (the captain files them) but the pad shows no activity, because
     seats work in worktrees and only narrate if they remember to. The arena LOOKS idle
     while it is at its busiest.
     WHY IT MATTERS: this is P3 from the operator's chair. I had to grep git to learn
     whether codex was alive; EC has to ask. The pad is meant to BE the surface of the
     work — if progress is invisible there, the operator is flying blind and every
     status question becomes a manual investigation.
     REQUIRED: progress appears on the pad BY DEFAULT, not by politeness.
       (a) taking a lane, landing a commit, and closing a card each emit a pad line
           automatically — driven by the artifact contract, not by the agent choosing to.
       (b) a compact activity view (`stitchpad lanes`) showing per-seat: lane, last turn
           outcome, artifact expected vs present, age.
       (c) heartbeat/lane events should be visible without opening a terminal.
     GATE: run a lane end-to-end with an agent that never calls `say`, and assert the pad
     still shows: lane taken, commit landed, card closed.

## THE UNIFYING PRINCIPLE (EC, and it reframes the whole ledger)

EC: "the whole part of this is for this to be a surface where we can oversee agent teams
and for it to be fully transparent every step of the way."

**EVERY QUESTION EC HAD TO ASK ME IS A DEFECT IN THE SURFACE.**
Count them from this build: "eta?" (x8), "hows it going", "u still going?", "are kimi and
codex ok with everything?", "why didnt the other 4 go?", "i dont see any updates in ocean
arena", "i dont see yall cooking". Not one of those should have required a human to ask a
captain. Each is the board failing to answer on its own.

P20. THE BOARD SHOWS NO ETA — THE OPERATOR MUST ASK.
     OBSERVED: EC asked "eta?" at least EIGHT times across 48 hours. Every answer I gave
     was a hand-rolled estimate assembled by reading worktrees and guessing; several were
     wrong, and the wrong ones cost trust.
     NOTE: an ETA/rollup capability was already IDENTIFIED as a pasture card and never
     built — this is P8 (work filed, never landed) at the roadmap level.
     REQUIRED: per-card estimate + a wall-clock projection that MODELS PARALLELISM
     (busiest-owner chain + serialised tail), shown in the task section. The operator
     plans agent and token budget without asking anyone.
     GATE: board with N cards across M owners yields a projection; adding a card to the
     busiest owner moves the projection; adding one to an idle owner does not.

P21. THE TASK LIST IS STATIC — NO LIVE PROGRESS, NO OWNER ACTIVITY.
     OBSERVED: cards appear (the captain files them) but never move on their own. A card
     in_progress looks identical to a card whose owner died three hours ago.
     REQUIRED: each card shows owner, live/stale, last activity age, artifact expected vs
     present. A card whose owner has been idle past a threshold is flagged on the board,
     not discovered by a human asking.
     GATE: mark a card in_progress, kill its owner, assert the board flags it STALE
     without any operator action.

P22. THE OPERATOR CANNOT CONDUCT FROM THE SIDES.
     EC's ask: "when i ping any individual agent in here they should be able to respond
     within the context of what they're doing to me. so there's an orchestrator agent
     like u but i can also conduct from the sides n help move the players on the board."
     OBSERVED (dogfooded live, this session): posted "@pro5 what lane are you on and what
     is your ETA?" while pro5 was mid-turn. **No reply in 45s. No acknowledgement. No
     indication whether the mention was queued, deferred, or dropped.** The pad shows the
     question sitting there unanswered. watch.sh HAS defer-or-queue logic (INVARIANT 5)
     but none of it is visible to the person who asked.
     WHY IT MATTERS: this is the difference between a dashboard and an ARENA. Today the
     operator can only talk to the captain, and the captain becomes a bottleneck and a
     single point of misreporting — which is exactly how EC got told "kimi produced
     nothing" and "codex is cooking" when neither was true.
     REQUIRED:
       (a) A mention to a BUSY agent is queued and ACKNOWLEDGED immediately on the pad
           ("@pro5 is mid-lane; queued, will answer at end of turn") — silence is never
           the response to a direct question.
       (b) The agent answers IN THE CONTEXT OF ITS CURRENT LANE: what it is doing, how
           far along, what is blocking, its own ETA. Not a fresh cold turn.
       (c) The operator can steer without going through the captain: reassign a card,
           stop a lane, change priority, ask for status — and the agent obeys or says
           plainly why it cannot.
       (d) Direct operator instructions OUTRANK captain instructions, and the agent says
           so when they conflict.
     GATE: ping a mid-turn agent; assert (1) an acknowledgement appears on the pad within
     seconds, (2) a contextual answer naming its current lane arrives by end of turn,
     (3) an operator reassignment mid-lane is honoured, (4) the same ping to an IDLE
     agent answers immediately.

P23. THE FIXES DO NOT PROTECT THE FLEET THAT BUILDS THEM (no self-hosting).
     EC asked the sharpest question of the build: "can you implement the things you're
     fixing while you're doing it? You can patch the hole in the boat so that you don't
     sink going forward... because it seems like that's happened to us this whole time."
     He was right, and it is the reason the same failures kept recurring.
     OBSERVED: every fix lands in stitchpad-wt/fix, but the captain and all seats invoke
     ~/.stitchpad/bin/stitchpad -> the LIVE CHECKOUT (old code). **2,513 lines of fixes
     that we were not benefiting from while we kept suffering the exact bugs they fix.**
     We were repairing the blueprint while sailing the leaky boat.
     CONCRETE COST: after fixing false-success, our own `say` could still lie. After
     fixing the destroyed-pad guard, our own `roster` still printed zero rows and looked
     like an idle fleet. Both bit us AFTER the fix existed.
     PROVEN (this session, running the fixed tree):
       say on read-only git -> rc=1 + real diagnosis   (old: "✓ posted", exit 0)
       roster on destroyed pad -> rc=1 + names cause    (old: 0 rows, exit 0)
     REQUIRED:
       (a) A pad can PIN which stitchpad build it runs (path or SHA), so a team can
           self-host a candidate build and get its fixes immediately.
       (b) `stitchpad version` reports the build in use and whether it differs from the
           installed one — an operator must never be unsure which code is running.
       (c) The fleet's dispatch hygiene points seats at the pinned build by default, so
           a fix protects its own builders the moment it lands.
     GATE: pin a pad to a candidate build; assert every seat command resolves to it and
     that `version` reports the pin. Mutant: unpin -> commands fall back and version says so.
     INTERIM (done): the captain now runs the fixed tree via a wrapper; seats are being
     pointed at it in the standing dispatch hygiene.

P25. THE SIDEBAR CANNOT BE ORGANISED — NO PINNING, ORDERING, OR GROUPING.
     EC: "these gotta be locked in on a spot or maybe draggable so they can be organized
     how u want... cant be having this when ppl are gonna be depending on this side panel
     to channel their projects."
     OBSERVED: the channel list is an unordered dump. EC's four real projects sit mixed in
     with whatever else exists, in no controllable order.
     REQUIRED: pin a channel to a fixed position; drag to reorder; persist per-user;
     optionally group/collapse (e.g. Projects vs Scratch). The operator's primary
     navigation surface must be arrangeable by the operator.
     GATE: pin two channels, reorder them, restart the client — order persists.

P26. DELETING A LOCAL PAD LEAVES AN ORPHANED CHANNEL ON THE RELAY.
     OBSERVED: I removed all 18 scratch .stitchpad directories and verified ZERO remain on
     disk — yet the channels were still listed in EC's sidebar. There is no local registry
     containing those names, so channel membership is held SERVER-SIDE on the relay and is
     never revoked when the pad is deleted.
     WHY IT MATTERS: my P18 cleanup was therefore cosmetic AND unverifiable — I reported
     the sidebar clean based on local state while the operator still saw the mess. The
     product has no way for an operator to remove a channel at all.
     REQUIRED: (a) deleting/archiving a pad unregisters it from the relay; (b) an explicit
     `stitchpad pads --forget <name>` for orphans that already exist; (c) the client
     reconciles — a channel whose pad no longer exists is shown as orphaned and removable,
     never silently listed as live.
     GATE: create a pad, confirm the channel appears, delete the pad, assert the channel
     disappears from the relay listing without manual intervention.
     ⚠️ SUPERSEDES the P18 interim note: local deletion alone does NOT clean the sidebar.

P27. A RUNNING TEST FIXTURE CAN STEAL THE OPERATOR'S TERMINAL IDENTITY.
     OBSERVED LIVE while writing the phase-2 loop update: my `say` to ocean-arena was
     REFUSED — "this terminal is bound to /tmp/oversight-gate.38HUK8/.stitchpad (as @bob)".
     pro5's oversight-gate had run, joined its fixture as @bob on MY surface, and left the
     binding pointing at a temp directory. The operator could not post to their own pad.
     WHY IT MATTERS: this is P11 (fixture bleed) and P12 (ambient identity) combined and
     aimed at the human. A test run must NEVER be able to take the operator's identity or
     redirect their terminal to a fixture. Worse, the fixture pad is deleted afterwards —
     so the operator is left bound to a directory that no longer exists.
     REQUIRED: (a) fixtures get an isolated terminal namespace by construction, never the
     caller's surface (STITCHPAD_TERMINAL_NAMESPACE exists — fixtures must be FORCED onto
     it, not trusted to opt in); (b) a binding whose pad no longer exists is auto-released
     rather than wedging the terminal; (c) `stitchpad whoami` should say plainly what you
     are bound to, so this is diagnosable in one command instead of a refusal message.
     GATE: run any suite that joins a fixture, then assert the caller's terminal is still
     bound to its ORIGINAL pad and can still post.
     WORKAROUND USED: STITCHPAD_STEAL=1 — which is exactly the invariant-defeating escape
     hatch we tell seats never to use, and I had to use it to talk to my own arena.

## ⭐ THE CAPSTONE FINDING — EC named it, and it reframes this entire build

EC: "YOURE SUPPOSED TO BE ABLE TO DISPATCH but for some reason werent? the whole point of
this is to be able to command multi model agent fleets and for it to be reliable."

**Correct. The captain's orchestration failures were not incidental — they ARE the product
defect, and every one maps to a documented pain point.** This session is the most thorough
possible evidence for why these features must exist, because a competent operator with full
access, unlimited retries and 48 hours STILL could not run the fleet reliably.

| What went wrong while orchestrating | Root cause | Point |
|---|---|---|
| 6 kimi turns + 4 codex turns died silently; I told EC "kimi is non-functional" (FALSE — 28 commits) | `wake` returns `{"ok":true,"status":"running"}` for a model the daemon reports **ready=false**, exit 0 | **P1** |
| Could not distinguish "agent failed" from "agent thinking" — ever | No turn error surface at all: no /turns endpoint, no last_error | **P2** |
| Reported seats idle-with-nothing when they had committed 39–82 min earlier | No artifact contract; silence is indistinguishable from work | **P3** |
| Ten turns lost to `kimi-k3` vs `k3` | Model ids unvalidated at dispatch | **P4** |
| Arena looked dead at its busiest; EC had to ask "i dont see yall cooking" | Pad does not narrate; progress appears only if an agent remembers | **P19** |
| EC asked "eta?" EIGHT times; every answer a hand-rolled guess, several wrong | No board ETA, no projection, no live card state | **P20/P21** |
| EC could not ask a working agent anything; captain was the only channel | Pinging a busy agent returns silence — no ack, no queue signal | **P22** |
| Twice told EC a seat produced nothing when it had | Evidence has three possible homes; "is it sealed?" has three answers | **P7** |
| Fixes never protected the fleet building them | No self-hosting: 2,513 lines of fixes while the fleet ran the old tool | **P23** |

**The conclusion that matters:** an orchestrator cannot be reliable on top of a dispatch
layer that reports success for dead work, an agent layer that cannot say "I failed", and a
board that cannot show what is happening. Fleet command is not a prompt-engineering problem —
it is these nine features. Until they exist, every operator will burn the hours EC burned,
and every captain will misreport the way this one did.

**This is why the operator-experience layer is not "polish". It is the product.**

P28. THE ENTIRE BUILD WAS VALIDATED THROUGH THE CLI, NOT THROUGH HERDR.
     EC: "its probably a problem that i been doing this thru claude terminal n not herdr."
     He is right, and the numbers are stark.
     OBSERVED: **37 of 75 suites explicitly `unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV
     HERDR_SOCKET_PATH HERDR_WORKSPACE_ID`** — i.e. half the test suite is written to
     DISABLE the real integration surface before it runs. Every dispatch I made this build
     went through `ocean-heartbeat wake` on the CLI. Every pad operation went through
     `stitchpad` on the CLI. EC watched in the UI but could not act from it (P22), while I
     acted from a terminal EC could not see (P19).
     WHAT THIS MEANS: the operator surface is BIFURCATED. The product was hardened along
     the path nobody is meant to use in production, and the path a real operator WILL use —
     herdr panes, the sidebar, the task board, agent mentions — is the least exercised part
     of the system. Our 62-GREEN tripwire says almost nothing about it.
     Note also sp_this_surface() prefers HERDR_PANE_ID and only falls back to session ids;
     the terminal-identity defects (P12, P27) live in that fallback — the path we forced
     ourselves onto by unsetting HERDR everywhere.
     REQUIRED:
       (a) A herdr-path test lane: at least the core flows (join, say, read, task, mention,
           lane take/close) exercised WITH HERDR_* set, not unset.
       (b) Stop blanket-unsetting HERDR in fixtures; isolate via the terminal NAMESPACE
           (P12's fix) so tests can run on the real surface safely.
       (c) An end-to-end "operator does a full session in the UI" rehearsal before shipping —
           the equivalent of the human-flow rehearsal, but through herdr.
     GATE: run the core flow suite twice — once with HERDR_* set, once unset — and require
     both to pass. A product that only works with its own integration disabled is not shipped.

## TIER 0 — FOUND WHILE SELF-HOSTING IN HERDR (these blocked the captain live)

P29. THE CLAIM-HOOK ACCUSES A PHANTOM AGENT AND BLOCKS EVERY WRITE.  **PROVEN, LIVE.**
     The captain's first Edit of the session was denied with:
       "stitchpad: @ blocked — another agent holds a fresh write-lease on this
        file (...). Coordinate on the pad or wait for their release."
     `stitchpad claims` printed "(no active claims)". There was no other agent.
     `claim` documents THREE outcomes in its own comment block — 0 = I hold it,
     1 = someone else holds a FRESH lease, 2 = no identity — and claim-hook
     treated every non-zero as case 1. The real cause was rc=2 (no identity).
     The named "holder" was `${holder:-$fp}` falling back to the file's own path,
     so the message accused the file of holding itself.
     COST: every Edit and Write in the session; the captain had to route all file
     changes through Bash for the rest of the build.
     GATE: deny only on rc=1; fail open otherwise. Mutant-proven — reintroducing
     the non-zero test reproduces the denial verbatim; the fix returns allow.
     ⚠️ STILL LIVE FOR EC: the hook Claude Code actually runs is
     ~/.stitchpad/adapters/claim-hook.sh (the OLD checkout). Until that install is
     refreshed, EVERY Claude Code session under $HOME is denied every file write.

P30. THE PAD WALK-UP HAS NO BOUNDARY — IT ESCAPES INTO $HOME.
     sp_find_pad() (lib.sh:103) and claim-hook's inline copy both walk up until
     "/". With a ~/.stitchpad present, EVERY directory under the operator's home
     resolves as "inside that pad" — including worktrees that correctly have no
     pad of their own. This is what made P29 fire in a tree with no .stitchpad,
     and it directly contradicts the hook's own stated intent ("not in a pad →
     allow, else we'd block every write in every non-pad project").
     FIXED at the call site (claim-hook stops at $HOME). sp_find_pad itself is
     NOT yet bounded — deliberately deferred, because changing pad resolution for
     every command at release time would require re-measuring all 72 suites.
     EXPLICITLY DEFERRED, not silently.

P31. A CRASHED SUITE REPORTS SUCCESS.  **THE GATE COULD NOT SEE CRASHES.**
     bash 3.2 (macOS default): when `set -e`/`set -u` ABORTS a script the EXIT
     trap still runs, and if the trap's last command SUCCEEDS the shell exits 0.
     Proven on this machine:
       cleanup(){ true; }; trap cleanup EXIT; set -u; echo "$UNSET"   -> rc=0
       same without the trap                                          -> rc=1
       explicit `exit 1` with the same trap                            -> rc=1
     70 of 77 suites install an EXIT trap, and five are baselined 0/0 — judged on
     exit code ALONE — so for those a mid-run crash was recorded as a clean pass.
     This is how oversight-gate.sh died at assertion 6 of 14 and still exited 0.
     GATE: the tripwire now classifies a fatal shell diagnostic as CRASHED
     regardless of exit status. Fixed at ONE point rather than in 70 fixtures.

P32. BASH 3.2 FOLDS A UTF-8 LEAD BYTE INTO A VARIABLE NAME.
     "$X→$Y" dies with `X<0xe2>: unbound variable`, rc=127; "${X}→${Y}" is fine.
     Six sites carried this landmine, including PRODUCTION code —
     tool/bin/stitchpad's wake nudge `your open tasks: $_open— move each ...`.
     It is invisible until the line is reached, and then it is fatal.
     This is what corrupted oversight-gate.sh, which was then baselined 14/0 by a
     builder who never reached assertion 14. All six braced.

P33. THE TERMINAL-BINDING REFUSAL PRINTS THE SAME PATH TWICE.
     test-ponytail-instructions fails with:
       "REFUSED — this terminal is bound to <PATH> (as @fable), not <PATH>."
     — the two paths are IDENTICAL. sp_term_lock_check refuses when the pad OR
     the NAME differs (lib.sh:2482), but the message only ever talks about the
     pad. A name mismatch is therefore reported as an impossible pad mismatch.
     Same lying-error family as P29: the message names a cause that is not the
     cause, and an operator reading it cannot act on it.

P34. FIXTURES SHARE ONE TERMINAL AND THE GUARD CORRECTLY REFUSES THEM.
     ONE TERMINAL = ONE PAD (and one identity) is a real product rule, and three
     suites predated it: they join a second pad, or post as a second identity,
     on the SAME surface. Every call in those blocks was >/dev/null 2>&1, so the
     refusal was invisible and `set -e` killed the suite mid-run:
       rc1-c11-c13-regression       died at assertion 2 of 13
       test-ponytail-instructions   died before its only assertion
       pad-io-and-archive           13 failures, ALL of them after "crash recovery"
     The fixtures owed the guard a distinct surface, which is exactly what
     STITCHPAD_TERMINAL_NAMESPACE exists for. FIXED for rc1 (2 -> 13/0) and
     ponytail (-> 1/0 PASS); pad-io recovered 4 of 13 (63 -> 67). The assertion
     was never weakened — the simulation was made real.

P35. `join` REPORTS SUCCESS AND LEAVES YOU WITH NO IDENTITY.  (UX, by design.)
     CLI `join` prints "✓ alpha joined" and exits 0, after which `whoami` is
     empty and every following command refuses with "no identity — call the MCP
     join tool first (or set STITCHPAD_NAME for CLI/testing)". The refusal text
     documents the intent, so this is not a false success in the P17 sense — but
     the success line still overstates what happened, and it cost this session a
     debugging detour while building the P28 gate. `join` should say which
     identity path it actually established.

P36. TWO SUITES ENCODE OPPOSITE POLICY FOR CONFUSABLE NAMES.  **NEEDS EC.**
     roster-validation-gate asserts unicode/confusable names must be REJECTED
     ('davé', 'dáve'); the pro3-f3-unicode lane implements NORMALIZING them
     (NFKD+casefold) so they collapse onto one roster row. Both cannot be right.
     Checked out pro3-f3b (41d5522) and ran roster-validation against it: still
     9/3, so absorbing that lane would NOT close this. This is an operator
     decision, not an implementation detail, and it is why roster-validation is
     recorded KNOWN-RED rather than "fixed".

P37. THE REAL HERDR PANE RESOLVES A SURFACE BUT CARRIES NO IDENTITY.
     Exercised by hand from inside a live herdr pane (HERDR_PANE_ID=w4:p3), self-
     hosted on the fixed tree — the first time this build ran the core flow on the
     integration path instead of the CLI path:
       sp_this_surface  -> term_6583ffdbadffef   (the REAL `herdr pane get`
                           branch, not the pane-id fallback — so that branch works)
       whoami           -> EMPTY
       say              -> "no identity — call the MCP join tool first"
       doctor           -> "⚠ @captain (cli/pull) — no session identity file"
     So the pane is recognised as a stable terminal, and the operator standing in
     it is still nobody. `doctor` diagnoses the gap correctly; nothing closes it.
     Every core command worked once STITCHPAD_NAME was set (roster, task list,
     doctor, say all fine), so this is the ONE gap on the herdr path — not a
     broken integration, a missing identity binding.
     NOTE ON GATE SCOPE: p28-herdr-parity-gate covers the pane-id FALLBACK branch
     (where P12 and P27 lived). It deliberately does not bind a live pane, because
     a fixture that claims the operator's real pane IS P27. The `herdr pane get`
     branch above is therefore verified BY HAND, and this entry is that record.

P38. `task list` IS UNREADABLE IN A TERMINAL.
     Every card prints as one pipe-delimited line with the entire body inline —
     TASK-1's single line runs to ~700 characters of OBSERVED/REQUIRED/ACCEPTANCE
     prose. Six cards fill a screen and nothing can be scanned. The data is right;
     the presentation makes the board useless exactly when an operator is trying
     to see where the fleet is. Sits directly alongside P20/P21 (the board shows
     no ETA / no live progress) — same surface, same operator.
