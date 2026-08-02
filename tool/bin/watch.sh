#!/usr/bin/env bash
# stitchpad watcher (daemon body). One fswatch on stitchpad.md. On every change:
#   - auto-commit to the isolated pad git
#   - for EACH roster member, if new lines address them (@name), fire their adapter
#
# Adapters live in ~/.stitchpad/adapters/<adapter>.sh and are called as:
#   adapter.sh <event> <to> <stitchpad.md> <task-text-file>
# where event = "mention". The adapter decides push (spawn) vs pull (flag/notify)
# vs trigger (claude.ai remote-trigger) using the wake mode passed via $SP_WAKE.
#
# BUG HISTORY: an earlier version let inner `read`s consume the fswatch pipe's
# stdin, corrupting variable names ("old<mojibake>: unbound variable"). Fixed by
# (1) snapshotting the roster into an array, (2) redirecting every inner command
# that could read stdin from /dev/null, and (3) feeding the fswatch loop a
# function that itself takes no stdin.
set -uo pipefail
_src="${BASH_SOURCE[0]}"; while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
BIN_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
source "$BIN_DIR/lib.sh"
sp_init_paths || { echo "no stitchpad"; exit 1; }

WATCH_LIBRARY_MODE="${STITCHPAD_WATCH_LIB_ONLY:-0}"
DELIVERY_WORKER_MODE=0
[ "${1:-}" = "--delivery-worker" ] && DELIVERY_WORKER_MODE=1

if [ "$WATCH_LIBRARY_MODE" != "1" ] && [ "$DELIVERY_WORKER_MODE" -eq 0 ]; then
  # Self-register: overwrite the lock pid file with MY real PID. The spawner
  # writes $! (subshell PID) as a placeholder, but the actual watcher process has
  # a different PID after exec. This is the authoritative registration.
  if [ -d "$PAD_STATE/watch.lock.d" ]; then
    echo $$ > "$PAD_STATE/watch.lock.d/pid"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PAD_STATE/watch.lock.d/ts"
  fi
  # Ensure lock cleanup on ANY watcher exit. Seat-worker locks have their own
  # owner-checked cleanup and must not disturb this singleton.
  trap 'rm -rf "$PAD_STATE/watch.lock.d" 2>/dev/null' EXIT INT TERM
fi

# Snapshot the roster once for startup diagnostics and pending-work recovery.
declare -a SEED=()
if [ "$WATCH_LIBRARY_MODE" != "1" ] && [ "$DELIVERY_WORKER_MODE" -eq 0 ]; then
  while IFS= read -r _l; do SEED+=("$_l"); done < <(sp_roster)
  echo "[stitchpad] watching $PAD_MD"
  for _m in "${SEED[@]}"; do
    IFS='|' read -r _name _adapter _wake _ <<< "$_m"
    [ -n "$_name" ] || continue
    echo "  · @$_name → adapter=$_adapter wake=$_wake"
  done
fi

fire_adapter() {
  local name="$1" adapter="$2" wake="$3" target="$4" ordinal="$5" ack_file="${6:-}"
  local script="$ADAPTER_DIR/$adapter.sh"
  if [ ! -f "$script" ]; then
    echo "[stitchpad] no adapter '$adapter' for @$name (looked in $ADAPTER_DIR)"; return 2
  fi
  local taskfile; taskfile="$(mktemp)"
  sp_message_ordinal "$ordinal" > "$taskfile"
  local rc=0
  # Per-agent force-wake: if .state/forcewake.<name> exists, bypass the adapter's
  # focus-guard for this agent (wake even when its window is focused). Used for the
  # orchestrator (randy), whose window is often the focused one the human is typing
  # in — without this, pad mentions to randy chronically defer and never land.
  local force=0
  [ -f "$PAD_STATE/forcewake.$name" ] && force=1
  SP_WAKE="$wake" SP_TARGET="$target" SP_PAD_DIR="$PAD_DIR" SP_PAD_MD="$PAD_MD" \
    SP_DELIVERY_ACK_FILE="$ack_file" STITCHPAD_FORCE_WAKE="$force" \
    bash "$script" mention "$name" "$PAD_MD" "$taskfile" </dev/null || rc=$?
  rm -f "$taskfile"
  # Return the adapter's exit code so the caller can distinguish DELIVERED (0) from
  # DEFERRED (3, focus-guard) or FAILED (1). Only a real delivery should consume the
  # gate (read-clears-gate); a defer must re-fire later, so it must NOT consume.
  [ "$rc" -ne 0 ] && echo "[stitchpad] adapter $adapter for @$name → exit $rc (not consuming gate)"
  return "$rc"
}

# ── Per-seat durable delivery supervisors ────────────────────────────
# One current assignment per push seat is enough: a newer directive supersedes
# an older one before submission. Pull seats remain owned by lifecycle hooks and
# never enter this queue.
delivery_pending_file() { echo "$PAD_STATE/delivery.$1.pending"; }
delivery_state_file() { echo "$PAD_STATE/delivery.$1.state"; }
delivery_generation_file() { echo "$PAD_STATE/delivery.$1.generation"; }
delivery_tombstone_file() { echo "$PAD_STATE/delivery.$1.tombstones"; }
delivery_worker_lock() { echo "$PAD_STATE/delivery.$1.worker.lock.d"; }
delivery_cancel_dir() { echo "$PAD_STATE/delivery.$1.cancel.$2"; }
delivery_turn_file() { echo "$PAD_STATE/delivery.$1.turn.$2"; }
delivery_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

delivery_write_state() {
  local name="$1" state="$2" generation="$3" ordinal="$4" message_id="$5"
  local task_id="$6" accepted_at="$7" started_at="${8:-}" completed_at="${9:-}"
  local error_at="${10:-}" error_code="${11:-}" turn_id="${12:-}" turn_status="${13:-}" file tmp
  file="$(delivery_state_file "$name")"
  tmp="$(mktemp "$PAD_STATE/.delivery-state.XXXXXX")"
  {
    printf 'state=%s\n' "$state"
    printf 'generation=%s\n' "$generation"
    printf 'ordinal=%s\n' "$ordinal"
    printf 'message_id=%s\n' "$message_id"
    printf 'task_id=%s\n' "$task_id"
    printf 'accepted_at=%s\n' "$accepted_at"
    printf 'started_at=%s\n' "$started_at"
    printf 'completed_at=%s\n' "$completed_at"
    printf 'error_at=%s\n' "$error_at"
    printf 'error_code=%s\n' "$error_code"
    printf 'turn_id=%s\n' "$turn_id"
    printf 'turn_status=%s\n' "$turn_status"
  } > "$tmp"
  mv "$tmp" "$file"
}

delivery_cancel_ocean_turn() {
  local name="$1" turn_id="$2" reason="$3" dir response http daemon_url lock attempts=0 rc=1
  [ -n "$turn_id" ] || return 0
  dir="$(delivery_cancel_dir "$name" "$turn_id")"
  mkdir -p "$dir"
  lock="$dir/attempt.lock.d"
  while ! mkdir "$lock" 2>/dev/null; do
    [ "$(cat "$dir/result" 2>/dev/null || true)" = canceled ] && return 0
    attempts=$((attempts + 1)); [ "$attempts" -lt 100 ] || return 1
    sleep 0.01
  done
  if [ "$(cat "$dir/result" 2>/dev/null || true)" = canceled ]; then
    rmdir "$lock"; return 0
  fi
  [ -f "$dir/reason" ] || printf '%s\n' "$reason" > "$dir/reason"
  printf '%s|%s\n' "$(delivery_now)" "$reason" >> "$dir/attempts"
  [ -f "$dir/requested_at" ] || printf '%s\n' "$(delivery_now)" > "$dir/requested_at"
  response="$dir/response"; daemon_url="${OCEAN_DAEMON_URL:-http://127.0.0.1:4780}"
  http="$(curl -sS -o "$response" -w '%{http_code}' -X POST \
    -H 'content-type: application/json' -d '{}' \
    "$daemon_url/v1/requests/$turn_id/cancel" 2>"$dir/error" || true)"
  printf '%s\n' "${http:-000}" > "$dir/http_status"
  case "$http" in
    2??) printf 'canceled\n' > "$dir/result"; rc=0 ;;
    *) printf 'cancel_error\n' > "$dir/result"; rc=1 ;;
  esac
  rmdir "$lock"
  return "$rc"
}

delivery_ocean_turn_status() {
  local target="$1" turn_id="$2" daemon_url body
  daemon_url="${OCEAN_DAEMON_URL:-http://127.0.0.1:4780}"
  body="$(curl -sf --max-time 3 "$daemon_url/v1/agent/sessions/$target" 2>/dev/null || true)"
  [ -n "$body" ] || { printf 'unknown\n'; return; }
  printf '%s' "$body" | python3 -c 'import json,sys
turn=sys.argv[1]
try:
    active=json.load(sys.stdin).get("session", {}).get("active_turn")
    if isinstance(active, dict):
        active=active.get("turn_id") or active.get("id") or active.get("request_id")
    if not active: print("finished")
    elif str(active)==turn: print("active")
    else: print("other")
except Exception: print("unknown")' "$turn_id" 2>/dev/null || printf 'unknown\n'
}

delivery_tombstone() {
  local name="$1" generation="$2" ordinal="$3" message_id="$4" task_id="$5"
  local reason="$6" task_status="${7:--}" turn_id="${8:--}" file lock tmp attempts=0
  file="$(delivery_tombstone_file "$name")"; lock="$file.lock.d"
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1)); [ "$attempts" -lt 100 ] || return 1
    sleep 0.01
  done
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$(delivery_now)" "$generation" "$ordinal" \
    "$message_id" "$task_id" "$reason" "$task_status" "$turn_id" >> "$file"
  tmp="$(mktemp "$PAD_STATE/.delivery-tombstone.XXXXXX")"
  tail -n 32 "$file" > "$tmp" && mv "$tmp" "$file"
  rmdir "$lock"
}

delivery_pending_matches() {
  local name="$1" generation="$2" ordinal="$3" message_id="$4"
  local file g o m _
  file="$(delivery_pending_file "$name")"; [ -f "$file" ] || return 1
  IFS='|' read -r g o m _ < "$file"
  [ "$g" = "$generation" ] && [ "$o" = "$ordinal" ] && [ "$m" = "$message_id" ]
}

delivery_advance_seen() {
  local name="$1" ordinal="$2" seen=0 tmp_seen
  [ -f "$PAD_STATE/seen.$name" ] && seen="$(cat "$PAD_STATE/seen.$name" 2>/dev/null || echo 0)"
  if [ "$ordinal" -gt "${seen:-0}" ] 2>/dev/null; then
    tmp_seen="$(mktemp "$PAD_STATE/.delivery-seen.XXXXXX")"
    printf '%s' "$ordinal" > "$tmp_seen" && mv "$tmp_seen" "$PAD_STATE/seen.$name"
  fi
}

delivery_task_valid() {
  local name="$1" task_id="$2" line status assignee
  DELIVERY_TASK_STATUS="-"; DELIVERY_TASK_REASON=""
  [ "$task_id" != "-" ] || return 0
  line="$(sp_tasks | awk -F'|' -v id="$task_id" '$1==id {print $3 "|" $5; exit}')"
  [ -n "$line" ] || return 0
  IFS='|' read -r status assignee <<< "$line"
  DELIVERY_TASK_STATUS="${status:--}"
  case "$(printf '%s' "$status" | tr 'A-Z' 'a-z')" in
    done|cancelled|canceled|closed)
      DELIVERY_TASK_REASON="task_terminal"; return 1 ;;
  esac
  if [ -n "$assignee" ] && [ "$(printf '%s' "$assignee" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" ]; then
    DELIVERY_TASK_REASON="task_reassigned"; return 1
  fi
  return 0
}

delivery_drop_current() {
  local name="$1" generation="$2" ordinal="$3" message_id="$4" task_id="$5"
  local accepted_at="$6" reason="$7" task_status="${8:--}" turn_id="${9:-}"
  delivery_tombstone "$name" "$generation" "$ordinal" "$message_id" "$task_id" "$reason" "$task_status" "$turn_id" || true
  if delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
    rm -f "$(delivery_pending_file "$name")"
    # Tombstoned current work is resolved work. Advance monotonically so a
    # canceled/reassigned directive is not rediscovered and re-tombstoned on
    # every later pad append. Never move a cursor backwards if a lifecycle hook
    # advanced it concurrently.
    delivery_advance_seen "$name" "$ordinal"
    delivery_write_state "$name" tombstoned "$generation" "$ordinal" "$message_id" "$task_id" \
      "$accepted_at" "" "" "$(delivery_now)" "$reason:$task_status" "$turn_id" canceled
  fi
}

delivery_validate_current() {
  local name="$1" generation="$2" ordinal="$3" message_id="$4" task_id="$5"
  local accepted_at="$6" seen=0 meta current_ordinal current_sender current_id current_task
  delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id" || return 1
  [ -f "$PAD_STATE/seen.$name" ] && seen="$(cat "$PAD_STATE/seen.$name" 2>/dev/null || echo 0)"
  meta="$(sp_current_to_meta "$name" "$seen" 2>/dev/null || true)"
  if [ -z "$meta" ]; then
    delivery_drop_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" "$accepted_at" no_current_directive
    return 1
  fi
  IFS='|' read -r current_ordinal current_sender current_id current_task <<< "$meta"
  if [ "$current_ordinal" != "$ordinal" ] || [ "$current_id" != "$message_id" ]; then
    delivery_drop_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" "$accepted_at" superseded_current
    return 1
  fi
  if ! delivery_task_valid "$name" "$task_id"; then
    delivery_drop_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" "$accepted_at" \
      "$DELIVERY_TASK_REASON" "$DELIVERY_TASK_STATUS"
    return 1
  fi
  return 0
}

delivery_worker_cleanup() {
  local name="$1" lock owner
  lock="$(delivery_worker_lock "$name")"
  owner="$(cat "$lock/pid" 2>/dev/null || true)"
  [ "$owner" = "$$" ] && rm -rf "$lock" 2>/dev/null || true
}

delivery_worker() {
  local name="$1" lock pending generation ordinal message_id task_id accepted_at adapter wake target
  local started rc retry_seconds="${SP_DELIVERY_RETRY_SECONDS:-2}"
  local turn_id turn_status meta current_ordinal current_sender current_id current_task ack_file tmp_turn
  lock="$(delivery_worker_lock "$name")"
  mkdir "$lock" 2>/dev/null || exit 0
  printf '%s' "$$" > "$lock/pid"
  # EXIT runs after this function's locals have gone out of scope, so retain the
  # seat name explicitly. Referring to local `$name` from the trap leaves every
  # successful/error worker lock behind and permanently wedges that seat.
  DELIVERY_WORKER_NAME="$name"
  trap 'delivery_worker_cleanup "$DELIVERY_WORKER_NAME"' EXIT
  trap 'delivery_worker_cleanup "$DELIVERY_WORKER_NAME"; exit 130' INT
  trap 'delivery_worker_cleanup "$DELIVERY_WORKER_NAME"; exit 143' TERM
  while :; do
    pending="$(delivery_pending_file "$name")"; [ -f "$pending" ] || break
    IFS='|' read -r generation ordinal message_id task_id accepted_at adapter wake target < "$pending"
    turn_id="$(cat "$(delivery_turn_file "$name" "$generation")" 2>/dev/null || true)"
    [ -n "$turn_id" ] && started="$(sed -n 's/^started_at=//p' "$(delivery_state_file "$name")" 2>/dev/null | tail -1)"

    # Ocean delivery is ack-first so the exact daemon turn remains cancellable.
    # A restarted worker resumes this branch from the durable turn file instead
    # of submitting a duplicate request.
    if [ "$adapter" = ocean ] && [ -n "$turn_id" ]; then
      if ! delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
        until delivery_cancel_ocean_turn "$name" "$turn_id" superseded_generation; do
          sleep "$retry_seconds"
        done
        continue
      fi
      if ! delivery_task_valid "$name" "$task_id"; then
        if ! delivery_cancel_ocean_turn "$name" "$turn_id" "$DELIVERY_TASK_REASON"; then
          delivery_write_state "$name" cancel_pending "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "" "$(delivery_now)" cancel_failed "$turn_id" active
          sleep "$retry_seconds"; continue
        fi
        delivery_drop_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
          "$accepted_at" "$DELIVERY_TASK_REASON" "$DELIVERY_TASK_STATUS" "$turn_id"
        rm -f "$(delivery_turn_file "$name" "$generation")"
        continue
      fi
      meta="$(sp_current_to_meta "$name" "$(cat "$PAD_STATE/seen.$name" 2>/dev/null || echo 0)" 2>/dev/null || true)"
      if [ -n "$meta" ]; then
        IFS='|' read -r current_ordinal current_sender current_id current_task <<< "$meta"
        if [ "$current_ordinal" != "$ordinal" ] || [ "$current_id" != "$message_id" ]; then
          if ! delivery_cancel_ocean_turn "$name" "$turn_id" superseded_current; then
            delivery_write_state "$name" cancel_pending "$generation" "$ordinal" "$message_id" "$task_id" \
              "$accepted_at" "$started" "" "$(delivery_now)" cancel_failed "$turn_id" active
            sleep "$retry_seconds"; continue
          fi
          delivery_drop_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" superseded_current "$current_ordinal" "$turn_id"
          rm -f "$(delivery_turn_file "$name" "$generation")"
          # The watcher may have observed the successor while cancel was
          # transiently unavailable and intentionally left the old generation
          # in place. Once cancellation succeeds, enqueue the still-current
          # successor here so it does not need an unrelated future pad write.
          delivery_enqueue "$name" "$adapter" "$wake" "$target"
          continue
        fi
      fi
      turn_status="$(delivery_ocean_turn_status "$target" "$turn_id")"
      case "$turn_status" in
        finished|other)
          if delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
            delivery_advance_seen "$name" "$ordinal"
            rm -f "$pending" "$(delivery_turn_file "$name" "$generation")"
            delivery_write_state "$name" completed "$generation" "$ordinal" "$message_id" "$task_id" \
              "$accepted_at" "$started" "$(delivery_now)" "" "" "$turn_id" finished
          fi
          ;;
        active)
          delivery_write_state "$name" in_flight "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "" "" "" "$turn_id" active
          sleep "${SP_DELIVERY_POLL_SECONDS:-0.2}"
          ;;
        *)
          delivery_write_state "$name" in_flight "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "" "$(delivery_now)" status_unknown "$turn_id" unknown
          sleep "$retry_seconds"
          ;;
      esac
      continue
    fi

    if ! delivery_validate_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" "$accepted_at"; then
      continue
    fi
    started="$(delivery_now)"
    delivery_write_state "$name" started "$generation" "$ordinal" "$message_id" "$task_id" "$accepted_at" "$started"
    rc=0
    ack_file=""
    [ "$adapter" = ocean ] && ack_file="$(mktemp "$PAD_STATE/.delivery-ocean-ack.XXXXXX")"
    fire_adapter "$name" "$adapter" "$wake" "$target" "$ordinal" "$ack_file" || rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ "$adapter" = ocean ]; then
        turn_id="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("turn_id", ""))
except Exception: print("")' "$ack_file" 2>/dev/null)"
        rm -f "$ack_file"
        if [ -z "$turn_id" ]; then
          delivery_write_state "$name" error "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "" "$(delivery_now)" missing_turn_id
          break
        fi
        tmp_turn="$(mktemp "$PAD_STATE/.delivery-turn.XXXXXX")"
        printf '%s' "$turn_id" > "$tmp_turn" && mv "$tmp_turn" "$(delivery_turn_file "$name" "$generation")"
        if ! delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
          until delivery_cancel_ocean_turn "$name" "$turn_id" superseded_after_accept; do
            sleep "$retry_seconds"
          done
          continue
        fi
        delivery_write_state "$name" in_flight "$generation" "$ordinal" "$message_id" "$task_id" \
          "$accepted_at" "$started" "" "" "" "$turn_id" accepted
        continue
      fi
      # A newer generation or terminal task may have landed while the adapter
      # was running. Never let the old completion consume the newer directive.
      if ! delivery_validate_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" "$accepted_at"; then
        continue
      fi
      delivery_advance_seen "$name" "$ordinal"
      if delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
        rm -f "$pending"
        delivery_write_state "$name" completed "$generation" "$ordinal" "$message_id" "$task_id" \
          "$accepted_at" "$started" "$(delivery_now)"
      fi
      continue
    fi
    [ -n "$ack_file" ] && rm -f "$ack_file"
    if [ "$rc" -eq 3 ]; then
      # The adapter response belongs to the submitted generation. If a newer
      # generation arrived while it was running, loop directly to that work
      # instead of overwriting its accepted state with stale busy metadata.
      delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id" || continue
      delivery_write_state "$name" busy "$generation" "$ordinal" "$message_id" "$task_id" \
        "$accepted_at" "$started" "" "$(delivery_now)" busy
      sleep "$retry_seconds"
      continue
    fi
    # Hard adapter failure is durable and leaves the pending generation intact.
    # A watcher restart (or explicit enqueue of the same current directive)
    # supervises it again without losing or duplicating the assignment.
    if delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
      delivery_write_state "$name" error "$generation" "$ordinal" "$message_id" "$task_id" \
        "$accepted_at" "$started" "" "$(delivery_now)" "adapter_exit_$rc"
      break
    fi
    # A newer accepted generation now owns the same singleton. Keep supervising
    # it; exiting here would strand it until an unrelated pad write or restart.
    continue
  done
}

delivery_start_worker() {
  local name="$1" lock pid
  lock="$(delivery_worker_lock "$name")"
  if [ -d "$lock" ]; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    rm -rf "$lock" 2>/dev/null || true
  fi
  STITCHPAD_PAD_DIR="$PAD_DIR" SP_DELIVERY_RETRY_SECONDS="${SP_DELIVERY_RETRY_SECONDS:-2}" \
    bash "$BIN_DIR/watch.sh" --delivery-worker "$name" </dev/null \
      >> "$PAD_STATE/delivery.$name.log" 2>&1 &
}

delivery_enqueue() {
  local name="$1" adapter="$2" wake="$3" target="$4" seen=0 meta ordinal sender message_id task_id
  local pending old_generation old_ordinal old_message old_task old_accepted old_adapter old_wake old_target
  local old_turn generation accepted tmp
  # Preserve an unresolved pre-supervisor terminal-delivery recovery stamp during
  # rolling upgrades. Its Stop hook still owns that accepted turn; enqueueing a
  # newer generation here could present work over a turn that may already have
  # run. Ocean's daemon acceptance never used this shell recovery contract, and
  # old Ocean stamps are known replay hazards, so retain its established cleanup.
  if [ "$adapter" = ocean ]; then
    rm -f "$PAD_STATE/pending.$name" "$PAD_STATE/delivered_no_reply.$name" 2>/dev/null || true
  elif [ -f "$PAD_STATE/pending.$name" ]; then
    local legacy_pending
    legacy_pending="$(cat "$PAD_STATE/pending.$name" 2>/dev/null || echo 0)"
    if [ "${legacy_pending:-0}" -gt 0 ] 2>/dev/null; then
      echo "[stitchpad] deferring @$name — pending recovery target (ordinal $legacy_pending) unresolved" >&2
      return 0
    fi
  fi
  [ -f "$PAD_STATE/seen.$name" ] && seen="$(cat "$PAD_STATE/seen.$name" 2>/dev/null || echo 0)"
  meta="$(sp_current_to_meta "$name" "$seen" 2>/dev/null || true)"
  pending="$(delivery_pending_file "$name")"
  if [ -z "$meta" ]; then
    [ -f "$pending" ] && delivery_start_worker "$name"
    return 0
  fi
  IFS='|' read -r ordinal sender message_id task_id <<< "$meta"
  if [ -f "$pending" ]; then
    IFS='|' read -r old_generation old_ordinal old_message old_task old_accepted old_adapter old_wake old_target < "$pending"
    old_turn="$(cat "$(delivery_turn_file "$name" "$old_generation")" 2>/dev/null || true)"
    if [ "$old_ordinal" = "$ordinal" ] && [ "$old_message" = "$message_id" ]; then
      if ! delivery_task_valid "$name" "$old_task"; then
        if [ "$old_adapter" = ocean ] && ! delivery_cancel_ocean_turn "$name" "$old_turn" "$DELIVERY_TASK_REASON"; then
          delivery_start_worker "$name"; return 0
        fi
        delivery_drop_current "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
          "$old_accepted" "$DELIVERY_TASK_REASON" "$DELIVERY_TASK_STATUS" "$old_turn"
        rm -f "$(delivery_turn_file "$name" "$old_generation")"
        return 0
      fi
      delivery_start_worker "$name"; return 0
    fi
    if [ "$old_adapter" = ocean ] && [ -n "$old_turn" ]; then
      if ! delivery_cancel_ocean_turn "$name" "$old_turn" superseded_by_newer; then
        delivery_start_worker "$name"; return 0
      fi
    fi
    delivery_tombstone "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
      superseded_by_newer "$ordinal" "$old_turn" || true
    rm -f "$(delivery_turn_file "$name" "$old_generation")"
  fi
  generation=1
  [ -f "$(delivery_generation_file "$name")" ] && generation=$(( $(cat "$(delivery_generation_file "$name")" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$generation" > "$(delivery_generation_file "$name")"
  accepted="$(delivery_now)"
  tmp="$(mktemp "$PAD_STATE/.delivery-pending.XXXXXX")"
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$generation" "$ordinal" "$message_id" "$task_id" \
    "$accepted" "$adapter" "$wake" "$target" > "$tmp"
  mv "$tmp" "$pending"
  delivery_write_state "$name" accepted "$generation" "$ordinal" "$message_id" "$task_id" "$accepted"
  delivery_start_worker "$name"
}

# react() takes NO stdin — everything inside redirects from /dev/null where it
# might otherwise read the fswatch pipe.
react() {
  # KEEP-ALIVE self-exit — SAFE version. The earlier logic suicided whenever no
  # FRESH heartbeat existed, which killed working pads whose agents predate the
  # ticker (ocean-os, stitchpad-live both died this way). Corrected rule:
  #   - If there are NO alive.* files at all → heartbeat system isn't populated for
  #     this pad → DO NOT exit (absent ≠ dead). Keep running; agents still wake.
  #   - Only exit if heartbeats EXIST but every one is stale/dead.
  shopt -s nullglob 2>/dev/null || true
  local _hearts=( "$PAD_STATE"/alive.* )
  if [ "${#_hearts[@]}" -gt 0 ]; then
    local _any_alive=0
    for _heart in "${_hearts[@]}"; do
      [ -f "$_heart" ] || continue
      local _hts _hpid _hage
      _hts=$(stat -f %m "$_heart" 2>/dev/null || stat -c %Y "$_heart" 2>/dev/null || echo 0)
      _hage=$(( $(date +%s) - _hts ))
      [ "$_hage" -lt 90 ] || continue
      _hpid=$(grep -o '"pid":[0-9]*' "$_heart" 2>/dev/null | head -1 | cut -d: -f2)
      # a heartbeat with no pid still counts as alive if its mtime is fresh
      if [ -z "$_hpid" ] || kill -0 "$_hpid" 2>/dev/null; then _any_alive=1; break; fi
    done
    if [ "$_any_alive" -eq 0 ]; then
      echo "[stitchpad] all heartbeats stale — watcher exiting"
      rm -rf "$PAD_STATE/watch.lock.d" 2>/dev/null || true
      exit 0
    fi
  fi
  # else: no heartbeat files → system not in use here → keep watching (safe default)

  # An outer-repo `git stash -u` can briefly remove an unignored pad file. Never
  # commit that transient deletion or process a headerless recreation: either
  # would erase the roster and make @mentions disappear. The init/path guards
  # now ignore the whole pad, but this keeps older pads fail-closed too.
  if [ ! -f "$PAD_MD" ] || ! grep -q '^```roster[[:space:]]*$' "$PAD_MD" 2>/dev/null; then
    echo "[stitchpad] pad missing roster — skipping commit and wake cycle"
    return 0
  fi

  sp_commit "update ($(date '+%H:%M:%S'))"
  local -a members=()
  local rline
  while IFS= read -r rline; do members+=("$rline"); done < <(sp_roster)
  local m name adapter wake target
  for m in "${members[@]}"; do
    IFS='|' read -r name adapter wake target <<< "$m"
    [ -n "$name" ] || continue
    # `pull` means the runtime's real lifecycle hook owns delivery. Never spawn
    # an external adapter for it: that creates a hidden second agent lane and
    # makes the operator's visible terminal cease to be the source of truth.
    # The watcher exists only for explicit push targets (Herdr/Ocean).
    [ "$wake" = "pull" ] && continue
    # Enqueue and continue immediately. A singleton supervisor for this seat
    # performs validation, adapter work, busy retry and completion independently,
    # so a ten-minute Ocean turn cannot block any other roster member.
    delivery_enqueue "$name" "$adapter" "$wake" "$target"
  done
}

# Trap errors in the main loop so the watcher doesn't die on a single adapter failure.
trap 'echo "[stitchpad] watcher error at line $LINENO — continuing" >&2' ERR

if [ "$WATCH_LIBRARY_MODE" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

if [ "$DELIVERY_WORKER_MODE" -eq 1 ]; then
  delivery_worker "${2:?missing delivery seat}"
  exit $?
fi

# Recover accepted/busy/error work once at watcher start. Only current pending
# generations are considered; completed history and tombstones are never replayed.
for _m in "${SEED[@]}"; do
  IFS='|' read -r _name _adapter _wake _target <<< "$_m"
  [ -n "$_name" ] && [ "$_wake" != "pull" ] && [ -f "$(delivery_pending_file "$_name")" ] \
    && delivery_start_worker "$_name"
done

fswatch -0 "$PAD_MD" | while read -r -d "" _ev; do react </dev/null; done
