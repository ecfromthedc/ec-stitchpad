#!/usr/bin/env node
// stitchpad MCP server — the agent-facing side of stitchpad.
//
// ── TWO MODES ─────────────────────────────────────────────────────────
// LOCAL MODE (default): every tool shells out to the local `stitchpad` CLI,
//   which reads/writes the on-disk .stitchpad/stitchpad.md + isolated git. This
//   is how a teammate ON the host machine joins the pad. Nothing here changes.
//
// RELAY MODE: an agent on a REMOTE machine has no local pad file. When BOTH
//   STITCHPAD_RELAY (the Cloudflare relay base URL) and an invite/token are set,
//   the tools route over HTTP to the relay instead of the local CLI:
//     • STITCHPAD_INVITE                → redeemed ONCE at startup via POST /join-request
//     • STITCHPAD_TOKEN + STITCHPAD_PAD → used directly (skip the redeem)
//   say  → POST /say?pad=<pad>   {from, text}
//   read → GET  /pad?pad=<pad>   (returns {pad, roster, profiles}; we slice .pad)
//   who  → GET  /pad?pad=<pad>   (returns the .roster list)
//   join → no-op confirm (already joined via the invite redeem at startup)
//   leave→ courtesy /say "left"
//   Every relay call carries: authorization: Bearer <relayToken>, content-type json.
//
// Mode is chosen ONCE at startup (RELAY_MODE below) and every tool handler
// branches `if (RELAY_MODE) {...} else {<existing local CLI code>}`.
//
// The MCP is the ROSTER + TALKING surface. An agent adds this server and, at
// startup, calls `join` to pick its name and declare which runtime it is. The
// runtime's wake hook still needs STITCHPAD_NAME pinned to that name. The MCP
// does NOT do the wake itself.
//
// Tools:
//   join  — add yourself to the roster
//   say   — post a message to the pad (start with @name to address a teammate)
//   read  — read the recent conversation
//   who   — list the roster
//
// There is intentionally no `wait_for_mention`: the wake is the runtime's own
// turn-end hook reading the pad, not an MCP poll. MCP = register + talk; the
// hook does the waking.
//
// All LOCAL state lives in stitchpad.md + the isolated git, written via the
// `stitchpad` CLI so there is exactly one implementation of roster/commit logic.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFile, execFileSync } from "node:child_process";
import { chmod, mkdir, writeFile } from "node:fs/promises";
import fsSync from "node:fs";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import path from "node:path";

const execFileP = promisify(execFile);

// Resolve the stitchpad CLI relative to this file: tool/mcp/server.mjs -> tool/bin/stitchpad
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const STITCHPAD_HOME = path.resolve(__dirname, "..");
const CLI = path.join(STITCHPAD_HOME, "bin", "stitchpad");

// ── Mode detection: local pad (CLI) vs remote relay (HTTP) ──────────────
// RELAY MODE activates when STITCHPAD_RELAY (the relay base URL) is set together
// with either an invite (STITCHPAD_INVITE, redeemed once at startup) or a
// pre-issued bearer token (STITCHPAD_TOKEN, used directly with STITCHPAD_PAD).
// Otherwise we run in LOCAL MODE and shell out to the `stitchpad` CLI as before.
const RELAY_URL = (process.env.PASTURE_RELAY || process.env.STITCHPAD_RELAY || "").replace(/\/+$/, "");
const RELAY_INVITE = process.env.PASTURE_INVITE || process.env.STITCHPAD_INVITE || "";
const RELAY_MODE = !!(RELAY_URL && (RELAY_INVITE || process.env.PASTURE_TOKEN || process.env.STITCHPAD_TOKEN));

if (RELAY_MODE) {
  try {
    new URL(RELAY_URL);
  } catch {
    console.error("[stitchpad-mcp] STITCHPAD_RELAY is not a valid URL");
    process.exit(1);
  }
}

// Relay session, held in memory. Populated by redeemInvite() at startup (invite
// path) or straight from env (direct-token path). All relay HTTP calls use these.
let relayToken = process.env.PASTURE_TOKEN || process.env.STITCHPAD_TOKEN || "";
let padName = process.env.PASTURE_PAD || process.env.STITCHPAD_PAD || "";
let myHandle = process.env.PASTURE_HANDLE || process.env.STITCHPAD_HANDLE || "";

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

async function persistRelayHookEnv() {
  if (!RELAY_MODE || !relayToken || !padName || !myHandle) return;
  const stateDir = path.join(process.env.HOME || "", ".stitchpad", ".state");
  if (!stateDir.startsWith("/")) return;
  await mkdir(stateDir, { recursive: true, mode: 0o700 }).catch(() => {});
  const body = [
    `STITCHPAD_RELAY=${shellQuote(RELAY_URL)}`,
    `STITCHPAD_TOKEN=${shellQuote(relayToken)}`,
    `STITCHPAD_PAD=${shellQuote(padName)}`,
    `STITCHPAD_NAME=${shellQuote(myHandle)}`,
    `STITCHPAD_HANDLE=${shellQuote(myHandle)}`,
    "",
  ].join("\n");
  const files = [path.join(stateDir, "relay-hook.env")];
  if (SESSION_ID) files.unshift(path.join(stateDir, `relay-hook.${SESSION_ID}.env`));
  for (const file of files) {
    await writeFile(file, body, { mode: 0o600 });
    await chmod(file, 0o600).catch(() => {});
  }
}

// Where is the pad? Resolved PER CALL, never pinned at startup. The old code
// captured process.cwd() once when the harness spawned this server — so a
// terminal that later joined a different pad kept silently posting/reading
// through the STARTUP pad forever (the cross-pad bleed). Resolution order:
//   1. this terminal's identity lock (~/.stitchpad-terminals/<surface> =
//      "pad_dir|name|epoch", heartbeat-fresh) → THAT pad, wherever it is;
//   2. STITCHPAD_CWD env override;
//   3. the server's cwd (walk-up happens in the CLI).
function currentHerdrTerminalId() {
  const pane = process.env.HERDR_PANE_ID || "";
  if (!pane) return "";
  try {
    const raw = execFileSync("herdr", ["pane", "get", pane], { encoding: "utf8", timeout: 3000 });
    return JSON.parse(raw).terminal_id || "";
  } catch { return ""; }
}
function padCwd() {
  const terminal = currentHerdrTerminalId();
  if (terminal) {
    try {
      const raw = fsSync.readFileSync([path.join(process.env.HOME || "", ".pasture-terminals", terminal), path.join(process.env.HOME || "", ".stitchpad-terminals", terminal)].find(f => fsSync.existsSync(f)) || path.join(process.env.HOME || "", ".stitchpad-terminals", terminal), "utf8");
      const [padDir, , ts] = raw.trim().split("|");
      if (padDir && Date.now() / 1000 - (+ts || 0) < 300) return path.dirname(padDir);
    } catch {}
  }
  return process.env.PASTURE_CWD || process.env.STITCHPAD_CWD || process.cwd();
}

// `me` pins STITCHPAD_NAME for this call so the CLI derives the sender from
// identity, not a trusted arg. (LOCAL MODE only — relay tools call relay* below.)
// NOTE: sp() output is consumed PROGRAMMATICALLY in places (whoami → identity
// validation) — never decorate it here. Agent-facing handlers add padStamp().
async function sp(args, me, extraEnv = {}) {
  const { stdout, stderr } = await execFileP(CLI, args, {
    cwd: padCwd(),
    env: { ...process.env, STITCHPAD_HOME, ...extraEnv, ...(me ? { STITCHPAD_NAME: me } : {}) },
    maxBuffer: 1024 * 1024,
  });
  return (stdout || "") + (stderr ? `\n${stderr}` : "");
}
// Stamp agent-facing results with the pad they actually hit, so a misrouted
// call is self-evident to the agent instead of silent.
const padStamp = (s) => `${s}\n[pad: ${path.basename(padCwd())}]`;

// ── Relay HTTP client (remote-agent mode) ───────────────────────────────
function relayHeaders() {
  return {
    authorization: `Bearer ${relayToken}`,
    "content-type": "application/json",
  };
}

// Startup redeem: trade the one-time invite for a relay bearer token + pad + handle.
// POST /join-request {token: <invite>} → {token: <relayBearer>, pad, handle}
async function redeemInvite() {
  const r = await fetch(`${RELAY_URL}/join-request`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: RELAY_INVITE }),
  });
  if (!r.ok) throw new Error(`join-request ${r.status}: ${await r.text()}`);
  const j = await r.json();
  if (!j.token) throw new Error(`join-request returned no token: ${JSON.stringify(j)}`);
  relayToken = j.token;
  if (j.pad) padName = j.pad;
  if (j.handle) myHandle = j.handle;
}

// say → POST /say?pad=<pad> {from, text}
async function relaySay(textBody) {
  const r = await fetch(`${RELAY_URL}/say?pad=${encodeURIComponent(padName)}`, {
    method: "POST",
    headers: relayHeaders(),
    body: JSON.stringify({ from: myHandle, text: textBody }),
  });
  if (!r.ok) throw new Error(`say ${r.status}: ${await r.text()}`);
  return `posted to ${padName} as @${myHandle}`;
}

// GET /pad?pad=<pad> → {pad: <markdown>, roster:[...], profiles:{...}}
async function relayGetPad() {
  const r = await fetch(`${RELAY_URL}/pad?pad=${encodeURIComponent(padName)}`, {
    headers: relayHeaders(),
  });
  if (!r.ok) throw new Error(`pad ${r.status}: ${await r.text()}`);
  return r.json();
}

// read → recent slice of the pad markdown (last ~2000 chars).
async function relayRead() {
  const { pad = "" } = await relayGetPad();
  const slice = pad.length > 2000 ? pad.slice(-2000) : pad;
  return slice || "(pad is empty)";
}

// who → the roster list from the pad payload.
async function relayWho() {
  const { roster = [] } = await relayGetPad();
  if (!roster.length) return "(roster is empty)";
  return roster
    .map((m) => (typeof m === "string" ? m : m.name || m.handle || JSON.stringify(m)))
    .join("\n");
}


// Recover HERDR_PANE_ID from the parent when an MCP child did not inherit it.
// This keeps push-target auto-detection working for runtimes that filter env vars.
async function parentHerdrEnv() {
  const pane = process.env.HERDR_PANE_ID || "";
  if (pane) return { HERDR_PANE_ID: pane };
  try {
    const { stdout } = await execFileP("ps", ["eww", "-p", String(process.ppid), "-o", "command="], {
      maxBuffer: 1024 * 1024,
    });
    const m = stdout.match(/(?:^|\s)HERDR_PANE_ID=([^\s]+)/);
    return { HERDR_PANE_ID: m ? m[1] : "" };
  } catch {
    return { HERDR_PANE_ID: "" };
  }
}

async function herdrTerminalId(paneId) {
  const bins = ["herdr", path.join(process.env.HOME || "", ".local", "bin", "herdr")];
  for (const bin of bins) {
    try {
      const { stdout } = await execFileP(bin, ["agent", "get", paneId], { maxBuffer: 1024 * 1024 });
      const m = stdout.match(/"terminal_id"\s*:\s*"([^"]+)"/);
      if (m) return m[1];
    } catch { /* try next candidate */ }
  }
  return "";
}

// ── Identity, server-side ─────────────────────────────────────────────
// This server process serves exactly ONE agent session. The agent declares its
// name once via join(); we hold it here in memory so say/reply derive the sender
// — the agent never passes a name, so it cannot post as anyone else. We also
// write .state/sessions/<session_id> = name so the (separate) Stop-hook process
// can resolve the same identity from its payload's session_id.
let ME = null;                                   // the joined name; null until join
const SESSION_ID =
  process.env.STITCHPAD_SESSION ||
  process.env.CLAUDE_CODE_SESSION_ID ||
  process.env.CODEX_SESSION_ID ||
  "";

async function bindSession(name, extraEnv = {}) {
  ME = name;
  // With a session id (claude/codex): bind sessions/<id> so the Stop hook resolves
  // it from its payload. Without one (pi exposes no session id): bind the pad-level
  // default identity, which the pi extension's wake reads. pi is single-identity
  // per pad, so a pad default is correct, not a collision risk.
  const arg = SESSION_ID || "-";   // "-" = pad default (see CLI bind-session)
  await sp(["bind-session", arg, name], name, extraEnv).catch(() => {});
}

const server = new Server(
  { name: "stitchpad", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

const TOOLS = [
  {
    name: "join",
    description:
      "Join the stitchpad: pick your handle and declare your runtime. Call once " +
      "at startup. Your runtime's wake hook must also be pinned with " +
      "STITCHPAD_NAME=<your-name> so it knows to deliver messages addressed to " +
      "@you. After joining, you'll be woken at each turn-end whenever someone " +
      "posts a line starting with @your-name.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Your handle in the room, e.g. 'larry'." },
        adapter: {
          type: "string",
          enum: ["claude", "codex", "pi"],
          description:
            "Which runtime you are — selects how you get woken: claude/codex via " +
            "their Stop hook, pi via the pi adapter extension. All read the pad at " +
            "turn-end; no keystrokes are sent to your terminal.",
        },
      },
      required: ["name", "adapter"],
    },
  },
  {
    name: "say",
    description:
      "Post a message to the stitchpad as yourself (the name you joined as — the " +
      "server knows who you are, you cannot post as anyone else). To address a " +
      "teammate and wake them, start your text with @their-name; @flock (or @all) " +
      "wakes everyone at once. This is also how you reply when the wake hook " +
      "blocks you with an incoming message. Pass reply_to (a #m-… id from a " +
      "message header) to thread your message under that one — do this whenever " +
      "you're answering a specific message in a busy room.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "The message. Start with @name to address+wake someone; @flock wakes everyone." },
        reply_to: { type: "string", description: "Optional #m-… id to thread this message under." },
      },
      required: ["text"],
    },
  },
  {
    name: "amend",
    description:
      "Rewrite the BODY of one of YOUR OWN messages in place (by its #m-… id). " +
      "Header, id, and thread links survive; each amend is a git commit so " +
      "history keeps every version. Use it for LIVE cards — e.g. update a " +
      "posted ui timeline as your run progresses — or to correct your last " +
      "message. You cannot amend other agents' messages.",
    inputSchema: {
      type: "object",
      properties: {
        message_id: { type: "string", description: "The #m-… id of YOUR message to rewrite." },
        text: { type: "string", description: "The full replacement body (markdown, fences included)." },
      },
      required: ["message_id", "text"],
    },
  },
  {
    name: "react",
    description:
      "React to a message (by its #m-… header id) with an emoji or short word — " +
      "a lightweight ack that never wakes anyone. Use it instead of a whole " +
      "message when 👍 / ✅ / 👀 is the entire content. Same emoji again removes " +
      "your reaction.",
    inputSchema: {
      type: "object",
      properties: {
        message_id: { type: "string", description: "The #m-… id from the target message's header." },
        emoji: { type: "string", description: "One emoji or a short word (≤24 chars), e.g. 👍 ✅ 👀 🔥 ship-it." },
      },
      required: ["message_id", "emoji"],
    },
  },
  {
    name: "ui",
    description:
      "Post a rich component into the chat — ONLY when it genuinely beats prose " +
      "at collaborating on work: a diff to review, a table to scan, a poll to " +
      "decide, a form to fill, a checklist to track, sign-off to request. " +
      "Default to plain say; a room full of components is noise. Types: " +
      "callout, checklist, table, progress, diff, poll, approve, form (+ their " +
      ".vote/.verdict/.response reply types, which MUST set reply_to to the " +
      "originating component's #m-… id). `alt` is the one-line plain-text " +
      "stand-in every non-rich surface shows — write it like a normal message.",
    inputSchema: {
      type: "object",
      properties: {
        type: { type: "string", description: "Component type, e.g. 'table', 'poll', 'approve.verdict'." },
        payload: { type: "object", description: "The component payload — schema-checked; invalid payloads are rejected with the exact problems." },
        alt: { type: "string", description: "One-line plain-text fallback shown by the TUI/CLI. Required." },
        reply_to: { type: "string", description: "Optional #m-… id to thread under (REQUIRED for *.vote/*.verdict/*.response)." },
      },
      required: ["type", "payload", "alt"],
    },
  },
  {
    name: "shift_change",
    description:
      "END-OF-SHIFT handoff: write the complete invocation prompt your fresh " +
      "replacement session needs (who you are, pad mechanics, discipline, open " +
      "board, first moves — everything, it starts with ZERO context). Call this " +
      "as your LAST act, then finish your turn and stop. The bridge waits for " +
      "your pane to go idle, clears the session, and pastes your handoff into " +
      "the fresh chat automatically. Do not keep working after calling this.",
    inputSchema: {
      type: "object",
      properties: {
        handoff: { type: "string", description: "The full invocation prompt for your fresh session." },
      },
      required: ["handoff"],
    },
  },
  {
    name: "dm_say",
    description:
      "Send a PRIVATE direct message to one teammate — never lands on the pad. " +
      "Use this to answer incoming DMs (the operator's phone DMs arrive marked " +
      "PRIVATE) or for 1:1 side-channel coordination. Replying to a DM with the " +
      "public say tool broadcasts it to everyone — don't.",
    inputSchema: {
      type: "object",
      properties: {
        to: { type: "string", description: "Recipient handle (e.g. 'smaths')." },
        text: { type: "string", description: "The private message." },
      },
      required: ["to", "text"],
    },
  },
  {
    name: "dm_read",
    description:
      "Read your private DM conversation with one teammate (both directions, " +
      "stored locally per pair). Check this when a DM wake references earlier " +
      "context you don't have.",
    inputSchema: {
      type: "object",
      properties: {
        with: { type: "string", description: "The other party's handle." },
        lines: { type: "number", description: "How many recent messages (default 30)." },
      },
      required: ["with"],
    },
  },
  {
    name: "read",
    description: "Read the recent stitchpad conversation.",
    inputSchema: {
      type: "object",
      properties: {
        lines: { type: "number", description: "How many trailing lines to show (default 80).", default: 80 },
      },
    },
  },
  {
    name: "who",
    description: "List who is in the room (the parsed roster).",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "leave",
    description:
      "Leave the stitchpad: remove yourself from the roster and post a departure " +
      "note. Call when you're done collaborating or shutting down.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "tasks",
    description:
      "List the pad's task board (kanban tickets living in stitchpad.md). Check " +
      "this when you wake or start work — tasks assigned to you are yours to " +
      "drive without being asked.",
    inputSchema: {
      type: "object",
      properties: {
        mine: { type: "boolean", description: "Only tasks assigned to me." },
        status: {
          type: "string",
          enum: ["backlog", "todo", "in_progress", "in_review", "done", "canceled"],
          description: "Filter by status.",
        },
      },
    },
  },
  {
    name: "task_new",
    description:
      "Create a task on the pad's board. Use when work is agreed in chat that " +
      "someone should own — capture it as a ticket instead of leaving it implicit.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "Short imperative title." },
        priority: { type: "string", enum: ["none", "low", "medium", "high", "urgent"] },
        assignee: { type: "string", description: "Handle to assign (e.g. 'pi'). Posts an assignment note that wakes them." },
        labels: { type: "string", description: "Comma-separated labels." },
      },
      required: ["title"],
    },
  },
  {
    name: "task_update",
    description:
      "Update a task's status or metadata. MAINTAIN YOUR OWN TICKETS UNPROMPTED: " +
      "move your task to in_progress the moment you start it, in_review when you " +
      "post work for review, and done when it's finished and verified — as part of " +
      "the work itself, not when a human reminds you.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Task id, e.g. TASK-3." },
        status: { type: "string", enum: ["backlog", "todo", "in_progress", "in_review", "done", "canceled"] },
        priority: { type: "string", enum: ["none", "low", "medium", "high", "urgent"] },
        assignee: { type: "string", description: "Reassign to this handle." },
        labels: { type: "string", description: "Replace labels (comma-separated)." },
      },
      required: ["id"],
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: a = {} } = req.params;
  try {
    let out;
    switch (name) {
      case "join": {
        const adapter = a.adapter;
        if (!["claude", "codex", "pi"].includes(adapter)) {
          return text("adapter must be one of: claude, codex, pi");
        }
        if (RELAY_MODE) {
          // Already joined via the invite redeem at startup — there is no local
          // roster to write. Just confirm identity + pad. Honor the relay-assigned
          // handle (myHandle) when present, else adopt the requested name.
          if (a.name && !myHandle) myHandle = a.name;
          await persistRelayHookEnv();
          out =
            `(relay mode) you are @${myHandle || a.name} on pad "${padName}". ` +
            `Already joined via invite — use say/read/who. Stop-hook wake is wired from relay state. Identity is fixed server-side.`;
          break;
        }
        // Identity is bound to THIS coding session, not the name argument. If this
        // session already joined, that handle is locked — reuse it and ignore any
        // name passed. Only a session with no prior binding may set a name; absent
        // a name we derive a stable one from the session id. A session can never be
        // shoved into another session's identity.
        // The result must LOOK like a handle before we adopt it — an older CLI
        // answered unknown commands with its full help text at exit 0, and that
        // blob became an agent's identity. Anything non-handle-shaped = unbound.
        const boundRaw = SESSION_ID
          ? await sp(["whoami"], undefined, { STITCHPAD_SESSION: SESSION_ID }).then(s => s.trim()).catch(() => "")
          : "";
        const bound = /^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/.test(boundRaw) ? boundRaw : "";
        if (bound) {
          ME = bound;
          // Rejoin (e.g. after an MCP restart): identity is locked, but the heartbeat
          // ticker died with the old process — restart it so the live roster shows us.
          await sp(["heartbeat", "start", bound], bound, {
            STITCHPAD_SESSION: SESSION_ID,
            STITCHPAD_HEARTBEAT_PARENT_PID: String(process.ppid),
          }).catch(() => {});
          out = `(already joined this session as @${bound} — identity is locked to your session id; rejoin returns the same handle.)`;
          break;
        }
        const handle = (a.name && a.name.trim())
          || (SESSION_ID ? SESSION_ID.replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 8) : "")
          || "agent";
        // Herdr is the only terminal push transport. Outside a Herdr pane, join
        // with the runtime adapter in pull mode so its lifecycle hook remains the
        // sole owner of delivery. Ocean sessions bind their daemon target separately.
        const herdrEnv = await parentHerdrEnv();
        const termId = herdrEnv.HERDR_PANE_ID
          ? await herdrTerminalId(herdrEnv.HERDR_PANE_ID)
          : "";
        const rosterAdapter = termId ? "herdr" : adapter;
        const wake = termId ? "push" : "pull";
        const target = termId || "-";
        const wakeEnv = herdrEnv.HERDR_PANE_ID
          ? { HERDR_PANE_ID: herdrEnv.HERDR_PANE_ID }
          : {};
        out = await sp(["join", handle, rosterAdapter, wake, target], undefined, wakeEnv);
        await sp(["meta", "set", handle, "runtime", adapter]).catch(() => {});
        const model =
          process.env.STITCHPAD_MODEL ||
          process.env.CODEX_MODEL ||
          process.env.CLAUDE_MODEL ||
          process.env.ANTHROPIC_MODEL ||
          "";
        if (model) {
          await sp(["meta", "set", handle, "model", model]).catch(() => {});
        }
        await bindSession(handle, wakeEnv);   // hold identity + write session record for the hook
        // Sticky handle for zero-friction restarts: the SessionStart hook reads
        // .state/autoname.claude and auto-rebinds a NEW session to this name.
        try {
          const fs = await import("node:fs");
          fs.writeFileSync(path.join(process.cwd(), ".stitchpad", ".state", `autoname.${adapter}`), handle);
        } catch { /* pad may be relay/remote — sticky name is best-effort */ }
        out += target === "-"
          ? `\n(you are @${handle}, but no Herdr pane was detected — hook-based turn-end wake applies.)`
          : `\n(you are @${handle}; @${handle} mentions wake this Herdr pane. Reply with the say tool — identity is locked to your session.)`;
        break;
      }
      case "say": {
        if (RELAY_MODE) {
          out = await relaySay(a.text);
          break;
        }
        if (!ME) return text("call join first — you have no identity in this stitchpad yet.", true);
        const sayArgs = ["say"];
        if (a.reply_to) sayArgs.push("--re", String(a.reply_to));
        sayArgs.push(a.text);
        out = padStamp(await sp(sayArgs, ME));   // sender derived from server memory, never the agent
        break;
      }
      case "react":
        if (RELAY_MODE) return text("reactions are not available over relay yet.", true);
        if (!ME) return text("call join first — reactions need your identity.", true);
        out = padStamp(await sp(["react", String(a.message_id), String(a.emoji)], ME));
        break;
      case "amend": {
        if (RELAY_MODE) return text("amend is not available over relay yet.", true);
        if (!ME) return text("call join first — amend needs your identity.", true);
        const os = await import("node:os");
        const tmp = path.join(os.tmpdir(), `amend-${ME}-${process.pid}.md`);
        fsSync.writeFileSync(tmp, String(a.text || ""));
        out = padStamp(await sp(["amend", String(a.message_id), "--file", tmp], ME));
        try { fsSync.unlinkSync(tmp); } catch {}
        break;
      }
      case "ui": {
        if (RELAY_MODE) return text("ui components are not available over relay yet.", true);
        if (!ME) return text("call join first — ui components need your identity.", true);
        const { validate, composeFence } = await import(
          new URL("../pwa/ui/schemas.mjs", import.meta.url)
        );
        const uiType = String(a.type || "");
        const problems = validate(uiType, a.payload);
        if (problems.length) {
          return text(`ui rejected:\n- ${problems.join("\n- ")}`, true);
        }
        const isReplyType = /\.(vote|verdict|response)$/.test(uiType);
        if (isReplyType && !a.reply_to) {
          return text(`ui rejected: type "${uiType}" is a reply component — reply_to (the origin's #m-… id) is required.`, true);
        }
        const alt = String(a.alt || "").split("\n")[0].trim();
        if (!alt) return text("ui rejected: alt (one-line plain-text fallback) is required.", true);
        const body = composeFence(uiType, a.payload, alt);
        const uiArgs = ["say"];
        if (a.reply_to) uiArgs.push("--re", String(a.reply_to));
        uiArgs.push(body);
        out = padStamp(await sp(uiArgs, ME));
        break;
      }
      case "shift_change": {
        if (RELAY_MODE) return text("shift-change is not available over relay yet.", true);
        if (!ME) return text("call join first — shift-change needs your identity.", true);
        const os = await import("node:os");
        const tmp = path.join(os.tmpdir(), `shift-${ME}-${process.pid}.md`);
        fsSync.writeFileSync(tmp, String(a.handoff || ""));
        out = padStamp(await sp(["shift-change", "--save", ME, "--file", tmp], ME));
        try { fsSync.unlinkSync(tmp); } catch {}
        break;
      }
      case "dm_say":
        if (RELAY_MODE) return text("DMs are not available over relay yet.", true);
        if (!ME) return text("call join first — DMs need your identity.", true);
        out = padStamp(await sp(["dm", "say", String(a.to || "").replace(/^@/, ""), a.text], ME));
        break;
      case "dm_read":
        if (RELAY_MODE) return text("DMs are not available over relay yet.", true);
        if (!ME) return text("call join first — DMs need your identity.", true);
        out = padStamp(await sp(["dm", "read", String(a.with || "").replace(/^@/, ""), "-n", String(a.lines || 30)], ME));
        break;
      case "read":
        if (RELAY_MODE) {
          out = await relayRead();
          break;
        }
        out = padStamp(await sp(["read", "-n", String(a.lines || 80)]));
        break;
      case "who":
        if (RELAY_MODE) {
          out = await relayWho();
          break;
        }
        out = padStamp(await sp(["roster"]));
        break;
      case "leave":
        if (RELAY_MODE) {
          // Courtesy note; relay membership tears down server-side. Best-effort.
          await relaySay("left").catch(() => {});
          out = "left (relay)";
          break;
        }
        if (!ME) return text("you haven't joined this stitchpad.", true);
        out = await sp(["leave", ME], ME);
        ME = null;
        break;
      case "tasks": {
        if (RELAY_MODE) return text("tasks are not available over relay yet.", true);
        const args = ["task", "list"];
        if (a.mine) {
          if (!ME) return text("call join first — 'mine' needs your identity.", true);
          args.push("--mine", ME);
        }
        if (a.status) args.push("--status", a.status);
        out = await sp(args);
        out = out.trim()
          ? `id|title|status|priority|assignee|labels|created|description\n${out.trim()}`
          : "(no tasks match)";
        break;
      }
      case "task_new": {
        if (RELAY_MODE) return text("tasks are not available over relay yet.", true);
        if (!ME) return text("call join first — tasks are authored under your identity.", true);
        const args = ["task", "new", a.title];
        if (a.priority) args.push("--priority", a.priority);
        if (a.assignee) args.push("--to", a.assignee);
        if (a.labels) args.push("--labels", a.labels);
        out = await sp(args, ME);
        break;
      }
      case "task_update": {
        if (RELAY_MODE) return text("tasks are not available over relay yet.", true);
        if (!ME) return text("call join first — tasks are updated under your identity.", true);
        if (!a.id) return text("task id required (e.g. TASK-3).", true);
        const parts = [];
        if (a.status) {
          parts.push(await sp(["task", "move", a.id, a.status], ME));
        }
        const edit = [];
        if (a.priority) edit.push("--priority", a.priority);
        if (a.assignee) edit.push("--to", a.assignee);
        if (a.labels) edit.push("--labels", a.labels);
        if (edit.length) {
          parts.push(await sp(["task", "edit", a.id, ...edit], ME));
        }
        if (!parts.length) return text("nothing to update — pass status/priority/assignee/labels.", true);
        out = parts.join("\n");
        break;
      }
      default:
        return text(`unknown tool: ${name}`, true);
    }
    return text(out.trim() || "(ok)");
  } catch (err) {
    return text(`stitchpad error: ${err.stderr || err.message}`, true);
  }
});

function text(s, isError = false) {
  return { content: [{ type: "text", text: s }], isError };
}

// Auto-leave when the agent's session ends (the runtime kills this server).
// Best-effort + synchronous-ish: post the departure note before we exit.
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    if (RELAY_MODE) {
      if (relayToken && padName) await relaySay("left").catch(() => {});
    } else if (ME) {
      await sp(["leave", ME], ME).catch(() => {});
    }
    process.exit(0);
  });
}

// ── Startup ─────────────────────────────────────────────────────────────
// In relay mode with an invite, redeem it ONCE before serving so say/read/who
// have a bearer token + pad + handle ready. Direct-token mode skips this.
if (RELAY_MODE && RELAY_INVITE && !relayToken) {
  try {
    await redeemInvite();
    await persistRelayHookEnv();
    console.error(`[stitchpad-mcp] relay: joined pad "${padName}" as @${myHandle}`);
  } catch (err) {
    console.error(`[stitchpad-mcp] relay redeem failed: ${err.message}`);
    process.exit(1);
  }
} else if (RELAY_MODE) {
  await persistRelayHookEnv();
  console.error(`[stitchpad-mcp] relay: direct token, pad "${padName}" as @${myHandle}`);
}

// ── Auto-start relay-watch poller (inbound @mention wake) ──────────────
// In relay mode, spawn a background poller that watches the relay for new
// @mentions and fires the local app surface. One-paste UX: no second command.
if (RELAY_MODE && myHandle && relayToken) {
  const { spawn } = await import("node:child_process");
  const watchScript = path.join(STITCHPAD_HOME, "relay", "watch.sh");
  const child = spawn("bash", [watchScript], {
    env: {
      ...process.env,
      STITCHPAD_RELAY: RELAY_URL,
      STITCHPAD_TOKEN: relayToken,
      STITCHPAD_NAME: myHandle,
      STITCHPAD_PAD: padName,
    },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  child.stderr.on("data", (d) => console.error(`[relay-watch] ${d.toString().trim()}`));
  child.on("error", (e) => console.error(`[relay-watch] spawn failed: ${e.message}`));
  child.on("exit", (code) => console.error(`[relay-watch] exited with code ${code}`));
  child.unref();
  console.error(`[stitchpad-mcp] relay-watch poller spawned (pid ${child.pid})`);
}

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("[stitchpad-mcp] ready");
