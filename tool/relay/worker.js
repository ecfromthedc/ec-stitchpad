// stitchpad relay — a thin remote face on the TUI/pad backend. MULTI-PAD:
// many stitchpads, each keyed by NAME (= its directory basename). The PWA lists
// pads and picks one. The bash CLI stays the source of truth; this just mirrors.
//
//   GET  /pads               → [{name, at}]  list of known stitchpads
//   POST /push?pad=NAME      (Mac bridge)  body {pad, roster, files, colors} → store under NAME
//   GET  /pad?pad=NAME       (PWA)         → that pad's markdown + roster + files + colors
//   GET  /pad.colors?pad=NAME (PWA)        → [{name, color}, ...] single-source colors
//   POST /say?pad=NAME       (PWA)         body {from,text} → queued for NAME
//   GET  /outbox?pad=NAME    (Mac/tunnel)  → drain NAME's queued phone messages
//   GET  /ws?pad=NAME&token= (PWA/bridge)  → websocket into that pad's PadHub DO
//
// REALTIME (PadHub Durable Object, one per pad): the hot pad document lives in
// DO storage; /push and /pad route through the DO. Every push that actually
// CHANGES the pad fans out {type:"pad", data} to all connected PWA sockets —
// no more 3s poll lurch. If a bridge socket is connected, /say and /dm are
// delivered to it instantly; otherwise they fall back to the KV queues the
// bridge already drains over HTTP. KV keeps: pads index, invites, queues.
//
// Auth: bearer token on every request (WS: ?token=). STITCHPAD_TOKEN is the
// owner/legacy token; STITCHPAD_TOKENS (JSON: {"handle":"token"}) adds per-person
// tokens so one person's rotation can't lock everyone else out. /login and
// /join-request hand back the caller's own token when their handle has one.
const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });
const cors = { "access-control-allow-origin": "*", "access-control-allow-methods": "GET,POST,OPTIONS", "access-control-allow-headers": "authorization,content-type" };

// One DO instance per pad (idFromName(pad)). Pure hot path: pad doc + sockets.
export class PadHub {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; }

  async loadDoc(pad) {
    let doc = await this.ctx.storage.get("doc");
    if (!doc) {
      // lazy-migrate: seed from the legacy KV copy so /pad never goes blank
      const v = await this.env.STITCHPAD.get(`pad:${pad}`);
      if (v) { doc = JSON.parse(v); await this.ctx.storage.put("doc", doc); }
    }
    return doc || null;
  }

  async fetch(req) {
    const url = new URL(req.url);
    const pad = url.searchParams.get("pad") || "";

    // websocket attach (worker already authed the token)
    if (url.pathname === "/ws") {
      const role = url.searchParams.get("role") === "bridge" ? "bridge" : "client";
      const pair = new WebSocketPair();
      const [clientEnd, server] = Object.values(pair);
      this.ctx.acceptWebSocket(server, [role]);
      return new Response(null, { status: 101, webSocket: clientEnd });
    }

    // bridge push → store; broadcast ONLY when content actually changed
    // (the bridge pushes every ~3s; identical snapshots must not repaint phones)
    if (url.pathname === "/push" && req.method === "POST") {
      let body; try { body = await req.json(); } catch { return json({ error: "bad push body" }, 400); }
      const at = Date.now();
      const doc = { ...body, name: pad, at };
      const sig = JSON.stringify([body.pad, body.roster, body.colors, body.profiles, body.claims, body.files]);
      const prevSig = await this.ctx.storage.get("sig");
      await this.ctx.storage.put("doc", doc);
      if (sig !== prevSig) {
        await this.ctx.storage.put("sig", sig);
        // per-pad KV key — the old shared "index" key was a read-modify-write
        // that concurrent pushes from different pads' DOs clobbered (pads
        // vanished from the sidebar forever). One key per pad cannot race.
        await this.env.STITCHPAD.put("pad:" + pad, "1", { metadata: { at } });
        await this.ctx.storage.put("indexed2", true);
        this.broadcast("client", JSON.stringify({ type: "pad", data: doc }));
      } else if (!(await this.ctx.storage.get("indexed2"))) {
        // dormant pad whose content predates the per-pad index: an unchanged
        // push must still register it once, or it can never appear
        await this.env.STITCHPAD.put("pad:" + pad, "1", { metadata: { at } });
        await this.ctx.storage.put("indexed2", true);
      }
      return json({ ok: true, changed: sig !== prevSig });
    }

    if (url.pathname === "/pad" && req.method === "GET") {
      const doc = await this.loadDoc(pad);
      if (!doc) return json({ pad: "", roster: [], name: pad, at: 0 });
      const etag = `"${doc.at || 0}"`;
      if ((req.headers.get("if-none-match") || "") === etag) {
        return new Response(null, { status: 304, headers: { ...cors, etag } });
      }
      const tail = parseInt(url.searchParams.get("tail") || "0", 10);
      let out = doc;
      if (tail > 0 && typeof doc.pad === "string") {
        out = { ...doc, pad: doc.pad.split("\n").slice(-tail).join("\n") };
      }
      return new Response(JSON.stringify(out), { status: 200, headers: { "content-type": "application/json", ...cors, etag } });
    }

    if (url.pathname === "/pad.colors" && req.method === "GET") {
      const doc = await this.loadDoc(pad);
      return json(doc?.colors || {});
    }

    // instant delivery attempt: say/dm/file → a connected bridge socket.
    // {delivered:false} tells the worker to fall back to the KV queue.
    // DMs additionally persist to the per-pair DM log (the "terminal log" the
    // PWA DM pane renders) and broadcast {type:"dm"} to client sockets live.
    if (url.pathname === "/deliver" && req.method === "POST") {
      const { kind, msg } = await req.json();
      if (kind === "dm" || kind === "dm-in") {
        const pair = [msg.from, msg.to].sort().join("~");
        const log = (await this.ctx.storage.get("dm:" + pair)) || [];
        log.push(msg);
        await this.ctx.storage.put("dm:" + pair, log.slice(-200));
        this.broadcast("client", JSON.stringify({ type: "dm", pad, msg }));
        if (kind === "dm-in") return json({ delivered: true });   // inbound: no bridge hop
      }
      // delivery receipt: stamp the pair-log entry by id + fan out live
      if (kind === "dm-status") {
        const pair = [msg.from, msg.to].sort().join("~");
        const log = (await this.ctx.storage.get("dm:" + pair)) || [];
        const e = log.find(x => x.id === msg.id);
        if (e) { e.status = msg.status; e.detail = msg.detail || ""; await this.ctx.storage.put("dm:" + pair, log); }
        this.broadcast("client", JSON.stringify({ type: "dmstatus", pad, id: msg.id, status: msg.status, detail: msg.detail || "", from: msg.from, to: msg.to }));
        return json({ delivered: true });
      }
      // pad health snapshot from the bridge → store + fan out
      if (kind === "doctor-in") {
        await this.ctx.storage.put("doctor", msg);
        this.broadcast("client", JSON.stringify({ type: "doctor", pad, data: msg }));
        return json({ delivered: true });
      }
      // bridge posting back a finished thread summary → store + fan out
      if (kind === "summary-in") {
        await this.ctx.storage.put("summary", msg);
        this.broadcast("client", JSON.stringify({ type: "summary", pad, data: msg }));
        return json({ delivered: true });
      }
      // bridge posting back a terminal capture → store + fan out
      if (kind === "term-in") {
        await this.ctx.storage.put("term:" + msg.agent, msg);
        this.broadcast("client", JSON.stringify({ type: "term", pad, data: msg }));
        return json({ delivered: true });
      }
      const bridges = this.ctx.getWebSockets("bridge");
      if (!bridges.length) return json({ delivered: false });
      const s = JSON.stringify({ type: kind, pad, msg });
      let sent = 0;
      bridges.forEach(w => { try { w.send(s); sent++; } catch {} });
      return json({ delivered: sent > 0 });
    }
    // per-pair DM history (?a=&b=)
    if (url.pathname === "/dmlog" && req.method === "GET") {
      const pair = [url.searchParams.get("a") || "", url.searchParams.get("b") || ""].sort().join("~");
      return json((await this.ctx.storage.get("dm:" + pair)) || []);
    }
    // last stored thread summary
    if (url.pathname === "/summary" && req.method === "GET") {
      return json((await this.ctx.storage.get("summary")) || null);
    }
    // last stored terminal capture for ?agent=
    if (url.pathname === "/term" && req.method === "GET") {
      return json((await this.ctx.storage.get("term:" + (url.searchParams.get("agent") || ""))) || null);
    }
    // last stored health snapshot
    if (url.pathname === "/doctor" && req.method === "GET") {
      return json((await this.ctx.storage.get("doctor")) || null);
    }

    return json({ error: "not found" }, 404);
  }

  broadcast(tag, s) { this.ctx.getWebSockets(tag).forEach(w => { try { w.send(s); } catch {} }); }

  async webSocketMessage(ws, raw) {
    let m; try { m = JSON.parse(raw); } catch { return; }
    if (m.type === "ping") { try { ws.send('{"type":"pong"}'); } catch {} }
  }
  webSocketClose() {}
  webSocketError() {}
}

const hub = (env, pad) => env.PADHUB.get(env.PADHUB.idFromName(pad));
// try instant websocket delivery to the pad's bridge; false → caller queues in KV
async function tryDeliver(env, pad, kind, msg) {
  try {
    const r = await hub(env, pad).fetch(`https://hub/deliver?pad=${encodeURIComponent(pad)}`, { method: "POST", body: JSON.stringify({ kind, msg }) });
    if (!r.ok) return false;
    return (await r.json()).delivered === true;
  } catch { return false; }
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });

    // Keep legacy API/WebSocket clients working on the old domains, but send
    // browser visits to the Pasture-branded URL. A 308 preserves the path and
    // query string without turning old POST endpoints into redirects.
    const pastureHost = {
      "stitchpad.agentsworld.org": "pasture.agentsworld.org",
      "ec-stitchpad.agentsworld.org": "ec-pasture.agentsworld.org",
    }[url.hostname];
    const wantsHtml = (req.headers.get("accept") || "").includes("text/html");
    if (pastureHost && (req.method === "GET" || req.method === "HEAD") && (url.pathname === "/" || wantsHtml)) {
      url.hostname = pastureHost;
      return Response.redirect(url.toString(), 308);
    }

    // handle → personal token map; legacy shared token stays valid alongside it
    let TOKENS = {};
    try { TOKENS = JSON.parse((env.PASTURE_TOKENS || env.STITCHPAD_TOKENS) || "{}"); } catch {}
    const legacyToken = env.PASTURE_TOKEN || env.STITCHPAD_TOKEN;
    const tokenFor = (handle) => TOKENS[handle] || legacyToken;

    // Login: username+password → {token, handle}. Multi-user so coworkers each get
    // their OWN identity (posts show as them, not @smaths). Users come from the
    // STITCHPAD_USERS secret (JSON: {"user":{"pass":"...","handle":"..."}}) with the
    // original single STITCHPAD_USER/PASS kept as a fallback (handle @smaths).
    if (url.pathname === "/login" && req.method === "POST") {
      const { user, pass } = await req.json().catch(() => ({}));
      let users = {};
      try { users = JSON.parse((env.PASTURE_USERS || env.STITCHPAD_USERS) || "{}"); } catch {}
      const u = users[user];
      if (u && u.pass === pass) return json({ token: tokenFor(u.handle || user), handle: u.handle || user });
      // fallback: the original single operator login
      if (user === (env.PASTURE_USER || env.STITCHPAD_USER) && pass === (env.PASTURE_PASS || env.STITCHPAD_PASS)) return json({ token: tokenFor("smaths"), handle: "smaths" });
      return json({ error: "bad credentials" }, 401);
    }

    // Redeem an invite token (PUBLIC — the remote agent doesn't have the bearer yet).
    // Owner generates a token with /invite; the remote agent trades it here for a
    // pad-scoped session token + its handle. This is how an agent on ANOTHER network
    // joins a stitchpad: no shared password, owner-gated by token issuance.
    if (url.pathname === "/join-request" && req.method === "POST") {
      const { token } = await req.json().catch(() => ({}));
      if (!token) return json({ error: "missing invite token" }, 400);
      const raw = await env.STITCHPAD.get(`invite:${token}`);
      if (!raw) return json({ error: "invalid or revoked invite" }, 403);
      const inv = JSON.parse(raw);
      if (inv.expires && Date.now() > inv.expires) {
        await env.STITCHPAD.delete(`invite:${token}`);
        return json({ error: "invite expired" }, 403);
      }
      // Valid → hand back the relay token scoped to this pad + the invited handle.
      return json({ token: tokenFor(inv.handle), pad: inv.pad, handle: inv.handle });
    }

    // Non-API paths → serve the PWA static assets (index.html, manifest).
    const API = ["/login", "/join-request", "/invite", "/pads", "/pad", "/pad.colors", "/push", "/say", "/outbox", "/dm", "/dmbox", "/dm-in", "/dm-status", "/dmlog", "/summarize", "/summary-in", "/summary", "/task", "/term", "/term-in", "/doctor", "/doctor-in", "/upload-image", "/upload-file", "/filebox", "/ws"];
    if (!API.includes(url.pathname) && !url.pathname.startsWith("/img/") && !url.pathname.startsWith("/f/")) {
      return env.ASSETS ? env.ASSETS.fetch(req) : json({ error: "no assets" }, 404);
    }
    // WS can't set headers from the browser — accept the bearer as ?token= there.
    const tok = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || (url.searchParams.get("token") || "");
    if (!tok || !(tok === legacyToken || Object.values(TOKENS).includes(tok))) return json({ error: "unauthorized" }, 401);

    const pad = (url.searchParams.get("pad") || "").trim();

    // Create an invite token (OWNER-authed — passed the bearer gate above). Stores
    // invite:<token> → {pad, handle, expires}. Owner shares the token; remote agent
    // redeems via /join-request. ttlSec=0 → permanent. This is the room owner's gate:
    // generate to grant, /invite?revoke=<token> to kill access.
    if (url.pathname === "/invite" && req.method === "POST") {
      if (!pad) return json({ error: "missing ?pad=NAME" }, 400);
      const body = await req.json().catch(() => ({}));
      const handle = (body.handle || "guest").trim();
      const ttlSec = Number(body.ttlSec || 0);
      // token derived from random bytes (crypto), short + url-safe
      const bytes = crypto.getRandomValues(new Uint8Array(12));
      const token = "inv_" + Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
      const expires = ttlSec > 0 ? Date.now() + ttlSec * 1000 : 0;
      await env.STITCHPAD.put(`invite:${token}`, JSON.stringify({ pad, handle, expires }), ttlSec > 0 ? { expirationTtl: Math.max(60, ttlSec) } : {});
      return json({ token, pad, handle, expires });
    }
    if (url.pathname === "/invite" && req.method === "DELETE") {
      const rev = (url.searchParams.get("revoke") || "").trim();
      if (!rev) return json({ error: "missing ?revoke=TOKEN" }, 400);
      await env.STITCHPAD.delete(`invite:${rev}`);
      return json({ ok: true, revoked: rev });
    }

    // list all pads: per-pad KV keys (race-free), merged with the legacy
    // shared "index" key for recency continuity
    if (url.pathname === "/pads" && req.method === "GET") {
      const idx = JSON.parse((await env.STITCHPAD.get("index")) || "{}");
      const l = await env.STITCHPAD.list({ prefix: "pad:" });
      for (const k of l.keys) {
        const n = k.name.slice(4), at = (k.metadata && k.metadata.at) || 0;
        if (!idx[n] || at > idx[n]) idx[n] = at;
      }
      return json(Object.entries(idx).map(([name, at]) => ({ name, at })).sort((a, b) => b.at - a.at));
    }
    // Serve attached files from R2 (token-gated; no ?pad needed — key is global)
    if (url.pathname.startsWith("/f/") && req.method === "GET") {
      const obj = await env.IMAGES.get("files/" + url.pathname.slice(3));
      if (!obj) return json({ error: "not found" }, 404);
      const headers = new Headers(cors);
      headers.set("content-type", obj.httpMetadata?.contentType || "application/octet-stream");
      return new Response(obj.body, { headers });
    }
    if (!pad) return json({ error: "missing ?pad=NAME" }, 400);

    // realtime hot path → the pad's Durable Object
    if (url.pathname === "/ws" || url.pathname === "/push" || url.pathname === "/pad" || url.pathname === "/pad.colors" || url.pathname === "/dmlog" || url.pathname === "/summary" || (url.pathname === "/doctor" && req.method === "GET") || (url.pathname === "/term" && req.method === "GET")) {
      return hub(env, pad).fetch(req);
    }
    // bridge reporting a DM's delivery outcome → pair-log update + live receipt
    if (url.pathname === "/dm-status" && req.method === "POST") {
      const body = await req.json();
      if (!body.id) return json({ error: "need id" }, 400);
      await hub(env, pad).fetch(`https://hub/deliver?pad=${encodeURIComponent(pad)}`, { method: "POST", body: JSON.stringify({ kind: "dm-status", msg: body }) });
      return json({ ok: true });
    }
    // bridge posting the pad's health snapshot → stored + fanned out live
    if (url.pathname === "/doctor-in" && req.method === "POST") {
      const body = await req.json();
      await hub(env, pad).fetch(`https://hub/deliver?pad=${encodeURIComponent(pad)}`, { method: "POST", body: JSON.stringify({ kind: "doctor-in", msg: body }) });
      return json({ ok: true });
    }
    // agent → human DM (bridge forwards `stitchpad dm` output): record + broadcast
    if (url.pathname === "/dm-in" && req.method === "POST") {
      const { from, to, text, at } = await req.json();
      if (!from || !to || !text) return json({ error: "need from + to + text" }, 400);
      await tryDeliver(env, pad, "dm-in", { from, to, text, at: at || Date.now() });
      return json({ ok: true });
    }
    // kanban ops from the PWA → bridge runs the task CLI (new/move/edit)
    if (url.pathname === "/task" && req.method === "POST") {
      const body = await req.json().catch(() => ({}));
      if (!body.op) return json({ error: "need op" }, 400);
      const ok = await tryDeliver(env, pad, "task", { ...body, at: Date.now() });
      return json(ok ? { ok: true } : { ok: false, error: "bridge offline" }, ok ? 200 : 503);
    }
    // terminal-view request (PWA) → bridge captures the agent's pane, posts back
    if (url.pathname === "/term" && req.method === "POST") {
      const { agent } = await req.json().catch(() => ({}));
      if (!agent) return json({ error: "need agent" }, 400);
      const ok = await tryDeliver(env, pad, "term", { agent, at: Date.now() });
      return json(ok ? { ok: true } : { ok: false, error: "bridge offline" }, ok ? 200 : 503);
    }
    // bridge posts the session-chat capture here
    if (url.pathname === "/term-in" && req.method === "POST") {
      const { agent, msgs, error, at } = await req.json();
      if (!agent) return json({ error: "need agent" }, 400);
      await tryDeliver(env, pad, "term-in", { agent, msgs: msgs || null, error: error || "", at: at || Date.now() });
      return json({ ok: true });
    }
    // summarize request (PWA) → bridge runs the local summarizer and posts back
    if (url.pathname === "/summarize" && req.method === "POST") {
      const { by } = await req.json().catch(() => ({}));
      const ok = await tryDeliver(env, pad, "summarize", { by: by || "smaths", at: Date.now() });
      return json(ok ? { ok: true } : { ok: false, error: "bridge offline" }, ok ? 200 : 503);
    }
    // bridge posts the finished summary here
    if (url.pathname === "/summary-in" && req.method === "POST") {
      const { text, error, by } = await req.json();
      await tryDeliver(env, pad, "summary-in", { text: text || "", error: error || "", by: by || "", at: Date.now() });
      return json({ ok: true });
    }

    if (url.pathname === "/say" && req.method === "POST") {
      const { from, text } = await req.json();
      if (!text) return json({ error: "empty" }, 400);
      const msg = { from: from || "smaths", text, at: Date.now() };
      if (await tryDeliver(env, pad, "say", msg)) return json({ ok: true, delivered: "ws" });
      const qk = `outbox:${pad}`;
      const q = JSON.parse((await env.STITCHPAD.get(qk)) || "[]");
      q.push(msg);
      await env.STITCHPAD.put(qk, JSON.stringify(q));
      return json({ ok: true, queued: q.length });
    }
    if (url.pathname === "/outbox" && req.method === "GET") {
      const qk = `outbox:${pad}`;
      const q = JSON.parse((await env.STITCHPAD.get(qk)) || "[]");
      await env.STITCHPAD.put(qk, "[]");
      return json({ messages: q });
    }
    // True DM: injected DIRECTLY into the target agent's terminal session
    // (herdr pane) — never lands on the shared pad.
    if (url.pathname === "/dm" && req.method === "POST") {
      const { from, to, text } = await req.json();
      if (!to || !text) return json({ error: "need to + text" }, 400);
      // id = the delivery-receipt key: the bridge reports the outcome on
      // /dm-status with it, and the phone anchors the receipt to the bubble.
      const msg = { from: from || "smaths", to, text, at: Date.now(), id: crypto.randomUUID().slice(0, 8) };
      if (await tryDeliver(env, pad, "dm", msg)) return json({ ok: true, delivered: "ws", id: msg.id });
      const qk = `dmbox:${pad}`;
      const q = JSON.parse((await env.STITCHPAD.get(qk)) || "[]");
      q.push(msg);
      await env.STITCHPAD.put(qk, JSON.stringify(q));
      return json({ ok: true, queued: q.length, id: msg.id });
    }
    if (url.pathname === "/dmbox" && req.method === "GET") {
      const qk = `dmbox:${pad}`;
      const q = JSON.parse((await env.STITCHPAD.get(qk)) || "[]");
      await env.STITCHPAD.put(qk, "[]");
      return json({ messages: q });
    }
    // Image upload endpoint — accepts multipart/form-data with 'image' field
    // Returns {url, sha, w, h, mime} for embedding in the pad
    if (url.pathname === "/upload-image" && req.method === "POST") {
      const contentType = req.headers.get("content-type") || "";
      if (!contentType.includes("multipart/form-data")) {
        return json({ error: "expected multipart/form-data" }, 400);
      }
      const formData = await req.formData();
      const file = formData.get("image");
      if (!file || typeof file === "string") {
        return json({ error: "missing 'image' field" }, 400);
      }
      // Validate mime type
      const allowedMimes = ["image/png", "image/jpeg", "image/gif", "image/webp"];
      if (!allowedMimes.includes(file.type)) {
        return json({ error: `invalid mime type: ${file.type}. Allowed: ${allowedMimes.join(", ")}` }, 400);
      }
      // Validate size (10MB max)
      const maxSize = 10 * 1024 * 1024;
      if (file.size > maxSize) {
        return json({ error: `file too large: ${file.size} bytes (max ${maxSize})` }, 400);
      }
      // Compute SHA-256 hash for dedupe
      const arrayBuffer = await file.arrayBuffer();
      const hashBuffer = await crypto.subtle.digest("SHA-256", arrayBuffer);
      const hashArray = Array.from(new Uint8Array(hashBuffer));
      const sha = hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
      // R2 key: images/<sha>.<ext>
      const ext = file.name.split(".").pop() || "png";
      const r2Key = `images/${sha}.${ext}`;
      // Upload to R2
      await env.IMAGES.put(r2Key, arrayBuffer, {
        httpMetadata: { contentType: file.type },
        customMetadata: { originalName: file.name, uploadedAt: new Date().toISOString() }
      });
      // Construct public URL served through our own domain via the /img proxy
      // route below — NOT the r2.dev dev URL (rate-limited, not for prod) and no
      // public-bucket exposure. r2Key is images/<sha>.<ext>; /img strips "images/".
      const publicUrl = `https://stitchpad.agentsworld.org/img/${sha}.${ext}`;
      return json({ url: publicUrl, sha, mime: file.type, size: file.size });
    }
    // File attach: any type up to 15MB → R2 + queued in filebox:<pad> for the
    // Mac bridge to land in the project's .stitchpad/dropbox/.
    if (url.pathname === "/upload-file" && req.method === "POST") {
      const contentType = req.headers.get("content-type") || "";
      if (!contentType.includes("multipart/form-data")) {
        return json({ error: "expected multipart/form-data" }, 400);
      }
      const formData = await req.formData();
      const file = formData.get("file");
      if (!file || typeof file === "string") return json({ error: "missing 'file' field" }, 400);
      const maxSize = 15 * 1024 * 1024;
      if (file.size > maxSize) return json({ error: `file too large: ${file.size} bytes (max ${maxSize})` }, 400);
      const buf = await file.arrayBuffer();
      const hashBuffer = await crypto.subtle.digest("SHA-256", buf);
      const sha = Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, "0")).join("").slice(0, 16);
      const safe = (file.name || "file").replace(/[^a-zA-Z0-9._-]/g, "_").slice(-80);
      const key = `files/${sha}-${safe}`;
      await env.IMAGES.put(key, buf, {
        httpMetadata: { contentType: file.type || "application/octet-stream" },
        customMetadata: { originalName: file.name || safe, uploadedAt: new Date().toISOString() }
      });
      const fmsg = { name: safe, key, at: Date.now() };
      if (await tryDeliver(env, pad, "file", fmsg)) return json({ ok: true, name: safe, key, size: file.size, delivered: "ws" });
      const qk = `filebox:${pad}`;
      const q = JSON.parse((await env.STITCHPAD.get(qk)) || "[]");
      q.push(fmsg);
      await env.STITCHPAD.put(qk, JSON.stringify(q));
      return json({ ok: true, name: safe, key, size: file.size });
    }
    if (url.pathname === "/filebox" && req.method === "GET") {
      const qk = `filebox:${pad}`;
      const q = JSON.parse((await env.STITCHPAD.get(qk)) || "[]");
      await env.STITCHPAD.put(qk, "[]");
      return json({ messages: q });
    }
    // Serve images from R2
    if (url.pathname.startsWith("/img/") && req.method === "GET") {
      const key = "images/" + url.pathname.slice(5);
      const obj = await env.IMAGES.get(key);
      if (!obj) return json({ error: "not found" }, 404);
      const headers = new Headers(cors);
      headers.set("content-type", obj.httpMetadata?.contentType || "application/octet-stream");
      headers.set("cache-control", "public, max-age=31536000");
      return new Response(obj.body, { headers });
    }
    return json({ error: "not found" }, 404);
  },
};
