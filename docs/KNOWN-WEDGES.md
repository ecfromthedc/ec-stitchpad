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
