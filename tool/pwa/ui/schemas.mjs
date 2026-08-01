// Pasture UI component schemas — the ONE source of truth for what a
// ```ui <type> fence may carry. Imported by BOTH:
//   · tool/mcp/server.mjs  — validates at write time (agents can't ship garbage)
//   · tool/pwa/ui/render.js — validates defensively at render time
// It lives under pwa/ (not mcp/) so the Worker's [assets] binding serves it to
// the client unchanged; the MCP server imports it by relative path.
//
// Design rule (john): components are NOT a tool-calling sideshow. A type earns
// a slot only when it beats prose at collaborating on work — a diff you can
// read, a table you can scan, a vote you can cast. Everything else is `say`.
//
// Validator dialect: a deliberate JSON-Schema subset (no external dep):
//   type (object|array|string|number|boolean), required, properties, items,
//   enum, maxLength, maxItems, additionalProperties:false is implied.
// Every payload also gets GLOBAL caps: ≤ 16 KB serialized, ≤ 200 array items.

export const MAX_PAYLOAD_BYTES = 16 * 1024;
export const MAX_ARRAY_ITEMS = 200;

const str = (max = 2000) => ({ type: "string", maxLength: max });
const short = str(200);

export const SCHEMAS = {
  // ── structure ────────────────────────────────────────────────
  callout: {
    doc: "Highlighted note: decision, warning, or heads-up the room must not scroll past.",
    schema: {
      type: "object",
      required: ["tone", "text"],
      properties: {
        tone: { enum: ["info", "success", "warn", "danger"] },
        title: short,
        text: str(4000),
      },
    },
  },
  checklist: {
    doc: "Live checklist for a work item — done/undone rows, no priorities, no dates.",
    schema: {
      type: "object",
      required: ["items"],
      properties: {
        title: short,
        items: {
          type: "array",
          items: {
            type: "object",
            required: ["text"],
            properties: { text: str(500), done: { type: "boolean" } },
          },
        },
      },
    },
  },

  timeline: {
    doc: "Vertical rail of labeled events with state — a reusable temporal primitive. Presets (e.g. run-report: steps + pass/fail + duration) compose over it.",
    schema: {
      type: "object",
      required: ["events"],
      properties: {
        title: short,
        events: {
          type: "array",
          items: {
            type: "object",
            required: ["label"],
            properties: {
              label: short,
              at: short, // freeform timestamp/duration, e.g. "14:32" or "1.2s"
              state: { enum: ["done", "active", "todo", "failed"] },
              note: str(500),
            },
          },
        },
      },
    },
  },

  // ── data ─────────────────────────────────────────────────────
  table: {
    doc: "Small data table (≤ 200 rows). Right-align numbers automatically.",
    schema: {
      type: "object",
      required: ["columns", "rows"],
      properties: {
        title: short,
        columns: { type: "array", items: short },
        rows: { type: "array", items: { type: "array", items: str(500) } },
      },
    },
  },
  progress: {
    doc: "Progress toward a bounded goal: value/max plus an optional per-step breakdown.",
    schema: {
      type: "object",
      required: ["label", "value", "max"],
      properties: {
        label: short,
        value: { type: "number" },
        max: { type: "number" },
        steps: {
          type: "array",
          items: {
            type: "object",
            required: ["label", "state"],
            properties: {
              label: short,
              state: { enum: ["done", "active", "todo", "failed"] },
            },
          },
        },
      },
    },
  },

  // ── dev ──────────────────────────────────────────────────────
  diff: {
    doc: "Unified diff hunk(s) for review. `text` is standard unified-diff format.",
    schema: {
      type: "object",
      required: ["text"],
      properties: {
        file: short,
        text: str(12000),
      },
    },
  },

  // ── interactive (round-trip rides threads: a vote/submit is a
  //    structured REPLY to the origin message — no new server state) ──
  poll: {
    doc: "Ask the room to vote. Votes arrive as ui:poll.vote replies threaded on this message.",
    schema: {
      type: "object",
      required: ["question", "options"],
      properties: {
        question: str(500),
        options: { type: "array", items: short },
        multi: { type: "boolean" },
      },
    },
  },
  "poll.vote": {
    doc: "A vote reply. Post with reply_to = the poll's message id.",
    schema: {
      type: "object",
      required: ["choice"],
      properties: { choice: { type: "array", items: short } },
    },
  },
  approve: {
    doc: "Request sign-off (merge? ship? proceed?). Verdicts arrive as ui:approve.verdict replies.",
    schema: {
      type: "object",
      required: ["text"],
      properties: { title: short, text: str(4000) },
    },
  },
  "approve.verdict": {
    doc: "A sign-off reply. Post with reply_to = the approve request's message id.",
    schema: {
      type: "object",
      required: ["verdict"],
      properties: { verdict: { enum: ["approve", "reject"] }, note: str(1000) },
    },
  },
  form: {
    doc: "Ask the room for structured input. Submissions arrive as ui:form.response replies.",
    schema: {
      type: "object",
      required: ["fields"],
      properties: {
        title: short,
        fields: {
          type: "array",
          items: {
            type: "object",
            required: ["key", "label", "kind"],
            properties: {
              key: str(60),
              label: short,
              kind: { enum: ["text", "textarea", "select", "checkbox"] },
              options: { type: "array", items: short },
              required: { type: "boolean" },
            },
          },
        },
      },
    },
  },
  "form.response": {
    doc: "A form submission reply. Post with reply_to = the form's message id.",
    schema: {
      type: "object",
      required: ["values"],
      properties: { values: { type: "object", properties: {} } },
    },
  },
};

/// Validate `payload` against the schema for `type`. Returns [] when clean,
/// else a list of human-readable problems. Enforces the global caps first.
export function validate(type, payload) {
  const entry = SCHEMAS[type];
  if (!entry) return [`unknown ui type "${type}" — known: ${Object.keys(SCHEMAS).join(", ")}`];
  let raw;
  try {
    raw = JSON.stringify(payload);
  } catch {
    return ["payload is not JSON-serializable"];
  }
  if (raw.length > MAX_PAYLOAD_BYTES) return [`payload too large (${raw.length} > ${MAX_PAYLOAD_BYTES} bytes)`];
  const errs = [];
  check(payload, entry.schema, "payload", errs);
  return errs;
}

function check(v, s, path, errs) {
  if (errs.length > 8) return; // enough
  if (s.enum) {
    if (!s.enum.includes(v)) errs.push(`${path}: must be one of ${s.enum.join("|")}`);
    return;
  }
  switch (s.type) {
    case "string":
      if (typeof v !== "string") return void errs.push(`${path}: expected string`);
      if (s.maxLength && v.length > s.maxLength) errs.push(`${path}: too long (>${s.maxLength})`);
      return;
    case "number":
      if (typeof v !== "number" || !Number.isFinite(v)) errs.push(`${path}: expected number`);
      return;
    case "boolean":
      if (typeof v !== "boolean") errs.push(`${path}: expected boolean`);
      return;
    case "array": {
      if (!Array.isArray(v)) return void errs.push(`${path}: expected array`);
      const cap = s.maxItems || MAX_ARRAY_ITEMS;
      if (v.length > cap) return void errs.push(`${path}: too many items (>${cap})`);
      if (s.items) v.forEach((it, i) => check(it, s.items, `${path}[${i}]`, errs));
      return;
    }
    case "object": {
      if (typeof v !== "object" || v === null || Array.isArray(v))
        return void errs.push(`${path}: expected object`);
      for (const req of s.required || []) {
        if (!(req in v)) errs.push(`${path}.${req}: required`);
      }
      const props = s.properties || {};
      // free-form objects (properties:{}) skip the unknown-key check (form values)
      const freeform = Object.keys(props).length === 0;
      for (const [k, val] of Object.entries(v)) {
        if (props[k]) check(val, props[k], `${path}.${k}`, errs);
        else if (!freeform) errs.push(`${path}.${k}: unknown key`);
      }
      return;
    }
    default:
      return;
  }
}

/// Compose the on-pad message body for a component: alt line (the graceful
/// degradation every non-rich surface shows) + the fenced payload.
export function composeFence(type, payload, alt) {
  return `${alt}\n\n\`\`\`ui ${type}\n${JSON.stringify(payload, null, 1)}\n\`\`\``;
}
