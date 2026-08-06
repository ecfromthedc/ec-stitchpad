# Close-out session — 2026-08-06

Task: `evidence/NEXT-SESSION-PROMPT.md` — the ten remaining verified defects,
plus the codex seat. Worked entirely in a `git worktree`; the live install at
`/Users/ecfromthedc/dev/tools/stitchpad-md` was never checked out or edited
during the work (a launchd job executes it every 120s).

## What shipped

Eleven findings closed, one commit each, every one reproduced BEFORE the fix and
gated with a mutant that was checked to actually apply.

| commit | finding |
|---|---|
| `652d32a` | k3 F16 — the installer's success banner over a fleet it never wired |
| `4349007` | ds F13 — `compact`/`archive` destroyed every cursor, then said they hadn't |
| `e379169` | k3 F4 — the wake misdirection guard exempted the relay path |
| `c619759` | k3 F18 — two sessions starting together both became @fable |
| `d93e7ce` | ds F5 / k3 F14 — one @mention to an idle claude seat notified forever |
| `943dd06` | k3 F13 — `ocean.sh` fired the wake whenever it could not ask |
| `67c7c7b` | ds F6 — a duplicated roster row made two parts of the system disagree |
| `4b97717` | k3 F0 — a seat the watchdog had given up on still read WORKING |
| `9eafe26` | k3 F1 — the watcher promised a rescue nobody performs |
| `6fd9c3d` | ds F7 — a fresh pad's first command pointed at a dead end |
| `27edcc1` | k3 F15 + F17 — both promoted from UNPROVEN, with the evidence |

Seven new suites, four extended; `evidence/REVIEW-FINDINGS-TRIAGE.md` rewritten
so no finding is left open.

## Findings that did not survive contact with execution

Recorded because a review's wrong half matters as much as its right half.

- **k3 F4's headline was already fixed.** The local pull path refuses a
  third-party wake and does not move the cursor — verified by execution, and the
  gate that covers it (`p43` G5/G5b) was already green. The real residue was the
  `relay_mode -eq 0` exemption, which kept the entire defect on the relay
  cursor. That is what `e379169` closes.
- **ds F6's double-dispatch does not reproduce.** `delivery_enqueue` is
  idempotent per (ordinal, message_id). Asserted as a property with a mutant
  that breaks the identity check and makes the double-dispatch appear, so the
  reason it cannot happen is now recorded rather than assumed.
- **k3 F13's fix broke a test that was lying.** Making the ocean idle-guard fail
  closed turned `delivery-supervision-regression` red, because its fake `curl`
  answered every URL with the `/v1/requests` list shape — which the real daemon
  never returns for the session route. Rather than weaken the assertion, the
  daemon's actual contract was checked: a live probe, `ocean-agent-sdk`
  (`AgentSession.active_turn`, `skip_serializing_if = "Option::is_none"`), and
  `ocean-daemon/src/main.rs:7669` (derived from the live request registry). The
  probe was right; the fixture was an incomplete simulation, and it was the
  fixture that got fixed.

## Three things the gates caught in my own work

The mutant discipline earned its keep three times, all in the same direction —
a fix that looked right and was not:

1. **The F14 give-up notice re-armed the retry it announced.** It named the seat
   a second time as " @name", which is a mention, so posting it minted a new
   delivery generation: give up → announce → new generation → retry → give up,
   unbounded, with a pad write per round. Measured at ordinal 1 → 3 and adapter
   calls 4 → 16 before the notice was rewritten to name the seat once, in the
   `_@name` form the mention regex does not match.
2. **The F15 truncation suffix put `(` and `)` back into the pty** *after*
   sanitising. The metacharacter assertion went red on the fix, not the mutant.
3. **An F15 mutant survived for the wrong reason.** With the length cap still in
   place, the truncation landed inside an unbalanced backquote, `sh` refused to
   parse the line, and nothing ran — so a dangerous string scored as safe for a
   reason unrelated to the sanitizer. The assertion is now a byte-level
   invariant, and the mutant restores the pre-fix adapter in full.

## Fleet observations (read-only probes, no wakes)

- `gpt-5.6-sol` is `ready=true` on the daemon, so the codex seat can be
  restored.
- **`kimi-k3`, `kimi-k2.6` and `kimi-k2` are all `ready=false`** right now. The
  handover notes list kimi as a working seat; its provider is currently down at
  the daemon, so a wake to @kimi will not land until it returns. Nothing in
  stitchpad is at fault, and nothing in stitchpad reports it either — the seat
  reads `stale` on `lanes`, which is true but does not say why.
- The three ocean seats on `#campaign-hub-rust-rebuild` (glm, deepseek, kimi)
  all have live sessions whose last turn is `completed` and no `active_turn`:
  idle, not stuck.
