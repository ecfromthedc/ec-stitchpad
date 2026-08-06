# stitchpad - TASKS

> Working backlog. Priority order top-down.

## Done (2026-06-14)
- [x] **Rename chatroom -> stitchpad everywhere.** `sp_` prefix,
      `STITCHPAD_HOME`, `stitchpad.md`, `.stitchpad/`, `stitchpad-git`, `sgit`.
      `stitchpad-tui` symlink created.
- [x] **Hook-driven wake architecture.** Claude Code and Codex share
      `tool/adapters/stop-hook.sh`; pi uses `tool/adapters/stitchpad/`. Identity is
      pinned with `STITCHPAD_NAME`, and adapters feed addressed messages back as
      the next turn at the runtime's turn-end hook.
- [x] **MCP server** (`tool/mcp/server.mjs`). Tools: `join`, `say`, `read`,
      `who`. MCP records roster entries and posts messages; it does not wake
      agents.
- [x] **Watcher bug fixed.** The optional fswatch watcher no longer lets inner
      reads consume the fswatch pipe, and the old unbound-var path is removed.
- [x] **TUI and install path.** `stitchpad-tui` resolves through the installed
      symlink, and `~/.stitchpad` points at this checkout's `tool/` directory.
- [x] **Wake regression coverage.** `test/wake-regression.sh` covers bounded
      addressed blocks and ensures unrelated later commits do not re-emit old
      mentions. It also covers explicit hook identity.

## Later / optional
- [ ] **Auto-join on MCP session load.** Right now the agent must call `join`
      once. Consider a session-start nudge or MCP initialization pattern so
      registration is closer to zero-touch.
- [ ] **Improve non-interactive TUI behavior.** `stitchpad-tui --help` currently
      launches the live TUI. Add a real help/usage path.
- [ ] **Migrate Librarian onto it.** Add chief + larry to a real
      `.stitchpad/stitchpad.md` when that project is ready.

---

### Test Pattern That Worked
Use a temp directory, run `stitchpad init`, `stitchpad join <name> <runtime>`,
post a line that starts with `@name`, then assert:

- `stitchpad wake <name>` or `STITCHPAD_NAME=<name> stitchpad wake` prints the
  stitchpad context preface + addressed block once.
- A second wake for the same name is empty because the cursor advanced.
- The Stop hook returns `{"decision":"block","reason":...}` when stdin contains
  `{"cwd":"<pad-dir>","stop_hook_active":false}`.
- The Stop hook exits silently when `stop_hook_active` is true.

For MCP, run `node tool/mcp/server.mjs` over stdio and drive JSON-RPC tool
calls. The MCP should only register/read/write; wake remains the runtime hook.

### Verified Working
init - join - say - read - roster/who - mention detection - `stitchpad wake`
context preface + cursor drain - Claude/Codex Stop hook JSON response - MCP
server startup - isolated-git blame trail - install symlinks.
