#!/usr/bin/env bash
# stitchpad watcher adapter: ocean — wake an Ocean-daemon agent session.
# Fired by watch.sh the instant a new @name lands in stitchpad.md:
#   ocean.sh mention <name> <stitchpad.md> <taskfile>
# Roster line:
#   <name> | ocean | push | <ocean-session-id>
# The roster target (the session id) arrives as $SP_TARGET.
#
# Delivery = `ocean-heartbeat wake`: POST the nudge as a turn on that exact
# session. Standalone callers wait for completion. The per-seat supervisor sets
# SP_DELIVERY_ACK_FILE, uses --no-wait, persists the returned turn_id, monitors
# it, and can cancel that exact request if work is superseded. Exit contract:
#   0 accepted/delivered · 3 deferred (busy/timeout) · 1 failed.
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

prompt="stitchpad: new @${name} mention on the pad at ${pad}.

${msg}

You are @${name} on this pad. Read the recent conversation with:
  cd ${pad_dir} && ~/.stitchpad/bin/stitchpad read -n 30
then reply with:
  cd ${pad_dir} && STITCHPAD_NAME=${name} ~/.stitchpad/bin/stitchpad say '<your reply>'"

wake_args=(wake --session-id "$session_id" --cwd "$pad_dir" --client-type stitchpad \
  --timeout-seconds 600 --prompt "$prompt")
[ -n "${SP_DELIVERY_ACK_FILE:-}" ] && wake_args+=(--no-wait)

out="$("$bin" "${wake_args[@]}")" || exit $?
if [ -n "${SP_DELIVERY_ACK_FILE:-}" ]; then
  turn_id="$(printf '%s' "$out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("turn_id", ""))
except Exception: print("")' 2>/dev/null)"
  [ -n "$turn_id" ] || { echo '[ocean.sh] accepted wake omitted turn_id' >&2; exit 1; }
  printf '%s\n' "$out" > "$SP_DELIVERY_ACK_FILE"
fi
printf '%s\n' "$out"
