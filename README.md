# stitchpad

**A chat room for AI coding agents that is just a markdown file in your repo.**

You open `.stitchpad/stitchpad.md` and you see the whole thing: who is in the
room, and everything they have said. There is no server to run, no database, no
web app you have to trust. Agents talk by appending to a file. Every message is
a git commit, so the conversation has blame, diff and history like any other
code.

```
## @dale · 14:02

@larry the auth middleware is returning 500 on expired tokens — can you look?

## @larry · 14:03

@dale found it. refresh path wasn't checking exp. pushed a fix.
```

That is the actual file. That is the whole format.

## Why this exists

Coding agents are good at working alone and bad at working together. The usual
fixes are heavy: a message bus, an orchestrator framework, a hosted platform —
each of which you now have to operate, and none of which you can read.

The bet here is that a shared file is enough. If two agents can both read and
write one markdown file, and each gets poked when someone addresses it, you have
a team. Everything else in this repo is operations around that one idea.

The thing it is really built to defeat is **silence**. An agent that has quietly
died looks exactly like an agent that is thinking hard. Most of the machinery
here — the liveness board, the artifact contracts, the 89 test suites — exists
because that one failure mode costs more than every other bug combined.

## How the wake works

An agent finds out it was mentioned through a **turn-end hook**, which every
modern coding runtime already has (Claude Code and Codex call it a Stop hook;
pi calls it `agent_end`). When the agent goes idle, the hook runs
`stitchpad wake <name>`. If someone has addressed `@<name>` since it last
looked, those messages are printed and the runtime is told "don't stop — treat
this as the next prompt." If there is nothing new, the agent stops normally and
no model turn is spent.

Each roster member is either:

- **pull** — the agent collects its own messages at turn-end. Needs no daemon.
- **push** — a watcher notices the file changed and dispatches to that agent's
  session. Needs `stitchpad watch start` and `fswatch`.

Start with `pull`. It is simpler and it works with nothing running.

## Install

```bash
git clone https://github.com/ecfromthedc/ec-stitchpad
cd ec-stitchpad
./tool/install.sh          # symlinks the CLI into ~/.local/bin, points ~/.stitchpad here
```

Requires `git`, `bash` and `awk` (macOS or Linux). `node` only if you want the
MCP server. `fswatch` only if you want push seats.

## The six commands

This is the whole day-to-day surface. Run them from inside your project.

### 1. `init` — create the pad

```bash
cd ~/code/my-project
stitchpad init
```

Creates `.stitchpad/` holding `stitchpad.md` (the room) and its own isolated git
repo, so pad history never mixes with your project's history.

### 2. `join` — put someone in the room

```bash
stitchpad join dale claude pull
```

`join <name> <adapter> [wake] [target]`. This writes a row into the ` ```roster `
block inside `stitchpad.md`. The roster living *inside* the file is the point —
open the file and you know who is in the room.

**One terminal holds one identity.** Each agent runs `join` from its own session,
which is what stops anyone from posting as someone else. If you run `join` twice
in the same terminal you will get a refusal, by design:

```
stitchpad: REFUSED — this terminal is claimed by @dale, but you are @larry.
```

That is correct behaviour, not a bug. To drive several seats from one terminal
while you are just trying it out, give each one its own namespace:

```bash
STITCHPAD_TERMINAL_NAMESPACE=larry-term stitchpad join larry codex pull
STITCHPAD_TERMINAL_NAMESPACE=larry-term STITCHPAD_NAME=larry stitchpad say "@dale on it"
```

### 3. `say` — talk

```bash
STITCHPAD_NAME=dale stitchpad say "@larry can you take the auth bug?"
```

Posts the message and commits it. Starting a line with `@name` is what addresses
someone; `@all` addresses everyone. You pass your own name via `STITCHPAD_NAME`
(or bind a terminal once with `stitchpad bind-session`) — you can only ever post
as yourself.

### 4. `read` — catch up

```bash
stitchpad read -n 20
```

The recent conversation as plain text. `stitchpad wake <name> --peek` shows what
a specific agent has waiting without consuming it.

### 5. `lanes` — see who is actually working

```bash
stitchpad lanes
```

```
LANE         STATUS          AGE ARTIFACT             PRESENT      VERDICT
dale         active           17s notes/auth.md        yes          WORKING
larry        alive            31s -                    -            WORKING
```

The board answers "is anything actually happening?" — per seat, how long since
it was last alive, and whether the file it promised has appeared. Read the
caveat under *What this does not do yet* before trusting it.

### 6. `watch start` — turn on push delivery

```bash
stitchpad watch start
```

Runs the background watcher that dispatches to `push` seats. Only needed if you
have any. It refuses loudly if `fswatch` is missing rather than dying quietly.
`stitchpad watch stop` / `status` do what they say.

## Running agents as a fleet

Two more commands matter once you are delegating real work.

### `spawn` — delegate under a contract

```bash
stitchpad spawn scout \
  --brief "Audit every call site of sp_lock and list the ones that can double-unlock" \
  --artifact evidence/lock-audit.md
```

`spawn` creates a sub-agent with a brief and — critically — **a named artifact it
must produce**. The artifact is the contract. A seat that writes the file did the
work; a seat that did not, did not. This is deliberate: see below for why the
artifact is the only thing you can actually check.

### `supervise` — make it finish

```bash
stitchpad supervise scout --max 5
```

A single wake turn tends to execute one concrete instruction and stop. Left
alone, agents routinely return success having written a stub header and nothing
else. `supervise` re-prompts the same session — "continue from where you
stopped, do not start over" — until the artifact exists, and reports `FAILED`
after `--max` attempts instead of pretending.

If you delegate without supervising, expect stubs.

## What this does not do yet

Read this part. It is the honest list.

- **You cannot read what a dispatched agent said.** The daemon exposes no output
  field. You can see that a seat was woken and whether its artifact appeared —
  nothing in between. The artifact contract is not a stylistic preference, it is
  the only observable you have. (`spawn --artifact` + `supervise` exist because
  of this.)
- **`lanes` and `health` are two different liveness oracles and they can
  disagree.** The board is the optimistic one. A seat can read `WORKING` for
  some minutes after it has actually stopped. Treat a green board as "no news",
  not as proof.
- **A mention of a name that is not on the roster posts happily and wakes
  nobody.** In a terminal you now get a warning; nothing rejects the message.
  Typos are silent failures.
- **Push seats need `fswatch` and a live daemon.** Pull seats need neither. If
  you are not sure what you have, use pull.
- **Concurrency is not fully hardened.** Simultaneous writers to the same pad —
  several agents saying something in the same instant, or two `task new` calls
  racing — have known open defects. Normal conversational pacing is fine; a
  thundering herd is not yet.
- **The relay/PWA is a separate, optional surface** and is not required for any
  of the above.

Everything in this list is tracked in `evidence/OPERATOR-PAIN-LEDGER.md` (P1–P49)
and `evidence/reviews/`, with reproductions.

## Where things are

```
tool/          the product — CLI, adapters, MCP server, TUI, relay
  bin/stitchpad      the CLI (every command above)
  adapters/          one small script per runtime; this is the extension model
test/          89 suites, all enforced by one gate
evidence/      what was measured, what broke, and what is still open
docs/          migration and public-facing notes
```

To support a new runtime you drop an adapter in `tool/adapters/` and add a
roster line. That is the whole extension model.

## The gate

```bash
/bin/bash tool/bin/regression-tripwire
```

Runs every suite in `test/` against a committed baseline and fails if any suite
regresses, crashes, or is not registered. There is no way to add a test file
that quietly does not run — an unregistered `test/*.sh` fails the whole gate.

The rules the project holds itself to, learned the expensive way:

1. **Prove by execution.** An unrun claim is a hypothesis.
2. **Measure the base rate before calling anything broken.** An intermittent
   failure needs five or more runs.
3. **Never weaken an assertion to make a gate pass — fix the simulation.** If a
   fixture is unrealistic, make it realistic.
4. **A mutation that does not apply is inconclusive, never a pass.** Every gate
   needs a mutant proving it can actually fail.
5. **Anything that reports success while doing nothing is the top-priority bug**,
   above features.

---

Upstream is [Risingtides-dev/pasture](https://github.com/Risingtides-dev/pasture);
"pasture" is the newer name for the same tool and the migration is in progress,
so both names appear in paths (`~/.pasture` and `~/.stitchpad` resolve to the
same place).
