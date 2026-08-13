# Known wedges — verified failure modes, recoveries, and the real fixes

Operational failures that have each wedged a real multi-seat build at least
once. Every entry has a REPRO, a RECOVERY that worked, and where known the
proper tooling fix. If you hit one of these and the recovery here is wrong,
update this file in the same PR as your fix — this document exists so crews
stop re-learning these from scratch.

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
