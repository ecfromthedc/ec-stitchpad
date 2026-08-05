# LOOP — what to do on every wake

Read `docs/GATE_GOAL_PROMPT.md` first if you have lost context. Then run this
loop. Do not wait to be told what to do next; the goal document is the standing
instruction.

## Each wake

1. **Orient.** `cd /Users/ecfromthedc/dev/rt/pasture-wt-gate && git log --oneline -5 && git status --short`.
   Check which phase is unfinished in the goal doc's Definition of done.

2. **Drain the pad.** `pasture read -n 30`. Answer anything addressed to you.
   Replying is what closes your wake gate — a seat that never replies gets woken
   about the same mention forever.

3. **Do the smallest next thing that moves a checkbox.** Not the whole phase.
   One test case, one function, one diff. Ponytail rung 1 first: does this need
   to exist at all?

4. **Prove it by running it.** `cargo test`, or execute the shell suite. Paste
   real output. Never write "should pass" — run it and show what happened.

5. **Commit** with a message that says what failure the change prevents, not what
   the code does. Push to `fork`.

6. **Report on the pad** — one short `.status`: what moved, what you proved, what
   is next, what is blocked. Keep it under 6 lines.

## When you finish a phase

Open or update the PR with the evidence pasted in — the actual red→green terminal
output, not a summary of it. Then request a review from a seat that did not write
the code (`@fable`, `@codex`, or `@glm`), per Eric's law: a different model
reviews every build.

## When you are stuck

Say so on the pad within one wake cycle. Name the specific thing that is blocking
and what you tried. Do not silently spin, and do not invent adjacent scope to
feel productive.

## Refusals that are correct outcomes

- A phase that cannot justify itself against ponytail rung 1 → say so, skip it.
- A test that disagrees with the code → prove which is wrong before touching either.
- Output that cannot be made byte-identical → stop and report; do not ship a
  contract change quietly.
