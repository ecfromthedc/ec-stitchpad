# Known wedges — verified failure modes, recoveries, and the real fixes

Operational failures that have each wedged a real multi-seat build at least
once. Every entry has a REPRO, a RECOVERY that worked, and where known the
proper tooling fix. If you hit one of these and the recovery here is wrong,
update this file in the same PR as your fix — this document exists so crews
stop re-learning these from scratch.

**Everything in this file is CONFIRMED.** Patterns that have been noticed but
not yet reproduced live in [`OPEN-OBSERVATIONS.md`](OPEN-OBSERVATIONS.md), and
they stay there until someone can make them fail on demand. A guard built on an
unconfirmed pattern becomes a false alarm, and an alarm that cries wolf on a
schedule is one the operator learns to ignore — which is worse than no alarm.
Confirm one and move it here with its fix; disprove one and delete it. Both are
progress.

## 1. Reassigning a task after creation tombstones the seat's delivery

**Repro:** `task new …`, then `task edit --to <seat>` / `task move todo` as
separate steps afterward. The seat's pending delivery is tombstoned with
`error_code: task_reassigned:todo`, `turn_status: not_submitted` — the seat
shows [ok]/idle but never submits the turn. Two seats wedged this way
starting a three-lane build (2026-08-10).

**Recovery:** `stitchpad reset <seat> --redeliver 1` works but requires
`deploy` authority (`reset-others`), which an orchestrator seat typically
lacks. The recovery that works without it: post a FRESH actionable @mention
(a new delivery) — with the watchdog running, the seat goes busy within a
sweep.

**Prevention:** assign + set status in as few ops as possible, BEFORE
posting the actionable brief, so the brief is the seat's first fresh
delivery. Also: `task edit`'s assign flag is `--to`, NOT `--owner` — the
wrong flag is silently ignored and leaves the task orphaned (no seat ever
picks it up). Verify with `task show <id>` after assigning.

**Real fix (open):** reassignment should re-deliver rather than tombstone;
and `reset --redeliver` on a tombstoned (not mid-turn) delivery should not
require deploy authority — an orchestrator healing its own crew is the
common case, not an attack.

## 2. `ocean-heartbeat wake --session-file` + `--allow-new-session` reuses instead of minting

**Repro:** trying to give a seat a FRESH session while keeping the durable
session-file wiring:
`ocean-heartbeat wake --allow-new-session --session-file .state/ocean-session.kimi …`
does NOT mint — the existing file resolves to the old session id, which wins,
and the wake lands on the OLD session. `--allow-new-session` only mints when
no id resolves at all. Bit a live reseat on 2026-08-12 (both seats' "fresh"
sessions were silently the old ones).

**Recovery:** delete the session-file first (`rm .state/ocean-session.<name>`),
then the same command mints and writes the new id back to the file. Before
doing this at all, check whether you NEED a fresh session: a seat showing
`completed`/`stored` at a high turn count is just idle — a plain wake resumes
it; turn counts near 200 are not a cap.

**Real fix (open):** a `--fresh-session` flag on `wake` in ocean-os
(ecfromthedc/ocean-os, `crates/ocean-heartbeat`): skip the session-file read,
mint, write the new id back. The resolution block is at the top of the wake
handler; the write-back path already exists for `--session-file`.

## 3. Seats writing into the shared main checkout

**Repro:** a seat "just checks something live" in the shared main checkout
instead of its worktree — staged files appear in the orchestrator's tree and
block merges with `Merge with strategy ort failed` (untracked/staged
collisions). Happened 2026-08-12: two byte-identical files staged at review
time; git refused both merges until cleaned.

**Recovery:** if the strays are byte-identical to branch content
(`diff -q <file> <(git show <branch>:<file>)`), unstage + delete them and
re-merge. If they differ, STOP — someone's real work is only in that tree.

**Prevention:** the standing directive line every crew should carry: seats
work ONLY in their assigned worktrees, never the shared checkouts. To
inspect pushed work, read from the ref (`git show origin/<branch>:<file>`),
never by checking anything out into a tree you don't own.

## 4. The lead stalls on its own promises (and a silent push is invisible)

**Repro (cost hours, 2026-08-12, twice):** the LEAD ends a turn after a
status message with its own build work promised ("building now") — nothing
re-invokes it: the operator-waiter and crew-waiter watch OTHERS' posts;
nobody watches the lead's own pending work. Compounding it: a seat that
fixes-and-PUSHES without posting to the pad never fires the crew-waiter
(it is pad-keyed, not git-keyed) — the lead sits idle on work that is
already done.

**Recovery:** the operator yells. That is the failure, not a recovery.

**Prevention (both laws, now in the fleet README):**
1. **The dead-man timer:** the lead NEVER ends a turn with own-work pending
   unless a timer is armed that will re-invoke it (harness scheduler when
   available, else a background `sleep N && echo CONTINUE <task>` whose
   exit is the wake). Re-arm on every firing.
2. **Every push posts:** a seat that pushes commits MUST post one pad line
   naming the branch and SHA in the same breath — the push itself is
   invisible to pad-keyed waiters. "Push after every green unit" therefore
   reads "push AND post after every green unit."

## 5. The watchdog "wakes" a seat that no longer exists (and says it worked)

**Repro (observed 2026-08-12):** a seat's session is re-minted — a shift
change, a wedge recovery, `stitchpad reset` — and the watchdog, which read
`ocean-session.*` ONCE at startup, keeps polling the OLD id. `ocean-heartbeat
wake` accepts the post against a dead session and exits 0, so the watchdog
prints `[watchdog] WOKE stalled seat @name` on every cooldown, forever, while
the seat is never actually woken. Meanwhile a genuinely idle seat with open
work sits untouched because the log looks healthy.

**Why it hid:** the success message was keyed on the wake command's exit
code, not on the seat going busy — the same failure family as an alarm that
prints "healthy" when its own check failed. Both bugs make a guard *look*
alive while it does nothing.

**Recovery:** restart the watchdog (it re-reads the roster at startup), or
`rm .state/ocean-session.<name>` and re-seat.

**Real fix (shipped):** `stitchpad-watchdog` now re-reads the roster every
sweep, and after a wake it polls the session for up to ~12s to confirm the
turn actually started. A wake that doesn't land is reported as
`WAKE DID NOT LAND`; three in a row posts an @-visible pad warning that the
seat is unreachable and hushes it for 30 minutes instead of burning cycles.

## 6. A seat pinned to a model the daemon no longer offers goes dark in silence

**Repro (cost the most time of any wedge so far, 2026-08-12):** a seat is
pinned via `.state/seat-model.<name>`. The daemon later stops offering that
model — a provider dropped, a key expired, the model renamed. Every wake now
fails `ocean-heartbeat`'s model preflight, the seat never runs a turn, and
**nothing says why**: the watchdog piped wake stderr to `/dev/null`, so the
operator sees a seat that "keeps going idle" and debugs the agent instead of
the engine. Hours were spent re-seating, re-minting sessions, and rewriting
prompts for a seat whose model simply no longer existed.

**The tell that would have solved it in a minute:** `GET /v1/models` listed
neither the pin nor — remarkably — the daemon's own advertised `current`
model, which was the same dead id.

**Real fix (shipped):** `stitchpad-watchdog` now audits every seat's pin
against the daemon's ready list each sweep and posts ONE pad warning naming
the seat, the dead pin, and the models that ARE available; the warning
repeats only if the pin changes and re-arms once it is fixed. Wake stderr is
captured and included in `WAKE DID NOT LAND` / unreachable reports instead of
being discarded. `--check-pins` runs the audit one-shot for a human or CI.

**Recovery:** `curl $DAEMON/v1/models`, pick a ready id, write it to
`.state/seat-model.<name>`, delete `.state/ocean-session.<name>`, re-seat.

## 7. A delegated sub-agent cannot post as itself

**Repro (cost a full build's worth of relaying, 2026-08-12):** the lead spawns
a helper — `codex exec`, a `stitchpad spawn` sub-agent, a CI runner. The child
inherits the parent's terminal environment, so the terminal-identity lock is
held by the LEAD. The helper sets `STITCHPAD_NAME=<itself>` and posts; the
guard sees a name mismatch on a claimed terminal and refuses: *"this terminal
is claimed by @fable."* Every delegated seat then has to hand its report to
the lead to re-post by hand — a reporting channel with a human in the middle,
which is exactly how a seat's findings arrive late or not at all.

**Why the guard was there:** one terminal = one PAD, to kill cross-pad ghost
posts from a bad resolver (wrong cwd, stale MCP server, wrong env). That
protection is real and stays.

**Real fix (shipped):** the refusal now distinguishes the two cases. A claim
belonging to a DIFFERENT pad still refuses, always. A claim on the SAME pad
with a different name is a delegated agent, and is allowed **when that name is
actually on this pad's roster**; an unrostered name is still refused. This
does not weaken a security boundary — the CLI has always trusted
`STITCHPAD_NAME` on an unclaimed terminal — it removes a delegation blocker.
Pinned by `test/delegate-can-speak.sh`.

## 8. A headless agent parks forever on stdin, and "running" is a lie

**Repro (cost 2h21m of a three-lane build, 2026-08-12):** a lead spawns a
headless agent from an orchestration shell or a pipeline —
`codex exec … "$brief" | tail -20`, or any background launcher whose stdin is
an open socket. The agent prints nothing and sits at **0% CPU**. No session
file is ever created. **Not one API call is made.** `ps` shows it `S` and
alive, the task tracker shows "running", the orchestrator believes both, and
the lane it was supposed to build sits untouched for hours.

The cause is the agent's own first startup step, which you never see because
it is buffered behind the block:

    Reading additional input from stdin...

A headless agent treats a non-TTY stdin as piped context and **blocks reading
it**. From a pipeline, a background shell, or anything whose stdin never
reaches EOF, that read never returns. It is not slow, not rate-limited, not
thinking — it is parked before it ever started.

**Recovery:** kill it and relaunch with stdin closed —
`codex exec … "$brief" < /dev/null > run.log 2>&1 &` — then confirm real
output within ~10s. In the incident the relaunched agent produced 18KB of work
in ten seconds, against zero bytes in two hours and twenty-one minutes.

**Detection you can trust:** a fresh session file under `~/.codex/sessions/`,
or growth in the log. Never `ps`. **A process that exists is not a process
that is working.**

**Real fix (shipped): `tool/bin/stitchpad-exec`.** It redirects stdin from
`/dev/null` so the startup read EOFs instantly, and — because the redirect
alone would still fail quiet if the agent stalled for any *other* reason — it
refuses to call the spawn successful until the child has actually PRODUCED
something. Nothing before the deadline means the child is killed and the wedge
announced (exit 78), rather than left as a corpse that looks alive. Pinned by
`test/headless-spawn-stdin.sh`, which also asserts the wedge itself is still
reproducible, so the test goes loud instead of blind if the behaviour changes.

**Prevention, and the better answer:** prefer a **managed seat** (an ocean
session) over a raw headless exec for any long-lived agent. A seat is
watchdog-covered, posts to the pad as itself, and cannot enter this state. The
crew that hit this moved its last CLI agent onto an ocean seat the same night.
Reach for `stitchpad-exec` for one-shot work, not for a lane.

## 9. A seat goes inert near ~200 turns and never says so

**Repro (2026-08-13, cost most of an hour and three silently-dropped tasks):**
an ocean seat accumulates turns across a long build. Somewhere around **~200**
it stops doing work. It does not error. Every wake is accepted, the session
reports `running` and then `completed`, and the seat produces **nothing** — no
commit, no push, no pad post, an untouched worktree. Three seats hit this
within minutes of each other at **198, 199 and 200 turns**. Three dispatches
were dropped before anyone thought to compare branch heads before and after a
dispatch and noticed nothing had moved.

The tell is brutal in hindsight: a seat that "completed" a 20-minute review in
under two seconds. `completed` means *the turn ended*, never *the work
happened* — the same lie as wedges #5 and #6, one layer up.

**Recovery that worked:** archive the session file, delete it, mint a fresh one
with the SAME name/model/cwd, and re-brief. The rotated seat produced a full
cross-review within two minutes of a rotation that had been silent for three
dispatches. Turn counts after rotation: 1, 9, 36 — all working.

**Two signals, and only one of them is proof:**

| | |
|---|---|
| turn count | a **leading indicator**. Cheap, available before the damage, never conclusive — a seat can be fine at 210 or dead at 150 depending on how heavy its turns were. |
| an artifact | the **proof**. A moved branch head, a new commit, a pad post. No artifact means the seat is inert regardless of what the daemon says. |

**Real fix (shipped): `tool/bin/stitchpad-seat-health`.** It reports every
seat's turns and state, warns at 150, says ROTATE NOW at 185 (before ~200, not
after) and exits 3 so a script can act, and prints the reminder that turns are
not proof. `--rotate <seat>` does the archive/delete/mint dance, and:

- **it refuses to rotate without `--brief`.** A fresh seat remembers nothing;
  rotating without re-briefing trades an inert seat for an amnesiac one, which
  is worse — the inert seat at least does no damage, while an unbriefed seat
  acts confidently on nothing.
- **it verifies the mint produced a NEW id** and fails loudly if the daemon
  reused the old one (wedge #2), instead of reporting a rotation that did not
  happen.
- it archives the dead session rather than destroying it.

Pinned by `test/seat-context-exhaustion.sh` (9 cases, including the reused-id
no-op and the missing-brief refusal).

**Prevention:** run it between phases of a long build, and after any dispatch
confirm an artifact moved. Rotate at a clean break — never mid-lane, since the
seat loses its working context.
