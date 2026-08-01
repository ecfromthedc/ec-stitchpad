// stitchpad PWA — Preact port. Same single-page app, same CSS, same transport;
// the DOM now renders through a keyed vdom (vendored htm/preact standalone,
// no build step) instead of hand-managed innerHTML — the whole class of
// "state and screen drifted apart" bugs dies here.
//
// Layering:
//   store      — tiny external store the imperative transport writes into
//   transport  — websocket to the PadHub DO + polling fallback (unchanged logic)
//   components — App / Login / Sidebar / Log / Composer / cards stay imperative
import { html, render, useState, useEffect, useLayoutEffect, useRef } from "./vendor/preact-standalone.module.js";
import { renderUi, extractUi } from "./ui/render.js";
import { composeFence, validate as validateUi } from "./ui/schemas.mjs";

// ── helpers (unchanged from the vanilla app) ─────────────────
const RELAY = location.origin;
const esc = s => (s || "").replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
const initials = n => (n || "?").slice(0, 2).toUpperCase();
const OVR = { smaths: "#f1ece4", randy: "#0d9488", dale: "#00d000", larry: "#e01010", ernie: "#9b30ff", dennis: "#ff8c00", Jill: "#ff1493", mark: "#ffd700",
  codex: "#a8a3ff", fable: "#d97757", claude: "#d97757", "claude-main": "#c96442", pi: "#aeb8c4", "kimi-pi": "#1783ff", kimi: "#1783ff", ocean: "#38bdf8", deepseek: "#4d6bfe" };
const PAL = ["#00afff", "#ff8700", "#5fff00", "#d75fff", "#ffaf00", "#00ffff", "#ff00af", "#ffd700", "#87ffff", "#af87ff", "#ff5faf", "#5fff5f", "#ff5fff", "#87d787", "#d7af5f", "#ffff00", "#5fffff", "#ff87ff", "#afffaf", "#afffff"];
let RELAY_COLORS = {};
function setRelayColors(c) {
  const m = {};
  if (Array.isArray(c)) c.forEach(e => { if (e && e.name) m[e.name] = e.color || e.hex; });
  else if (c && typeof c === "object") Object.assign(m, c);
  RELAY_COLORS = m;
}
const colorFor = n => RELAY_COLORS[n] || OVR[n] || (typeof harnessOf === "function" && HARNESS_COLOR[harnessOf(n)]) || PAL[[...(n || "")].reduce((s, c) => s + c.charCodeAt(0), 0) % PAL.length];
const lum = h => { const c = h.replace("#", ""); return (0.299 * parseInt(c.slice(0, 2), 16) + 0.587 * parseInt(c.slice(2, 4), 16) + 0.114 * parseInt(c.slice(4, 6), 16)) / 255; };
const onLight = n => lum(colorFor(n)) > 0.85;
const nameColor = n => onLight(n) ? "#e7e9ec" : colorFor(n);
const initInk = n => onLight(n) ? "#12151c" : "#fff";
const djb2 = s => { let h = 5381; for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0; return h.toString(36); };
// inline SVG icons — UI chrome never uses emoji (renders as colored pictographs,
// clashes with the design). stroke=currentColor so they inherit button color.
const ICONS = {
  tasks: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><rect x="1.8" y="2.2" width="3.4" height="8.6" rx="1"/><rect x="6.3" y="2.2" width="3.4" height="11.6" rx="1"/><rect x="10.8" y="2.2" width="3.4" height="6" rx="1"/></svg>',
  summarize: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2.2 3.2h11.6M2.2 6.4h11.6M2.2 9.6h6.5M2.2 12.8h4"/><path d="M12.2 9.2l.9 1.9 1.9.9-1.9.9-.9 1.9-.9-1.9-1.9-.9 1.9-.9z" fill="currentColor" stroke="none"/></svg>',
  mail: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><rect x="1.8" y="3.2" width="12.4" height="9.6" rx="1.6"/><path d="M2.2 4.4 8 8.8l5.8-4.4"/></svg>',
  at: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><circle cx="8" cy="8" r="2.6"/><path d="M10.6 8v1.2a1.8 1.8 0 0 0 3.6 0V8a6.2 6.2 0 1 0-2.3 4.8"/></svg>',
  bolt: '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor" stroke="none"><path d="M9.2 1.4 3.4 9h3.2l-.9 5.6L11.6 7H8.3z"/></svg>',
};
const Icon = ({ n }) => html`<span class="ico" dangerouslySetInnerHTML=${{ __html: ICONS[n] || "" }}></span>`;
function fmt(t) {
  t = esc(t);
  t = t.replace(/```([\s\S]*?)```/g, (m, c) => `<div class="cb"><button class="cpy" title="copy">copy</button><pre>${c.trim()}</pre></div>`);
  t = t.replace(/`([^`]+)`/g, "<code>$1</code>");
  t = t.replace(/!\[([^\]]*)\]\(((?:https?:\/\/|\/(?:img|f)\/)[^\s)]+)\)/g, (m, alt, url) => `<img class="msg-img" src="${url}" alt="${alt}" loading="lazy" referrerpolicy="no-referrer">`);
  // [text](url) markdown links — scheme-restricted (https?: or our /img /f
  // media routes) so a hostile pad line can never mint a javascript: href
  t = t.replace(/\[([^\]]+)\]\(((?:https?:\/\/|\/(?:img|f)\/)[^\s)]+)\)/g, (m, txt, url) => `<a href="${url}" target="_blank" rel="noopener">${txt}</a>`);
  t = t.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
  t = t.replace(/(https?:\/\/[^\s]+)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>');
  t = t.replace(/(^|[\s(])@([a-zA-Z0-9_-]+)/g, (m, p, n) => `${p}<b style="color:${colorFor(n)}">@${n}</b>`);
  return t;
}
// fenced blocks: ```task TASK-N renders as a real card (title, status,
// assignee, DESCRIPTION — the body after ---); everything else stays a
// copyable code block. Content arrives pre-escaped.
function fenceBlock(f, ctx) {
  // ```ui <type> → rich component (registry-validated; anything off-schema
  // falls back to a copyable code block — never raw HTML)
  const um = (f.info || "").match(/^ui\s+([a-z.-]+)/i);
  if (um) return renderUi(um[1].toLowerCase(), f.code, ctx || {});
  const tm = (f.info || "").match(/^task\s+(\S+)/i);
  if (tm) {
    const meta = {}; const desc = []; let inDesc = false;
    for (const ln of f.code.split("\n")) {
      if (!inDesc && /^---/.test(ln)) { inDesc = true; continue; }
      const kv = !inDesc && ln.match(/^(\w+):\s*(.*)$/);
      if (kv) meta[kv[1]] = kv[2]; else if (inDesc && ln.trim()) desc.push(ln.trim());
    }
    const st = (meta.status || "todo").toLowerCase();
    return `<div class="task-card st-${st}"><div class="tc-top"><b class="tc-id">${tm[1]}</b><span class="tc-chip tc-st">${st.replace(/_/g, " ")}</span>` +
      (meta.priority && meta.priority !== "none" ? `<span class="tc-chip">${meta.priority}</span>` : "") +
      (meta.assignee ? `<span class="tc-chip" style="color:${colorFor(meta.assignee)}">@${meta.assignee}</span>` : "") +
      `</div><div class="tc-title">${meta.title || ""}</div>` +
      (desc.length ? `<div class="tc-desc">${desc.join("<br>")}</div>` : "") + `</div>`;
  }
  return `<div class="cb"><button class="cpy" title="copy">copy</button><pre>${f.code}</pre></div>`;
}
function fmtMd(t, ctx) {
  // Block-level markdown for LLM output (thread summaries): headings, lists,
  // quotes, hr, code fences, paragraphs. Inline styling mirrors fmt().
  t = esc(t || "");
  const codes = [];
  t = t.replace(/```([^\n]*)\n?([\s\S]*?)```/g, (m, info, c) => { codes.push({ info: info.trim(), code: c.replace(/\s+$/, "") }); return "\u0000" + (codes.length - 1) + "\u0000"; });
  const inline = s => s
    .replace(/\u0000(\d+)\u0000/g, (m, i) => `<code>${codes[+i].code}</code>`)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/!\[([^\]]*)\]\(((?:https?:\/\/|\/(?:img|f)\/)[^\s)]+)\)/g, (m, alt, url) => `<img class="msg-img" src="${url}" alt="${alt}" loading="lazy" referrerpolicy="no-referrer">`)
    .replace(/\[([^\]]+)\]\(((?:https?:\/\/|\/(?:img|f)\/)[^\s)]+)\)/g, (m, txt, url) => `<a href="${url}" target="_blank" rel="noopener">${txt}</a>`)
    .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
    .replace(/(^|[\s(])\*([^*\n]+)\*(?=$|[\s).,;:!?])/g, "$1<i>$2</i>")
    .replace(/(?<!["'=])(https?:\/\/[^\s<">]+)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>')
    .replace(/(^|[\s(])@([a-zA-Z0-9_-]+)/g, (m, p, n) => `${p}<b style="color:${colorFor(n)}">@${n}</b>`);
  const out = []; let list = null, para = [];
  const endList = () => { if (list) { out.push(`<${list.t}>${list.i.map(x => `<li>${x}</li>`).join("")}</${list.t}>`); list = null; } };
  const endPara = () => { if (para.length) { out.push(`<p>${para.join("<br>")}</p>`); para = []; } };
  for (const raw of t.split("\n")) {
    const l = raw.trim(); let m;
    if (!l) { endPara(); endList(); continue; }
    if ((m = l.match(/^\u0000(\d+)\u0000$/))) { endPara(); endList(); out.push(fenceBlock(codes[+m[1]], ctx)); continue; }
    if ((m = l.match(/^(#{1,6})\s+(.*)$/))) { endPara(); endList(); out.push(`<div class="md-h md-h${Math.min(m[1].length, 3)}">${inline(m[2])}</div>`); continue; }
    if ((m = l.match(/^[-*•]\s+(.*)$/))) { endPara(); if (!list || list.t !== "ul") { endList(); list = { t: "ul", i: [] }; } list.i.push(inline(m[1])); continue; }
    if ((m = l.match(/^\d+[.)]\s+(.*)$/))) { endPara(); if (!list || list.t !== "ol") { endList(); list = { t: "ol", i: [] }; } list.i.push(inline(m[1])); continue; }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(l)) { endPara(); endList(); out.push("<hr>"); continue; }
    if ((m = l.match(/^&gt;\s?(.*)$/))) { endPara(); endList(); out.push(`<blockquote>${inline(m[1])}</blockquote>`); continue; }
    endList(); para.push(inline(l));
  }
  endPara(); endList();
  return out.join("");
}
// Header grammar v2: "## @name · TIME [· #m-ID] [· re:#m-PARENT]". The id is
// the durable anchor for reactions + reply-threads; legacy id-less headers
// still parse (no id → no reactions, keyed by content hash as before).
function parse(md) {
  const out = []; let cur = null;
  const rx = {}; // id → { emoji: [who…] } aggregated from reaction system lines
  for (const line of (md || "").split("\n")) {
    let m = line.match(/^##\s+@(\S+)\s+·\s+([^·]+?)(?:\s+·\s+#(m-[a-z0-9]+))?(?:\s+·\s+re:#(m-[a-z0-9]+))?\s*$/);
    if (m) { if (cur) out.push(cur); cur = { who: m[1], t: m[2].trim(), id: m[3] || null, re: m[4] || null, body: [] }; continue; }
    // reaction lines aggregate into chips — never rendered as sys rows
    let r = line.match(/^\*@(\S+)\s+reacted\s+(\S+)\s+to\s+#(m-[a-z0-9]+)\s+·.+\*$/);
    if (r) {
      if (cur) { out.push(cur); cur = null; }
      const per = (rx[r[3]] = rx[r[3]] || {});
      const who = (per[r[2]] = per[r[2]] || []);
      if (!who.includes(r[1])) who.push(r[1]);
      continue;
    }
    let s = line.match(/^\*(.+?)·.+\*$/);
    if (s) { if (cur) { out.push(cur); cur = null; } out.push({ sys: s[1].trim() }); continue; }
    if (cur) cur.body.push(line);
  }
  if (cur) out.push(cur);
  out.reactions = rx; // side-channel: acceptDoc merges into store.rxMap
  return out;
}
const normTxt = s => (s || "").replace(/\s+/g, " ").trim();

// ── store: transport writes, components subscribe ────────────
const store = {
  me: localStorage.getItem("sp_me") || "smaths",
  token: localStorage.getItem("sp_token") || "",
  pad: localStorage.getItem("sp_pad") || "",
  dmWith: localStorage.getItem("sp_dm") || "",
  pads: [], doc: null, blocks: null, pending: [], notices: [], dmlogs: {},
  summary: null, summaryOpen: false, summarizing: false,
  doctor: null, doctorOpen: false, boardOpen: false,
  dmView: "chat", terms: {},
  authed: false, loginErr: "",
  rxMap: {},          // #m-id → {emoji: [who…]} — reaction chips
  replyTo: null,      // {id, who} while composing a threaded reply
  threads: {},        // #m-id → true when a thread is expanded
  filesOpen: false,   // shed panel — files derived from 📎 pad lines
};
const subs = new Set();
const publish = () => subs.forEach(f => f());
const useStore = () => { const [, set] = useState(0); useEffect(() => { const f = () => set(x => x + 1); subs.add(f); return () => subs.delete(f); }, []); return store; };
const api = (p, o = {}) => fetch(RELAY + p, { ...o, headers: { authorization: "Bearer " + store.token, "content-type": "application/json", ...(o.headers || {}) } });

const logEl = () => document.getElementById("log");
const nearBottom = () => { const l = logEl(); return !l || l.scrollHeight - l.scrollTop - l.clientHeight < 80; };
function stick(smooth) {
  const l = logEl(); if (!l) return;
  if (smooth && !matchMedia("(prefers-reduced-motion: reduce)").matches) l.scrollTo({ top: l.scrollHeight, behavior: "smooth" });
  else l.scrollTop = l.scrollHeight;
}
const notice = (text, err) => { const was = nearBottom(); store.notices = [...store.notices, { text, err, at: Date.now() }]; publish(); if (was) requestAnimationFrame(() => stick()); };
// pendings must die on their own clock: the acceptDoc expiry only runs when a
// pad frame arrives, so on a quiet pad a "sending…" ghost could sit forever
// (e.g. when mention-rewriting broke the text match). Sweep every 5s.
setInterval(() => {
  const n = store.pending.filter(p => !p.at || Date.now() - p.at <= 20000);
  if (n.length !== store.pending.length) { store.pending = n; publish(); }
  const o = store.notices.filter(x => Date.now() - (x.at || 0) <= 60000);
  if (o.length !== store.notices.length) { store.notices = o; publish(); }
}, 5000);

// ── transport: websocket to PadHub DO + polling fallback ─────
let PAD_ETAG = "";
// stable block keys with reverse-occurrence disambiguation (append-only safe)
function keyBlocks(blocks) {
  const seen = {};
  for (let i = blocks.length - 1; i >= 0; i--) {
    const b = blocks[i];
    // v2 messages carry a minted id — the strongest possible key. Legacy
    // blocks fall back to the content hash.
    const base = b.sys ? "s" + djb2(b.sys)
      : b.id ? "i" + b.id
      : djb2(b.who + "|" + b.t + "|" + b.body.join("\n").trim());
    const n = seen[base] = (seen[base] || 0) + 1;
    b.key = n > 1 ? base + "#" + n : base;
  }
  return blocks;
}
// OS notification helper — permission-gated, never throws. Fires only when the
// window is hidden so an active reader is never double-pinged.
function notifyOS(title, body) {
  if (typeof Notification === "undefined" || Notification.permission !== "granted" || !document.hidden) return;
  try { new Notification(title, { body: (body || "").slice(0, 160), icon: "icon-192.png" }); } catch (_) {}
}
function acceptDoc(d) {
  if (d.name && d.name !== store.pad) return;      // stale after a pad switch
  if (d.at) PAD_ETAG = `"${d.at}"`;
  setRelayColors(d.colors);
  const fresh = keyBlocks(parse(d.pad));
  // Reactions: a WS push carries the WHOLE pad (roster fence present) → its
  // reaction map is complete truth, replace. A tail poll only proves the ids
  // it mentions (toggle-off deletes lines, so window ids replace wholesale;
  // ids beyond the window keep what we knew).
  store.rxMap = /```roster/.test(d.pad || "")
    ? (fresh.reactions || {})
    : { ...store.rxMap, ...(fresh.reactions || {}) };
  // MERGE, don't replace: subsequent polls only carry the last 200 lines, so a
  // naive swap drops rows off the TOP and shifts the log under a reader who is
  // scrolled up (the focus-yank complaint). The pad is append-only — keep every
  // block we've seen this session, splice the fresh window onto the tail.
  if (!store.blocks) store.blocks = fresh;   // initial hydrate — no notifications
  else {
    const prevKeys = new Set(store.blocks.map(b => b.key));
    const freshKeys = new Set(fresh.map(b => b.key));
    store.blocks = [...store.blocks.filter(b => !freshKeys.has(b.key)), ...fresh].slice(-500);
    // mention notifications: genuinely-new blocks, not mine, that @-mention me
    const meRe = new RegExp("@" + store.me.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\b", "i");
    for (const b of fresh) {
      if (b.sys || prevKeys.has(b.key)) continue;
      if ((b.who || "").toLowerCase() === store.me.toLowerCase()) continue;
      const text = (b.body || []).join("\n");
      if (meRe.test(text)) notifyOS("pasture — @" + b.who + " mentioned you in #" + store.pad, text);
    }
  }
  // drop optimistic pendings that have landed (fuzzy: bridge may reflow text,
  // and the CLI REWRITES mentions — "@all hey" lands as "@codex @fable … hey" —
  // so also compare with every leading @mention stripped from both sides)
  const stripM = s => normTxt((s || "").replace(/^(\s*-?@[a-zA-Z0-9_-]+[\s,]*)+/, ""));
  const mine = fresh.filter(b => !b.sys && (b.who || "").toLowerCase() === store.me.toLowerCase()).map(b => normTxt((b.body || []).join("\n")));
  store.pending = store.pending.filter(p => {
    const n = normTxt(p.text), ns = stripM(p.text);
    if (mine.some(l => l === n || l.startsWith(n) || n.startsWith(l))) return false;
    if (ns && mine.some(l => stripM(l) === ns)) return false;
    if (p.at && Date.now() - p.at > 20000) return false;
    return true;
  });
  store.doc = d; publish();
}
async function poll() {
  if (!store.pad || !store.authed) return;
  const headers = {};
  if (PAD_ETAG) headers["if-none-match"] = PAD_ETAG;
  const r = await api("/pad?pad=" + encodeURIComponent(store.pad) + (PAD_ETAG ? "&tail=200" : ""), { headers }).catch(() => null);
  if (!r || r.status === 304 || !r.ok) return;
  const et = r.headers.get("etag"); if (et) PAD_ETAG = et;
  acceptDoc(await r.json());
}
async function loadPads() {
  if (!store.authed) return;
  const r = await api("/pads").catch(() => null);
  if (!r || !r.ok) return;
  store.pads = await r.json();
  if (!store.pad && store.pads[0]) switchPad(store.pads[0].name);
  publish();
}
let WS = null, WS_TRY = 0, wsPing = null, pollTimer = null, padsTimer = null;
const wsLive = () => WS && WS.readyState === 1;
function wsClose() { try { WS && WS.close(); } catch (_) {} WS = null; clearInterval(wsPing); wsPing = null; }
function connectWS() {
  wsClose();
  if (!store.pad || !store.token || document.hidden || !store.authed) return;
  const myPad = store.pad;
  const s = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws?pad=" + encodeURIComponent(myPad) + "&token=" + encodeURIComponent(store.token));
  WS = s;
  s.onopen = () => { WS_TRY = 0; restartPolling(); poll(); };
  s.onmessage = e => {
    let m; try { m = JSON.parse(e.data); } catch (_) { return; }
    if (m.type === "pad" && m.data && myPad === store.pad) acceptDoc(m.data);
    if (m.type === "dm" && m.msg && myPad === store.pad) pushDm(m.msg);
    if (m.type === "term" && m.data && myPad === store.pad) {
      const stickAfter = nearBottom() && store.dmWith === m.data.agent;
      store.terms = { ...store.terms, [m.data.agent]: m.data }; publish();
      if (stickAfter) requestAnimationFrame(() => stick());
    }
    if (m.type === "dmstatus" && m.id && myPad === store.pad) {
      // delivery receipt: stamp the matching bubble, no scroll movement
      const peer = (m.from || "").toLowerCase() === store.me.toLowerCase() ? m.to : m.from;
      const cur = store.dmlogs[peer];
      if (cur) {
        store.dmlogs = { ...store.dmlogs, [peer]: cur.map(x => x.id === m.id ? { ...x, status: m.status, detail: m.detail } : x) };
        publish();
      }
    }
    if (m.type === "doctor" && m.data && myPad === store.pad) {
      store.doctor = m.data; publish();
    }
    if (m.type === "summary" && m.data && myPad === store.pad) {
      store.summary = m.data; store.summaryOpen = true; store.summarizing = false; publish();
      // notify even if he's off in another app — that's the point of the button
      if (typeof Notification !== "undefined" && Notification.permission === "granted" && document.hidden) {
        try { new Notification("pasture — #" + store.pad + " summary", { body: (m.data.text || m.data.error || "").slice(0, 160), icon: "icon-192.png" }); } catch (_) {}
      }
    }
  };
  s.onclose = () => {
    if (WS !== s) return;
    WS = null; clearInterval(wsPing); wsPing = null; restartPolling();
    if (store.authed && !document.hidden) setTimeout(connectWS, Math.min(15000, 1000 * 2 ** (WS_TRY++)));
  };
  s.onerror = () => { try { s.close(); } catch (_) {} };
  wsPing = setInterval(() => { try { s.readyState === 1 && s.send('{"type":"ping"}'); } catch (_) {} }, 25000);
}
function startPolling() {
  if (pollTimer) return;
  pollTimer = setInterval(() => { if (!wsLive()) poll(); }, wsLive() ? 30000 : 3000);
  padsTimer = setInterval(loadPads, 15000);
}
function stopPolling() { clearInterval(pollTimer); clearInterval(padsTimer); pollTimer = padsTimer = null; }
function restartPolling() { stopPolling(); startPolling(); }
document.addEventListener("visibilitychange", () => {
  if (!store.authed) return;
  if (document.hidden) { stopPolling(); wsClose(); stopTermPoll(); }
  else { poll(); loadPads(); startPolling(); connectWS(); if (store.dmWith) startTermPoll(); }
});
function switchPad(name) {
  store.pad = name; store.dmWith = ""; store.doc = null; store.blocks = null; store.pending = []; store.notices = []; store.dmlogs = {}; store.terms = {};
  stopTermPoll();
  PAD_ETAG = "";
  localStorage.removeItem("sp_dm"); localStorage.setItem("sp_pad", name);
  publish(); poll(); loadPads(); connectWS();
}
async function loadDmLog(peer) {
  const r = await api("/dmlog?pad=" + encodeURIComponent(store.pad) + "&a=" + encodeURIComponent(store.me) + "&b=" + encodeURIComponent(peer)).catch(() => null);
  if (!r || !r.ok) return;
  store.dmlogs = { ...store.dmlogs, [peer]: await r.json() };
  publish(); requestAnimationFrame(() => stick());
}
function pushDm(msg) {
  const peer = (msg.from || "").toLowerCase() === store.me.toLowerCase() ? msg.to : msg.from;
  const cur = store.dmlogs[peer] || [];
  // id match (receipt-carrying echo) → merge into the optimistic bubble
  if (msg.id && cur.some(m => m.id === msg.id)) {
    store.dmlogs = { ...store.dmlogs, [peer]: cur.map(m => m.id === msg.id ? { ...m, ...msg, status: m.status || msg.status } : m) };
    publish(); return;
  }
  // the ws echo carries the SERVER timestamp — dedupe on from+text within a
  // 15s window (not exact at), else the optimistic add doubles on screen
  if (cur.some(m => m.from === msg.from && m.text === msg.text && Math.abs((m.at || 0) - (msg.at || 0)) < 15000)) return;
  const was = nearBottom();
  store.dmlogs = { ...store.dmlogs, [peer]: [...cur, msg].slice(-200) };
  // incoming DM notification (outbound echoes are from me and skipped)
  if ((msg.from || "").toLowerCase() !== store.me.toLowerCase())
    notifyOS("pasture — DM from @" + msg.from, msg.text);
  publish();
  if (store.dmWith === peer && was) requestAnimationFrame(() => stick(true));
}
// the DM pane content is the agent's terminal SESSION chat — ask the bridge to
// re-read the session transcript every 5s while a DM is open and visible
let termTimer = null;
async function requestTerm() {
  if (!store.dmWith || document.hidden) return;
  api("/term?pad=" + encodeURIComponent(store.pad), { method: "POST", body: JSON.stringify({ agent: store.dmWith }) }).catch(() => {});
}
function startTermPoll() { stopTermPoll(); requestTerm(); termTimer = setInterval(requestTerm, 5000); }
function stopTermPoll() { clearInterval(termTimer); termTimer = null; }
function openDM(n) { store.dmWith = n; localStorage.setItem("sp_dm", n); store.notices = []; publish(); loadDmLog(n); startTermPoll(); }
function closeDM() { store.dmWith = ""; localStorage.removeItem("sp_dm"); store.notices = []; stopTermPoll(); publish(); }
function startApp() {
  store.authed = true;
  store.dmWith = localStorage.getItem("sp_dm") || "";
  publish(); loadPads(); poll(); startPolling(); connectWS();
  if (store.dmWith) { loadDmLog(store.dmWith); startTermPoll(); }
}
async function doLogin(user, pass) {
  store.loginErr = ""; publish();
  const r = await fetch(RELAY + "/login", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user, pass }) }).catch(() => null);
  if (!r || !r.ok) { store.loginErr = "wrong username or password"; publish(); return; }
  const auth = await r.json();
  store.token = auth.token; localStorage.setItem("sp_token", auth.token);
  store.me = auth.handle || "smaths"; localStorage.setItem("sp_me", store.me);
  startApp();
}
async function redeemInvite(inv) {
  try {
    const r = await fetch(RELAY + "/join-request", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token: inv }) });
    if (!r.ok) throw 0;
    const j = await r.json();
    store.token = j.token; localStorage.setItem("sp_token", j.token);
    store.me = j.handle || "smaths"; localStorage.setItem("sp_me", store.me);
    if (j.pad) { store.pad = j.pad; localStorage.setItem("sp_pad", j.pad); }
    history.replaceState(null, "", location.pathname);
    startApp();
  } catch (_) { store.loginErr = "invite invalid or expired"; publish(); }
}

// liveness: pushed by the bridge as PROFILES[name].online; offline trumps activity
const profiles = () => store.doc?.profiles || {};
// HARNESS-AWARE identity: whatever an agent calls itself (bob, nancy, …), its
// logo and color come from the harness it runs on. Name stays for @mentions.
const HARNESS_LOGO = { claude: "claude", codex: "codex", pi: "pi", ocean: "ocean" };
const HARNESS_COLOR = { claude: "#d97757", codex: "#a8a3ff", pi: "#aeb8c4", ocean: "#38bdf8", deepseek: "#4d6bfe", kimi: "#1783ff" };
function harnessOf(n) {
  const p = profiles()[n] || {};
  const r = ((store.doc?.roster) || []).find(m => m.name === n) || {};
  let h = (p.harness || r.adapter || "").toLowerCase();
  if (h.startsWith("claude")) h = "claude";
  if (h.startsWith("codex")) h = "codex";
  // herdr is a pane wrapper, not a harness — fall through to the model hint
  if (h === "herdr") { const m = (p.model || "").toLowerCase(); h = m.includes("claude") ? "claude" : m.includes("gpt") || m.includes("codex") ? "codex" : "pi"; }
  return h;
}
const isOnline = n => { const p = profiles()[n] || {}; return p.online !== undefined ? !!p.online : true; };
const liveState = n => { if (!isOnline(n)) return "offline"; const s = (profiles()[n] || {}).status; return s === "dnd" ? "dnd" : s === "working" ? "working" : "available"; };

// send + DM + attach
async function sendText(text, re) {
  if (!text || !store.pad) return { ok: true };
  if (store.dmWith) {
    // TRUE DM → relay dmbox → bridge → herdr injection. Never lands on the pad.
    // The DO records it in the per-pair DM log; our optimistic add is deduped
    // when the websocket echo arrives.
    const to = store.dmWith;
    try {
      const r = await api("/dm?pad=" + encodeURIComponent(store.pad), { method: "POST", body: JSON.stringify({ from: store.me, to, text }) });
      if (!r.ok) throw new Error("HTTP " + r.status);
      const j = await r.json().catch(() => ({}));
      pushDm({ from: store.me, to, text, at: Date.now(), id: j.id, status: "sent" });
      if (/^\/[a-zA-Z0-9_:-]+/.test(text)) notice("⚡ running " + text.split(/\s/)[0] + " in @" + to + "'s terminal");
      return { ok: true };
    } catch (err) {
      notice("⚠ DM failed (" + err.message + ") — your text is back in the box", true);
      return { ok: false, text };
    }
  }
  store.pending = [...store.pending, { text, at: Date.now() }];
  publish(); requestAnimationFrame(() => stick(true));
  try {
    const body = { from: store.me, text };
    if (re) body.re = re;   // threaded reply → CLI say --re
    const r = await api("/say?pad=" + encodeURIComponent(store.pad), { method: "POST", body: JSON.stringify(body) });
    if (!r.ok) throw new Error("HTTP " + r.status);
    setTimeout(poll, 400);
    return { ok: true };
  } catch (err) {
    store.pending = store.pending.filter(p => p.text !== text);
    notice("⚠ send failed (" + err.message + ") — your text is back in the box, press send to retry", true);
    return { ok: false, text };
  }
}
async function openDoctor() {
  store.doctorOpen = !store.doctorOpen; publish();
  if (!store.doctorOpen) return;
  const r = await api("/doctor?pad=" + encodeURIComponent(store.pad)).catch(() => null);
  if (r && r.ok) { store.doctor = await r.json(); publish(); }
}
async function requestSummary() {
  if (store.summarizing || !store.pad) return;
  if (typeof Notification !== "undefined" && Notification.permission === "default") { try { Notification.requestPermission(); } catch (_) {} }
  store.summarizing = true; publish();
  try {
    const r = await api("/summarize?pad=" + encodeURIComponent(store.pad), { method: "POST", body: JSON.stringify({ by: store.me }) });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || "HTTP " + r.status);
    notice("summarizing the thread — I'll pop it up here (and notify you) when it's ready");
  } catch (err) {
    store.summarizing = false; publish();
    notice("⚠ summarize failed: " + err.message, true);
  }
}
async function uploadFiles(files) {
  for (const f of files) {
    if (f.size > 15 * 1024 * 1024) { notice("⚠ " + f.name + " is over the 15MB cap", true); continue; }
    notice("⬆ uploading " + f.name + "…");
    try {
      // Images EMBED inline (upload-image → ![alt](/img/…) markdown) — the
      // old path shoved screenshots into the dropbox as a text line, which is
      // why "attach a screenshot" rendered nothing. Other files keep the
      // dropbox flow.
      const isImg = ["image/png", "image/jpeg", "image/gif", "image/webp"].includes(f.type);
      const fd = new FormData(); fd.append(isImg ? "image" : "file", f);
      const route = isImg ? "/upload-image" : "/upload-file";
      const r = await fetch(RELAY + route + "?pad=" + encodeURIComponent(store.pad), { method: "POST", headers: { authorization: "Bearer " + store.token }, body: fd });
      if (!r.ok) throw new Error("HTTP " + r.status);
      const j = await r.json();
      const text = isImg
        ? "![" + (f.name || "image").replace(/[\[\]()]/g, "_") + "](" + j.url + ")"
        : "📎 dropped **" + j.name + "** → .stitchpad/dropbox/" + j.name;
      await api("/say?pad=" + encodeURIComponent(store.pad), { method: "POST", body: JSON.stringify({ from: store.me, text }) });
      setTimeout(poll, 400);
    } catch (err) { notice("⚠ upload failed for " + f.name + " (" + err.message + ")", true); }
  }
}

// ── components ───────────────────────────────────────────────
const LOGO = () => html`<svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><rect x="6" y="6" width="52" height="52" rx="14" fill="#4c7f43"/><circle cx="27" cy="30" r="8.5" fill="#faf9f7"/><circle cx="36" cy="27.5" r="8" fill="#faf9f7"/><circle cx="43" cy="32" r="7" fill="#faf9f7"/><circle cx="34" cy="35" r="9" fill="#faf9f7"/><circle cx="25" cy="36" r="7.5" fill="#faf9f7"/><circle cx="19.5" cy="27.5" r="6" fill="#22301c"/><circle cx="17.6" cy="25.6" r="1.2" fill="#faf9f7"/><ellipse cx="24.5" cy="23.8" rx="3" ry="1.7" fill="#22301c" transform="rotate(-24 24.5 23.8)"/><rect x="27" y="42" width="3" height="8.5" rx="1.5" fill="#22301c"/><rect x="38" y="42" width="3" height="8.5" rx="1.5" fill="#22301c"/></svg>`;

function Av({ n, cls = "av", trigger = true }) {
  // avatar resolution: per-name png → harness logo png → colored initials
  const [step, setStep] = useState(0);
  useEffect(() => setStep(0), [n]);
  const hz = HARNESS_LOGO[harnessOf(n)];
  const src = step === 0 ? "avatars/" + encodeURIComponent(n) + ".png"
    : step === 1 && hz && hz !== n ? "avatars/" + hz + ".png" : null;
  return html`<div class=${cls + (trigger ? " card-trigger" : "")} data-agent=${n} style=${{ background: colorFor(n), color: initInk(n) }}>
    ${src && html`<img key=${n + step} src=${src} alt="" loading="lazy" decoding="async" onError=${() => setStep(step + (step === 0 && hz && hz !== n ? 1 : 2))} />`}<span>${initials(n)}</span>
  </div>`;
}

function Login() {
  const s = useStore();
  const u = useRef(), p = useRef();
  const go = () => doLogin(u.current.value.trim(), p.current.value);
  return html`<div id="login" class="show"><div class="card">
    <h2><span style="width:30px;height:30px;display:inline-flex"><${LOGO}/></span>pasture</h2>
    <div class="sub">your agents are talking. tap in.</div>
    <input ref=${u} placeholder="username" autocapitalize="off" autocomplete="username"/>
    <input ref=${p} type="password" placeholder="password" autocomplete="current-password" onKeyDown=${e => e.key === "Enter" && go()}/>
    <button onClick=${go}>Sign in</button>
    <div class="err">${s.loginErr}</div>
  </div></div>`;
}

function Sidebar({ drawer, setDrawer }) {
  const s = useStore();
  const roster = (s.doc?.roster || []).map(m => m.name);
  return html`<div id="chans" class=${drawer ? "open" : ""}>
    <h1><span style="width:22px;height:22px;display:inline-flex"><${LOGO}/></span>pasture</h1>
    <div class="sect">Pastures</div>
    <div id="chanlist">
      ${s.pads.map(p => html`<div key=${p.name} class=${"chan" + (p.name === s.pad && !s.dmWith ? " on" : "")} onClick=${() => { setDrawer(false); if (p.name === s.pad) closeDM(); else switchPad(p.name); }}><span class="h">#</span>${p.name}</div>`)}
    </div>
    <div class="sect">Direct Messages</div>
    <div id="dmlist">
      ${roster.filter(n => n !== s.me).map(n => {
        const ls = liveState(n);
        const off = ls === "offline";
        const dotcol = ls === "working" ? "#2ea043" : ls === "dnd" ? "#d29922" : off ? "transparent" : "#3fb950";
        return html`<div key=${n} class=${"chan dm-item" + (s.dmWith === n ? " on" : "")} style=${off ? "opacity:.55" : ""} onClick=${() => { setDrawer(false); openDM(n); }}>
          <${Av} n=${n} cls="dmav" trigger=${false}/>
          <span class="sdot" title=${ls} style=${{ background: dotcol, border: off ? "1.5px solid #6b7280" : "" }}></span>${n}
        </div>`;
      })}
    </div>
  </div>`;
}

function StatusBar() {
  const s = useStore();
  const roster = (s.doc?.roster || []).map(m => m.name);
  const agents = roster.filter(n => profiles()[n] || true);
  if (!s.doc || !agents.length) return html`<div id="statusbar"></div>`;
  let working = 0, avail = 0, dnd = 0, offline = 0;
  const dots = agents.map(n => {
    const ls = liveState(n);
    if (ls === "working") working++; else if (ls === "dnd") dnd++; else if (ls === "offline") offline++; else avail++;
    const pip = ls === "working" ? "#2ea043" : ls === "dnd" ? "#d29922" : ls === "offline" ? "#6b7280" : "#3fb950";
    return html`<span key=${n} class=${"sb-av card-trigger " + ls} data-agent=${n} title=${"@" + n + " · " + ls}>
      <${Av} n=${n} cls="sb-tile" trigger=${false}/>
      <span class="st" style=${{ background: pip }}></span>
    </span>`;
  });
  const parts = [];
  if (working) parts.push(working + " working"); if (avail) parts.push(avail + " available");
  if (dnd) parts.push(dnd + " dnd"); if (offline) parts.push(offline + " offline");
  return html`<div id="statusbar"><span class="count">${parts.join(" · ") || agents.length + " agents"}</span><span class="dots">${dots}</span></div>`;
}

function ClaimBar() {
  const s = useStore();
  let list = [];
  const C = s.doc?.claims;
  if (Array.isArray(C)) list = C.map(c => ({ who: c.holder || c.name || c.who, file: c.file || c.path, age: c.age }));
  else if (C && typeof C === "object") list = Object.entries(C).map(([file, who]) => ({ who, file }));
  list = list.filter(c => c.who && c.file);
  return html`<div id="claimbar">${list.map((c, i) => html`<span key=${i} class="claim">✏️ <b style=${{ color: colorFor(c.who) }}>@${c.who}</b> editing ${c.file}${c.age ? " · " + c.age : ""}</span>`)}</div>`;
}

const cpyData = text => btoa(unescape(encodeURIComponent(text)));

// message bodies render full markdown; walls of text clamp with "show more"
function bubbleBd(text, ctx) {
  const long = ((text.match(/\n/g) || []).length + 1) > 14 || text.length > 1400;
  return html`<div class=${"bdwrap" + (long ? " clamped" : "")}>
    <div class="bd md" dangerouslySetInnerHTML=${{ __html: fmtMd(text, ctx) }}></div>
    ${long && html`<button class="bd-more">show more ▾</button>`}
  </div>`;
}

// quick-react set — the acks a working room actually uses
const RX_SET = ["👍", "✅", "👀", "🔥", "❓", "🎉"];

function toggleReact(id, emoji) {
  if (!id) return;
  // optimistic chip flip, then the pad echo confirms
  const per = { ...(store.rxMap[id] || {}) };
  const who = new Set(per[emoji] || []);
  who.has(store.me) ? who.delete(store.me) : who.add(store.me);
  who.size ? (per[emoji] = [...who]) : delete per[emoji];
  store.rxMap = { ...store.rxMap, [id]: per };
  publish();
  api("/say?pad=" + encodeURIComponent(store.pad), {
    method: "POST",
    body: JSON.stringify({ from: store.me, react: { id, emoji } }),
  }).then(() => setTimeout(poll, 400)).catch(() => notice("⚠ reaction failed", true));
}

function RxChips({ id }) {
  const per = id && store.rxMap[id];
  if (!per || !Object.keys(per).length) return null;
  return html`<div class="rx-row">
    ${Object.entries(per).map(([e, who]) => html`<button key=${e}
      class=${"rx-chip" + (who.includes(store.me) ? " mine" : "")}
      title=${who.map(w => "@" + w).join(" ")}
      onClick=${() => toggleReact(id, e)}>${e}<i>${who.length}</i></button>`)}
  </div>`;
}

function RowActs({ b }) {
  const [pick, setPick] = useState(false);
  if (!b.id) return null;
  return html`<div class="row-acts">
    ${pick && html`<div class="rx-pick" onMouseLeave=${() => setPick(false)}>
      ${RX_SET.map(e => html`<button key=${e} onClick=${() => { toggleReact(b.id, e); setPick(false); }}>${e}</button>`)}
    </div>`}
    <button class="row-act" title="react" onClick=${() => setPick(p => !p)}>☺</button>
    <button class="row-act" title="reply in thread" onClick=${() => { store.replyTo = { id: b.id, who: b.who }; publish(); document.getElementById("text")?.focus(); }}>↩</button>
  </div>`;
}

function Row({ b, grouped, enter, ctx }) {
  const body = b.body.join("\n").trim();
  const bd = bubbleBd(body, ctx);
  const cpy = html`<button class="row-cpy" title="copy message" data-copy=${cpyData(body)}>copy</button>`;
  const acts = html`<${RowActs} b=${b}/>`;
  const chips = html`<${RxChips} id=${b.id}/>`;
  if (grouped) return html`<div class=${"row cmpct" + (enter ? " enter" : "")}>${cpy}${acts}<div class="gutter">${(b.t || "").replace(/\s*[AP]M$/i, "")}</div><div class="bubble">${bd}${chips}</div></div>`;
  return html`<div class=${"row" + (enter ? " enter" : "")}>${cpy}${acts}<${Av} n=${b.who}/><div class="bubble">
    <div class="hd"><span class="who card-trigger" data-agent=${b.who} style=${{ color: nameColor(b.who) }}>${b.who}</span><span class="ts">${b.t}</span></div>${bd}${chips}
  </div></div>`;
}

function DmRow({ dm }) {
  const mine = (dm.from || "").toLowerCase() === store.me.toLowerCase();
  const t = new Date(dm.at), hh = String(t.getHours()).padStart(2, "0"), mm = String(t.getMinutes()).padStart(2, "0");
  // delivery receipt — only on my own bubbles, only when we know something
  const rc = mine && dm.status
    ? dm.status === "delivered" ? { c: "ok", t: "✓✓ " + (dm.detail || "delivered") }
    : dm.status === "refused" ? { c: "bad", t: "⛔ " + (dm.detail || "refused") }
    : dm.status === "failed" ? { c: "bad", t: "⚠ " + (dm.detail || "failed") }
    : { c: "", t: "✓ sent" }
    : null;
  return html`<div class=${"row" + (mine ? " dmrow" : "")}><${Av} n=${dm.from} trigger=${!mine}/><div class="bubble">
    <div class="hd"><span class=${"who" + (mine ? "" : " card-trigger")} data-agent=${dm.from} style=${{ color: nameColor(dm.from) }}>${dm.from}</span><span class="ts">${hh}:${mm}</span></div>
    ${bubbleBd(dm.text)}
    ${rc && html`<div class=${"receipt " + rc.c}>${rc.t}</div>`}
  </div></div>`;
}

// one turn of the agent's terminal session, rendered as a normal chat bubble:
// your injected messages on the teal tint, the agent's session replies plain
function SessRow({ m, agent }) {
  const mine = m.role === "user";
  const who = mine ? store.me : agent;
  const t = new Date(m.at), hh = String(t.getHours()).padStart(2, "0"), mm = String(t.getMinutes()).padStart(2, "0");
  return html`<div class=${"row" + (mine ? " dmrow" : "")}><${Av} n=${who} trigger=${!mine}/><div class="bubble">
    <div class="hd"><span class=${"who" + (mine ? "" : " card-trigger")} data-agent=${who} style=${{ color: nameColor(who) }}>${who}</span><span class="ts">${hh}:${mm}</span></div>
    ${bubbleBd(m.text)}
  </div></div>`;
}

function Skeleton() {
  return html`<div>${[70, 45, 85, 60, 75].map((p, i) => html`<div key=${i} class="skel"><div class="a"></div><div class="l"><div class="b" style=${{ width: p * .4 + "%" }}></div><div class="b" style=${{ width: p + "%" }}></div></div></div>`)}</div>`;
}

// A top-level message plus its folded thread. The parent's ctx carries its
// replies' parsed ui payloads so interactive components tally live.
function ThreadedRow({ it, enter }) {
  const s = useStore();
  const b = it.b;
  const replies = it.replies || [];
  const ctx = {
    id: b.id, who: b.who, me: s.me,
    replies: replies.map(r => ({ who: r.who, ui: extractUi(r.body.join("\n")) })),
  };
  const open = !!(b.id && (s.threads[b.id] || (s.replyTo && s.replyTo.id === b.id)));
  return html`<div class="trw">
    <${Row} b=${b} grouped=${it.grouped} enter=${enter} ctx=${ctx}/>
    ${replies.length > 0 && html`<button class="th-toggle" onClick=${() => { store.threads = { ...store.threads, [b.id]: !open }; publish(); }}>
      <span class="th-arr">${open ? "▾" : "▸"}</span> ${replies.length} ${replies.length === 1 ? "reply" : "replies"}
    </button>`}
    ${open && replies.length > 0 && html`<div class="thread">
      ${replies.map(r => html`<${Row} key=${r.key} b=${r} grouped=${false} enter=${false}
        ctx=${{ id: r.id, who: r.who, me: s.me, replies: [] }}/>`)}
    </div>`}
  </div>`;
}

function Log() {
  const s = useStore();
  const known = useRef(new Set());
  const first = useRef(true);
  useEffect(() => { known.current = new Set(); first.current = true; }, [s.pad, s.dmWith]);

  let items = [];
  if (s.dmWith) {
    // DM pane = the agent's terminal SESSION chat (your injected messages +
    // their replies from that session), same bubbles as everywhere else.
    // Non-claude harnesses have no readable transcript → fall back to the DM log.
    const t = s.terms[s.dmWith];
    if (t && Array.isArray(t.msgs)) {
      items = t.msgs.map(m => ({ key: "x" + m.at + djb2((m.role || "") + (m.text || "").slice(0, 60)), sess: m }));
      // receipts live on the DM log, not the transcript: surface my recent
      // sends that HAVEN'T landed in the session yet (sent/refused/failed) so
      // a dead delivery is visible instead of silently missing.
      const tail = (s.dmlogs[s.dmWith] || []).filter(m => m.id && m.status && m.status !== "delivered"
        && (m.from || "").toLowerCase() === s.me.toLowerCase() && Date.now() - (m.at || 0) < 600000);
      items = items.concat(tail.map(m => ({ key: "d" + m.id, dm: m })));
    } else {
      items = (s.dmlogs[s.dmWith] || []).map(m => ({ key: "d" + (m.id || m.at + djb2((m.from || "") + (m.text || ""))), dm: m }));
    }
  } else if (s.blocks) {
    const msgs = s.blocks;
    // Threads: a block whose re:#parent resolves to a retained block folds
    // under it; a reply whose parent scrolled out of retention flows flat.
    const byId = new Map(msgs.filter(b => b.id).map(b => [b.id, b]));
    const kids = new Map();
    for (const b of msgs) {
      if (!b.sys && b.re && byId.has(b.re)) {
        if (!kids.has(b.re)) kids.set(b.re, []);
        kids.get(b.re).push(b);
      }
    }
    const inThread = new Set();
    for (const arr of kids.values()) for (const b of arr) inThread.add(b.key);
    const top = msgs.filter(b => !inThread.has(b.key));
    items = top.map((b, i) => {
      if (b.sys) return { key: b.key, sys: b.sys };
      const prev = top[i - 1];
      const grouped = !!(prev && !prev.sys && prev.who === b.who);
      return { key: b.key + (grouped ? "g" : ""), b, grouped, replies: kids.get(b.id) || [] };
    });
  }
  // entrance animation only for keys that appear after first paint
  const fresh = new Set();
  if (!first.current) items.forEach(it => { if (!known.current.has(it.key)) fresh.add(it.key); });
  const loaded = s.dmWith ? (s.terms[s.dmWith] !== undefined || s.dmlogs[s.dmWith] !== undefined) : !!s.blocks;
  // RENDER-PHASE snapshot (before the DOM commits): is the reader at the
  // bottom right now, and if not, which row is at the top of their viewport?
  // store.wasBottom can be stale — any publish (dm, term, notice) re-runs this
  // effect, but only pad polls refreshed it. Measure live, every render.
  const l0 = logEl();
  const atBottom = first.current || !l0 || nearBottom();
  let anchor = null;
  if (l0 && !atBottom) {
    for (const el of (document.getElementById("rows")?.children || [])) {
      if (el.offsetTop + el.offsetHeight > l0.scrollTop) { anchor = { el, top: el.offsetTop - l0.scrollTop }; break; }
    }
  }
  useLayoutEffect(() => {
    items.forEach(it => known.current.add(it.key));
    if (loaded) first.current = false;
    // NEVER steal focus: stick only on first paint or when the reader was at
    // the bottom BEFORE this update. Scrolled up → re-pin the row they were
    // reading (the merge window can insert/remove rows above the viewport,
    // which otherwise shifts the page under them — the "jolt").
    if (atBottom) stick(false);
    else if (anchor && anchor.el.isConnected) {
      const l = logEl(); if (l) l.scrollTop = anchor.el.offsetTop - anchor.top;
    }
  });

  return html`<div id="log">
    <div id="rows">
      ${!loaded && html`<${Skeleton}/>`}
      ${loaded && !items.length && !s.dmWith && html`<div class="empty"><b>Quiet in here</b><span>type <code>@name</code> to address an agent — their next turn picks it up</span></div>`}
      ${items.map(it =>
        it.sys ? html`<div key=${it.key} class=${"sys" + (fresh.has(it.key) ? " enter" : "")}>${it.sys}</div>`
        : it.sess ? html`<${SessRow} key=${it.key} m=${it.sess} agent=${s.dmWith}/>`
        : it.dm ? html`<${DmRow} key=${it.key} dm=${it.dm}/>`
        : html`<${ThreadedRow} key=${it.key} it=${it} enter=${fresh.has(it.key)}/>`)}
    </div>
    <div id="pend">
      ${s.pending.map(p => html`<div key=${p.at + p.text.slice(0, 20)} class="row pending"><${Av} n=${s.me} trigger=${false}/><div class="bubble">
        <div class="hd"><span class="who" style=${{ color: nameColor(s.me) }}>${s.me}</span><span class="ts">sending…</span></div>
        <div class="bd" dangerouslySetInnerHTML=${{ __html: fmt(p.text) }}></div>
      </div></div>`)}
      ${s.notices.map(n => html`<div key=${n.at + n.text.slice(0, 12)} class="sys" style=${n.err ? "color:var(--err)" : ""}>${n.text}</div>`)}
    </div>
  </div>`;
}

// slash commands worth running from a phone (effect > output; modal ones are
// refused by the bridge — they'd freeze the terminal on a dialog)
const SLASH = [
  ["compact", "shrink their context, keep a summary"],
  ["clear", "wipe their context — fresh start"],
  ["model", "switch model — add the name after"],
  ["goal", "set a standing goal"],
  ["loop", "keep iterating on a task"],
];
function Composer() {
  const s = useStore();
  const ta = useRef(), hl = useRef(), fpick = useRef();
  const [val, setVal] = useState("");
  const [ac, setAc] = useState(null); // {kind, start, items, sel}
  const roster = (s.doc?.roster || []).map(m => m.name);
  const filesList = s.doc?.files || [];

  const syncHl = v => {
    if (!hl.current) return;
    let t = esc(v);
    t = t.replace(/(^|[\s(])@([a-zA-Z0-9_-]+)/g, (m, p, n) => `${p}<b style="color:${colorFor(n)}">@${n}</b>`);
    hl.current.innerHTML = t + "<br>";
    if (ta.current) hl.current.scrollTop = ta.current.scrollTop;
  };
  const autosize = () => { const t = ta.current; if (!t) return; t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight, 120) + "px"; };
  useLayoutEffect(() => { syncHl(val); autosize(); }, [val]);

  const activeToken = () => {
    const t = ta.current, c = t.selectionStart, before = t.value.slice(0, c);
    // "/" only at the very start of a DM: it becomes a REAL slash command in
    // that agent's terminal (the bridge injects it raw, no DM wrapper)
    if (s.dmWith) { const sm = before.match(/^\/([a-zA-Z0-9_:-]*)$/); if (sm) return { kind: "/", q: sm[1], start: 0 }; }
    const m = before.match(/(^|[\s])([@>])([a-zA-Z0-9_./-]*)$/);
    return m ? { kind: m[2], q: m[3], start: c - m[3].length - 1 } : null;
  };
  const updateAc = () => {
    const t = activeToken();
    if (!t) { setAc(null); return; }
    const q = t.q.toLowerCase();
    const items = t.kind === "@"
      ? ["all", "flock", ...roster.filter(n => n !== s.me)].filter(n => n.toLowerCase().startsWith(q)).slice(0, 12)
      : t.kind === "/"
      ? SLASH.filter(c => c[0].startsWith(q)).slice(0, 12)
      : filesList.filter(f => f.toLowerCase().includes(q)).slice(0, 12);
    setAc(items.length ? { kind: t.kind, start: t.start, items, sel: 0 } : null);
  };
  const applyAc = a => {
    if (!a || !a.items.length) return;
    const pick = a.items[a.sel];
    const ins = (a.kind === "@" ? "@" + pick : a.kind === "/" ? "/" + pick[0] : pick) + " ";
    const t = ta.current;
    const nv = t.value.slice(0, a.start) + ins + t.value.slice(t.selectionStart);
    setVal(nv); setAc(null);
    requestAnimationFrame(() => { const pos = a.start + ins.length; t.setSelectionRange(pos, pos); t.focus(); });
  };
  const doSend = async () => {
    const text = val.trim(); if (!text) return;
    const re = s.replyTo?.id;
    setVal(""); setAc(null);
    if (re) { store.replyTo = null; publish(); }
    const res = await sendText(text, re);
    if (!res.ok) setVal(res.text);   // restore so the send isn't lost
  };
  const onKey = e => {
    if (ac) {
      if (e.key === "ArrowDown") { e.preventDefault(); setAc({ ...ac, sel: (ac.sel + 1) % ac.items.length }); return; }
      if (e.key === "ArrowUp") { e.preventDefault(); setAc({ ...ac, sel: (ac.sel - 1 + ac.items.length) % ac.items.length }); return; }
      if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey)) { e.preventDefault(); applyAc(ac); return; }
      if (e.key === "Escape") { e.preventDefault(); setAc(null); return; }
    }
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); doSend(); }
  };
  const atClick = () => {
    const t = ta.current, c = t.selectionStart, before = t.value.slice(0, c);
    const pre = (before && !/[\s(]$/.test(before)) ? " @" : "@";
    setVal(before + pre + t.value.slice(t.selectionEnd));
    requestAnimationFrame(() => { const pos = c + pre.length; t.setSelectionRange(pos, pos); t.focus(); updateAc(); });
  };

  return html`<div id="cwrap">
    ${ac && html`<div id="ac" class="show">
      <div class="ac-list">
        ${ac.items.map((it, i) => ac.kind === "@"
          ? html`<div key=${it} class=${"ac-item" + (i === ac.sel ? " sel" : "")} onMouseDown=${e => { e.preventDefault(); applyAc({ ...ac, sel: i }); }}>
              ${it === "all" || it === "flock"
                ? html`<span class="aav" style="background:var(--teal-soft);color:var(--teal)">@</span>`
                : html`<${Av} n=${it} cls="aav" trigger=${false}/>`}
              <span class="anm">@${it}</span>
              ${it !== "all" && it !== "flock" && html`<span class="adot" style=${{ background: liveState(it) === "working" ? "#2ea043" : liveState(it) === "dnd" ? "#d29922" : liveState(it) === "offline" ? "#4b5563" : "#3fb950" }}></span>`}
              <span class="sub">${it === "all" ? "everyone" : it === "flock" ? "gang-prompt the whole flock" : ((s.doc?.roster || []).find(m => m.name === it) || {}).adapter || ""}</span>
            </div>`
          : ac.kind === "/"
          ? html`<div key=${it[0]} class=${"ac-item" + (i === ac.sel ? " sel" : "")} onMouseDown=${e => { e.preventDefault(); applyAc({ ...ac, sel: i }); }}><span class="fico">/</span><span class="anm">/${it[0]}</span><span class="sub">${it[1]}</span></div>`
          : html`<div key=${it} class=${"ac-item" + (i === ac.sel ? " sel" : "")} onMouseDown=${e => { e.preventDefault(); applyAc({ ...ac, sel: i }); }}><span class="fico">›</span><span class="anm">${it}</span></div>`)}
      </div>
      <div class="ac-hint"><span><b>↑↓</b> navigate</span><span><b>tab</b> select</span><span><b>esc</b> dismiss</span></div>
    </div>`}
    ${s.replyTo && html`<div id="replybar">↩ replying to <b style=${{ color: nameColor(s.replyTo.who) }}>@${s.replyTo.who}</b>
      <button aria-label="cancel reply" onClick=${() => { store.replyTo = null; publish(); }}>✕</button></div>`}
    <div id="composer">
      <button id="atbtn" aria-label="mention an agent" title="mention" onClick=${atClick}>@</button>
      <button id="attbtn" aria-label="attach a file" title="attach → .stitchpad/dropbox" onClick=${() => fpick.current.click()}>
        <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M20.5 11.5 12.7 19.3a5.25 5.25 0 0 1-7.42-7.42l8.13-8.13a3.5 3.5 0 0 1 4.95 4.95l-8.13 8.13a1.75 1.75 0 0 1-2.47-2.48l7.42-7.42" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </button>
      <input type="file" ref=${fpick} multiple hidden onChange=${e => { uploadFiles([...e.target.files]); e.target.value = ""; }}/>
      <div id="edwrap">
        <div id="hl" ref=${hl} aria-hidden="true"></div>
        <textarea id="text" ref=${ta} rows="1" placeholder="Message…" value=${val}
          onInput=${e => { setVal(e.target.value); requestAnimationFrame(updateAc); }}
          onClick=${updateAc} onKeyDown=${onKey}
          onScroll=${() => hl.current && (hl.current.scrollTop = ta.current.scrollTop)}
          onBlur=${() => setTimeout(() => setAc(null), 150)}
          onFocus=${() => setTimeout(() => { if (nearBottom()) stick(); }, 350)}></textarea>
      </div>
      <button id="send" aria-label="send" disabled=${!val.trim()} onClick=${doSend}>
        <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M4.4 11.05 19.3 4.24c.9-.41 1.83.52 1.42 1.42l-6.81 14.9c-.44.96-1.85.84-2.12-.18l-1.44-5.46a1.15 1.15 0 0 0-.82-.82l-5.46-1.44c-1.02-.27-1.14-1.68-.18-2.12Z" fill="currentColor"/></svg>
      </button>
    </div>
    ${!s.dmWith && html`<div class="tags">you are @${s.me} · type @name to address agents</div>`}
  </div>`;
}

// ── the shed: shared files, derived from 📎 pad lines ────────
// `stitchpad drop` and the paperclip both post one 📎 line; this panel is
// just a collected view of those lines — the pad stays the only state.
function shedFiles(blocks) {
  const out = [];
  for (const b of blocks || []) {
    if (b.sys) continue;
    for (const line of b.body || []) {
      const m = line.match(/^📎 \*\*(.+?)\*\* · (\S+) → (\S+?)((?:\s+\[view\]\((\S+)\))?)(?:\s+—\s+(.+))?$/);
      if (m) out.push({ name: m[1], size: m[2], link: m[5] || null, note: m[6] || "", who: b.who, t: b.t });
    }
  }
  return out.reverse(); // newest first
}
function FilesPanel() {
  const s = useStore();
  const files = shedFiles(s.blocks);
  return html`<div class="sum-panel">
    <h3>🗄 The shed <span class="sub">#${s.pad} · ${files.length} file${files.length === 1 ? "" : "s"}</span><button class="x" aria-label="close" onClick=${() => { store.filesOpen = false; publish(); }}>✕</button></h3>
    <div class="body">
      ${!files.length && html`<div class="doc-empty">nothing on the shelf — agents \`stitchpad drop\` docs here; the 📎 button attaches from the phone</div>`}
      ${files.map(f => html`<div class="shed-row" key=${f.name + f.t}>
        ${f.link ? html`<a class="shed-name" href=${f.link} target="_blank" rel="noopener">${f.name}</a>` : html`<span class="shed-name">${f.name}</span>`}
        <span class="shed-meta">${f.size} · @${f.who} · ${f.t}</span>
        ${f.note && html`<span class="shed-note">${f.note}</span>`}
      </div>`)}
    </div>
  </div>`;
}

// ── doctor: the pad's vitals, straight from the bridge ───────
const fmtAge = s => s < 0 ? "none" : s < 90 ? s + "s" : s < 5400 ? Math.round(s / 60) + "m" : Math.round(s / 3600) + "h";
function DoctorPanel() {
  const s = useStore();
  const d = s.doctor;
  const stale = d ? Math.round((Date.now() - d.at) / 1000) : -1;
  return html`<div class="sum-panel doc-panel">
    <h3>♥ Pad vitals <span class="sub">#${s.pad}</span><button class="x" aria-label="close" onClick=${() => { store.doctorOpen = false; publish(); }}>✕</button></h3>
    <div class="body">
      ${!d && html`<div class="doc-empty">no snapshot yet — the bridge reports every 30s</div>`}
      ${d && d.agents.map(a => {
        const hbBad = a.hb_age < 0 || a.hb_age > 120;
        const lockBad = a.lock && a.lock !== "ok" && a.lock !== "stale" && a.lock !== "unclaimed";
        return html`<div key=${a.name} class="doc-row">
          <${Av} n=${a.name} trigger=${false}/>
          <div class="doc-main">
            <div class="doc-name"><b style=${{ color: nameColor(a.name) }}>@${a.name}</b><span class="doc-sub">${a.adapter} · ${a.wake}</span></div>
            <div class="doc-chips">
              <span class=${"chip " + (hbBad ? "bad" : "ok")}>♥ ${fmtAge(a.hb_age)}</span>
              <span class=${"chip " + (a.gate === "owes a reply" ? "warn" : "")}>${a.gate}</span>
              ${a.lock && html`<span class=${"chip " + (lockBad ? "bad" : "")}>${a.lock === "ok" ? "lock ✓" : a.lock}</span>`}
              ${a.last_wake && html`<span class=${"chip " + (a.last_wake.ok ? "" : "bad")}>wake ${a.last_wake.ok ? "✓ " + a.last_wake.at.slice(11, 16) : "✗ " + (a.last_wake.why || "")}</span>`}
              ${a.last_dm && html`<span class=${"chip " + (a.last_dm.status === "delivered" ? "" : "bad")}>dm ${a.last_dm.status === "delivered" ? "✓✓" : "✗"} ${fmtAge(a.last_dm.ago)} ago</span>`}
            </div>
          </div>
        </div>`;
      })}
      ${d && html`<div class=${"doc-foot" + (stale > 90 ? " bad" : "")}>bridge report ${fmtAge(stale)} ago${stale > 90 ? " — bridge may be down" : ""}</div>`}
    </div>
  </div>`;
}

function App() {
  const s = useStore();
  const [drawer, setDrawer] = useState(false);
  useEffect(() => { document.body.classList.toggle("drawer", drawer); }, [drawer]);
  useEffect(() => { const f = () => setDrawer(false); window.addEventListener("sp:closedrawer", f); return () => window.removeEventListener("sp:closedrawer", f); }, []);
  if (!s.authed) return html`<${Login}/>`;
  const members = (s.doc?.roster || []).length;
  return html`<div id="app">
    <div id="side"><div class="ws"><${LOGO}/></div></div>
    <${Sidebar} drawer=${drawer} setDrawer=${setDrawer}/>
    <div id="main">
      <div id="top">
        <button id="hamb" aria-label="channels" onClick=${() => setDrawer(!drawer)}>☰</button>
        <span class="name">${s.dmWith ? "@" + s.dmWith : "# " + (s.pad || "…")}</span>
        ${!s.dmWith && html`<span class="meta">${s.doc ? members + " members" : ""}</span>`}
        ${!s.dmWith && html`<button id="taskbtn" title="kanban board — tasks parsed live from the pad" onClick=${() => { store.boardOpen = true; publish(); }}><${Icon} n="tasks"/><span class="lbl">tasks</span></button>`}
        ${!s.dmWith && html`<button id="filebtn" title="the shed — shared files dropped by agents + phone" onClick=${() => { store.filesOpen = !store.filesOpen; publish(); }}>🗄<span class="lbl">files</span></button>`}
        ${!s.dmWith && html`<button id="docbtn" title="pad vitals — heartbeats, wakes, locks, deliveries" onClick=${openDoctor}>♥<span class="lbl">vitals</span></button>`}
        ${!s.dmWith && html`<button id="sumbtn" title="summarize this thread" disabled=${s.summarizing} onClick=${requestSummary}>${s.summarizing ? "…" : html`<${Icon} n="summarize"/>`}<span class="lbl">${s.summarizing ? "summarizing" : "summarize"}</span></button>`}
      </div>
      <${StatusBar}/>
      <${ClaimBar}/>
      <${Log}/>
      <${Composer}/>
      ${s.doctorOpen && html`<${DoctorPanel}/>`}
      ${s.filesOpen && html`<${FilesPanel}/>`}
      ${s.boardOpen && html`<${BoardPanel}/>`}
      ${s.summaryOpen && s.summary && html`<div class="sum-panel">
        <h3><${Icon} n="summarize"/> Thread summary <span class="sub">#${s.pad}</span><button class="x" aria-label="close" onClick=${() => { store.summaryOpen = false; publish(); }}>✕</button></h3>
        ${s.summary.error
          ? html`<div class="body">⚠ ${s.summary.error}</div>`
          : html`<div class="body md" dangerouslySetInnerHTML=${{ __html: fmtMd(s.summary.text) }}></div>`}
      </div>`}
    </div>
  </div>`;
}

// ── boot ─────────────────────────────────────────────────────
render(html`<${App}/>`, document.getElementById("root"));
document.getElementById("scrim").addEventListener("click", () => window.dispatchEvent(new Event("sp:closedrawer")));

const INVITE = new URLSearchParams(location.search).get("invite");
if (INVITE) redeemInvite(INVITE); else if (store.token) startApp();
if ("serviceWorker" in navigator) navigator.serviceWorker.getRegistrations().then(rs => rs.forEach(r => r.unregister()));

// KEYBOARD-AWARE VIEWPORT (iOS): size the shell to the real visible height,
// compensate the standalone-mode layout shove, keep the log glued to bottom.
if (window.visualViewport) {
  const vv = window.visualViewport; let vvT = null;
  const applyVV = () => {
    const was = nearBottom();
    document.documentElement.style.setProperty("--vvh", Math.round(vv.height) + "px");
    const app = document.getElementById("app");
    if (app) app.style.transform = vv.offsetTop > 1 ? `translateY(${Math.round(vv.offsetTop)}px)` : "";
    window.scrollTo(0, 0);
    if (was) requestAnimationFrame(() => stick());
  };
  vv.addEventListener("resize", () => { clearTimeout(vvT); vvT = setTimeout(applyVV, 16); });
  vv.addEventListener("scroll", () => { clearTimeout(vvT); vvT = setTimeout(applyVV, 16); });
}

// ── ui component actions: vote / verdict / form submit ───────
// A component interaction is just a STRUCTURED THREADED REPLY — composed
// client-side with the same schemas the MCP validates, sent down the normal
// /say path with re:<origin>. Zero new server state.
async function postUiReply(type, payload, alt, re) {
  const problems = validateUi(type, payload);
  if (problems.length) { notice("⚠ " + problems[0], true); return; }
  await sendText(composeFence(type, payload, alt), re);
}
function handleUiAct(el) {
  const act = el.dataset.uiAct, id = el.dataset.uiId;
  if (!id) return;
  if (act === "vote") {
    const opt = el.dataset.uiOpt;
    postUiReply("poll.vote", { choice: [opt] }, "voted: " + opt, id);
  } else if (act === "verdict") {
    const v = el.dataset.uiV;
    postUiReply("approve.verdict", { verdict: v }, v === "approve" ? "✓ approved" : "✕ rejected", id);
  } else if (act === "form-submit") {
    const box = el.closest("[data-ui-form]");
    if (!box) return;
    const values = {};
    for (const f of box.querySelectorAll("[data-ui-key]")) {
      const k = f.dataset.uiKey;
      values[k] = f.type === "checkbox" ? f.checked : f.value;
    }
    postUiReply("form.response", { values }, "submitted form", id);
  }
}

// delegated: copy buttons (rows + code blocks) — operate on rendered DOM
document.addEventListener("click", e => {
  const ub = e.target.closest("[data-ui-act]");
  if (ub) { handleUiAct(ub); return; }
  const rb = e.target.closest(".row-cpy");
  if (rb) {
    const text = decodeURIComponent(escape(atob(rb.dataset.copy || "")));
    navigator.clipboard.writeText(text).then(() => { rb.textContent = "copied"; rb.classList.add("done"); setTimeout(() => { rb.textContent = "copy"; rb.classList.remove("done"); }, 1400); });
    return;
  }
  const b = e.target.closest(".cpy");
  if (b && b.parentElement.querySelector("pre")) {
    const code = b.parentElement.querySelector("pre").innerText;
    navigator.clipboard.writeText(code).then(() => { b.textContent = "copied"; b.classList.add("done"); setTimeout(() => { b.textContent = "copy"; b.classList.remove("done"); }, 1400); });
    return;
  }
  // wall-of-text clamp toggle
  const mo = e.target.closest(".bd-more");
  if (mo) {
    const w = mo.closest(".bdwrap"); if (!w) return;
    const open = !w.classList.toggle("clamped");
    mo.textContent = open ? "show less ▴" : "show more ▾";
  }
});
// images loading in can grow the log after we stuck to bottom — re-stick
document.addEventListener("load", e => { if (e.target.tagName === "IMG" && e.target.closest("#log") && nearBottom()) stick(); }, true);

// ── kanban board: tasks parsed straight from the pad markdown ─
const TASK_STATUSES = ["backlog", "todo", "in_progress", "in_review", "done", "canceled"];
const TASK_PRIOS = ["none", "low", "medium", "high", "urgent"];
function parseTasks(md) {
  const out = []; const re = /```task (\S+)\n([\s\S]*?)```/g; let m;
  while ((m = re.exec(md || ""))) {
    const t = { id: m[1], title: "", status: "todo", priority: "none", assignee: "", labels: "", created: "", desc: [] };
    let inDesc = false;
    for (const ln of m[2].split("\n")) {
      if (!inDesc && /^---/.test(ln)) { inDesc = true; continue; }
      const kv = !inDesc && ln.match(/^(\w+):\s*(.*)$/);
      if (kv && kv[1] in t && kv[1] !== "desc") t[kv[1]] = kv[2].trim();
      else if (inDesc && ln.trim()) t.desc.push(ln.trim());
    }
    t.desc = t.desc.join("\n");
    const i = out.findIndex(x => x.id === t.id); if (i >= 0) out.splice(i, 1); // dup blocks: last wins
    if (t.title !== "example task") out.push(t);
  }
  return out;
}
async function taskOp(body) {
  try {
    const r = await api("/task?pad=" + encodeURIComponent(store.pad), { method: "POST", body: JSON.stringify({ ...body, by: store.me }) });
    const j = await r.json();
    if (!j.ok) notice("⚠ board: " + (j.error || "failed"), true);
  } catch (e) { notice("⚠ board: " + e.message, true); }
}
function BoardPanel() {
  const s = useStore();
  const [sel, setSel] = useState(null);
  const [showNew, setShowNew] = useState(false);
  const tasks = parseTasks(s.doc?.pad);
  const roster = (s.doc?.roster || []).map(r => r.name);
  // agents invent statuses ("queued") — a task must NEVER fall off the board
  // because its column wasn't in the standard list. Unknowns get real columns.
  const extra = [...new Set(tasks.map(t => t.status))].filter(x => !TASK_STATUSES.includes(x));
  const cols = [...TASK_STATUSES.slice(0, 2), ...extra, ...TASK_STATUSES.slice(2)];
  const col = st => tasks.filter(t => t.status === st);
  const close = () => { store.boardOpen = false; publish(); };
  const move = (id, st) => { taskOp({ op: "move", id, status: st }); setSel(null); notice(`${id} → ${st.replace(/_/g, " ")}`); };
  const submitNew = e => {
    e.preventDefault(); const f = e.target;
    if (!f.title.value.trim()) return;
    taskOp({ op: "new", title: f.title.value.trim(), priority: f.priority.value, assignee: f.assignee.value, labels: f.labels.value.trim(), desc: f.desc.value.trim() });
    setShowNew(false); notice("creating task…");
  };
  return html`<div class="board-back" onClick=${close}></div>
  <div class="board">
    <div class="b-hd"><h3><${Icon} n="tasks"/> Tasks <span class="sub">#${s.pad} · ${tasks.length}</span></h3>
      <button class="b-new" onClick=${() => setShowNew(!showNew)}>＋ task</button>
      <button class="x" aria-label="close" onClick=${close}>✕</button></div>
    ${showNew && html`<form class="b-form" onSubmit=${submitNew}>
      <input name="title" placeholder="title" required maxlength="180"/>
      <textarea name="desc" placeholder="description — scope / acceptance" rows="3"></textarea>
      <div class="b-form-row">
        <select name="assignee"><option value="">unassigned</option>${roster.map(n => html`<option key=${n} value=${n}>@${n}</option>`)}</select>
        <select name="priority">${TASK_PRIOS.map(pr => html`<option key=${pr} value=${pr}>${pr}</option>`)}</select>
        <input name="labels" placeholder="labels,comma"/>
        <button type="submit">create</button>
      </div>
    </form>`}
    <div class="b-cols">
      ${cols.map(st => html`<div class="b-col" key=${st}>
        <div class="b-col-hd">${st.replace(/_/g, " ")} <span class="cnt">${col(st).length}</span></div>
        ${col(st).map(t => html`<div class=${"b-card" + (sel === t.id ? " sel" : "")} key=${t.id} onClick=${() => setSel(sel === t.id ? null : t.id)}>
          <div class="b-card-top"><b>${t.id}</b>${t.priority !== "none" ? html`<span class=${"b-pri p-" + t.priority}>${t.priority}</span>` : null}${t.assignee ? html`<span class="b-as" style=${{ color: colorFor(t.assignee) }}>@${t.assignee}</span>` : null}</div>
          <div class="b-title">${t.title}</div>
          ${t.desc && html`<div class="b-desc">${t.desc}</div>`}
          ${t.labels && html`<div class="b-labels">${t.labels}</div>`}
          ${sel === t.id && html`<div class="b-acts" onClick=${e => e.stopPropagation()}>
            <div class="b-act-row"><span class="lb">→</span>${TASK_STATUSES.filter(x => x !== t.status).map(x => html`<button key=${x} onClick=${() => move(t.id, x)}>${x.replace(/_/g, " ")}</button>`)}</div>
            <div class="b-act-row"><span class="lb">pri</span>${TASK_PRIOS.map(x => html`<button key=${x} class=${x === t.priority ? "on" : ""} onClick=${() => { taskOp({ op: "edit", id: t.id, priority: x }); setSel(null); }}>${x}</button>`)}</div>
            <div class="b-act-row"><span class="lb">to</span>${roster.map(n => html`<button key=${n} class=${n === t.assignee ? "on" : ""} onClick=${() => { taskOp({ op: "edit", id: t.id, assignee: n }); setSel(null); }}>@${n}</button>`)}</div>
          </div>`}
        </div>`)}
      </div>`)}
    </div>
  </div>`;
}

// ── agent cards (imperative popover, same as before) ─────────
const cardEl = document.getElementById("card"), cardBack = document.getElementById("cardback");
function agentCard(name) {
  const info = ((store.doc?.roster) || []).find(m => m.name === name) || {};
  const prof = profiles()[name] || {};
  const col = colorFor(name), ink = initInk(name);
  const harness = prof.harness || info.adapter || "—";
  const model = prof.model || "—";
  const role = prof.role || "";
  const level = prof.level || "";
  const skills = Array.isArray(prof.skills) ? prof.skills : [];
  const ctx = prof.context || "";
  const pfp = `<div class="pfp" style="background:${col};color:${ink}"><img src="avatars/${encodeURIComponent(name)}.png" alt="" onerror="this.remove()">${initials(name)}</div>`;
  // the model chip is the session DEFAULT; clients (TUI/GUI) can pass an
  // explicit per-turn model that outranks it — surface the divergence
  // the ACTUAL model (what the last turn really ran) is the headline; the
  // session/global default only appears, demoted, when they diverge
  const lastM = prof.last_model && prof.last_model !== model ? prof.last_model : "";
  const shownModel = lastM || (model !== "—" ? model : "");
  const chips = [level ? `<span class="chip">${esc(level)}</span>` : "", harness !== "—" ? `<span class="chip">${esc(harness)}</span>` : "", shownModel ? `<span class="chip">${esc(shownModel)}</span>` : "", lastM && model !== "—" ? `<span class="chip">default: ${esc(model)}</span>` : "", ctx ? `<span class="chip">${esc(ctx)}</span>` : ""].join("");
  const full = `<div class="full">` +
    (role ? `<div class="sec"><h4>Role</h4>${esc(role)}</div>` : "") +
    (prof.persona ? `<div class="sec"><h4>Persona</h4><div class="persona">${esc(prof.persona)}</div></div>` : "") +
    (skills.length ? `<div class="sec"><h4>Skills</h4>${skills.map(sk => `<div class="skill"><b>${esc(sk.name || sk)}</b>${sk.desc ? " — " + esc(sk.desc) : ""}</div>`).join("")}</div>` : "") +
    (!role && !prof.persona && !skills.length ? `<div class="sec" style="color:var(--dim)">Full profile not pushed yet (bridge \`profiles\` blob pending).</div>` : "") +
    `</div>`;
  // LIVE VITALS: the doctor snapshot already knows this agent's real state —
  // surface it right on the card instead of making him open the panel.
  const dv = (store.doctor?.agents || []).find(a => a.name === name);
  const vit = dv ? `<div class="cvitals">` +
    `<span class="chip ${dv.hb_age < 0 || dv.hb_age > 120 ? "bad" : "ok"}">♥ ${fmtAge(dv.hb_age)}</span>` +
    `<span class="chip ${dv.gate === "owes a reply" ? "warn" : ""}">${esc(dv.gate || "")}</span>` +
    (dv.lock && dv.lock !== "ok" ? `<span class="chip bad">${esc(dv.lock)}</span>` : "") +
    (dv.last_dm ? `<span class="chip ${dv.last_dm.status === "delivered" ? "" : "bad"}">dm ${dv.last_dm.status === "delivered" ? "✓✓" : "✗"} ${fmtAge(dv.last_dm.ago)} ago</span>` : "") +
    `</div>` : "";
  // ACTIONS: message → the DM pane; mention → drops @name in the composer;
  // compact → the real /compact through the DM slash pipe (claude only).
  // /compact is a HARNESS feature: Claude Code and Codex CLI both understand it
  // as a terminal slash command; pi bounces slashes (chat text) and ocean seats
  // have no terminal. Button appears only where the keystroke actually works.
  const isClaude = ["claude", "codex"].includes(harnessOf(name));
  const acts = `<div class="cacts">` +
    `<button class="cact" data-act="dm" data-n="${esc(name)}"><span class="ico">${ICONS.mail}</span> message</button>` +
    `<button class="cact" data-act="mention" data-n="${esc(name)}"><span class="ico">${ICONS.at}</span> mention</button>` +
    (isClaude ? `<button class="cact" data-act="compact" data-n="${esc(name)}"><span class="ico">${ICONS.bolt}</span> compact</button>` : "") +
    `</div>`;
  return `<div class="top" style="background:${col}"></div><div class="body">` + pfp +
    `<div class="nm" style="color:${nameColor(name)}">@${esc(name)}</div>` +
    (role ? `<div class="role">${esc(role)}</div>` : "") +
    (chips ? `<div class="meta">${chips}</div>` : "") + vit + acts + full +
    `<button class="exp">View full profile ▾</button></div>`;
}
function openCard(name, x, y) {
  cardEl.innerHTML = agentCard(name);
  cardEl.classList.remove("expanded");
  cardEl.classList.add("show"); cardBack.classList.add("show");
  const r = cardEl.getBoundingClientRect();
  cardEl.style.left = Math.max(12, Math.min(x, window.innerWidth - r.width - 12)) + "px";
  cardEl.style.top = Math.max(12, Math.min(y, window.innerHeight - r.height - 12)) + "px";
}
function closeCard() { cardEl.classList.remove("show", "expanded"); cardBack.classList.remove("show"); }
cardBack.onclick = closeCard;
cardEl.addEventListener("click", e => {
  if (e.target.closest(".exp")) cardEl.classList.add("expanded");
  const b = e.target.closest(".cact"); if (!b) return;
  const n = b.dataset.n, act = b.dataset.act;
  closeCard();
  if (act === "dm") openDM(n);
  else if (act === "mention") {
    const t = document.getElementById("text");
    if (t) { const pre = t.value && !/[\s(]$/.test(t.value) ? " @" : "@"; t.value += pre + n + " "; t.focus(); t.dispatchEvent(new Event("input", { bubbles: true })); }
  } else if (act === "compact") {
    api("/dm?pad=" + encodeURIComponent(store.pad), { method: "POST", body: JSON.stringify({ from: store.me, to: n, text: "/compact" }) })
      .then(r => r.json()).then(j => { pushDm({ from: store.me, to: n, text: "/compact", at: Date.now(), id: j.id, status: "sent" }); })
      .catch(() => notice("⚠ compact send failed", true));
    notice("⚡ compacting @" + n + "'s context — receipt lands in their DM");
  }
});
document.addEventListener("click", e => {
  const t = e.target.closest(".card-trigger"); if (!t || !t.dataset.agent) return;
  e.stopPropagation();
  openCard(t.dataset.agent, e.clientX + 8, e.clientY + 8);
});
