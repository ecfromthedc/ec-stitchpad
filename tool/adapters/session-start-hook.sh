#!/usr/bin/env bash
# stitchpad auto-rejoin — claude SessionStart hook. Zero-friction reconnect:
# a restarted claude session re-binds its NEW session id to this pad's sticky
# handle (.state/autoname.claude, written by the MCP join tool), restarts the
# heartbeat, and re-pins the herdr wake target to this pane's terminal id.
# Fast no-op when the cwd has no pad or no sticky name.
#
# IDENTITY GUARD — the sticky name is a RECOVERY hint, not a grant. A pad dir
# can host SEVERAL claude sessions at once (fable + helpers); blindly adopting
# the sticky name let a second session steal the handle, hijack the wake
# target, and receive another agent's messages (the 02:53 fable incident).
# Adopt ONLY when one of these holds:
#   (1) true resume  — this session id is already bound to the name
#   (2) same terminal — we're starting in the very herdr terminal the roster
#       says @name lives in (normal restart-in-place)
#   (3) orphan rescue — @name's heartbeat is stale/dead (nobody is the name)
set -uo pipefail

input="$(cat 2>/dev/null || true)"
jqbin="$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)"
cwd=""; sid=""
if [ -x "$jqbin" ] && [ -n "$input" ]; then
  cwd="$(printf '%s' "$input" | "$jqbin" -r '.cwd // empty' 2>/dev/null)"
  sid="$(printf '%s' "$input" | "$jqbin" -r '.session_id // empty' 2>/dev/null)"
fi
[ -n "$cwd" ] || cwd="$PWD"
pad="$cwd/.stitchpad"
[ -d "$pad" ] || exit 0

name=""
[ -f "$pad/.state/autoname.claude" ] && name="$(cat "$pad/.state/autoname.claude" 2>/dev/null | tr -d '[:space:]')"
[ -n "$name" ] || exit 0

bin="$HOME/.stitchpad/bin/stitchpad"
[ -x "$bin" ] || bin="$(command -v stitchpad 2>/dev/null || true)"
[ -n "$bin" ] && [ -x "$bin" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# Resolve this pane's herdr terminal id once (used by guard rule 2 + re-pin).
myterm=""
if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  hd="$(command -v herdr 2>/dev/null || echo "$HOME/.local/bin/herdr")"
  if [ -x "$hd" ] && [ -x "$jqbin" ]; then
    myterm="$("$hd" agent get "$HERDR_PANE_ID" 2>/dev/null | "$jqbin" -r '.result.agent.terminal_id // empty' 2>/dev/null)"
  fi
fi

adopt=0
# (1) true resume: this session id already bound to this name
if [ -n "$sid" ] && [ -f "$pad/.state/sessions/$sid" ]; then
  bound="$(cat "$pad/.state/sessions/$sid" 2>/dev/null | tr -d '[:space:]')"
  [ "$bound" = "$name" ] && adopt=1
fi
# (2) same terminal: restarting in the terminal the roster pins for @name
if [ "$adopt" -eq 0 ] && [ -n "$myterm" ]; then
  rterm="$("$bin" roster 2>/dev/null | awk -F'|' -v n="$name" '$1==n {print $4}' | tr -d '[:space:]')"
  [ -n "$rterm" ] && [ "$rterm" = "$myterm" ] && adopt=1
fi
# (3) orphan rescue: no fresh heartbeat with a live pid → nobody IS the name
if [ "$adopt" -eq 0 ]; then
  hb="$pad/.state/alive.$name"
  orphan=1
  if [ -f "$hb" ]; then
    hts="$(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null || echo 0)"
    hage=$(( $(date +%s) - hts ))
    if [ "$hage" -lt 90 ]; then
      hpid="$(grep -o '"pid":[0-9]*' "$hb" 2>/dev/null | head -1 | cut -d: -f2)"
      if [ -z "$hpid" ] || kill -0 "$hpid" 2>/dev/null; then
        orphan=0   # @name is alive elsewhere — do NOT steal it
      fi
    fi
  fi
  [ "$orphan" -eq 1 ] && adopt=1
fi
[ "$adopt" -eq 1 ] || exit 0

# Re-bind THIS session id, restart the heartbeat under the live claude pid.
[ -n "$sid" ] && "$bin" bind-session "$sid" "$name" >/dev/null 2>&1 || true
STITCHPAD_NAME="$name" STITCHPAD_HEARTBEAT_PARENT_PID="$PPID" \
  "$bin" heartbeat start "$name" >/dev/null 2>&1 || true

# Re-pin the push wake target to this terminal (stable across pane moves).
[ -n "$myterm" ] && "$bin" set-wake "$name" push "$myterm" herdr >/dev/null 2>&1 || true

# stdout becomes session context: remind the agent who it is on this pad and
# rebuild the same shared coding discipline a brand-new session would get.
printf '%s\n' "stitchpad: you are @$name on this project's pad (auto-rejoined — session re-bound, heartbeat live, wake target re-pinned). Use the stitchpad say/read/tasks MCP tools; @$name mentions wake you at turn-end. Do NOT call join again." \
  | "$bin" prompt-context
exit 0
