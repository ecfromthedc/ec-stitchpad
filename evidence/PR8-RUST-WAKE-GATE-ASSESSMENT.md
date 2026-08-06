# PR #8 (`feat/rust-wake-gate`) — assessed, and deliberately NOT merged

Date: 2026-08-06. Assessed against master `b52ea76` (+ the tripwire width fix).
Branch head: `a0d7ce9`, 13 commits.

**Decision: leave it out of master for now.** Not because it is bad work — it is
better than expected — but because one measurement says it is not
interchangeable with master's wake gate, and the wake gate is the component
whose failure mode is silence.

## What was actually run

Everything below is execution, not inspection.

**It builds, and it is genuinely lean.** Zero dependencies (`Cargo.lock` is 7
lines), edition 2024:

    $ cargo build --release
       Compiling wake-gate v0.1.0
        Finished `release` profile [optimized] target(s) in 0.45s

**Its own goldens pass, both ways.** 8 corpora — 7 synthetic plus a 413-line
capture of a live `campaign-hub` pad:

    $ STITCHPAD_HOME=./tool bash test/golden/run-all.sh          # awk oracle
      8 checked, 0 failed
    $ PASTURE_RUST_GATE=1 STITCHPAD_HOME=./tool bash test/golden/run-all.sh
      8 checked, 0 failed

**And the Rust path is really being exercised** — this is the check that matters
in this repo, because "8 checked, 0 failed" is exactly what a dead code path also
prints. `sp_engagement` falls through to awk when the binary is missing *or
exits non-zero*, so a green run proves nothing on its own. Replacing the binary
with one that prints garbage and exits 0:

    $ printf '#!/bin/sh\necho "WRONG-MUTANT-OUTPUT"\nexit 0\n' > .../wake-gate
    $ PASTURE_RUST_GATE=1 ... bash test/golden/run-all.sh
      8 checked, 8 failed

The mutant applies. The port is byte-compatible with **the branch's** awk oracle
across all 8 corpora, and that is a real result.

## The blocker

The goldens were characterized against the branch's `lib.sh`. Master's
`sp_engagement` has moved since. Running the branch's goldens against **master's**
oracle:

    $ STITCHPAD_HOME=<master>/tool bash run-all.sh
      8 checked, 1 failed

`synthetic/broadcast.md` — alice posts `@all`, bob posts `@all`, charlie replies
`@bob @alice`. For seat `charlie`, `since=0`:

    branch oracle:  1 alice 3 bob     <- mention #1 (alice's @all) is PENDING
    master oracle:  0        3 bob    <- nothing pending

Master holds that charlie's block-3 reply, which addresses `@alice`, answers
alice's broadcast. The branch holds that it does not, and would wake charlie
again about a broadcast it has already responded to.

I have not adjudicated which is correct, and deliberately did not re-bless either
side. Master's reading is the more recently reasoned one — master carries
Regression 14 ("per-sender reply ledger must not mask later mentions") and the
`--peek-ordinal` anchoring — but "more recent" is not proof.

What is certain is that **the Rust binary is byte-compatible with the branch's
gate, not with master's.** Merging it as-is would put a second, subtly different
wake oracle behind an env flag in a system whose expensive failure is a seat that
never gets woken — or gets woken twice for the same message.

## What master already has from this branch

The bash-side fixes are not lost by leaving the merge out. They were absorbed
into master earlier:

  - Regression 14 — present, `test/wake-regression.sh:675`
  - `--peek-ordinal` oracle — present, `tool/bin/stitchpad:3399-3576`
  - `sp_recover_inplace` truncation race — master no longer has the truncating
    `cat "$ready" > "$target"` at all; it moved to owned generation directories
    with ownership validation, a roster-transition guard and quarantine
    (`sp_apply_ready_generation`), using the same `conv=notrunc` cure inside a
    stronger contract.

So the merge would contribute the Rust crate, the golden harness, and
`docs/GATE_*_PROMPT.md` — and would drag its older `ocean.sh` / `lib.sh` /
`stitchpad` / `wake-regression.sh` sides into conflict with master's newer ones
(5 conflicting files).

## What would land it

In this order — each step is cheap, and the first one may resolve the rest:

1. Re-characterize the goldens against **master's** awk oracle and diff them
   against the committed `.tsv`s. Exactly one corpus disagrees; decide, with a
   written argument, whether charlie should be re-woken by an `@all` it has
   already replied to. That answer is worth having regardless of the port.
2. Land the golden harness on master FIRST, on its own, as a bash-only
   characterization gate. It has value with no Rust in the tree at all, and it
   pins the oracle's behaviour before anything reimplements it.
3. Then port the crate on top and require both oracles to agree on the
   master-blessed goldens, with the garbage-binary mutant above kept as a
   permanent assertion that the Rust path is live.
4. Register `test/golden/run-all.sh` in `test/suite-baseline.txt`. Note the
   tripwire's meta-gate only globs `test/*.sh`, so files under `test/golden/`
   are invisible to it today — the harness would be an ungated gate, which is
   the thing the meta-gate exists to prevent.

Until step 1 is answered, this stays out.
