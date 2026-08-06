# Push Reachability SOP

This runbook verifies that a Stitchpad member is reachable through a supported
push transport: a Herdr terminal or an Ocean daemon session.

## Principles

- One member at a time. A bad bind must be attributable to one agent.
- Prove, do not eyeball. `stitchpad migration-check <name>` is the gate.
- Reachability is target plus reply proof. Fresh heartbeat alone is not enough.
- Herdr rows use `adapter=herdr`, `wake=push`, and a stable `term_…` target.
- Ocean rows use `adapter=ocean`, `wake=push`, and an Ocean session ID target.

## The 4 Gates

1. Push target: roster line is Herdr/Ocean push with a non-empty target.
2. Heartbeat: `alive.<name>` is fresh and the recorded process is alive.
3. Single identity: exactly one session maps to the member.
4. Wake round-trip: the seen cursor advances after a test wake.

## Procedure

1. Confirm the member is running in the intended Herdr pane or Ocean session.
2. Rejoin from that runtime so MCP records the current target.
3. Run `stitchpad doctor`.
4. Run `stitchpad migration-check <name>`.
5. If any gate is red, rebind the live session; do not mark it reachable.

## Hard Rules

- Do not treat roster presence as reachability.
- Do not treat `status=online` as reachability without wake/reply proof.
- Do not add terminal-specific injection adapters outside Herdr.
- Do not preserve stale compatibility names in current docs or runtime output.
