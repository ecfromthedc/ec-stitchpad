# GOAL PROMPT V4 — DOGFOOD TO THE FINISH LINE
# Authored by the captain at fix tip b06cc54. This supersedes every prior goal prompt.
# EC: "using the thing and building away your problems and implementing them until we're done."

## THE MISSION
Use stitchpad for EVERYTHING between now and the finish line. Not as a formality —
as the bug-finding method. Every command you run through it is a probe. Every moment
of friction is a defect that a real operator will hit. **Find every last pain point and
BUILD IT AWAY.** We are turning an arena we merely survived into one that is a pleasure
to run.

## THE LOOP (non-negotiable)
1. **DO THE WORK THROUGH STITCHPAD.** Coordinate with `say`. Track with `task new|list|move|edit`.
   Check membership with `roster`. Read with `read --new`. Seal with evidence commands.
   If you would normally reach for a raw shell/git equivalent, use the stitchpad path
   FIRST and note what was worse about it.
2. **THE MOMENT SOMETHING IS AWKWARD, IT IS A DEFECT.** Slow, confusing, silent, wrong
   default, missing verb, unclear error, needs a workaround, made you check twice — all
   count. Do not push through it. **File it: `stitchpad task new "<Pn> <symptom>"`.**
3. **FIX IT PROPERLY.** Product change + a MUTANT-PROVEN gate: reintroduce the defect,
   the gate must go RED. A mutation that does not APPLY is INCONCLUSIVE, never a pass.
4. **BASELINE IT.** Add the suite to test/suite-baseline.txt — the tripwire REFUSES
   unbaselined suites, so an ungated gate cannot exist.
5. **COMMIT IT.** Uncommitted work does not exist. This build nearly lost 7 gates that way.
6. **CLOSE THE CARD** with `task move <id> done` and say one line on the pad.

## HARD RULES (each one is a scar from this build)
- **NEVER a bare `pkill`.** Kill only PIDs you recorded. It SIGKILLed the captain 3x
  and manufactured 17 phantom regressions.
- **NEVER touch** /Users/ecfromthedc/dev/tools/stitchpad-md or ~/.stitchpad.
- **NEVER leave a scratch pad behind.** A worktree that becomes a channel is a defect
  (P18) — EC's sidebar is for EC's projects only.
- **NEVER patch a gate to make it pass.** Fix the simulation, never weaken the assertion.
- **NEVER report a seat idle without checking artifacts** — silence is not evidence.
- macOS has NO `timeout`; cap waits in bash. Any run containing 'mkdtemp failed' is VOID.
- Measurement runs ALONE. Contention manufactures regressions.

## MODELS THAT ACTUALLY WORK (verified by output tonight)
- `deepseek-v4-pro`   — builders, fixes, hard reasoning
- `deepseek-v4-flash` — recon, attacks, verification sweeps
- `k3`                — Kimi; the ONLY non-deepseek eye. NOTE: the id is `k3`, NOT
                        `kimi-k3` (that one is ready=false and dispatch dies silently — P1).
- DO NOT USE: codex/gpt-5.6-* (ready=true but produces nothing), glm (out of tokens).

## DEFINITION OF DONE
1. Every pain point in OPERATOR-PAIN-LEDGER.md is either FIXED+GATED or an explicit,
   named, EC-visible deferral. No silent carry-overs.
2. All suites GREEN and the real `regression-tripwire` exits 0 against filled baselines.
3. Zero scratch channels in EC's sidebar.
4. A fresh operator can run this arena for an hour and hit NOTHING that needs a workaround.
5. PR updated with the honest scorecard: what was broken, what is fixed, what is deferred.

## THE STANDARD
EC has run this for 48 hours. Every hour of that surfaced something. The measure of
success is not "the tests pass" — it is **"the next person does not have to suffer what
EC suffered."** Every fix must remove a category of pain, not an instance of it.


## SELF-HOSTING (added after EC's "patch the hole in the boat" question — P23)
**Every seat runs the FIXED tree, not the installed one.** A fix that does not protect its
own builders is a fix we keep re-suffering. In every lane:
    export STITCHPAD_HOME=/Users/ecfromthedc/dev/agents/stitchpad-wt/fix/tool
    export PATH=/Users/ecfromthedc/dev/agents/stitchpad-wt/fix/tool/bin:$PATH
    # and NEVER call ~/.stitchpad/bin/stitchpad — that is the OLD live checkout
If a pad command behaves badly under the fixed tree, that is a REGRESSION WE JUST SHIPPED
and it outranks whatever lane you are on: stop, file it, fix it.
