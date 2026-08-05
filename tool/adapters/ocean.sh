#!/usr/bin/env bash
# stitchpad watcher adapter: ocean — wake an Ocean-daemon agent session.
# Fired by watch.sh the instant a new @name lands in stitchpad.md:
#   ocean.sh mention <name> <stitchpad.md> <taskfile>
# Roster line:
#   <name> | ocean | push | <ocean-session-id>
# The roster target (the session id) arrives as $SP_TARGET.
#
# Delivery = `ocean-heartbeat wake`: POST the nudge as a turn on that exact
# session and wait for the turn to finish. Exit contract:
#   0 delivered (turn completed) · 3 deferred (busy/timeout) · 1 failed.
# The Stop hook (stitchpad hook via [[hooks.Stop]] in ocean.toml) then keeps
# the agent engaged at turn boundaries; bind the session once with:
#   stitchpad bind-session <session-id> <name>
set -uo pipefail

name="${2:-}"; pad="${3:-}"; taskfile="${4:-}"
session_id="${SP_TARGET:-}"
[ -n "$name" ] || exit 1
[ -n "$session_id" ] && [ "$session_id" != "-" ] || {
  echo "[ocean.sh] no session id in roster target for @$name" >&2; exit 1; }

# Prefer an installed binary; fall back to the ocean-os release build.
bin="$(command -v ocean-heartbeat 2>/dev/null || true)"
[ -z "$bin" ] && bin="$HOME/dev/ocean-os/target/release/ocean-heartbeat"
[ -x "$bin" ] || { echo "[ocean.sh] ocean-heartbeat not found" >&2; exit 1; }

pad_dir="$(cd "$(dirname "$pad")/.." && pwd)"
msg="$(head -c 2000 "$taskfile" 2>/dev/null)"

# IDLE-GUARD: posting a wake turn while the session is mid-turn queues it as
# stale pending input (the parked-message bug smaths hit). Defer instead — the
# watcher keeps the gate and retries, and the Stop hook covers turn-end
# delivery for a session that is already running.
daemon_url="${OCEAN_DAEMON_URL:-http://127.0.0.1:4780}"
active="$(curl -sf --max-time 3 "$daemon_url/v1/agent/sessions/$session_id" 2>/dev/null \
  | python3 -c 'import json,sys
try:
    s=json.load(sys.stdin).get("session",{})
    print("busy" if s.get("active_turn") else "idle")
except Exception:
    print("unknown")' 2>/dev/null)"
if [ "$active" = "busy" ]; then
  echo "[ocean.sh] session $session_id mid-turn — deferring wake for @$name" >&2
  exit 3
fi

# PER-SEAT MODEL: stitchpad stores each roster member's model as
# .state/model.<name> (set via `stitchpad meta set <name> model <id>`).
# Passing it pins THIS wake turn to that model, so one pad can run several
# Ocean seats on different models without flipping the daemon's global default.
# Absent -> omit the flag and inherit the daemon default.
seat_model=""
# NOTE: use seat-model.<name>, NOT model.<name>. The latter is written BY the
# agent at join/turn time to REPORT the model it actually ran, so it gets
# overwritten on every wake — useless as config. seat-model.<name> is operator
# config: written once, read here, never touched by the runtime.
_mf="$(dirname "$pad")/.state/seat-model.${name}"
[ -f "$_mf" ] && seat_model="$(tr -d '[:space:]' < "$_mf" 2>/dev/null || true)"
# master annotates the model on the roster row and exports it as SP_MODEL. Keep
# that path as a fallback so a roster-pinned seat still works; the per-seat file
# wins because it is operator config that the runtime never rewrites.
[ -z "$seat_model" ] && [ -n "${SP_MODEL:-}" ] && [ "${SP_MODEL}" != "-" ] && seat_model="$SP_MODEL"

set -- --session-id "$session_id" \
  --cwd "$pad_dir" \
  --client-type "stitchpad" \
  --timeout-seconds 600
[ -n "$seat_model" ] && set -- "$@" --model "$seat_model"

"$bin" wake "$@" \
  --prompt "stitchpad: new @${name} mention on the pad at ${pad}.

THE MESSAGE ADDRESSED TO YOU:
${msg}

Answer THAT message. Post exactly one reply:
  cd ${pad_dir} && STITCHPAD_NAME=${name} ~/.stitchpad/bin/stitchpad say '@<sender> <your answer>'

Rules:
- Start your reply with @ and the name of whoever addressed you, so they are woken.
- Answer the question asked. Do not summarise the pad or report on its state.
- If you need context first: cd ${pad_dir} && ~/.stitchpad/bin/stitchpad read --new
  (unread only — do NOT dump the whole history, it drowns the actual question).
- Post ONCE. Your turn-end hook may wake you again after this; if there is nothing
  new addressed to you, post NOTHING and simply stop. Never post filler such as
  'no new messages', 'already replied', or 'roll call complete' — an empty turn is
  the correct, expected outcome and costs nobody anything."
exit $?
