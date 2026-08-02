#!/usr/bin/env bash
# One-shot anti-starvation keeper for roster-bound Ocean seats.
#
# The keeper never infers work from historical @mention counts. It asks the
# same FIFO wake gate used by runtime hooks for the current unread ordinal and
# the canonical task parser for the seat's current open work. One seat gets at
# most one coalesced wake per run.
set -uo pipefail

_src="${BASH_SOURCE[0]}"; while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
BIN_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
source "$BIN_DIR/lib.sh"

SP="$BIN_DIR/stitchpad"
HB="${OCEAN_HEARTBEAT_BIN:-$(command -v ocean-heartbeat 2>/dev/null || true)}"
DAEMON="${OCEAN_DAEMON_URL:-http://127.0.0.1:4780}"
MIN_SECONDS="${STITCHPAD_KEEPER_MIN_SECONDS:-600}"
CONFIG="${STITCHPAD_KEEPER_CONFIG:-}"
repos=()

usage() {
  echo "usage: stitchpad keeper [--config <repos-file>] <repo> [...]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || { usage; exit 2; }
      CONFIG="$2"; shift 2
      ;;
    --) shift; while [ $# -gt 0 ]; do repos+=("$1"); shift; done ;;
    -*) echo "seat-keeper: unknown option: $1" >&2; usage; exit 2 ;;
    *) repos+=("$1"); shift ;;
  esac
done

case "$MIN_SECONDS" in *[!0-9]*|'') echo "seat-keeper: STITCHPAD_KEEPER_MIN_SECONDS must be a non-negative integer" >&2; exit 2;; esac
[ -n "$HB" ] && [ -x "$HB" ] || { echo "seat-keeper: ocean-heartbeat not found (set OCEAN_HEARTBEAT_BIN)" >&2; exit 1; }

if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || { echo "seat-keeper: config not found: $CONFIG" >&2; exit 1; }
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    case "$repo" in \#*) continue;; esac
    repos+=("$repo")
  done < "$CONFIG"
fi
[ "${#repos[@]}" -gt 0 ] || { usage; exit 2; }

failures=0

delivery_owned() {
  local state="$1" name="$2" lock pid phase
  # Durable delivery supervision owns every accepted/recoverable generation,
  # including error retry. The keeper must not create a parallel turn.
  [ -f "$state/delivery.$name.pending" ] && return 0
  lock="$state/delivery.$name.worker.lock.d"
  [ -d "$lock" ] || return 1
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  phase="$(awk -F= '$1=="state" {print $2; exit}' "$state/delivery.$name.state" 2>/dev/null || true)"
  [ "$phase" = "started" ] || [ "$phase" = "busy" ]
}

for repo in "${repos[@]}"; do
  pad="$(sp_find_pad "$repo" 2>/dev/null || true)"
  [ -n "$pad" ] && [ -f "$pad/stitchpad.md" -o -f "$pad/pasture.md" ] || {
    echo "seat-keeper: skip $repo (no pad)" >&2
    continue
  }
  state="$pad/.state"
  roster="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_PAD_DIR="$pad" "$SP" roster 2>/dev/null || true)"
  while IFS='|' read -r name adapter wake sid; do
    [ -n "$name" ] || continue
    # This keeper owns only explicit Ocean push seats. Pull hooks and other
    # adapters remain authoritative for their own delivery surfaces.
    [ "$adapter" = "ocean" ] && [ "$wake" = "push" ] || continue
    case "$sid" in ''|-|*/*|*..*|*[!a-zA-Z0-9._-]*) continue;; esac

    # The roster target and sessions/<id> binding must agree. Legacy
    # ocean-session.<name> and user config names are deliberately ignored.
    binding="$state/sessions/$sid"
    [ -f "$binding" ] && [ "$(cat "$binding" 2>/dev/null)" = "$name" ] || continue
    [ ! -f "$state/dnd.$name" ] || continue
    # A delivery/recovery already in flight is busy work; never stack a keeper
    # turn on top of it.
    [ ! -f "$state/pending.$name" ] && [ ! -f "$state/delivered_no_reply.$name" ] || continue
    delivery_owned "$state" "$name" && continue

    session_json="$(curl -sf -m 4 "$DAEMON/v1/agent/sessions/$sid" 2>/dev/null || true)"
    active="$(printf '%s' "$session_json" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get("session", {}).get("active_turn")
    print("busy" if value else "idle")
except Exception:
    print("unknown")
' 2>/dev/null)"
    [ "$active" = "idle" ] || continue

    now="$(date +%s)"
    last="$(cat "$state/keeper-last.$name" 2>/dev/null || echo 0)"
    case "$last" in *[!0-9]*|'') last=0;; esac
    [ $((now - last)) -ge "$MIN_SECONDS" ] || continue

    # Current unread means the FIFO wake gate has an ordinal strictly after the
    # seat's seen cursor. A historical mention already consumed by wake is 0.
    unread="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_PAD_DIR="$pad" "$SP" wake "$name" --peek-ordinal 2>/dev/null || true)"
    case "$unread" in *[!0-9]*|'') unread=0;; esac

    # Canonical task parser reads tasks.md plus legacy inline cards. Only the
    # current actionable states ride the wake; done/canceled never do.
    open_tasks="$(STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_PAD_DIR="$pad" "$SP" task list --mine "$name" 2>/dev/null \
      | awk -F'|' '
          $3=="in_progress" || $3=="todo" || $3=="in_review" {
            if (n < 4) {
              if (n) printf "; "
              printf "%s[%s] %s", $1, $3, $2
            }
            n++
          }
          END { if (n > 4) printf "; +%d more", n-4 }
        ')"
    [ "$unread" -gt 0 ] || [ -n "$open_tasks" ] || continue

    state_parts=""
    [ "$unread" -gt 0 ] && state_parts="unread mention ordinal $unread"
    if [ -n "$open_tasks" ]; then
      [ -z "$state_parts" ] || state_parts="$state_parts; "
      state_parts="${state_parts}open work: $open_tasks"
    fi
    prompt="stitchpad keeper: current state for @$name — $state_parts. Read only current unread context with \`stitchpad read --new\`, then continue the current task. Do not replay historical mentions or create duplicate work."

    args=(wake --session-id "$sid" --cwd "$repo" --client-type stitchpad --no-wait --prompt "$prompt")
    # seat-model is operator-owned scheduling policy. model.<name> is merely
    # runtime-reported metadata and may be overwritten by any rebound session.
    model="$(cat "$state/seat-model.$name" 2>/dev/null || true)"
    [ -z "$model" ] || args+=(--model "$model")
    output="$("$HB" "${args[@]}" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$output" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if data.get("ok") is True else 1)
'; then
      printf '%s' "$now" > "$state/keeper-last.$name"
      echo "seat-keeper: woke @$name ($state_parts)"
    else
      echo "seat-keeper: wake failed for @$name: $(printf '%s\n' "$output" | tail -1)" >&2
      failures=$((failures + 1))
    fi
  done <<< "$roster"
done

[ "$failures" -eq 0 ]
