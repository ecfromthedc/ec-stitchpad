# r1-watcher-churn — P13 root cause, fix, gate

**Evidence of storm:** a machine-local log (`live-checkout-escapes.log`, on the
operator's machine outside this repo — not preserved in-tree), 110 lines
spanning 01:38:10–01:39:17. 41 `ensure-watcher` + 34 `watch.sh` spawns in 67
seconds. Not steady state — a respawn storm. The reproducible half of the
evidence is `test/watcher-singleton-gate.sh`, which re-creates the storm shape
without the log.

## Root cause (two bugs)

### Bug 1: `sp_stop_watchers_for_pad` killed the winner mid-startup

In the old `ensure_watcher` (bc64aaa–b06cc54), `sp_stop_watchers_for_pad` was called
**before** the `mkdir` singleton race. Flow with N concurrent callers:

1. All N call `sp_watcher_alive` → false (no lock, or lock exists but no owner yet)
2. All N call `sp_stop_watchers_for_pad` — if a lock exists (from a concurrent winner
   who just acquired it), this nukes the winner's generation and kills the watcher
3. Winner's just-spawned `watch.sh` finds its generation cancelled → exits
4. Next caller finds no watcher → spawns a new one → killed by next concurrent caller → cycle

Every heartbeat tick (30s interval, line 2428 in stitchpad) called `ensure-watcher`,
and with multiple pads in the fleet, the storm was continuous.

### Bug 2: P5 missing-git check blocked auto-create

`sp_init_paths_readonly` at line 157 checked `[ ! -d "$PAD_GIT" ]` and returned 1.
`sp_init_paths` called `sp_init_paths_readonly` at line 181 and returned 1 on failure.
The auto-create code at line 190 (`git --git-dir="$PAD_GIT" init -q`) was unreachable.

So `ensure_watcher` → `sp_init_paths` → `sp_init_paths_readonly` → "pad git missing"
→ returns 0 silently. The watcher was never spawned on a fresh pad.

## Fix (3 changes in `tool/bin/lib.sh`)

1. **Move auto-create BEFORE P5 check** in `sp_init_paths_readonly`. Now every path
   (read-only and read-write) auto-heals before checking. The P5 check still fires when
   auto-create fails (e.g., PAD_MD also missing, git command unavailable).

2. **Check `sp_watch_launcher_lease_is_fresh` before `sp_stop_watchers_for_pad`** in
   `ensure_watcher`. If a concurrent caller just acquired the lock and wrote a fresh
   generation, sleep 0.3s and return — do NOT nuke the active startup.

3. **Pass `STITCHPAD_HOME` to the watcher subshell** so the watcher can self-locate
   on re-entry paths.

## Gate: `test/watcher-singleton-gate.sh`

6 gates, all PASSED on the fixed tree at a1ca7c4:

| Gate | Assertion | Result |
|---|---|---|
| W1 | 8 concurrent ensure_watcher → exactly 1 fswatch | PASS |
| W2 | re-entry (single ensure_watcher) → no-op, count unchanged | PASS |
| W3 | watcher survives 8s idle (no heartbeat ticker running) | PASS |
| W4a | watcher alive after 11 rapid calls over 10s | PASS |
| W4b | zero NEW watchers spawned during 11 rapid calls | PASS |

## Mutant proof

The old `ensure_watcher` (bc64aaa, unconditional `sp_stop_watchers_for_pad` before `mkdir`)
produced the 41-ensure-watcher + 34-watch.sh storm in live-checkout-escapes.log. This is
the pre-fix state of the code — the storm IS the mutant proof. The fix (checking
`sp_watch_launcher_lease_is_fresh` before `sp_stop_watchers_for_pad`) eliminates the
condition that caused the churn.

## Commit

`a1ca7c4` — P13: watcher churn — singleton holds under N concurrent callers
Worktree: `/Users/ecfromthedc/dev/agents/stitchpad-wt/r1-watcher` (based on b06cc54)
Files changed: `tool/bin/lib.sh`, `test/watcher-singleton-gate.sh`, `test/suite-baseline.txt`
