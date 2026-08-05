# GOAL — port the pasture wake gate to Rust, behind a golden harness

You are the implementing seat. This document is your standing goal. It does not
change between wakes. `docs/GATE_LOOP_PROMPT.md` tells you what to do on each wake.

**Worktree:** `/Users/ecfromthedc/dev/rt/pasture-wt-gate`
**Branch:** `feat/rust-wake-gate` (based on `origin/master` + the proven bash fix)
**Upstream:** `Risingtides-dev/pasture`. You have READ only — push to the `fork`
remote (`ecfromthedc/pasture`) and open PRs from there.

---

## Why this exists

The wake gate decides whether an agent has an unanswered mention. It is ~300
lines of shell whose load-bearing half is two `awk` programs. In one audit on
2026-08-04 it produced three separate defects of the same family — *comparing
the wrong thing and treating the result as certain*:

1. `claim-hook` read "no identity" (exit 2) as "another agent holds the lease",
   denying every write by every identity-less session in a pad. (PR #6)
2. `seat-keeper` read `count.<seat>` — a cumulative total nothing maintains — as
   a backlog depth, burning ~570 paid model turns waking seats with no work while
   the one seat that needed waking starved. (PR #6)
3. `sp_engagement` compared the **newest reply** against the **oldest mention**,
   so replying to someone once made a seat **permanently deaf to everyone**.
   Four of six live seats were in this state. (PR #7 — already fixed in bash)

Defect 3 is fixed in bash and is the reference semantics. Your job is to make
this logic *typed and tested* so the fourth defect of this family cannot ship.

---

## Ponytail — how you write code here

`tool/instructions/ponytail.md` is canonical and applies to every line you write.
Before writing code, understand the request, read the code it touches, and trace
the real flow end to end. Then stop at the first rung that holds:

1. **YAGNI: does this need to exist?**
2. Reuse the codebase's existing helper, utility, or pattern.
3. Use the standard library.
4. Use a native platform feature.
5. Use an already-installed dependency.
6. If one line is clear and correct, use one line.
7. Only then write the minimum code that works.

Fix root causes, not one symptom. Prefer deletion over addition, boring over
clever, no unrequested abstractions, no avoidable dependency, the fewest files.

Never simplify away understanding, trust-boundary validation, error handling that
prevents data loss, or security. When two equally small choices exist, choose the
edge-case-correct one.

**Rung 1 applies to this whole project.** The bash fix already works. You are
adding types and tests, not features. If a phase below cannot justify itself
against rung 1, say so on the pad and skip it — that is a correct outcome, not a
failure.

### Reuse already found for you — do not rebuild these

- **`test/wake-regression.sh`** exists on `master` with 6 cases and a working
  fixture harness. **Extend it. Do not write a new harness.**
- **`probe-ponytail.sh`** (in `~/dev/agents/stitchpad-wt/`) is the established
  pattern for running a *frozen* test suite against an *arbitrary* tool revision
  in a hermetic `env -i` sandbox. That is your golden-harness shape.
- **`tool/tui-rs/`** is an existing Cargo project (edition 2024, ratatui). Reuse
  its workspace/toolchain conventions rather than inventing a new crate layout.
- `archive.sqlite` in a live pad holds real historical pad text — a free corpus.

---

## Phases

### Phase 0 — the regression that should have caught defect 3 (do this first)

`test/wake-regression.sh` has six cases and **none of them catch the deafness
bug**, because Regression 2 only asserts that a reply *does* clear a mention. It
never re-asks afterwards.

Add a case: `alice→bob`, `bob→alice`, `alice→bob` ⇒ bob must have a pending
mention. Also add: a reply to one sender must not clear another sender's mention.

**Prove it red before you prove it green.** Run the new case against *pristine*
`origin/master` (`git stash`, or a `git archive` sandbox like `probe-ponytail.sh`
uses) and show it FAILS. Then show it passes on this branch. A test you never
watched fail is not evidence.

Push to `fork` and comment the red→green output on **PR #7**.

### Phase 1 — the golden harness

A script that, for every seat in a pad and every `since` value that matters, runs
the **bash oracle** and the **Rust oracle** and diffs the 4-field output. Corpus:
`test/` fixtures plus real pad history from `archive.sqlite`.

This is the safety rail for Phase 2. It must exist and be green *before* any
swap. Reuse the `probe-ponytail.sh` hermetic-sandbox shape.

### Phase 2 — the Rust gate

A small binary the existing bash shells out to. Not a rewrite of pasture.

- Input: pad file path, seat name, `since`.
- Output: **byte-identical** to `sp_engagement` — `<ordinal> <sender> <last_reply> <reply_target>`, one line.
- Types are the point: make defect 3 unrepresentable. A mention's answered-ness
  is a property of the mention, resolved against a per-sender reply ledger.
- Must reproduce exactly: fenced-code exclusion, inline-code stripping,
  self-authored skip, silent-ack word list (agents only), `@all` broadcast,
  handle-boundary matching, and FIFO ordering.
- 12 call sites and 9 adapters consume this. Do not change the output contract.

Swap only behind the harness, and only with `sp_engagement` retained as a
fallback path.

---

## Hard rules

- **Never touch a live pad.** `campaign-hub-rust-rebuild/.stitchpad/` is a running
  fleet. Read `archive.sqlite` if you need corpus; copy it out first. Never `say`,
  `wake`, or write state there.
- **Execute, never infer.** `cargo check` is not evidence; only `cargo test` is.
  `bash -n` is not evidence; only a run is.
- **Never make an assertion match output.** If a test disagrees with the code,
  prove which one is wrong before changing either. On this repo, the code has
  been right more often than the test.
- **Byte-compatible output or it does not ship.** 9 adapters parse this.
- One concern per PR. Push to `fork`, PR into `Risingtides-dev/pasture:master`.
- If you are blocked or the goal looks wrong, say so on the pad rather than
  inventing scope.

## Definition of done

- [ ] Phase 0 regression merged into `test/wake-regression.sh`, shown red on pristine master and green here
- [ ] Golden harness runs bash-vs-Rust over the fixture + archive corpus, zero diffs
- [ ] Rust gate passes the full existing `test/wake-regression.sh` unchanged
- [ ] A cross-model review by a seat that did not write the code (Eric's law)
- [ ] PR open with the red→green evidence pasted in, not summarised
