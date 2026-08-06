# ec-stitchpad — where the build actually is

The close-out session took the WONT-FIX-TODAY list to zero. Read
`evidence/REVIEW-FINDINGS-TRIAGE.md` FIRST: all 33 review findings have verdicts
and nothing is left open. Do not re-litigate NOT-A-DEFECT entries without new
evidence — and note that two of them were PROMOTED to real defects on new
evidence, so the reverse is also fair game.

## The rules, unchanged — every one is a scar

- **Never `git add -A`.** `tool/keeper.conf`, `tool/relay/state/`,
  `wrangler.*.toml` are machine-local and some carry credential-shaped lines.
- **Never check out a different branch in `/Users/ecfromthedc/dev/tools/stitchpad-md`.**
  That tree is the live install; a launchd job runs the keeper from it every
  120s. Fast-forward the SAME branch only. Work in a `git worktree` elsewhere.
- **Never bare `pkill`.** Kill only pids you captured and identified.
- **No stray `test/*.sh`** — an unregistered suite fails the ENTIRE gate.
- **Do not edit `tool/` or `test/` while the tripwire is running.** It reads the
  working tree directly. Each full run is ~25–35 minutes.
- Run verification under `/bin/bash`; the interactive shell is zsh and mangles
  `git push fork "$b:$b"` and heredocs containing parentheses.
- macOS has no `timeout`. Cap waits with `perl -e 'select(undef,undef,undef,N)'`.
- `$?` after a pipeline is the LAST command's status.

## METHOD — it caught three defects in the last session's own work

1. **Prove by execution.** An unrun claim is a hypothesis.
2. **Measure the base rate before calling anything broken.** 5+ runs for
   anything intermittent, and state the rate. When a suite fails only in the
   full run, test the PRISTINE tree under the same load before blaming your
   changes — that is what separated a real regression from pre-existing load
   sensitivity last time.
3. **Never weaken an assertion to make a gate pass. Fix the simulation.**
4. **A mutation that does not APPLY is INCONCLUSIVE, never a pass** — and a
   mutant that SURVIVES for a reason you did not intend is worse than no mutant.
   One survived last session only because a length cap truncated inside an
   unbalanced backquote, so the shell refused to parse the line.
5. **"Reports success while doing nothing" is the top bug class** — including
   your own guards. Its mirror image, reporting FAILURE while succeeding, is
   just as expensive: it makes an operator retry work that already landed.
6. **Check a finding's premise, not just its symptom.** The k3 F1 fix was built
   on "there is no supervisor", which is false — `tool/bin/daemon.sh` is one.
   The full-tree gate caught it. Reviews are evidence, not gospel.

## OPEN — found and written up, not fixed

1. **`watcher-races.sh` is load-sensitive, and the fragility is in the PRODUCT.**
   Passes 5/5 standalone; fails inside a full tripwire run and under synthetic
   CPU load at `fail "ensure-watcher cancelled or replaced the live supervisor
   gap"`. The pristine pre-session tree fails identically under the same load,
   so this is not a regression — a concurrent `stitchpad` command can cancel a
   live supervisor's generation during the daemon's 2-second restart gap when
   the machine is busy. The assertion is CORRECT. Do not widen the budget to
   hide it; make the liveness evidence robust under load.
2. **`set-wake` prints "failed to bind" after successfully binding.** Observed
   live: `set-wake glm push <sid>` printed the failure, and an immediate
   `bind-session` said `already bound (no-op)`. False-failure report.
3. **`delivery_start_worker`'s 5s ownerless-lock grace returns WITHOUT
   spawning**, so a fresh delivery generation can wait for the next enqueue.
4. **UNPROVEN, and do not repeat it as fact:** `say` under contention with the
   live watcher printed a rollback-shaped warning while the message LANDED —
   four copies of one ping on `#campaign-hub-rust-rebuild` at 02:18 PM. Only the
   first line of each run was captured, so the exit code is unknown. Establish
   the rc FIRST: rc=0 means a wording problem, rc!=0 means a false-failure
   report that costs a duplicate post on every retry.

## Fleet state

All four ocean seats on `#campaign-hub-rust-rebuild` wake AND answer, verified
by execution, not by the join succeeding:

- **codex** — restored. Session `c33c4ffd-0c4b-4916-aaf5-d5696d9abaf9`,
  `gpt-5.6-sol`. It was NOT a stale session: the `openai-codex` block in
  `~/.config/ocean-rs/auth.json` had been REVOKED server-side while still in
  date (expires Aug 10), and its refresh token was dead too
  (`refresh_token_invalidated`). Ocean's auto-refresh is expiry-driven, so it
  never fired, and `resolve_codex_auth` prefers that block over the
  `~/.codex/auth.json` fallback whenever it is present-and-unexpired — a
  revoked-but-in-date block permanently shadows a working credential. Fixed by
  refreshing `~/.codex/auth.json` (its session was alive) and removing the dead
  ocean block; both files backed up. **This is an ocean-os finding**: treat a
  401 `token_invalidated` as a reason to re-resolve, not only `expires`.
- **kimi** — alive, replied `k3`. NOTE: `/v1/models` reports `kimi-k3`,
  `kimi-k2.6`, `kimi-k2` as `ready=false`; those are the METERED Moonshot models
  and the fleet does not use them. The seat is pinned to `k3`, which resolves to
  `ProviderId::KimiCoding` (the subscription endpoint), whose credential is
  present. Do not "fix" the seat by repinning it to `kimi-k3`.
- **deepseek** — alive, replied `deepseek-v4-pro`.
- **glm** — alive after a fresh session (`b51969e5-9d6a-491b-88a0-c16d48824375`).
  Its old session had 100 turns and completed turns WITHOUT posting; a new
  session answered immediately. A saturated session is a silent-seat cause worth
  checking early.
- **fable** — herdr terminal seat; only fires with a pane open. Expected.

## DONE means

1. `/bin/bash tool/bin/regression-tripwire` exits 0, 0 quarantined.
2. Every finding in `REVIEW-FINDINGS-TRIAGE.md` still has a verdict, and the
   OPEN list above is either closed or carried forward with fresh evidence.
3. Every seat on every live pad wakes and answers, or is off the roster with the
   reason recorded.
4. `master`, `fix/macos-arena`, `captain-dogfood-v4` identical, pushed, and the
   live install fast-forwarded to that sha.
5. First-run from an empty directory works via the LIVE install: `init`, `join`,
   `say`, `read`, `lanes`, `watch start`, clean `watch stop`, no leaked watcher.

End with **GREEN** or **NOT GREEN**. If NOT GREEN, name the single blocking item
in one sentence.
