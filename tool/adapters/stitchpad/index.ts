// stitchpad ← pi extension (herdr-native; self-contained: tools + wake).
//
// earendil pi (@earendil-works/pi-coding-agent) has NO built-in MCP — by design
// (usage.md: "intentionally does not include built-in MCP ... build or install
// as extensions or packages"). So unlike claude/codex (which get stitchpad via
// the MCP server), pi gets everything from THIS extension:
//   - registers join/say/read/who/leave as native pi tools (pi.registerTool)
//   - wakes at agent_end by draining the pad and steering messages in
//
// Wake transport is herdr (the terminal workspace manager hosting the pane):
// join pins `herdr | push | $HERDR_PANE_ID` in the roster, and the watcher's
// herdr.sh adapter injects the nudge from outside with `herdr pane run`
// (text + Enter). Outside herdr there is no pane to poke → `pi | pull | -`,
// and mentions deliver only at turn-end via drain() below.
//
// Identity: pi exposes no per-session id, so we use the pad-default identity
// (.state/whoami, written by `join`). One pi per pad — that's correct, not a
// collision. STITCHPAD_NAME overrides if you want to pin one.
//
// Install (herdr-plugin style, beside herdr-agent-state.ts):
//   cp index.ts ~/.pi/agent/extensions/stitchpad.ts
// One session only:  pi -e <this-dir>/index.ts

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { composePonytail } from "../../instructions/ponytail-compose.mjs";

const exec = promisify(execFile);

function stitchpadBin(): string {
  const fallback = join(homedir(), ".stitchpad", "bin", "stitchpad");
  return existsSync(fallback) ? fallback : "stitchpad";
}

function herdrBin(): string {
  const fallback = join(homedir(), ".local", "bin", "herdr");
  return existsSync(fallback) ? fallback : "herdr";
}

/// This pane's herdr TERMINAL id — the stable wake address (survives pane moves,
/// unlike pane ids). Falls back to the pane id, then "" outside herdr.
async function herdrTarget(): Promise<string> {
  const paneId = process.env.HERDR_ENV === "1" ? process.env.HERDR_PANE_ID || "" : "";
  if (!paneId) return "";
  try {
    const { stdout } = await exec(herdrBin(), ["agent", "get", paneId], { timeout: 5_000 });
    const term = JSON.parse(stdout)?.result?.agent?.terminal_id;
    if (typeof term === "string" && term) return term;
  } catch {}
  return paneId;
}

export default function stitchpadExtension(pi: ExtensionAPI) {
  const bin = stitchpadBin();
  const pinned = process.env.STITCHPAD_NAME || "";
  // Track the per-instance session key set during join.
  // This lets sp_me() resolve via sessions/<key> instead of shared whoami.
  let sessionKey = "";
  let ponytailRules: string | null = null;

  // Run a stitchpad CLI command in the session's cwd. `name` pins STITCHPAD_NAME
  // so the CLI derives the sender from identity, never a trusted arg.
  // Also exports STITCHPAD_SESSION so sp_me() resolves via sessions/<key>.
  async function sp(args: string[], cwd: string, name?: string): Promise<string> {
    const env = {
      ...process.env,
      ...(name ? { STITCHPAD_NAME: name } : {}),
      ...(sessionKey ? { STITCHPAD_SESSION: sessionKey } : {}),
    };
    const { stdout, stderr } = await exec(bin, args, { cwd, timeout: 10_000, env });
    return (stdout || "") + (stderr ? `\n${stderr}` : "");
  }
  async function sharedInstructions(cwd: string): Promise<string> {
    if (ponytailRules === null) {
      ponytailRules = (await sp(["instructions"], cwd).catch(() => "")).trim();
    }
    return ponytailRules;
  }
  const ok = (text: string) => ({ content: [{ type: "text" as const, text: text.trim() || "(ok)" }], details: {} });

  // Shared join/rejoin: used by the explicit tool AND the session_start
  // auto-rejoin. Idempotent — join no-ops on an existing row, set-wake re-pins
  // the live target, heartbeat restarts under THIS process, and the sticky
  // autoname makes the next restart fully automatic.
  async function joinPad(name: string, cwd: string): Promise<string> {
    const target = await herdrTarget();
    const adapter = target ? "herdr" : "pi";
    const wake = target ? "push" : "pull";
    await sp(["join", name, adapter, wake, target || "-"], cwd).catch(() => {});
    await sp(["set-wake", name, wake, target || "-", adapter], cwd).catch(() => {});
    await sp(["meta", "set", name, "runtime", "pi"], cwd).catch(() => {});
    if (process.env.STITCHPAD_MODEL) {
      await sp(["meta", "set", name, "model", process.env.STITCHPAD_MODEL], cwd).catch(() => {});
    }
    // join early-exits before its heartbeat when the row already exists —
    // always restart it explicitly so a rejoin shows online immediately.
    process.env.STITCHPAD_HEARTBEAT_PARENT_PID = String(process.pid);
    await sp(["heartbeat", "start", name], cwd, name).catch(() => {});
    sessionKey = target || "-";
    await sp(["bind-session", sessionKey, name], cwd).catch(() => {});
    await writeFile(join(cwd, ".stitchpad", ".state", "autoname.pi"), name).catch(() => {});
    return target;
  }

  // ── Tools (native pi, no MCP) ──────────────────────────────────────
  pi.registerTool({
    name: "stitchpad_join",
    label: "stitchpad: join",
    description: "Join the stitchpad (shared agent chat for this project): pick your handle. Call once at startup. After joining, @your-name mentions wake you at turn-end.",
    parameters: Type.Object({ name: Type.String({ description: "Your handle, e.g. 'pi'." }) }),
    async execute(_id, params, _sig, _upd, ctx) {
      const target = await joinPad(params.name, ctx.cwd);
      return ok(
        `joined as @${params.name}${target ? "" : " (not in a herdr pane — push wake off; mentions deliver at turn-end)"}. Reply with the stitchpad_say tool. Restarts auto-rejoin from now on.`
      );
    },
  });

  pi.registerTool({
    name: "stitchpad_say",
    label: "stitchpad: say",
    description: "Post a message to the stitchpad as yourself. Start the text with @name to address + wake a teammate. Use this to reply when woken with an incoming message.",
    parameters: Type.Object({ text: Type.String({ description: "The message. Start with @name to address someone." }) }),
    async execute(_id, params, _sig, _upd, ctx) {
      return ok(await sp(["say", params.text], ctx.cwd, pinned || undefined));
    },
  });

  pi.registerTool({
    name: "stitchpad_read",
    label: "stitchpad: read",
    description: "Read the recent stitchpad conversation.",
    parameters: Type.Object({ lines: Type.Optional(Type.Number({ description: "Trailing lines (default 80)." })) }),
    async execute(_id, params, _sig, _upd, ctx) {
      return ok(await sp(["read", "-n", String(params.lines || 80)], ctx.cwd));
    },
  });

  pi.registerTool({
    name: "stitchpad_who",
    label: "stitchpad: who",
    description: "List who is in the stitchpad (the roster).",
    parameters: Type.Object({}),
    async execute(_id, _params, _sig, _upd, ctx) { return ok(await sp(["roster"], ctx.cwd)); },
  });

  pi.registerTool({
    name: "stitchpad_leave",
    label: "stitchpad: leave",
    description: "Leave the stitchpad: remove yourself from the roster and post a departure note.",
    parameters: Type.Object({}),
    async execute(_id, _params, _sig, _upd, ctx) { return ok(await sp(["leave"], ctx.cwd, pinned || undefined)); },
  });

  pi.registerTool({
    name: "stitchpad_tasks",
    label: "stitchpad: tasks",
    description: "List the pad's task board. Check this when you wake or start work — tasks assigned to you are yours to drive without being asked.",
    parameters: Type.Object({
      mine: Type.Optional(Type.Boolean({ description: "Only tasks assigned to me." })),
      status: Type.Optional(Type.String({ description: "Filter: backlog|todo|in_progress|in_review|done|canceled" })),
    }),
    async execute(_id, params, _sig, _upd, ctx) {
      const args = ["task", "list"];
      if (params.mine) {
        const me = pinned || (await sp(["whoami"], ctx.cwd).catch(() => "")).trim();
        if (me) args.push("--mine", me);
      }
      if (params.status) args.push("--status", params.status);
      const out = await sp(args, ctx.cwd);
      return ok(out.trim() ? `id|title|status|priority|assignee|labels|created\n${out.trim()}` : "(no tasks match)");
    },
  });

  pi.registerTool({
    name: "stitchpad_task_new",
    label: "stitchpad: task new",
    description: "Create a task on the pad's board. Use when work is agreed in chat that someone should own — capture it as a ticket instead of leaving it implicit.",
    parameters: Type.Object({
      title: Type.String({ description: "Short imperative title." }),
      priority: Type.Optional(Type.String({ description: "none|low|medium|high|urgent" })),
      assignee: Type.Optional(Type.String({ description: "Handle to assign (e.g. 'codex'). Posts an assignment note that wakes them." })),
      labels: Type.Optional(Type.String({ description: "Comma-separated labels." })),
    }),
    async execute(_id, params, _sig, _upd, ctx) {
      const args = ["task", "new", params.title];
      if (params.priority) args.push("--priority", params.priority);
      if (params.assignee) args.push("--to", params.assignee);
      if (params.labels) args.push("--labels", params.labels);
      return ok(await sp(args, ctx.cwd, pinned || undefined));
    },
  });

  pi.registerTool({
    name: "stitchpad_task_update",
    label: "stitchpad: task update",
    description: "Update a task's status or metadata. MAINTAIN YOUR OWN TICKETS UNPROMPTED: move your task to in_progress the moment you start it, in_review when you post work for review, and done when it's finished and verified — as part of the work itself, not when a human reminds you.",
    parameters: Type.Object({
      id: Type.String({ description: "Task id, e.g. TASK-3." }),
      status: Type.Optional(Type.String({ description: "backlog|todo|in_progress|in_review|done|canceled" })),
      priority: Type.Optional(Type.String({ description: "none|low|medium|high|urgent" })),
      assignee: Type.Optional(Type.String({ description: "Reassign to this handle." })),
      labels: Type.Optional(Type.String({ description: "Replace labels (comma-separated)." })),
    }),
    async execute(_id, params, _sig, _upd, ctx) {
      const parts: string[] = [];
      if (params.status) parts.push(await sp(["task", "move", params.id, params.status], ctx.cwd, pinned || undefined));
      const edit: string[] = [];
      if (params.priority) edit.push("--priority", params.priority);
      if (params.assignee) edit.push("--to", params.assignee);
      if (params.labels) edit.push("--labels", params.labels);
      if (edit.length) parts.push(await sp(["task", "edit", params.id, ...edit], ctx.cwd, pinned || undefined));
      if (!parts.length) return ok("nothing to update — pass status/priority/assignee/labels.");
      return ok(parts.join("\n"));
    },
  });

  // ── Wake (agent_end = pi's idle moment, the claude/codex Stop equivalent) ──
  async function drain(ctx: ExtensionContext) {
    if (!ctx.isIdle()) return;   // don't collide with an in-flight turn
    try {
      const args = pinned ? ["wake", pinned] : ["wake"];
      const { stdout } = await exec(bin, args, { cwd: ctx.cwd, timeout: 10_000 });
      const msg = stdout.trim();
      if (!msg) return;
      await pi.sendMessage(
        { customType: "stitchpad_message", content: msg, display: true },
        { triggerTurn: true, deliverAs: "nextTurn" }
      );
    } catch {
      // no pad here / CLI missing / non-zero → silent no-op
    }
  }

  // Zero-friction restarts: if this pad has a sticky pi handle (written on the
  // first explicit join), a fresh/reloaded session rejoins automatically —
  // re-pins the wake target, restarts the heartbeat, re-binds. No tool call.
  async function autoRejoin(ctx: ExtensionContext) {
    try {
      const nameFile = join(ctx.cwd, ".stitchpad", ".state", "autoname.pi");
      if (!existsSync(nameFile)) return;
      const name = pinned || (await readFile(nameFile, "utf8")).trim();
      if (!name) return;
      await joinPad(name, ctx.cwd);
    } catch {
      // no pad / CLI missing → stay silent, the explicit join tool still works
    }
  }

  pi.on("agent_end", async (_e, ctx) => { await drain(ctx); });
  pi.on("before_agent_start", async (event, ctx) => {
    const rules = await sharedInstructions(ctx.cwd);
    if (!rules) return;
    const base = event?.systemPrompt || "";
    const systemPrompt = composePonytail(rules, base);
    if (systemPrompt === base) return;
    return { systemPrompt };
  });
  pi.on("session_start", async (_e, ctx) => {
    await autoRejoin(ctx);
    await drain(ctx);
  });
}
