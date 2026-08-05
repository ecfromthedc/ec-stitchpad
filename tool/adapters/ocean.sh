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
sp_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/stitchpad"
[ -x "$sp_bin" ] || sp_bin="$(command -v stitchpad 2>/dev/null || true)"
[ -n "$sp_bin" ] && [ -x "$sp_bin" ] || { echo "[ocean.sh] stitchpad CLI not found" >&2; exit 1; }
# TASK-1 model pinning: requested (.state/seat-model.<name>) vs resolved
# (.state/resolved-model.<name>) with a refuse/surface policy.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/lib.sh"
state_dir="$(dirname "$pad")/.state"
# PREFLIGHT: never let a wake silently inherit the daemon global default.
# policy=refuse turns an unpinned seat or an active requested/resolved
# mismatch into a refused wake (loud, never silent).
sp_model_pin_preflight "$state_dir" "$name" || exit 1

# Ocean-backed seats include Kimi, GLM, and DeepSeek. Build their wake through
# the same canonical prompt path as Stop/Herdr/Pi rather than maintaining a
# model-specific copy here.
prompt="$("$sp_bin" prompt-context <<EOF
stitchpad: new @${name} mention on the pad at ${pad}.

${msg}

You are @${name} on this pad. Read the recent conversation with:
  cd ${pad_dir} && ~/.stitchpad/bin/stitchpad read -n 30
then reply with:
  cd ${pad_dir} && STITCHPAD_NAME=${name} ~/.stitchpad/bin/stitchpad say '<your reply>'
EOF
)"

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

seat_model="$(sp_model_pin_requested "$state_dir" "$name")"
# master annotates the model on the roster row and exports SP_MODEL. Keep that as
# a FALLBACK so a roster-pinned seat still works; the explicit per-seat pin wins.
# NOTE on master's form (model_args=()): an EMPTY array expanded unguarded under
# `set -u` is fatal on stock bash 3.2.57 — "model_args[@]: unbound variable" — the
# adapter exits 1, the wake gate never clears, and the seat goes silently deaf.
# wake_args below is always initialised NON-EMPTY, so it cannot hit that.
[ -z "$seat_model" ] && [ -n "${SP_MODEL:-}" ] && [ "${SP_MODEL}" != "-" ] && seat_model="$SP_MODEL"
wake_args=(wake --session-id "$session_id" --cwd "$pad_dir" --client-type stitchpad \
  --timeout-seconds 600 --prompt "$prompt")
[ -n "$seat_model" ] && wake_args+=(--model "$seat_model")
[ -n "${SP_DELIVERY_ACK_FILE:-}" ] && wake_args+=(--no-wait)

# RESOLVED telemetry: after an accepted wake, read the session's own config
# back from the daemon and persist it as the resolved truth, then re-check
# against the requested pin. Best-effort: a daemon that cannot answer leaves
# the previous resolved record untouched (an empty read never erases truth).
record_resolved_from_daemon() {
  local cfg rmodel rprovider
  cfg="$(curl -sf --max-time 3 "$daemon_url/v1/agent/sessions/$session_id/config" 2>/dev/null || true)"
  [ -n "$cfg" ] || return 0
  rmodel="$(printf '%s' "$cfg" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("model") or "")
except Exception: print("")' 2>/dev/null)"
  rprovider="$(printf '%s' "$cfg" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("provider") or "")
except Exception: print("")' 2>/dev/null)"
  [ -n "$rmodel" ] || return 0
  sp_model_pin_record_resolved "$state_dir" "$name" "$rmodel" "$rprovider" \
    "ocean-wake-config-rpc" "$session_id" || true
  sp_model_pin_check "$state_dir" "$name" || true
}

if [ -n "${SP_DELIVERY_ACK_FILE:-}" ]; then
  "$bin" "${wake_args[@]}" > "$SP_DELIVERY_ACK_FILE" || exit $?
  turn_id="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("turn_id", ""))
except Exception: print("")' "$SP_DELIVERY_ACK_FILE" 2>/dev/null)"
  [ -n "$turn_id" ] || { echo '[ocean.sh] accepted wake omitted turn_id' >&2; exit 1; }
  record_resolved_from_daemon
  cat "$SP_DELIVERY_ACK_FILE"
else
  "$bin" "${wake_args[@]}"
  wake_rc=$?
  [ "$wake_rc" -eq 0 ] && record_resolved_from_daemon
  exit "$wake_rc"
fi
