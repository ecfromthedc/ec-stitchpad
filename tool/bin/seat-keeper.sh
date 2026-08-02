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
LOCK_STALE_SECONDS="${STITCHPAD_KEEPER_LOCK_STALE_SECONDS:-300}"
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
case "$LOCK_STALE_SECONDS" in *[!0-9]*|'') echo "seat-keeper: STITCHPAD_KEEPER_LOCK_STALE_SECONDS must be a non-negative integer" >&2; exit 2;; esac
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
KEEPER_LOCK_DIR=""
KEEPER_LOCK_OWNER=""
KEEPER_TMP=""

process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

keeper_lock_release() {
  if [ -n "$KEEPER_TMP" ]; then rm -f "$KEEPER_TMP" 2>/dev/null || true; fi
  if [ -n "$KEEPER_LOCK_DIR" ] && [ -d "$KEEPER_LOCK_DIR" ] \
    && [ "$(cat "$KEEPER_LOCK_DIR/owner" 2>/dev/null || true)" = "$KEEPER_LOCK_OWNER" ]; then
    rm -f "$KEEPER_LOCK_DIR/owner" 2>/dev/null || true
    rmdir "$KEEPER_LOCK_DIR" 2>/dev/null || true
  fi
  KEEPER_LOCK_DIR=""
  KEEPER_LOCK_OWNER=""
  KEEPER_TMP=""
}

keeper_lock_acquire() {
  local state="$1" name="$2" lock owner pid started epoch now current_start mtime age self_pid self_start
  lock="$state/keeper.$name.lock.d"
  now="$(date +%s)"
  self_pid="${BASHPID:-$$}"
  self_start="$(process_start "$self_pid")"
  if ! mkdir "$lock" 2>/dev/null; then
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    IFS='|' read -r pid started epoch <<<"$owner"
    case "$pid" in ''|*[!0-9]*) pid="";; esac
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      current_start="$(process_start "$pid")"
      # If either start identity is unavailable, fail closed: kill -0 still
      # proves a live process and it is never safe to steal that reservation.
      { [ -z "$started" ] || [ -z "$current_start" ] || [ "$current_start" = "$started" ]; } && return 1
    fi
    case "$epoch" in ''|*[!0-9]*)
      mtime="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")"
      epoch="$mtime"
      ;;
    esac
    age=$((now - epoch))
    [ "$age" -ge "$LOCK_STALE_SECONDS" ] || return 1
    # Re-read before removal so two stale cleaners cannot delete a newly
    # acquired owner's lock. mkdir below decides the sole winner.
    [ "$(cat "$lock/owner" 2>/dev/null || true)" = "$owner" ] || return 1
    rm -f "$lock/owner" 2>/dev/null || return 1
    rmdir "$lock" 2>/dev/null || return 1
    mkdir "$lock" 2>/dev/null || return 1
  fi
  KEEPER_LOCK_DIR="$lock"
  KEEPER_LOCK_OWNER="$self_pid|$self_start|$now"
  if ! printf '%s' "$KEEPER_LOCK_OWNER" > "$lock/owner"; then
    rmdir "$lock" 2>/dev/null || true
    KEEPER_LOCK_DIR=""
    KEEPER_LOCK_OWNER=""
    return 1
  fi
  return 0
}

keeper_write_atomic() {
  local target="$1" value="$2"
  KEEPER_TMP="$target.tmp.${BASHPID:-$$}"
  printf '%s' "$value" > "$KEEPER_TMP" || return 1
  mv "$KEEPER_TMP" "$target" || return 1
  KEEPER_TMP=""
}

trap 'keeper_lock_release' EXIT
trap 'keeper_lock_release; exit 130' HUP INT TERM

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

process_seat() {
  local repo="$1" pad="$2" state="$3" name="$4" sid="$5"
  local binding session_json active now last unread open_tasks state_parts prompt model output rc
  local -a args

  binding="$state/sessions/$sid"
  [ -f "$binding" ] && [ "$(cat "$binding" 2>/dev/null)" = "$name" ] || return 0
  keeper_lock_acquire "$state" "$name" || return 0

  # Everything that can make the seat ineligible is checked while holding the
  # atomic reservation. A second keeper therefore cannot observe the same
  # keeper-last value and race an identical external wake.
  [ -f "$binding" ] && [ "$(cat "$binding" 2>/dev/null)" = "$name" ] \
    || { keeper_lock_release; return 0; }
  [ ! -f "$state/dnd.$name" ] || { keeper_lock_release; return 0; }
  [ ! -f "$state/pending.$name" ] && [ ! -f "$state/delivered_no_reply.$name" ] \
    || { keeper_lock_release; return 0; }
  if delivery_owned "$state" "$name"; then keeper_lock_release; return 0; fi

  session_json="$(curl -sf -m 4 "$DAEMON/v1/agent/sessions/$sid" 2>/dev/null || true)"
  active="$(printf '%s' "$session_json" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get("session", {}).get("active_turn")
    print("busy" if value else "idle")
except Exception:
    print("unknown")
' 2>/dev/null)"
  [ "$active" = "idle" ] || { keeper_lock_release; return 0; }

  now="$(date +%s)"
  last="$(cat "$state/keeper-last.$name" 2>/dev/null || echo 0)"
  case "$last" in *[!0-9]*|'') last=0;; esac
  [ $((now - last)) -ge "$MIN_SECONDS" ] || { keeper_lock_release; return 0; }

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
  [ "$unread" -gt 0 ] || [ -n "$open_tasks" ] \
    || { keeper_lock_release; return 0; }

  state_parts=""
  [ "$unread" -gt 0 ] && state_parts="unread mention ordinal $unread"
  if [ -n "$open_tasks" ]; then
    [ -z "$state_parts" ] || state_parts="$state_parts; "
    state_parts="${state_parts}open work: $open_tasks"
  fi
  prompt="stitchpad keeper: current state for @$name — $state_parts. Read only current unread context with \`stitchpad read --new\`, then continue the current task. Do not replay historical mentions or create duplicate work."

  # Recheck cross-process delivery ownership and daemon activity immediately
  # before the external side effect. Delivery workers do not take keeper locks,
  # so their durable contract remains the final authority.
  [ -f "$binding" ] && [ "$(cat "$binding" 2>/dev/null)" = "$name" ] \
    || { keeper_lock_release; return 0; }
  [ ! -f "$state/dnd.$name" ] || { keeper_lock_release; return 0; }
  [ ! -f "$state/pending.$name" ] && [ ! -f "$state/delivered_no_reply.$name" ] \
    || { keeper_lock_release; return 0; }
  if delivery_owned "$state" "$name"; then keeper_lock_release; return 0; fi
  session_json="$(curl -sf -m 4 "$DAEMON/v1/agent/sessions/$sid" 2>/dev/null || true)"
  active="$(printf '%s' "$session_json" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get("session", {}).get("active_turn")
    print("busy" if value else "idle")
except Exception:
    print("unknown")
' 2>/dev/null)"
  [ "$active" = "idle" ] || { keeper_lock_release; return 0; }

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
    # Persist the accepted wake before releasing the reservation. The next
    # keeper must observe this acceptance under the same lock.
    keeper_write_atomic "$state/keeper-last.$name" "$now" || {
      echo "seat-keeper: could not persist accepted wake for @$name" >&2
      failures=$((failures + 1))
      keeper_lock_release
      return 0
    }
    echo "seat-keeper: woke @$name ($state_parts)"
  else
    echo "seat-keeper: wake failed for @$name: $(printf '%s\n' "$output" | tail -1)" >&2
    failures=$((failures + 1))
  fi
  keeper_lock_release
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
    process_seat "$repo" "$pad" "$state" "$name" "$sid"
  done <<< "$roster"
done

[ "$failures" -eq 0 ]
