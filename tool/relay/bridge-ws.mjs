#!/usr/bin/env node
// stitchpad bridge-ws — realtime Mac bridge (replaces bridge.sh's polling loop).
//
// One websocket per pad into its PadHub Durable Object (role=bridge):
//   inbound  (instant): say → `stitchpad say` · dm → herdr pane injection ·
//                       file → download into <project>/.stitchpad/dropbox/
//   outbound (instant): fs.watch on stitchpad.md → bridge-push-once.sh → the DO
//                       fans the changed pad out to every connected phone.
// Safety nets: full push sweep every 45s (presence/status refresh), HTTP queue
// drain every 30s (catches messages queued while a socket was down).
//
//   STITCHPAD_RELAY=... STITCHPAD_TOKEN=... node bridge-ws.mjs [roots...]
import { execFile, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, watch, writeFileSync, readFileSync, readdirSync, truncateSync, statSync, openSync, readSync, closeSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import os from "node:os";

// PASTURE COMPAT (stage 1): PASTURE_* env wins, STITCHPAD_* accepted until stage 4
const env = (k, d) => process.env["PASTURE_" + k] ?? process.env["STITCHPAD_" + k] ?? d;
const RELAY = env("RELAY", "https://pasture.agentsworld.org");
const TOKEN = env("TOKEN");
if (!TOKEN) { console.error("[bridge-ws] PASTURE_TOKEN (or STITCHPAD_TOKEN) required"); process.exit(1); }
const ROOTS = process.argv.slice(2).length ? process.argv.slice(2) : [os.homedir()];
// optional allowlist: PASTURE_PADS="ocean-surface,ocean-os" → only these sync
const ONLY = (env("PADS", "")).split(",").map(s => s.trim()).filter(Boolean);
const HOME = os.homedir();
const SP = [join(HOME, ".pasture/bin/pasture"), join(HOME, ".stitchpad/bin/stitchpad")].find(existsSync) || "stitchpad";
// migrated pads carry pasture.md; legacy stitchpad.md accepted until stage 4
const padMd = (padd) => { const f = join(padd, "pasture.md"); return existsSync(f) ? f : join(padd, "stitchpad.md"); };
const readTermLock = (t) => {
  for (const d of [join(HOME, ".pasture-terminals"), join(HOME, ".stitchpad-terminals")]) {
    try { return readFileSync(join(d, t), "utf8"); } catch { /* next */ }
  }
  return null;
};
const PUSH_ONCE = join(dirname(new URL(import.meta.url).pathname), "bridge-push-once.sh");
const HERDR = existsSync(join(HOME, ".local/bin/herdr")) ? join(HOME, ".local/bin/herdr") : "herdr";
const WSURL = RELAY.replace(/^http/, "ws");

const log = (...a) => console.log(`[bridge-ws ${new Date().toISOString().slice(11, 19)}]`, ...a);
const sh = (cmd, args, opts = {}) => new Promise(res => execFile(cmd, args, { timeout: 60000, ...opts }, (err, stdout, stderr) => res({ err, stdout: String(stdout || ""), stderr: String(stderr || "") })));
const api = (path, opts = {}) => fetch(RELAY + path, { ...opts, headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json", ...(opts.headers || {}) } });

// ── pad discovery ────────────────────────────────────────────
function findPads() {
  const out = [];
  for (const r of ROOTS) {
    // find exits non-zero on permission noise under $HOME — stdout is still good.
    // Prune the heavy trees (Library, node_modules, …): full-home scans were the
    // old bridge's slowest leg by far.
    const res = spawnSync("find", [r, "-maxdepth", "4",
      "(", "-name", "Library", "-o", "-name", "node_modules", "-o", "-name", ".Trash",
      "-o", "-name", ".git", "-o", "-name", ".nvm", "-o", "-name", ".cache",
      "-o", "-name", "target", "-o", "-name", ".cargo", "-o", "-name", ".rustup", ")", "-prune",
      "-o", "-type", "d", "(", "-name", ".pasture", "-o", "-name", ".stitchpad", ")", "-print"], { timeout: 60000 });
    for (const p of String(res.stdout || "").split("\n")) {
      if (!p || /\/\.(stitchpad|pasture)\/\.(stitchpad|pasture)/.test(p)) continue;
      if (ONLY.length && !ONLY.includes(basename(dirname(p)))) continue;
      if (existsSync(join(p, "stitchpad.md")) || existsSync(join(p, "pasture.md"))) out.push(p);
    }
  }
  return [...new Set(out)].sort();
}

// ── per-pad connection ───────────────────────────────────────
const pads = new Map(); // padd → {name, proj, ws, watcher, pushT, tries, closed}

function pushPad(p, why) {
  clearTimeout(p.pushT);
  p.pushT = setTimeout(async () => {
    const { err } = await sh("bash", [PUSH_ONCE, p.padd], { env: { ...process.env, STITCHPAD_RELAY: RELAY, STITCHPAD_TOKEN: TOKEN } });
    if (err) log(p.name, "push failed:", err.message?.slice(0, 120));
    else if (why !== "sweep") log(p.name, "pushed (" + why + ")");
  }, 250); // debounce bursts of fs events
}

async function onSay(p, msg) {
  const { from, text, re, react } = msg;
  const env = { ...process.env, STITCHPAD_NAME: from || "smaths" };
  if (react && react.id && react.emoji) {
    await sh(SP, ["react", String(react.id), String(react.emoji)], { cwd: p.proj, env });
    log(p.name, `← @${from} reacted ${react.emoji} to ${react.id}`);
    pushPad(p, "say");
    return;
  }
  if (!text) return;
  const args = ["say"];
  if (re) args.push("--re", String(re));   // threaded reply
  args.push(text);
  await sh(SP, args, { cwd: p.proj, env });
  log(p.name, `← @${from}: ${text.slice(0, 50)}`);
  pushPad(p, "say"); // echo lands on phones immediately, not next sweep
}

// resolve an agent's live herdr pane: roster herdr target, else the terminal
// its HEARTBEAT records (pull-mode agents live somewhere too)
async function resolvePane(p, name) {
  const { stdout: roster } = await sh(SP, ["roster"], { cwd: p.proj });
  const row = roster.split("\n").find(l => l.split("|")[0] === name);
  let [, adapter, , target] = (row || "").split("|");
  if (adapter !== "herdr" || !target || target === "-") {
    try {
      const hb = JSON.parse(readFileSync(join(p.padd, ".state", "alive." + name), "utf8"));
      if (hb.surface) { adapter = "herdr"; target = hb.surface; }
    } catch {}
  }
  if (adapter !== "herdr" || !target || target === "-") return null;
  // ONE TERMINAL = ONE PAD: refuse routing a DM into a terminal that is live in
  // a different pad or under a different name (~/.stitchpad-terminals registry).
  try {
    const surface = target.split("@@").pop();
    const [lpad, lname, lts] = (readTermLock(surface) || "").trim().split("|");
    if (Date.now() / 1000 - (+lts || 0) < 300 && (lpad !== p.padd || lname !== name)) {
      log(p.name, `CROSS-PAD BLOCKED: DM for @${name} — terminal ${surface} is live as @${lname} in ${lpad}`);
      return null;
    }
  } catch {}
  const { stdout: info } = await sh(HERDR, ["agent", "get", target]);
  return (info.match(/"pane_id"\s*:\s*"([^"]*)"/) || [])[1] || null;
}

// DM pane content: the agent's TERMINAL SESSION rendered as chat — the
// operator's injected messages (user turns) and the agent's replies (assistant
// turns), read from the harness session transcript. Claude Code writes
// ~/.claude/projects/<proj-slug>/<session-id>.jsonl; the freshest session
// bound to this agent name in .state/sessions is the live one.
function sessionTranscript(p, agent) {
  const sdir = join(p.padd, ".state", "sessions");
  let best = null;
  try {
    for (const f of readdirSync(sdir)) {
      try {
        if (readFileSync(join(sdir, f), "utf8").trim() !== agent) continue;
        const t = join(HOME, ".claude", "projects", p.proj.replaceAll("/", "-"), f + ".jsonl");
        if (!existsSync(t)) continue;
        const m = statSync(t).mtimeMs;
        if (!best || m > best.m) best = { t, m };
      } catch {}
    }
  } catch {}
  return best?.t || null;
}
function parseTranscript(file) {
  const msgs = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (e.isMeta || !e.message) continue;
    const at = e.timestamp ? Date.parse(e.timestamp) : 0;
    const c = e.message.content;
    if (e.type === "user") {
      // only real typed/injected text — skip tool results and harness noise
      const text = typeof c === "string" ? c : (Array.isArray(c) ? c.filter(b => b.type === "text").map(b => b.text).join("\n") : "");
      if (!text || text.startsWith("<") || text.startsWith("Caveat:")) continue;
      msgs.push({ role: "user", text: text.slice(0, 4000), at });
    } else if (e.type === "assistant") {
      const text = Array.isArray(c) ? c.filter(b => b.type === "text").map(b => b.text).join("\n") : "";
      if (!text.trim()) continue;
      // consecutive assistant chunks of one turn → merge
      const last = msgs[msgs.length - 1];
      if (last && last.role === "assistant" && at - last.at < 120000) last.text = (last.text + "\n\n" + text).slice(0, 8000);
      else msgs.push({ role: "assistant", text: text.slice(0, 8000), at });
    }
  }
  return msgs.slice(-60);
}
const TERM_SIG = {}; // "<pad>:<agent>" → transcript mtime:size at last post
async function onTerm(p, msg) {
  const agent = msg.agent; if (!agent) return;
  let out = { agent, msgs: null, error: "", at: Date.now() };
  const file = sessionTranscript(p, agent);
  // a phone pane polls this every few seconds — skip the reparse+repost when
  // the transcript hasn't moved (initial pane load reads GET /term's stored copy)
  if (file) {
    try {
      const st = statSync(file), sig = st.mtimeMs + ":" + st.size, key = p.name + ":" + agent;
      if (TERM_SIG[key] === sig) return;
      TERM_SIG[key] = sig;
    } catch { /* stat raced a rotation — fall through and post */ }
  }
  if (file) { try { out.msgs = parseTranscript(file); } catch (e) { out.error = "transcript parse failed: " + e.message; } }
  else out.error = "no session transcript for @" + agent + " (non-claude harness or session not bound)";
  const r = await api(`/term-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify(out) }).catch(e => ({ ok: false, statusText: e.message }));
  log(p.name, `session-chat @${agent}: ${out.error || (out.msgs?.length + " msgs")} → posted ${r.ok ? "ok" : "FAILED " + (r.status || r.statusText)}`);
}

// commands that open interactive dialogs/pickers — dead ends from a phone
const MODAL_CMDS = new Set(["status", "config", "permissions", "help", "doctor", "login", "logout", "exit", "quit", "vim", "hooks", "mcp", "agents", "resume", "theme", "terminal-setup", "install-github-app", "ide", "bug"]);
const OCEAN_URL = process.env.OCEAN_DAEMON_URL || "http://127.0.0.1:4780";
// delivery receipts: report each DM's outcome back to the relay (stamps the
// pair-log entry + pushes a live {type:"dmstatus"} to the phone) and remember
// the last outcome per agent for the doctor snapshot.
const LAST_DM = {};   // "<pad>:<agent>" → {at, status, detail}
async function dmStatus(p, msg, status, detail) {
  LAST_DM[`${p.name}:${msg.to}`] = { at: Date.now(), status, detail };
  if (!msg.id) return;
  await api(`/dm-status?pad=${encodeURIComponent(p.name)}`, {
    method: "POST",
    body: JSON.stringify({ id: msg.id, from: msg.from, to: msg.to, status, detail }),
  }).catch(() => {});
}
async function onDm(p, msg) {
  const { from, to, text } = msg;
  if (!to || !text) return;
  // record inbound in the pair's sqlite DB so the recipient can `dm read`
  // the whole conversation locally — delivery outcome is tracked separately
  sh(SP, ["dm", "record", from, to, text], { cwd: p.proj }).catch(() => {});
  let delivered = false;
  // OCEAN-ADAPTER agents live as daemon sessions, not terminals — deliver the
  // DM as a turn on their session. (Without this, the heartbeat-surface
  // fallback routed @ocean DMs into whatever terminal last started its
  // heartbeat — the operator's own, in practice.)
  try {
    const { stdout: roster } = await sh(SP, ["roster"], { cwd: p.proj });
    const row = (roster.split("\n").find(l => l.split("|")[0] === to) || "").split("|").map(s => (s || "").trim());
    if (row[1] === "ocean" && row[3] && row[3] !== "-") {
      if (/^\/[a-zA-Z0-9_:-]+/.test(text.trim())) {
        log(p.name, `DM @${from} → @${to} refused slash (daemon agent has no terminal commands)`);
        await dmStatus(p, msg, "refused", "daemon agent — no terminal commands");
        await api(`/dm-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify({ from: to, to: from, text: `⚠ @${to} is a daemon session, not a terminal — slash commands don't exist there. Plain messages work.`, at: Date.now() }) }).catch(() => {});
        return;
      }
      const prompt = `pasture DM from @${from} (private — not on the pad): ${text}\n\nReply PRIVATELY (do not post on the pad) with:\n  cd ${p.proj} && STITCHPAD_NAME=${to} ~/.stitchpad/bin/stitchpad dm say ${from} '<your reply>'\n(history: stitchpad dm read ${from})`;
      const r = await fetch(`${OCEAN_URL}/v1/agent/turns`, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ session_id: row[3], prompt, cwd: p.proj, client_type: "stitchpad" }),
      });
      if (r.ok) { log(p.name, `DM @${from} → @${to} ocean daemon turn (${text.slice(0, 40)})`); await dmStatus(p, msg, "delivered", "daemon session"); return; }
      log(p.name, `DM @${from} → @${to} daemon POST ${r.status} — falling back`);
    }
  } catch {}
  // A DM starting with "/" is a REAL slash command for the harness — inject it
  // raw (no DM wrapper, which would turn it into chat text). Gates run BEFORE
  // pane resolution: a refusal is about the harness/command, not reachability,
  // and must fire even when the terminal is gone.
  const clean = text.replace(/[\x00-\x1f\x7f]/g, " ").replace(/ +/g, " ").trim();
  const cmd = (clean.match(/^\/([a-zA-Z0-9_:-]+)/) || [])[1]?.toLowerCase();
  // harness gate: Claude Code (and codex) execute an injected "/cmd"; the pi
  // TUI treats it as chat text — silently "not working" from the phone.
  if (cmd) {
    let rt = "";
    try { rt = readFileSync(join(p.padd, ".state", "runtime." + to), "utf8").trim(); } catch {}
    if (rt === "pi") {
      log(p.name, `DM @${from} → @${to} refused slash /${cmd} (pi harness)`);
      await dmStatus(p, msg, "refused", `@${to} runs pi — /${cmd} is not a pi command`);
      await api(`/dm-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify({ from: to, to: from, text: `⚠ @${to} runs the pi harness — /${cmd} is a Claude Code command and would land as chat text. Plain messages still work.`, at: Date.now() }) }).catch(() => {});
      return;
    }
  }
  // modal gate: these open a dialog nobody on a phone can Esc out of
  if (cmd && MODAL_CMDS.has(cmd)) {
    log(p.name, `DM @${from} → @${to} refused modal /${cmd}`);
    await dmStatus(p, msg, "refused", `/${cmd} is interactive-only`);
    await api(`/dm-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify({ from: to, to: from, text: `⚠ /${cmd} opens a dialog only a keyboard can close — not sent. Commands that work from here: /compact, /clear, /model <name>, or any skill.`, at: Date.now() }) }).catch(() => {});
    return;
  }
  const pane = await resolvePane(p, to);
  {
    if (pane) {
      const dmsg = cmd ? clean
        : `pasture DM from @${from} (PRIVATE — do NOT answer on the pad): ${clean}\nreply privately: \`stitchpad dm say ${from} '<your reply>'\` (history: \`stitchpad dm read ${from}\`) — a pad \`say\` would broadcast your answer to everyone.`;
      const { err } = await sh(HERDR, ["pane", "run", pane, dmsg]);
      delivered = !err;
      if (delivered) {
        // SETTLE-RETRY: the Enter from `pane run` can fire before the TUI
        // finishes ingesting the paste, leaving the text parked in the input
        // box. After a beat, one bare Enter submits it; if it already went
        // through, a bare Enter on an empty input is a no-op. (Same trick as
        // the wake adapter.)
        await new Promise(r => setTimeout(r, 2000));
        await sh(HERDR, ["pane", "run", pane, ""]).catch(() => {});
      }
      if (delivered && cmd) log(p.name, `DM @${from} → @${to} slash /${cmd} injected raw`);
      // a delivered /model switch must show on the profile card — record it as
      // pad meta and re-push so the chip flips with the switch, not the vibe
      if (delivered && cmd === "model") {
        const marg = clean.replace(/^\/model\s*/i, "").trim();
        if (marg) {
          sh(SP, ["meta", "set", to, "model", marg], { cwd: p.proj }).catch(() => {});
          setTimeout(() => pushPad(p, "model-switch"), 500);
        }
      }
    }
  }
  if (delivered) {
    log(p.name, `DM @${from} → @${to} terminal (${text.slice(0, 40)})`);
    await dmStatus(p, msg, "delivered", "terminal");
  } else {
    await sh(SP, ["say", `@${to} (dm — terminal unreachable) ${text}`], { cwd: p.proj, env: { ...process.env, STITCHPAD_NAME: from || "smaths" } });
    log(p.name, `DM @${from} → @${to} FELL BACK to pad (no live pane)`);
    await dmStatus(p, msg, "failed", "terminal unreachable — posted on the pad instead");
    pushPad(p, "dm-fallback");
  }
}

async function onFile(p, msg) {
  const { name, key } = msg;
  if (!name || !key) return;
  const drop = join(p.padd, "dropbox");
  mkdirSync(drop, { recursive: true });
  try {
    const r = await api("/f/" + key.replace(/^files\//, ""));
    if (!r.ok) throw new Error("HTTP " + r.status);
    writeFileSync(join(drop, name.replace(/[\/\\]/g, "_")), Buffer.from(await r.arrayBuffer()));
    log(p.name, `📎 ${name} → .stitchpad/dropbox/`);
  } catch (e) { log(p.name, `📎 FAILED ${name}: ${e.message}`); }
}

function connect(p) {
  if (p.closed) return;
  const ws = new WebSocket(`${WSURL}/ws?pad=${encodeURIComponent(p.name)}&role=bridge&token=${TOKEN}`);
  p.ws = ws;
  ws.onopen = () => { p.tries = 0; log(p.name, "socket up"); drainQueues(p); };
  ws.onmessage = async e => {
    let m; try { m = JSON.parse(e.data); } catch { return; }
    if (m.type === "say") await onSay(p, m.msg || {});
    else if (m.type === "dm") await onDm(p, m.msg || {});
    else if (m.type === "file") await onFile(p, m.msg || {});
    else if (m.type === "summarize") summarize(p, m.msg || {});   // async, don't block the socket
    else if (m.type === "term") onTerm(p, m.msg || {});           // live terminal capture
    else if (m.type === "task") onTask(p, m.msg || {});           // kanban board ops
  };
  ws.onclose = () => { if (p.ws !== ws || p.closed) return; p.ws = null; setTimeout(() => connect(p), Math.min(30000, 1000 * 2 ** (p.tries++))); };
  ws.onerror = () => { try { ws.close(); } catch {} };
}

// drain any messages that queued in KV while our socket was down
async function drainQueues(p) {
  for (const [box, handler] of [["outbox", onSay], ["dmbox", onDm], ["filebox", onFile]]) {
    try {
      const r = await api(`/${box}?pad=${encodeURIComponent(p.name)}`);
      if (!r.ok) continue;
      for (const m of (await r.json()).messages || []) await handler(p, m);
    } catch {}
  }
}

function track(padd) {
  if (pads.has(padd)) return;
  const proj = dirname(padd);
  const p = { padd, proj, name: basename(proj), ws: null, watcher: null, pushT: null, tries: 0, closed: false };
  pads.set(padd, p);
  try {
    p.watcher = watch(padMd(padd), () => pushPad(p, "fs"));
  } catch { /* file may briefly not exist; sweep still covers it */ }
  connect(p);
  pushPad(p, "startup");
  log("tracking", p.name);
}

// thread summarizer: PWA button → ws {type:"summarize"} → run headless claude
// over the pad tail → POST /summary-in (relay stores + notifies every phone).
const CLAUDE = existsSync(join(HOME, ".local/bin/claude")) ? join(HOME, ".local/bin/claude") : "claude";
async function summarize(p, msg) {
  log(p.name, `summarize requested by @${msg.by || "?"}`);
  let padTxt = "";
  try { padTxt = readFileSync(padMd(p.padd), "utf8"); } catch {}
  const tail = padTxt.split("\n").slice(-600).join("\n");
  const prompt = `Summarize this multi-agent coding thread for the human operator (@${msg.by || "smaths"}). ` +
    `Plain english, short bullets, under 180 words. Cover: (1) current state / what just happened, ` +
    `(2) what each agent is working on, (3) decisions made, (4) anything BLOCKED waiting on the operator — put that first if it exists. ` +
    `Respond with ONLY the summary text.`;
  const post = async body => api(`/summary-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify({ ...body, by: msg.by }) }).catch(() => {});
  try {
    const c = spawn(CLAUDE, ["-p", prompt, "--model", "haiku"], { env: process.env, stdio: ["pipe", "pipe", "pipe"] });
    let out = "", errS = "";
    c.stdout.on("data", d => out += d);
    c.stderr.on("data", d => errS += d);
    const t = setTimeout(() => { try { c.kill("SIGKILL"); } catch {} }, 180000);
    c.on("close", async code => {
      clearTimeout(t);
      const text = out.trim();
      if (code === 0 && text) { await post({ text }); log(p.name, "summary posted"); }
      else { await post({ error: (errS || "summarizer exited " + code).slice(0, 300) }); log(p.name, "summary FAILED:", (errS || String(code)).slice(0, 120)); }
    });
    c.stdin.write("THREAD:\n\n" + tail); c.stdin.end();
  } catch (e) { await post({ error: e.message }); }
}

// kanban ops from the phone board: run the task CLI with validated flags only,
// then re-push so every phone's board re-renders from the pad itself
const TASK_STATUSES = new Set(["backlog", "todo", "in_progress", "in_review", "done", "canceled"]);
const TASK_PRIOS = new Set(["none", "low", "medium", "high", "urgent"]);
async function onTask(p, msg) {
  const { op } = msg || {};
  try {
    if (op === "move" && msg.id && TASK_STATUSES.has(msg.status)) {
      await sh(SP, ["task", "move", String(msg.id).slice(0, 20), msg.status], { cwd: p.proj });
      log(p.name, `task ${msg.id} → ${msg.status} (by @${msg.by || "?"})`);
    } else if (op === "new" && msg.title) {
      const args = ["task", "new", String(msg.title).slice(0, 200)];
      if (TASK_PRIOS.has(msg.priority)) args.push("--priority", msg.priority);
      if (msg.assignee) args.push("--to", String(msg.assignee).slice(0, 40));
      if (msg.labels) args.push("--labels", String(msg.labels).slice(0, 120));
      if (msg.desc) args.push("--desc", String(msg.desc).slice(0, 1000));
      await sh(SP, args, { cwd: p.proj });
      log(p.name, `task new "${String(msg.title).slice(0, 40)}" (by @${msg.by || "?"})`);
    } else if (op === "edit" && msg.id) {
      const args = ["task", "edit", String(msg.id).slice(0, 20)];
      if (TASK_PRIOS.has(msg.priority)) args.push("--priority", msg.priority);
      if (msg.assignee !== undefined) args.push("--to", String(msg.assignee).slice(0, 40));
      if (msg.labels !== undefined) args.push("--labels", String(msg.labels).slice(0, 120));
      await sh(SP, args, { cwd: p.proj });
      log(p.name, `task edit ${msg.id} (by @${msg.by || "?"})`);
    } else { log(p.name, "task op ignored:", JSON.stringify(msg || {}).slice(0, 80)); return; }
    pushPad(p, "task");
  } catch (e) { log(p.name, "task op failed:", e.message?.slice(0, 100)); }
}

// agent → human DMs: `stitchpad dm` appends to .state/dmout.jsonl; forward each
// line to the relay (/dm-in records it in the pair log + broadcasts to phones).
async function drainDmOut(p) {
  const f = join(p.padd, ".state", "dmout.jsonl");
  try { if (!existsSync(f) || statSync(f).size === 0) return; } catch { return; }
  let raw = "";
  try { raw = readFileSync(f, "utf8"); truncateSync(f, 0); } catch { return; }
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const m = JSON.parse(line);
      await api(`/dm-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify(m) });
      log(p.name, `DM @${m.from} → @${m.to} (agent → phone)`);
    } catch (e) { log(p.name, "dm-in forward failed:", e.message); }
  }
}

// DOCTOR: the pad's health snapshot, pushed every 30s so the phone can show
// per-agent vitals — heartbeat freshness, wake gate, terminal lock, last
// wake/DM outcome — instead of the operator diagnosing by vibes.
function lastWakeFor(p, name) {
  // adapter logs are the delivery ground truth; scan the tails
  let best = null;
  for (const f of ["adapter.herdr.log", "adapter.ocean.log", "adapter.codex.log"]) {
    let raw; try { raw = readFileSync(join(p.padd, ".state", f), "utf8"); } catch { continue; }
    const lines = raw.trimEnd().split("\n").slice(-200);
    for (let i = lines.length - 1; i >= 0; i--) {
      const l = lines[i];
      if (!l.includes(`@${name}`)) continue;
      const ts = (l.match(/^\[([^\]]+)\]/) || [])[1] || "";
      if (l.includes(`delivered wake to @${name}`)) { best = best || { at: ts, ok: true }; break; }
      if (l.includes("CROSS-PAD BLOCKED") || l.includes("failed")) { best = best || { at: ts, ok: false, why: l.includes("CROSS-PAD") ? "cross-pad blocked" : "delivery failed" }; break; }
    }
    if (best) break;
  }
  return best;
}
async function buildDoctor(p) {
  let roster;
  try { roster = (await sh(SP, ["roster"], { cwd: p.proj })).stdout; } catch { return null; }
  const agents = [];
  for (const line of roster.split("\n")) {
    const [name, adapter, wake, target] = line.split("|").map(s => (s || "").trim());
    if (!name) continue;
    const a = { name, adapter, wake: wake || "-", target: target || "-" };
    try {
      const hb = JSON.parse(readFileSync(join(p.padd, ".state", "alive." + name), "utf8"));
      a.hb_age = Math.max(0, Math.round(Date.now() / 1000 - (hb.ts || 0)));
    } catch { a.hb_age = -1; }   // -1 = no heartbeat file
    if (target && target !== "-" && adapter !== "ocean") {
      try {
        const surface = target.split("@@").pop();
        const [lpad, lname, lts] = (readTermLock(surface) || "").trim().split("|");
        const fresh = Date.now() / 1000 - (+lts || 0) < 300;
        a.lock = !fresh ? "stale" : (lpad === p.padd && lname === name) ? "ok"
          : lname === "operator" ? "OPERATOR TERMINAL" : `CONFLICT: @${lname} in ${lpad.split("/").slice(-2, -1)[0]}`;
      } catch { a.lock = "unclaimed"; }
    }
    try {
      const { stdout } = await sh(SP, ["wake", name, "--peek-ordinal"], { cwd: p.proj });
      a.gate = stdout.trim() ? "owes a reply" : "idle";
    } catch { a.gate = "?"; }
    const w = lastWakeFor(p, name);
    if (w) a.last_wake = w;
    const d = LAST_DM[`${p.name}:${name}`];
    if (d) a.last_dm = { status: d.status, detail: d.detail, ago: Math.round((Date.now() - d.at) / 1000) };
    agents.push(a);
  }
  return { pad: p.name, at: Date.now(), bridge: "ws", agents };
}
async function pushDoctor(p) {
  const doc = await buildDoctor(p);
  if (!doc) return;
  await api(`/doctor-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify(doc) }).catch(() => {});
}
setInterval(() => pads.forEach(pushDoctor), 30000);

// AUTO-HEAL roster wake targets: the roster row is written ONCE (at join or a
// manual set-wake) while terminals churn constantly, so its pane pointer rots.
// The agent's own heartbeat (alive.<name>) rewrites its current pane every few
// seconds — the live source of truth. When a fresh heartbeat disagrees with
// the roster target, rewrite the roster row (keeping wake mode + adapter).
async function healRoster(p) {
  let roster;
  try { roster = (await sh(SP, ["roster"], { cwd: p.proj })).stdout; } catch { return; }
  for (const line of roster.split("\n")) {
    const [name, adapter, wake, target] = line.split("|").map(s => (s || "").trim());
    if (!name || !(wake === "push" || wake === "pull")) continue;
    // herdr rows only: Ocean keys its target on
    // adapter-specific ids (session uuids), not panes — a heartbeat pane would
    // clobber them. Their DMs already fall back to the heartbeat in resolvePane.
    if (adapter !== "herdr") continue;
    let hb;
    try { hb = JSON.parse(readFileSync(join(p.padd, ".state", "alive." + name), "utf8")); } catch { continue; }
    if (!hb.surface || Date.now() / 1000 - (hb.ts || 0) > 300) continue; // no fresh heartbeat → leave it
    if (hb.surface === target) continue;
    try {
      await sh(SP, ["set-wake", name, wake, hb.surface, adapter && adapter !== "-" ? adapter : "herdr"], { cwd: p.proj });
      log(p.name, `heal: @${name} target ${target || "-"} → ${hb.surface} (from heartbeat)`);
    } catch (e) { log(p.name, `heal failed for @${name}:`, e.message); }
  }
}
setInterval(() => pads.forEach(healRoster), 60000);

// KEEPALIVE: a terminal reload kills every disowned heartbeat ticker at once;
// with all tickers dead the watcher refuses to spawn ("no one listening") and
// the wake loop goes dark silently. The bridge outlives terminals (launchd),
// so it revives tickers for roster seats with a wake target and re-ensures
// the watcher every cycle.
async function keepAlive(p) {
  // dormant pads don't get revived tickers: a dead test pad's heartbeat could
  // claim a vacant terminal lock and block deliveries in a live pad. Using a
  // dormant pad again (any write) re-arms its keepalive automatically.
  try { if (Date.now() - statSync(padMd(p.padd)).mtimeMs > 7 * 86400e3) return; } catch { return; }
  // ROSTER GUARD: direct-file writers (remote agents, raw edits) have dropped
  // the pad header before — a missing roster silently breaks gates, doctor,
  // and profiles while the running watcher coasts on its cached copy. Back the
  // block up whenever it parses; put it back the moment it vanishes.
  try {
    const padTxt = readFileSync(padMd(p.padd), "utf8");
    const rb = padTxt.match(/```roster\n[\s\S]*?```/);
    const bak = join(p.padd, ".state", "roster.backup");
    if (rb) writeFileSync(bak, rb[0]);
    else if (existsSync(bak)) {
      // Recovery must share the CLI's mutation lock with say/join. A raw
      // writeFileSync here raced a simultaneous repair once and produced two
      // roster blocks; the CLI re-checks after locking and commits atomically.
      const { err } = await sh(SP, ["restore-roster", bak], { cwd: p.proj });
      if (err) log(p.name, "ROSTER RESTORE FAILED:", err.message?.slice(0, 120));
      else log(p.name, "ROSTER RESTORED from backup — a direct write had dropped the pad header");
    }
  } catch { /* pad mid-rewrite; next cycle */ }
  let roster;
  try { roster = (await sh(SP, ["roster"], { cwd: p.proj })).stdout; } catch { return; }
  for (const line of roster.split("\n")) {
    const [name, , , target] = line.split("|").map(s => (s || "").trim());
    if (!name || !target || target === "-") continue;
    let stale = true;
    try {
      const hb = JSON.parse(readFileSync(join(p.padd, ".state", "alive." + name), "utf8"));
      stale = Date.now() / 1000 - (hb.ts || 0) > 120;
    } catch { /* no alive file → stale */ }
    if (!stale) continue;
    try {
      await sh(SP, ["heartbeat", "start", name], { cwd: p.proj, env: { ...process.env, STITCHPAD_NAME: name, STITCHPAD_HEARTBEAT_PARENT_PID: "0" } });
      log(p.name, `keepalive: revived heartbeat for @${name}`);
    } catch (e) { log(p.name, `keepalive failed for @${name}:`, e.message); }
  }
  sh(SP, ["ensure-watcher"], { cwd: p.proj }).catch(() => {});
  // AUTO-COMPACT: past ~700KB a pad breaks WS pushes (1MiB frame cap) and
  // drowns agent context. Compact moves old transcript to archive.sqlite and
  // leaves a rolling summary; 6h guard so one oversize pad can't thrash.
  try {
    const st = statSync(padMd(p.padd));
    const guard = join(p.padd, ".state", "compact.last");
    let last = 0; try { last = statSync(guard).mtimeMs; } catch { /* never compacted */ }
    if (st.size > 700000 && Date.now() - last > 6 * 3600e3) {
      writeFileSync(guard, String(Date.now()));
      log(p.name, `auto-compact: pad ${Math.round(st.size / 1024)}KB — archiving old transcript`);
      sh(SP, ["compact", "--keep", "200"], { cwd: p.proj })
        .then(({ stdout }) => { log(p.name, "auto-compact:", (stdout || "").trim().slice(0, 120)); pushPad(p, "compact"); })
        .catch(e => log(p.name, "auto-compact FAILED:", e.message?.slice(0, 120)));
    }
  } catch { /* pad file briefly absent */ }
}
setInterval(() => pads.forEach(keepAlive), 60000);

// TARGET RE-RESOLUTION: an app reload rotates EVERY terminal id; roster targets
// keep naming the dead ids and wakes route nowhere. Heartbeats can't self-heal
// this (their surface IS the roster target). The bridge re-maps: a herdr row
// whose terminal no longer exists gets re-pointed at the unique live pane
// matching the agent's runtime + the pad's project dir. Ambiguous → skip + log;
// never guess, never touch operator-locked or foreign-claimed terminals.
const RUNTIME_AGENT = { claude: "claude", codex: "codex", pi: "pi" };
// REAL model detection: the pane list names each agent's live session file —
// the last "model" the session actually recorded beats any guessed chip.
function findSessionFile(root, id, depth = 0) {
  if (depth > 3) return null;
  let entries; try { entries = readdirSync(root, { withFileTypes: true }); } catch { return null; }
  for (const e of entries) {
    const f = join(root, e.name);
    if (e.isFile() && e.name.includes(id) && e.name.endsWith(".jsonl")) return f;
    if (e.isDirectory()) { const r = findSessionFile(f, id, depth + 1); if (r) return r; }
  }
  return null;
}
function modelFromSession(sess) {
  try {
    if (!sess || !sess.value) return null;
    let file = null;
    if (sess.kind === "path") file = sess.value.replace(/^~\//, HOME + "/");
    else if (sess.kind === "id") {
      const root = (sess.source || "").includes("claude") ? join(HOME, ".claude", "projects") : join(HOME, ".codex", "sessions");
      file = findSessionFile(root, sess.value);
    }
    if (!file || !existsSync(file)) return null;
    const sz = statSync(file).size, len = Math.min(sz, 262144);
    const fd = openSync(file, "r"), buf = Buffer.alloc(len);
    readSync(fd, buf, 0, len, sz - len); closeSync(fd);
    // STRUCTURED fields only, newest line first — a regex over raw text can be
    // faked by pasted JSON inside chat content; real session entries can't.
    const lines = buf.toString("utf8").split("\n");
    const pick = o => o && (o.modelId || o.model ||
      (o.message && o.message.model) ||
      (o.turn_context && o.turn_context.model) ||
      (o.payload && (o.payload.model || (o.payload.turn_context && o.payload.turn_context.model))));
    for (let i = lines.length - 1; i >= 0; i--) {
      const ln = lines[i].trim(); if (!ln.startsWith("{")) continue;
      try { const v = pick(JSON.parse(ln)); if (typeof v === "string" && /^[A-Za-z0-9._:\/-]{2,48}$/.test(v)) return v; } catch { /* partial first line of the tail window */ }
    }
    return null;
  } catch { return null; }
}
async function healTargets() {
  let panes = [];
  try {
    const { stdout } = await sh(HERDR, ["pane", "list"]);
    panes = JSON.parse(stdout)?.result?.panes || [];
  } catch { return; }
  const liveTerms = new Set(panes.map(x => x.terminal_id).filter(Boolean));
  const lockOf = t => { const r = readTermLock(t); return r ? r.split("|") : null; };
  for (const [, p] of pads) {
    try { if (Date.now() - statSync(padMd(p.padd)).mtimeMs > 7 * 86400e3) continue; } catch { continue; }
    let roster;
    try { roster = (await sh(SP, ["roster"], { cwd: p.proj })).stdout; } catch { continue; }
    for (const line of roster.split("\n")) {
      const [name, adapter, wake, target] = line.split("|").map(s => (s || "").trim());
      if (!name || adapter !== "herdr" || !target || target === "-") continue;
      const term = target.split("@@").pop();
      const livePane = panes.find(x => x.terminal_id === term);
      if (livePane) {
        // target healthy → keep the model chip TRUE: read what the agent's
        // session actually ran last, straight from its transcript
        const mdl = modelFromSession(livePane.agent_session);
        if (mdl) { try { writeFileSync(join(p.padd, ".state", "model." + name), mdl); } catch {} }
        continue;
      }
      let runtime = "";
      try { runtime = readFileSync(join(p.padd, ".state", "runtime." + name), "utf8").trim(); } catch {}
      const want = RUNTIME_AGENT[runtime] || null;
      const cands = panes.filter(x =>
        x.terminal_id && x.cwd === p.proj &&
        (want ? x.agent === want : true) &&
        (() => { const l = lockOf(x.terminal_id); return !l || (l[0] === p.padd && l[1] === name); })());
      if (cands.length !== 1) {
        log(p.name, `retarget: @${name} target ${term} is dead, ${cands.length} candidate panes — skipping (no guessing)`);
        continue;
      }
      const nt = cands[0].terminal_id;
      try {
        await sh(SP, ["set-wake", name, wake || "push", nt, "herdr"], { cwd: p.proj });
        // reset kills the old ticker (still beating the dead surface), clears
        // the wake cursor, and restarts the heartbeat from the NEW roster target
        await sh(SP, ["reset", name], { cwd: p.proj });
        log(p.name, `retarget: @${name} ${term} (dead) → ${nt} (${cands[0].pane_id})`);
      } catch (e) { log(p.name, `retarget failed for @${name}:`, e.message?.slice(0, 100)); }
    }
  }
}
setInterval(healTargets, 90000);

// SHIFT-CHANGE delivery: an agent saved its next-session invocation (handoffs
// table, status=pending). We act ONLY when its pane is IDLE — never mid-turn —
// then: /clear|/new → wait for the fresh prompt → paste the handoff → settle
// Enter. Exactly-once via the sqlite state machine; a 'delivering' row older
// than 4 minutes is assumed crashed and retried.
const SHIFT_CLEAR = { claude: "/clear", codex: "/new" };
const SHIFT_BUSY = new Set(); // "<pad>:<agent>" in-flight this process
async function shiftSweep() {
  let panes = null;
  for (const [, p] of pads) {
    const db = join(p.padd, ".state", "archive.sqlite");
    if (!existsSync(db)) continue;
    let rows = "";
    try { rows = (await sh("/usr/bin/sqlite3", ["-separator", "|", db, "SELECT id, agent, status, at FROM handoffs WHERE status IN ('pending','delivering');"])).stdout.trim(); } catch { continue; }
    if (!rows) continue;
    for (const line of rows.split("\n")) {
      const [id, agent, status, at] = line.split("|");
      if (!id || !agent) continue;
      const key = `${p.name}:${agent}`;
      if (SHIFT_BUSY.has(key)) continue;
      if (status === "delivering" && Date.now() - Date.parse(at || 0) < 4 * 60e3) continue; // someone's on it
      let runtime = ""; try { runtime = readFileSync(join(p.padd, ".state", "runtime." + agent), "utf8").trim(); } catch {}
      const clearCmd = SHIFT_CLEAR[runtime];
      if (!clearCmd) { log(p.name, `shift-change @${agent}: runtime '${runtime || "?"}' has no clear command — leaving pending`); continue; }
      if (!panes) {
        try { panes = JSON.parse((await sh(HERDR, ["pane", "list"])).stdout)?.result?.panes || []; } catch { panes = []; }
      }
      let roster = ""; try { roster = (await sh(SP, ["roster"], { cwd: p.proj })).stdout; } catch {}
      const row = roster.split("\n").find(l => l.split("|")[0] === agent);
      const term = (row || "").split("|")[3]?.split("@@").pop();
      const pane = panes.find(x => x.terminal_id === term);
      if (!pane) { log(p.name, `shift-change @${agent}: no live pane — waiting`); continue; }
      if (pane.agent_status && pane.agent_status !== "idle") continue; // NEVER mid-turn
      SHIFT_BUSY.add(key);
      (async () => {
        try {
          const { stdout: bodyPath, err } = await sh(SP, ["shift-change", "--claim", id], { cwd: p.proj });
          if (err || !bodyPath.trim()) throw new Error("claim failed");
          const body = readFileSync(bodyPath.trim(), "utf8");
          log(p.name, `shift-change @${agent}: clearing session (${clearCmd}) on ${pane.pane_id}`);
          await sh(HERDR, ["pane", "run", pane.pane_id, clearCmd]);
          await new Promise(r => setTimeout(r, 8000));          // fresh prompt settles
          await sh(HERDR, ["pane", "run", pane.pane_id, body]);  // the handoff, pasted whole
          await new Promise(r => setTimeout(r, 2500));
          await sh(HERDR, ["pane", "run", pane.pane_id, ""]);    // settle-retry Enter
          await sh(SP, ["shift-change", "--mark", id, "delivered"], { cwd: p.proj });
          log(p.name, `shift-change @${agent}: DELIVERED — fresh session briefed`);
        } catch (e) {
          log(p.name, `shift-change @${agent} FAILED: ${e.message?.slice(0, 100)} — will retry`);
          await sh(SP, ["shift-change", "--mark", id, "pending"], { cwd: p.proj }).catch(() => {});
        } finally { SHIFT_BUSY.delete(key); }
      })();
    }
  }
}
setInterval(shiftSweep, 20000);

// ── main ─────────────────────────────────────────────────────
log(`relay=${RELAY} roots=${ROOTS.join(",")} (websocket mode)`);
findPads().forEach(track);
setInterval(() => findPads().forEach(track), 60000);              // new pads appear live
setInterval(() => pads.forEach(p => pushPad(p, "sweep")), 45000); // presence/status refresh
setInterval(() => pads.forEach(p => p.ws?.readyState === 1 ? p.ws.send('{"type":"ping"}') : null), 25000);
setInterval(() => pads.forEach(p => { if (!p.ws || p.ws.readyState !== 1) drainQueues(p); }), 30000);
setInterval(() => pads.forEach(drainDmOut), 2000);                // agent DM replies
// heartbeat file so `stitchpad doctor` can see the bridge is alive.
// `interval` is REQUIRED (TASK-70): doctor computes its staleness threshold as
// interval*3 and falls back to 3s when the field is absent — so a healthy 15s
// ws bridge was permanently reported stale against a 9s threshold. A health
// check that always warns trains everyone to ignore doctor output, which is
// exactly the tool we would have used to catch the wake-drop bug hours sooner.
// Keep this constant and the setInterval period the same value.
const HEARTBEAT_INTERVAL_MS = 15000;
setInterval(() => pads.forEach(p => {
  try {
    writeFileSync(
      join(p.padd, ".state", "bridge-heartbeat"),
      JSON.stringify({
        ts: new Date().toISOString(),
        pad: p.name,
        mode: "ws",
        interval: HEARTBEAT_INTERVAL_MS / 1000,
      }),
    );
  } catch {}
}), HEARTBEAT_INTERVAL_MS);
