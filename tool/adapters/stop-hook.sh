#!/usr/bin/env bash
# stitchpad ← Stop-hook shim for Claude Code AND Codex. STABLE: all logic lives in
# `stitchpad hook`, so this file's hash never changes and codex only needs to
# trust it ONCE (via /hooks). Wire it the same in both runtimes:
#   Claude ~/.claude/settings.json · Codex ~/.codex/hooks.json
#     { "hooks": { "Stop": [ { "hooks": [ { "type": "command",
#         "command": "/Users/you/.stitchpad/adapters/stop-hook.sh" } ] } ] } }
# Identity: launch each agent with its name in the env so the hook inherits it —
#   STITCHPAD_NAME=larry codex   ·   STITCHPAD_NAME=dale claude
# (export it in the same shell where you run `stitchpad say` too). The runtime
# pipes its Stop JSON to our stdin; we forward it to the CLI, which does the work.
sp="$(command -v stitchpad 2>/dev/null || true)"
[ -z "$sp" ] && sp="$HOME/.stitchpad/bin/stitchpad"
# FAIL OPEN, BUT NEVER IN SILENCE (k3 F10). This was a bare `[ -x "$sp" ] || exit 0`.
# Failing open is right — a Stop hook that errors can wedge the runtime, and one
# broken install must not stop anyone coding. Failing open with NO TRACE is not:
# when the CLI is missing or not executable, every claude/codex seat stops
# answering mentions simultaneously, while the heartbeat ticker keeps running so
# health and lanes still show them alive. They are simply deaf, forever, and
# nothing anywhere records why.
# Leave one rate-limited breadcrumb in a fixed location and still exit 0.
if [ ! -x "$sp" ]; then
  _log="${STITCHPAD_HOOK_LOG:-$HOME/.stitchpad-hook-errors.log}"
  _stamp="$_log.stamp"
  _now="$(date +%s 2>/dev/null || echo 0)"
  _last="$(cat "$_stamp" 2>/dev/null || echo 0)"
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  if [ "$(( _now - _last ))" -ge 3600 ]; then
    printf '[%s] stitchpad wake hook is DEAD: no executable CLI at %s — this seat will not answer mentions, and its heartbeat will keep it looking alive.\n' \
      "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$sp" >> "$_log" 2>/dev/null || true
    echo "$_now" > "$_stamp" 2>/dev/null || true
  fi
  exit 0
fi
exec "$sp" hook
