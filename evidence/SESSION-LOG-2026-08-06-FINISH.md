# Finish session — 2026-08-06 (fable)

Task: `evidence/NEXT-SESSION-PROMPT.md` — close the four OPEN items, verify the
fleet, run the gate, ship. Worked in the same `git worktree`; the live install
was never checked out or edited during the work.

## Fleet: down, why, and restored

The machine died mid-session and took the **ocean daemon** with it — the
supervised LaunchAgent (`dev.risingtides.ocean-daemon`) was never installed on
this machine, so the daemon was a hand-launched process with no respawn. Every
ocean seat on every pad read `stale` purely because :4780 was refusing
connections.

Restored by hand-launch matching the supervised launcher's exact shape
(neutral cwd `$HOME`, `OCEAN_YOLO=1`, prebuilt release binary), log at
`~/Library/Logs/ocean-daemon-hand.log`. Sessions survived the restart with
full turn history — idle, not stuck.

**Verified by execution, not by the join succeeding** — liveness pings posted
as @captain; every seat woke AND answered:

| seat | pad | replied | resolved model (authority) |
|---|---|---|---|
| codex | campaign-hub | "gpt-5.6-sol" | gpt-5.6-sol ✓ |
| glm | campaign-hub | "Claude (Anthropic)." (self-ID confusion; see below) | glm-5.2 ✓ |
| deepseek | campaign-hub | "deepseek-v4-pro" | deepseek-v4-pro ✓ |
| kimi | campaign-hub | "k3" | k3 ✓ |
| deepseek | pasture-wt-gate | "deepseek-chat" (self-ID confusion) | deepseek-v4-pro ✓ |
| fable | both | herdr/manual seat — posts verified (this session posted as it on pad 2) | n/a |
| captain | campaign-hub | pull seat — posting verified (the pings) | n/a |

A model's self-naming in reply TEXT is not evidence — glm-5.2 answers "Claude",
deepseek answers "deepseek-chat". The daemon-side resolved config is the
authority, which is exactly why the TASK-1 pin telemetry exists.

## Model-pin drift: found by the pin system, root-caused, fixed

On the first post-restart wake, `model-mismatch.glm` (glm-5.2 → k3) and
`model-mismatch.codex` (gpt-5.6-sol → k3) both fired. Root cause, by build
archaeology, and **this is an ocean-os finding**:

- The wake path passes `--model <pin>` per seat (`ocean-heartbeat` client,
  built Aug 4, has the flag).
- The **running daemon binary was built Jul 31 12:28 — ten hours BEFORE the
  `wake --model` feature landed (2a1e349, Jul 31 22:25)**. It ignores the
  per-turn pin, so sessions ride the daemon's GLOBAL model (k3).
- deepseek never drifted because its session carries a per-SESSION model
  (`model_source: "session"`); kimi matched by coincidence (global == pin).

Fix that does not depend on daemon feature support: pinned codex and glm at
session scope via `PATCH /v1/agent/sessions/{id}/config {"model": ...}` —
the same shape deepseek already had. Re-woken and re-verified: both resolved
their pinned models and `sp_model_pin_check` cleared both mismatch markers.

**Ocean-os ops items (not stitchpad faults):**
1. Install the supervised daemon (`ops/install-ocean-daemon.sh`) so a reboot
   cannot silently kill the fleet again — that is precisely what happened here.
   Note the installer requires a clean tree on main; the checkout currently
   carries local modifications, so this needs an operator decision.
2. Rebuild the daemon from main to pick up `wake --model` per-turn pinning;
   until then session-scope pins hold and are robust against global flips.

## OPEN list disposition

1. **watcher-races load fragility** — fixed in tool (see the OPEN #1 commit):
   a live supervisor is no longer scored dead on one stale wall-clock
   observation; no-progress now needs two observations a full restart-grace
   apart with the SAME heartbeat stamp, at every judgment site
   (`sp_watcher_alive` both branches, `sp_reap_duplicate_watchers_for_pad`).
2. **set-wake false "failed to bind"** — fixed (`474d024`),
   gated by `setwake-bind-truth-gate.sh` with an applying mutant.
3. **delivery_start_worker ownerless grace strand** — fixed (`565ca48`),
   gated by `delivery-grace-spawn-gate.sh` with an applying mutant.
4. **say-under-contention rc** — resolved by evidence (`82e20f7`): rc=0,
   wording class; forensics in `REVIEW-FINDINGS-TRIAGE.md`.
