STEP 0, RIGHT NOW, BEFORE READING FURTHER — run exactly this, substituting YOUR
artifact path from the SEAT section at the bottom:

    printf '# <seat> review\n\n(started)\n' > <YOUR ARTIFACT PATH>

That file is your ONLY output. Text you print in chat is discarded and nobody
will ever read it. APPEND to the file as you go, finding by finding. If your turn
ends early, whatever is in that file is all that survives — so write each finding
down the moment you have it, not at the end.

# THE JOB: adversarial end-to-end review of stitchpad/pasture

Tree: **/private/tmp/wt-merge** (branch pushed as ecfromthedc/pasture@master).
The operator is about to rely on this daily. Your job is to find what will bite
them — not to admire it.

## What this system is
A markdown file is the chat room. Agents are rows in a ```roster fenced block
inside it (`name | adapter | wake | target`). Someone writes `@dale do X`; a
watcher notices the file changed and pokes dale's AI session with that message;
dale writes back into the same file. `wake` is `pull` (agent polls) or `push`
(watcher dispatches). Everything else is operations around that idea.

Read: `tool/bin/stitchpad`, `tool/bin/lib.sh`, `tool/bin/watch.sh`,
`tool/bin/seat-keeper.sh`, `tool/adapters/*.sh`, `tool/bin/regression-tripwire`,
`evidence/OPERATOR-PAIN-LEDGER.md` (P1–P48 — read this FIRST, it is the list of
everything already known and fixed; do not re-report those).

## The failure CLASS that matters here
Not style. Not "could be cleaner". The thing that has cost this project the most
is **silence**: a seat that produces nothing looks identical to one that is
working. Hunt for:
1. Any path where a message/turn/wake is consumed, acked or cursor-advanced
   WITHOUT the agent receiving it.
2. Producer and consumer computing the SAME path differently (this shipped twice:
   `role.<name>` written vs `runtime.<name>` read; `help` printing a hardcoded
   line range that hid six commands).
3. Failures that exit 0, successes that exit non-zero, or output that contradicts
   the exit code.
4. State written but never read, or read but never written.
5. Guards that silently no-op when a variable is unset.
6. Anything an orchestrator cannot observe: running vs hung vs dead vs
   finished-and-lost.
7. **A first-run experience that fails.** Pretend you are a new operator with
   nothing set up. `init`, `join`, `say`, `read`, `lanes`, `watch start`. Does it
   work? Are the error messages actionable? What is confusing?

## RULES — this project's standard, and it is strict
- **PROVE every finding by EXECUTION.** Paste the command and its REAL output.
  A finding you did not run is a hypothesis, and hypotheses are worthless here —
  this build has lost hours to plausible-but-wrong claims.
- If you cannot reproduce it, mark it **UNPROVEN**. That is a fine answer.
- **Measure the base rate before calling something broken.** An intermittent
  failure needs 5+ runs before you claim anything. This exact mistake was made
  three times in one session.
- Never weaken an assertion to make a gate pass. Fix the simulation, not the test.
- Work in your OWN temp dirs. Do NOT edit /private/tmp/wt-merge, do not commit,
  do not push. Propose fixes as diffs inside your artifact.
- NEVER touch ~/.stitchpad, ~/.pasture, or /Users/ecfromthedc/dev/tools/stitchpad-md
  — that is the operator's LIVE install.
- Never run pkill. Kill only PIDs you captured yourself.
- macOS has NO `timeout`. Cap every wait with perl: perl -e 'select(undef,undef,undef,N)'
- Run verification under /bin/bash explicitly.

## FORMAT — append one block per finding, most severe first
    ## F<n> — <one-line title>
    SEVERITY: LOSES-WORK | WASTES-TIME | CONFUSING | COSMETIC
    FILE: <path>:<line>
    WHAT HAPPENS: <the observable wrong behaviour>
    PROOF:
      $ <command you actually ran>
      <its real output>
    FIX: <specific enough to apply — a diff if you can>

End with: `TOTAL: <n> findings, <m> proved by execution`.
If a category is clean, say so explicitly. A short honest file beats a padded one.


## ONE MORE RULE
NEVER leave a file behind in the repo tree. If you must place a scratch script under
test/ so that $ROOT resolves, name it `test/.zz-scratch.sh` (dot-prefixed, so the
release gate glob ignores it) and delete it when you are done. A stray test/*.sh
file makes the release gate refuse the ENTIRE run as an unregistered suite.
