// Pasture ```ui fence → HTML string renderers. Slots into the existing
// string-based markdown pipeline (fenceBlock dispatch), so every renderer
// RETURNS AN HTML STRING and interactivity rides delegated data-ui-* clicks —
// same pattern as data-copy / card-trigger. No component may emit unescaped
// input: payload text goes through h() before hitting the string.
//
// Aesthetic contract (PRODUCT.md): workshop-calm. Components are dense inline
// artifacts in the flow of conversation — never giant SaaS cards. Tallies for
// interactive types are derived from ctx.replies (the message's thread), so
// interactivity needs zero server state.

import { validate } from "./schemas.mjs";

const h = s =>
  String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
// fence code arrives pre-escaped by the pipeline's esc() (&<> only) — undo it
// so JSON.parse sees real JSON, then re-escape on the way out via h().
const unesc = s => String(s ?? "").replace(/&(amp|lt|gt);/g, m => ({ "&amp;": "&", "&lt;": "<", "&gt;": ">" }[m]));

/// ctx: { id, who, me, replies: [{who, ui:{type,data}}] }
export function renderUi(type, escapedCode, ctx = {}) {
  let data;
  try {
    data = JSON.parse(unesc(escapedCode));
  } catch {
    return fallback(type, escapedCode, "unparseable payload");
  }
  const problems = validate(type, data);
  if (problems.length) return fallback(type, escapedCode, problems[0]);
  const fn = RENDER[type];
  if (!fn) return fallback(type, escapedCode, "unknown type");
  try {
    return `<div class="ui-card ui-${type.replace(/\./g, "-")}">${fn(data, ctx)}</div>`;
  } catch {
    return fallback(type, escapedCode, "render error");
  }
}

const fallback = (type, code, why) =>
  `<div class="cb"><button class="cpy" title="copy">copy</button><pre>ui ${h(type)} (${h(why)})\n${code}</pre></div>`;

const title = t => (t ? `<div class="ui-title">${h(t)}</div>` : "");

/// replies of one ui reply-type, e.g. uiReplies(ctx, "poll.vote")
const uiReplies = (ctx, t) => (ctx.replies || []).filter(r => r.ui && r.ui.type === t);

const RENDER = {
  // ── structure ────────────────────────────────────────────────
  callout: d =>
    `<div class="ui-callout co-${h(d.tone)}">` +
    (d.title ? `<b>${h(d.title)}</b>` : "") +
    `<span>${h(d.text)}</span></div>`,

  checklist: d => {
    const done = d.items.filter(i => i.done).length;
    return (
      title(d.title) +
      `<div class="ui-meter"><i style="width:${d.items.length ? Math.round((done / d.items.length) * 100) : 0}%"></i></div>` +
      `<ul class="ui-check">` +
      d.items
        .map(i => `<li class=${i.done ? '"ck-done"' : '"ck-open"'}><span class="ck-box">${i.done ? "✓" : ""}</span>${h(i.text)}</li>`)
        .join("") +
      `</ul><div class="ui-sub">${done}/${d.items.length} done</div>`
    );
  },

  timeline: d => {
    // glyph+color paired per state; `st` is whitelisted before it reaches a
    // class name, so raw payload never lands unescaped in an attribute.
    const glyph = { done: "✓", active: "▸", todo: "·", failed: "✕" };
    return (
      title(d.title) +
      `<ol class="ui-tl">` +
      d.events
        .map(e => {
          const st = glyph[e.state] ? e.state : "todo";
          return (
            `<li class="tl-ev tl-${st}">` +
            `<span class="tl-dot">${glyph[st]}</span>` +
            `<div class="tl-body"><div class="tl-head"><span class="tl-label">${h(e.label)}</span>` +
            (e.at ? `<span class="tl-at">${h(e.at)}</span>` : "") +
            `</div>` +
            (e.note ? `<div class="tl-note">${h(e.note)}</div>` : "") +
            `</div></li>`
          );
        })
        .join("") +
      `</ol>`
    );
  },

  // ── data ─────────────────────────────────────────────────────
  table: d => {
    const numeric = ci => d.rows.length > 0 && d.rows.every(r => r[ci] === undefined || /^-?[\d,.%$]+$/.test(String(r[ci]).trim()));
    const aligns = d.columns.map((_, ci) => (numeric(ci) ? ' class="num"' : ""));
    return (
      title(d.title) +
      `<div class="ui-tblwrap"><table class="ui-tbl"><thead><tr>` +
      d.columns.map((c, ci) => `<th${aligns[ci]}>${h(c)}</th>`).join("") +
      `</tr></thead><tbody>` +
      d.rows
        .map(r => `<tr>` + d.columns.map((_, ci) => `<td${aligns[ci]}>${h(r[ci] ?? "")}</td>`).join("") + `</tr>`)
        .join("") +
      `</tbody></table></div>`
    );
  },

  progress: d => {
    const pct = d.max > 0 ? Math.min(100, Math.max(0, Math.round((d.value / d.max) * 100))) : 0;
    return (
      `<div class="ui-prog"><span class="ui-title">${h(d.label)}</span><span class="ui-sub">${h(d.value)}/${h(d.max)}</span></div>` +
      `<div class="ui-meter"><i style="width:${pct}%"></i></div>` +
      (d.steps
        ? `<div class="ui-steps">` +
          d.steps.map(s => `<span class="stp stp-${h(s.state)}" title="${h(s.label)}">${h(s.label)}</span>`).join("") +
          `</div>`
        : "")
    );
  },

  // ── dev ──────────────────────────────────────────────────────
  diff: d =>
    (d.file ? `<div class="ui-title ui-mono">${h(d.file)}</div>` : "") +
    `<pre class="ui-diff">` +
    d.text
      .split("\n")
      .map(l => {
        const c = l.startsWith("+") ? "dl-add" : l.startsWith("-") ? "dl-del" : /^@@/.test(l) ? "dl-hunk" : "dl-ctx";
        return `<span class="${c}">${h(l) || " "}</span>`;
      })
      .join("\n") +
    `</pre>`,

  // ── interactive (tallies derive from thread replies) ─────────
  poll: (d, ctx) => {
    const votes = uiReplies(ctx, "poll.vote");
    const count = new Map(d.options.map(o => [o, []]));
    for (const v of votes)
      for (const c of v.ui.data.choice || []) if (count.has(c)) count.get(c).push(v.who);
    const total = votes.length;
    const mine = votes.some(v => v.who === ctx.me);
    return (
      `<div class="ui-title">${h(d.question)}</div>` +
      d.options
        .map(o => {
          const who = count.get(o);
          const pct = total ? Math.round((who.length / total) * 100) : 0;
          const iVoted = who.includes(ctx.me);
          return (
            `<button class="ui-opt${iVoted ? " mine" : ""}" data-ui-act="vote" data-ui-id="${h(ctx.id)}" data-ui-opt="${h(o)}"` +
            ` title="${who.length ? h(who.map(w => "@" + w).join(" ")) : "vote"}">` +
            `<i style="width:${pct}%"></i><span class="opt-t">${h(o)}</span><span class="opt-n">${who.length || ""}</span></button>`
          );
        })
        .join("") +
      `<div class="ui-sub">${total} vote${total === 1 ? "" : "s"}${mine ? " · you voted" : ""}${d.multi ? " · multi" : ""}</div>`
    );
  },

  "poll.vote": d => `<div class="ui-reply">voted: <b>${(d.choice || []).map(h).join(", ")}</b></div>`,

  approve: (d, ctx) => {
    const verdicts = uiReplies(ctx, "approve.verdict");
    const ok = verdicts.filter(v => v.ui.data.verdict === "approve");
    const no = verdicts.filter(v => v.ui.data.verdict === "reject");
    const mine = verdicts.find(v => v.who === ctx.me);
    return (
      title(d.title || "sign-off requested") +
      `<div class="ui-body">${h(d.text)}</div>` +
      `<div class="ui-actions">` +
      `<button class="ui-btn ok${mine?.ui.data.verdict === "approve" ? " mine" : ""}" data-ui-act="verdict" data-ui-id="${h(ctx.id)}" data-ui-v="approve">approve${ok.length ? " · " + ok.length : ""}</button>` +
      `<button class="ui-btn bad${mine?.ui.data.verdict === "reject" ? " mine" : ""}" data-ui-act="verdict" data-ui-id="${h(ctx.id)}" data-ui-v="reject">reject${no.length ? " · " + no.length : ""}</button>` +
      `</div>` +
      (verdicts.length
        ? `<div class="ui-sub">${verdicts.map(v => `<b style="color:${v.ui.data.verdict === "approve" ? "var(--ok,#3fb950)" : "var(--err,#f85149)"}">@${h(v.who)}</b>`).join(" ")}</div>`
        : "")
    );
  },

  "approve.verdict": d =>
    `<div class="ui-reply">${d.verdict === "approve" ? "✓ approved" : "✕ rejected"}${d.note ? " — " + h(d.note) : ""}</div>`,

  form: (d, ctx) => {
    const got = uiReplies(ctx, "form.response");
    const mine = got.some(r => r.who === ctx.me);
    return (
      title(d.title || "input requested") +
      `<div class="ui-form" data-ui-form="${h(ctx.id)}">` +
      d.fields
        .map(f => {
          const req = f.required ? " <i class='req'>*</i>" : "";
          if (f.kind === "textarea")
            return `<label>${h(f.label)}${req}<textarea rows="2" data-ui-key="${h(f.key)}"></textarea></label>`;
          if (f.kind === "select")
            return `<label>${h(f.label)}${req}<select data-ui-key="${h(f.key)}"><option value=""></option>${(f.options || []).map(o => `<option>${h(o)}</option>`).join("")}</select></label>`;
          if (f.kind === "checkbox")
            return `<label class="lb-ck"><input type="checkbox" data-ui-key="${h(f.key)}"/>${h(f.label)}</label>`;
          return `<label>${h(f.label)}${req}<input type="text" data-ui-key="${h(f.key)}"/></label>`;
        })
        .join("") +
      `<div class="ui-actions"><button class="ui-btn ok" data-ui-act="form-submit" data-ui-id="${h(ctx.id)}">${mine ? "submit again" : "submit"}</button></div>` +
      `</div>` +
      (got.length ? `<div class="ui-sub">${got.length} response${got.length === 1 ? "" : "s"}: ${got.map(r => "@" + h(r.who)).join(" ")}</div>` : "")
    );
  },

  "form.response": d =>
    `<div class="ui-reply"><dl class="ui-kv">` +
    Object.entries(d.values || {})
      .map(([k, v]) => `<dt>${h(k)}</dt><dd>${h(String(v))}</dd>`)
      .join("") +
    `</dl></div>`,
};

/// Parse a raw (UNescaped) message body for its ```ui fence → {type, data} or null.
/// Used by the Log to hand parents their replies' payloads for tallies.
export function extractUi(bodyText) {
  const m = String(bodyText || "").match(/```ui\s+([a-z.-]+)\s*\n([\s\S]*?)```/i);
  if (!m) return null;
  try {
    return { type: m[1].toLowerCase(), data: JSON.parse(m[2]) };
  } catch {
    return null;
  }
}
