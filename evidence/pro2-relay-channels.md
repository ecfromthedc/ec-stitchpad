# P26: Deleting a local pad unregisters its relay channel

## Verdict: PASSED — 9/9 gates, mutant-proven

## Problem
P18 cleaned scratch pads from disk but the relay retained every channel forever.
KV keys (`pad:*`) were written on push but never deleted. Deleting a .stitchpad
directory had no effect on the sidebar — channels were immortal.

## Changes

### (a) Relay worker: DELETE /pads?pad=NAME
New endpoint removes the KV `pad:<name>` key and clears the DO storage.
Returns `{ok: true, forgotten: "name"}`.

### (b) Bridge reconciliation
Each cycle the bridge collects all pad names, writes them to a state file.
On the next cycle, any name in the previous file but not in the current
scan triggers a DELETE call to the relay. A deleted pad directory
automatically unregisters within one bridge interval.

### (c) CLI: `stitchpad pads --forget <name>`
Manual unregister for orphaned channels. Calls DELETE on the relay.
Requires STITCHPAD_RELAY + STITCHPAD_TOKEN.

### (d) PadHub DO: /forget handler
Clears DO storage (`deleteAll()`) so the pad document is fully removed.

## Gate (p26-relay-channel-gate.sh)

| Gate | Result | Proves |
|------|--------|--------|
| G1a | PASS | Relay lists pad after push |
| G1b | PASS | Relay no longer lists pad after DELETE |
| G1c | PASS | DELETE call received by relay |
| G2a | PASS | Relay lists pad before --forget |
| G2b | PASS | pads --forget reports success |
| G2c | PASS | Relay no longer lists pad after --forget |
| G3 | PASS | MUTANT: local deletion without DELETE → orphaned channel (RED) |
| G4 | PASS | --forget without token exits non-zero with clear error |
| G5 | PASS | Four real pads still list |

## Mutant proof
G3 proves the fix is necessary: delete the .stitchpad WITHOUT calling the
DELETE endpoint, and the channel remains listed on the relay. This is exactly
the P26 defect — the sidebar shows channels whose local pads are gone.

## Files changed
- `tool/relay/worker.js`: DELETE /pads endpoint + DO /forget handler
- `tool/relay/bridge.sh`: per-cycle reconciliation + vanished-pad DELETE
- `tool/bin/stitchpad`: pads --forget <name> command
- `test/p26-relay-channel-gate.sh`: 9-assertion gate (new)
- `test/suite-baseline.txt`: p26-relay-channel-gate 9/0
