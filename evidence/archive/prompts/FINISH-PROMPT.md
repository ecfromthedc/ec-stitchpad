# FINISH IT — no open items, no caveats, green light or a stated reason why not

You are closing out ec-stitchpad. The operator has been on this five days and
needs completion today. Partial is not acceptable; neither is pretending.

## Definition of done — every line must be true and PROVEN BY EXECUTION

1. `/bin/bash tool/bin/regression-tripwire` exits 0, 0 quarantined.
2. Every one of the 33 findings in `evidence/reviews/` has a VERDICT recorded in
   `evidence/REVIEW-FINDINGS-TRIAGE.md`: FIXED, ALREADY-FIXED, NOT-A-DEFECT, or
   WONT-FIX-WITH-REASON. Zero entries may say "not re-verified".
3. Every seat on every live pad can actually be woken, or is removed from the
   roster with the reason recorded. No seat may sit quarantined and unexplained.
4. `master`, `fix/macos-arena`, `captain-dogfood-v4` identical, pushed to the
   fork, and the live install fast-forwarded to the same sha.
5. First-run works from an empty directory via the LIVE install.

## Rules — these are scars, not preferences

- Never `git add -A`. Add by path. `tool/keeper.conf`, `tool/relay/state/`,
  `wrangler.*.toml` are machine-local and some carry credential-shaped lines.
- Never check out a different branch in `/Users/ecfromthedc/dev/tools/stitchpad-md`.
  Fast-forward the SAME branch only.
- Never bare `pkill`. Kill only pids you captured.
- No stray `test/*.sh` — an unregistered suite fails the ENTIRE gate. Every new
  suite goes in `test/suite-baseline.txt`.
- Run verification under `/bin/bash` explicitly; the interactive shell is zsh and
  will mangle `$b:$b` refspecs via its `:r` modifier.
- macOS has no `timeout`. Cap waits with `perl -e 'select(undef,undef,undef,N)'`.
- Do not edit `tool/` or `test/` while the tripwire is running — it reads the
  working tree directly and the run becomes meaningless.

## Method — non-negotiable

- **Prove by execution.** An unrun claim is a hypothesis. Paste the command and
  its real output.
- **Measure the base rate before calling anything broken.** 5+ runs for anything
  intermittent, and state the rate.
- **Never weaken an assertion to make a gate pass. Fix the simulation.**
- **A mutation that does not APPLY is INCONCLUSIVE, never a pass.** Every fix
  needs a mutant proving its gate can actually fail.
- **Reports success while doing nothing is the top bug class**, above features.
  That includes your own guards: verify the guard fires, not just that it exists.
- A finding is not real because a review says so. Verify it yourself. If it is
  not a defect, say so and say why — closing a false finding is finishing it.

## Order of work

1. Live seats first — the fleet is the product. A seat that cannot be woken makes
   everything else theoretical.
2. Then the findings, cheapest-to-verify first, so the count drops fast and what
   remains is the genuinely hard work.
3. Gate, ship, green light.

## The green light

State it explicitly at the end: GREEN or NOT GREEN. If NOT GREEN, name the exact
blocking item in one sentence. Do not hedge, do not pad it with caveats that are
not blocking, and do not call something done that you did not run.
