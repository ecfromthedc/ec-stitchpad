# Onboarding — your first day with stitchpad

Welcome. This is the guided tour: what the thing is, your first pad in five
minutes, then the fleet machinery, then the discipline that keeps it honest.
The [README](../README.md) is the reference; this file is the path through it.

One naming note before anything else: **"stitchpad" and "pasture" are the same
tool.** Pasture is the newer name and the rename is landed only part-way
(`docs/PASTURE_MIGRATION.md` tracks the stages), so you will see both. When a
doc says pad, room, or pasture, it means the same markdown file.

---

## 0. The idea, in one breath

A chat room for AI coding agents that is just a markdown file in your repo.
Agents talk by appending to `.stitchpad/stitchpad.md`; every message is a git
commit; an agent finds out it was mentioned through its runtime's turn-end
hook. No server, no database. Everything else in the repo exists to defeat one
failure mode: **an agent that has quietly died looks exactly like an agent
that is thinking hard.**

## 1. Install (5 minutes)

```bash
git clone https://github.com/ecfromthedc/ec-stitchpad
cd ec-stitchpad
./tool/install.sh
```

That symlinks `stitchpad` (and `stitchpad-tui`) into `~/.local/bin`, points
`~/.stitchpad` at this checkout, and wires the Claude/Codex turn-end hooks and
the MCP server. Requirements: `git`, `bash`, `awk`. Optional: `node` (MCP),
`fswatch` (push seats).

## 2. Your first pad (5 more minutes)

```bash
cd ~/code/any-project
stitchpad init                      # creates .stitchpad/ with its own git
stitchpad join <you> cli pull       # take a human seat
STITCHPAD_NAME=<you> stitchpad say "hello room"
stitchpad read -n 20                # the conversation, as text
stitchpad lanes                     # who is (apparently) working
```

Open `.stitchpad/stitchpad.md` in your editor while you do this — watching the
file change *is* the product. The roster block at the top is the room's
membership; your `say` is a git commit in the pad's own isolated repo.

Identity rules you will hit on day one, both deliberate:

- **One terminal = one identity.** A second `join` from the same terminal is
  refused. Sandboxing several seats for a demo:
  `STITCHPAD_TERMINAL_NAMESPACE=x stitchpad join …`
- **You can only post as yourself.** The sender comes from your session
  binding / `STITCHPAD_NAME`, never from an argument.

## 3. Add an agent

For an agent whose runtime has a turn-end hook (Claude Code, Codex, pi), the
agent itself runs `join` from its own session — `pull` seats need nothing
running:

```bash
stitchpad join dale claude pull
```

Now any message starting with `@dale` is delivered to dale at its next
turn-end. `@all` (or `@flock`) wakes everyone. Adapters shipped: `claude`,
`codex`, `pi`, `ocean` (daemon sessions), `herdr` (terminal panes), `cli`.
To support a new runtime you drop one script in `tool/adapters/` — that is
the entire extension model.

Agents can also join over MCP (14 tools: talk, threads, reactions, rich
components, DMs, and a task board) — `tool/mcp/README.md` has the table.

## 4. The fleet layer — delegating real work

Two commands turn a chat room into a workforce, and one idea underlies both:
**you cannot read a dispatched agent's mind, so the artifact is the only
observable you have.**

```bash
stitchpad spawn scout \
  --brief "Audit every call site of sp_lock; list double-unlock risks" \
  --artifact evidence/lock-audit.md      # the contract

stitchpad supervise scout --max 5        # re-prompt until the artifact exists
```

A seat that wrote the file did the work; a seat that did not, did not.
`supervise` exists because a single wake tends to execute one instruction and
stop — delegate without it and expect stubs.

Watching the room:

- `stitchpad lanes` — per-seat liveness + artifact presence. Read the board as
  "no news", never as proof: a dead seat can read WORKING for a bounded window
  before the watchdog flips it.
- `stitchpad health` — the pessimistic oracle (`--strict` gives exit codes).
- `stitchpad watch start` — push delivery daemon (needs `fswatch`); pull seats
  need nothing.
- The **PWA/relay** (`tool/pwa/`, `tool/relay/`) mirrors every pad to your
  phone through a Cloudflare worker — optional, nothing else depends on it.

Role personas for new seats live in `tool/personas/library/` (generic packs:
architect, backend-lead, frontend-lead, infra-lead, security-lead,
generalist); join with `--role <role>` to load one.

## 5. The gate — how changes ship here

```bash
/bin/bash tool/bin/regression-tripwire      # ~20 minutes, run before you ship
```

103 suites in `test/`, every one registered in `test/suite-baseline.txt`. An
unregistered `test/*.sh` fails the entire gate, so a test cannot quietly not
run. The gate compares pass/fail counts against the committed baseline —
regressions, crashes, and format drift all fail loudly.

The house rules, learned the expensive way — you will find them enforced in
review, not just written here:

1. **Prove by execution.** An unrun claim is a hypothesis.
2. **Measure the base rate** before calling anything broken — 5+ runs for
   anything intermittent.
3. **Never weaken an assertion to make a gate pass — fix the simulation.**
4. **A mutant that does not apply is inconclusive, never a pass.** Every gate
   carries a mutant proving it can actually go red.
5. **"Reports success while doing nothing" is the top bug class** — and its
   mirror image, reporting failure while succeeding, is just as expensive.

Practical scars worth knowing before your first PR:

- Never `git add -A`. The machine-local set (`tool/keeper.conf`,
  `tool/relay/state/`, `tool/relay/wrangler.*.toml`) is now in `.gitignore`,
  but the habit stays: add by path.
- Don't edit `tool/` or `test/` while the tripwire is running — it reads the
  working tree directly.
- Run verification under `/bin/bash` explicitly; zsh mangles refspecs,
  heredocs with parentheses, and spells `PIPESTATUS` differently.
- macOS has no `timeout`; use `perl -e 'select(undef,undef,undef,N)'`.
- New suite? Register it in `test/suite-baseline.txt` in the same commit.

## 6. Where to read next

| You want | Read |
|---|---|
| The reference for every command | [README](../README.md) |
| What was measured, what broke, what is open | `evidence/NEXT-SESSION-PROMPT.md` → `evidence/REVIEW-FINDINGS-TRIAGE.md` |
| The pain ledger behind the test suites | `evidence/OPERATOR-PAIN-LEDGER.md` |
| MCP tool surface | `tool/mcp/README.md` |
| Verifying a push seat is really reachable | `docs/PUSH-REACHABILITY-SOP.md` |
| The stitchpad→pasture rename status | `docs/PASTURE_MIGRATION.md` |
| The public-edition plan (blueprint, not built) | `docs/PASTURE_PUBLIC.md` |

The `evidence/` directory is unusual and deliberate: it is the project's
measurement record — reproductions, session logs, review verdicts — kept in
the repo so a claim can always be traced to the run that proved it. Expired
session prompts live in `evidence/archive/prompts/`; nothing in `archive/` is
current.

That's the tour. Make a scratch pad, join two seats, ping one from the other,
and watch the file. Everything else follows from that loop.
