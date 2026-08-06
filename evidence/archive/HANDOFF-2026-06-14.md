# stitchpad - HANDOFF

> Read this first. Last updated: 2026-06-14. The current architecture is
> hook-driven: runtime turn-end hooks call `stitchpad wake`, identity is pinned
> with `STITCHPAD_NAME`, and MCP is only the talking surface.

---

## Current Architecture

`stitchpad.md` is a self-describing markdown bus for AI coding agents. The
roster lives inside the file in a fenced `roster` block. Agents post messages to
the same file; a line that starts with `@name` is addressed to that teammate.
Every message is committed to an isolated git repo under `.stitchpad/`.

The wake is not tmux, terminal injection, or MCP polling. It is runtime-native
hooks:

```
stitchpad.md  (the bus; roster lives inside it)
   |
   |-- stitchpad MCP server (tool/mcp/server.mjs)
   |     tools: join, say, read, who
   |     role: register identity + write/read the pad
   |
   `-- runtime turn-end hook
         Claude/Codex: tool/adapters/stop-hook.sh
         pi:           tool/adapters/stitchpad/
         identity:     STITCHPAD_NAME=<agent-name>
         action:       stitchpad wake
                       -> if messages exist, feed them into the next turn
                       -> if empty, stop normally and burn no model turn
```

This makes wake turn-gated rather than instant interrupt. That is intentional:
the runtime only checks when the agent finishes a turn. There is no keystroke
injection and no `wait_for_mention` MCP tool.

## What Is On Disk

```
~/stitchpad/
|-- README.md
|-- TASKS.md
|-- HANDOFF.md
|-- tool/
|   |-- bin/
|   |   |-- stitchpad        CLI: init, join, say, read, wake, watch, start/stop/status, roster, log
|   |   |-- lib.sh           core pad resolution, roster parse, locking, git, mention detection
|   |   |-- watch.sh         optional fswatch watcher; not the core wake path
|   |   |-- daemon.sh        optional watcher background manager
|   |   |-- tui.sh           live terminal renderer
|   |   `-- stitchpad-tui -> tui.sh
|   |-- adapters/
|   |   |-- stop-hook.sh     shared Claude Code + Codex Stop hook
|   |   `-- pi/              pi extension using agent_end/session_start
|   |-- mcp/
|   |   |-- server.mjs       MCP join/say/read/who
|   |   `-- README.md
|   `-- install.sh
`-- reference/               prior art only; not shipped
```

## What Works

- `stitchpad init` creates `.stitchpad/stitchpad.md`, `.stitchpad/.state/`, and
  `.stitchpad/stitchpad-git/`.
- `stitchpad join <name> <adapter> [wake] [target]` adds a roster entry.
- `STITCHPAD_NAME=<you> stitchpad say <text>` appends a message and commits it.
- `stitchpad read`, `stitchpad roster`, and `stitchpad who` parse the pad.
- `stitchpad wake <name>` or `STITCHPAD_NAME=<name> stitchpad wake` emits a
  short stitchpad context preface plus addressed messages newer than that name's
  cursor, then advances `.state/cursor.<name>`.
- `tool/adapters/stop-hook.sh` pipes hook JSON stdin into `stitchpad hook`;
  `STITCHPAD_NAME` pins which agent is being woken.
- `tool/adapters/stitchpad/` does the same drain from pi's native `agent_end` and
  `session_start` events.
- `tool/mcp/server.mjs` starts over stdio and exposes `join`, `say`, `read`,
  and `who`.

## Verified In This Cleanup

- Temp pad smoke: `init -> join -> say -> wake`.
- Cursor behavior: first wake printed the context preface + message; second wake
  was empty.
- Regression coverage: `test/wake-regression.sh` verifies bounded message
  extraction and no old-mention re-emission after unrelated commits.
- Stop hook smoke: `stop_hook_active:false` returned `decision:block`; the active
  guard returned nothing.
- Installed symlinks point at this checkout:
  `~/.local/bin/stitchpad`, `~/.local/bin/stitchpad-tui`, and `~/.stitchpad`.
- MCP server starts with `node tool/mcp/server.mjs`.

## Known Runtime Facts

- Codex hook config is `~/.codex/hooks.json`.
- Claude hook config is `~/.claude/settings.json`.
- Both should point their Stop hook command at
  `STITCHPAD_NAME=<agent-name> ~/.stitchpad/adapters/stop-hook.sh`.
- pi should install the directory adapter:
  `pi install ~/.stitchpad/adapters/stitchpad`.
- The optional file watcher needs `fswatch`; it is a convenience path, not the
  agent wake spine.

## How To Resume

1. `cd ~/stitchpad`
2. Read this file and `README.md`.
3. For behavior work, test the shared primitive first: `stitchpad wake`.
4. For runtime wake work, test the relevant hook adapter next.
5. For MCP work, keep the boundary clear: MCP registers and talks; hooks wake.

## Naming Note

"teammate" is taken by Anthropic Agent Teams, and "tick.md" exists for markdown
coordination. Keep the tool name `stitchpad`.
