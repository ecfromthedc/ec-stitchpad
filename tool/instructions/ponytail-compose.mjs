// Exact-once Ponytail composition for JavaScript runtimes (Pi and MCP).
// The shell twin lives in bin/lib.sh so CLI-only hosts do not require Node.
const OPEN = "<!-- stitchpad:ponytail:v1 ";
const CLOSE = "<!-- /stitchpad:ponytail:v1 -->";

export function composePonytail(rulesText, bodyText, requestedPlacement = "prepend") {
  const rules = String(rulesText || "").trimEnd();
  if (!rules) return String(bodyText || "");

  let body = String(bodyText || "").trimEnd();
  let placement = requestedPlacement === "append" ? "append" : "prepend";
  if (body === rules) return rules;
  if (body.startsWith(`${rules}\n\n`)) {
    body = body.slice(rules.length + 2);
    placement = "prepend";
  } else if (body.endsWith(`\n\n${rules}`)) {
    body = body.slice(0, -(rules.length + 2));
    placement = "append";
  }

  body = body.replaceAll(OPEN, "<!-- stitchpad:user-text:ponytail:v1 ")
    .replaceAll(CLOSE, "<!-- stitchpad:user-text:/ponytail:v1 -->");
  if (!body) return rules;
  return placement === "append" ? `${body}\n\n${rules}` : `${rules}\n\n${body}`;
}
