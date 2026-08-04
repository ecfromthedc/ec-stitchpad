# P18: Agent scratch trees must not become channels — FINAL

## Verdict: PASSED — 12/12 gates, mutant-proven

## Changes

### (a) Worktree detection + refusal
`stitchpad init` detects git worktrees (`.git` as a file or `git rev-parse --git-common-dir` pointing to a worktrees/ dir). Without `--scratch` or `--force`, init REFUSES with a clear message.

### (b) --scratch / --force flags
- `--scratch`: creates a `.scratch` sentinel file inside the pad; pad is excluded from channel listings, bridge scanning.
- `--force`: operator override — creates a real channel pad even inside a worktree.

### (c) .scratch sentinel
A zero-byte `.scratch` file in the pad root. The `pads` command and bridge `find_pads()` both skip pads with this sentinel. Fixture pads created with `--scratch` are invisible to discovery.

### (d) `stitchpad pads --scratch|--prune|--all`
- `pads` (no args): lists only channel pads (non-scratch)
- `pads --scratch`: lists only scratch pads
- `pads --all`: lists everything
- `pads --prune`: removes all scratch pads (implies --scratch)

### Bridge hardening
`tool/relay/bridge.sh` `find_pads()` now filters out scratch pads (`.scratch` sentinel present).

## Gate (p18-scratch-pad-gate.sh)

| Gate | Result | What it proves |
|------|--------|----------------|
| G1 | PASS | init in worktree without flag REFUSED |
| G1b | PASS | no .stitchpad created on refusal |
| G2 | PASS | --scratch creates .scratch sentinel |
| G2b | PASS | output says "NOT a channel" |
| G3 | PASS | --force creates NO sentinel (real channel) |
| G4 | PASS | scratch pad NOT in channel listing |
| G5 | PASS | scratch pad IS in --scratch listing |
| G6 | PASS | --force pad IS in channel listing |
| G7 | PASS | --prune removes scratch pads |
| G8 | PASS | suite sweep: ZERO new channels (11 before = 11 after) |
| G9 pre | PASS | scratch pad hidden before mutation |
| G9 mutant | PASS | removing .scratch exposes pad as channel |

### Mutant proof
G9 proves the sentinel is the ONLY barrier: remove `.scratch` from a scratch pad, and it immediately appears in the channel listing. The gate is real, not cosmetic.

## Real pads preserved
All four EC-required pads still list:
- ocean-arena ✓
- ocean-rooms-campaign ✓
- lifted-ship-clipppers ✓
- sales-agent ✓

## Files changed
- `tool/bin/stitchpad`: init worktree gate + pads subcommand
- `tool/relay/bridge.sh`: bridge skips scratch pads
- `test/p18-scratch-pad-gate.sh`: 12-assertion gate (new)
- `test/suite-baseline.txt`: p18-scratch-pad-gate 12/0
