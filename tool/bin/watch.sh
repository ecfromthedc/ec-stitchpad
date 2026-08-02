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
    bash "$script" mention "$name" "$PAD_MD" "$taskfile" </dev/null &
  DELIVERY_ADAPTER_PID=$!
  wait "$DELIVERY_ADAPTER_PID" || rc=$?
  DELIVERY_ADAPTER_PID=""
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
delivery_successor_file() { echo "$PAD_STATE/delivery.$1.successor"; }
delivery_state_file() { echo "$PAD_STATE/delivery.$1.state"; }
delivery_generation_file() { echo "$PAD_STATE/delivery.$1.generation"; }
delivery_tombstone_file() { echo "$PAD_STATE/delivery.$1.tombstones"; }
delivery_worker_lock() { echo "$PAD_STATE/delivery.$1.worker.lock.d"; }
delivery_cancel_dir() { echo "$PAD_STATE/delivery.$1.cancel.$2"; }
delivery_turn_file() { echo "$PAD_STATE/delivery.$1.turn.$2"; }
delivery_ack_file() { echo "$PAD_STATE/delivery.$1.ack.$2.json"; }
delivery_submit_file() { echo "$PAD_STATE/delivery.$1.submit.$2"; }
delivery_keeper_reservation() { echo "$PAD_STATE/delivery.$1.keeper-reservation"; }
delivery_keeper_invalid() { echo "$PAD_STATE/delivery.$1.keeper-reservation.invalid"; }
delivery_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

delivery_process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

delivery_parse_ocean_ack() {
  local file="$1" target="$2"
  python3 -c 'import json,sys
try:
 d=json.load(open(sys.argv[1])); turn=d.get("turn_id", ""); sid=d.get("session_id")
 valid=d.get("ok") is True and isinstance(turn,str) and bool(turn.strip())
 valid=valid and (sid is None or str(sid)==sys.argv[2])
 print(turn.strip() if valid else "")
except Exception: print("")' "$file" "$target" 2>/dev/null
}

delivery_report_invalid_keeper() {
  local name="$1" reason="$2" raw="$3" file tmp digest
  file="$(delivery_keeper_invalid "$name")"
  digest="$(printf '%s' "$raw" | cksum | awk '{print $1 ":" $2}')"
  tmp="$(mktemp "$PAD_STATE/.delivery-keeper-invalid.XXXXXX")" || return 1
  {
    printf 'detected_at=%s\n' "$(delivery_now)"
    printf 'reason=%s\n' "$reason"
    printf 'record_cksum=%s\n' "$digest"
  } > "$tmp" && mv "$tmp" "$file"
  echo "[stitchpad] refusing watcher admission for @$name — malformed keeper reservation ($reason)" >&2
}

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
  local cancel_state terminal token epoch claim claim_base nested owner pid pstart live_start born age
  local poll_attempts poll_seconds poll_deadline cancel_deadline_seconds lock_attempts lock_sleep stale_path
  DELIVERY_CANCEL_OUTCOME=none
  [ -n "$turn_id" ] || { DELIVERY_CANCEL_OUTCOME=no_turn; return 0; }
  if [ -L "$PAD_STATE" ]; then
    DELIVERY_CANCEL_OUTCOME=pending
    echo "[stitchpad] refusing Ocean cancel through symlinked pad state: $PAD_STATE" >&2
    return 1
  fi
  case "$name:$turn_id" in
    *[!A-Za-z0-9_:-]*)
      DELIVERY_CANCEL_OUTCOME=pending
      echo "[stitchpad] refusing unsafe Ocean cancel identity: $name/$turn_id" >&2
      return 1 ;;
  esac
  dir="$(delivery_cancel_dir "$name" "$turn_id")"
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
    DELIVERY_CANCEL_OUTCOME=pending
    echo "[stitchpad] refusing unsafe Ocean cancel directory: $dir" >&2
    return 1
  fi
  mkdir "$dir" 2>/dev/null || [ -d "$dir" ] || { DELIVERY_CANCEL_OUTCOME=pending; return 1; }
  case "$(cd -P "$dir" 2>/dev/null && pwd)" in
    "$(cd -P "$PAD_STATE" 2>/dev/null && pwd)"/delivery.*.cancel.*) ;;
    *) DELIVERY_CANCEL_OUTCOME=pending; echo "[stitchpad] Ocean cancel directory escaped pad state" >&2; return 1 ;;
  esac
  for response in reason attempts requested_at response error http_status result attempt.lock.d; do
    if [ -L "$dir/$response" ]; then
      DELIVERY_CANCEL_OUTCOME=pending
      echo "[stitchpad] refusing symlinked Ocean cancel state: $dir/$response" >&2
      return 1
    fi
  done
  lock="$dir/attempt.lock.d"
  token="$(date +%s)-$$-$RANDOM-$RANDOM"; epoch="$(date +%s)"
  lock_attempts="${SP_DELIVERY_CANCEL_LOCK_ATTEMPTS:-500}"
  case "$lock_attempts" in ''|*[!0-9]*) lock_attempts=500;; esac
  lock_sleep="${SP_DELIVERY_CANCEL_LOCK_SLEEP_SECONDS:-0.01}"
  claim="$dir/attempt.claim.$token.d"; claim_base="${claim##*/}"
  mkdir "$claim" || return 1
  pstart="$(delivery_process_start "$$")"
  [ -n "$pstart" ] || { rm -rf "$claim"; return 1; }
  printf '%s|%s|%s|%s\n' "$$" "$pstart" "$token" "$epoch" > "$claim/owner"
  while :; do
    if mv "$claim" "$lock" 2>/dev/null; then
      if [ "$(cut -d'|' -f3 "$lock/owner" 2>/dev/null || true)" = "$token" ]; then break; fi
      # Another owner won between our inspection and rename; mv placed our
      # complete candidate inside its directory. Remove only our tokened child,
      # rebuild it, and keep waiting.
      nested="$lock/$claim_base"
      [ "$(cut -d'|' -f3 "$nested/owner" 2>/dev/null || true)" = "$token" ] && rm -rf "$nested"
      mkdir "$claim" || return 1
      printf '%s|%s|%s|%s\n' "$$" "$pstart" "$token" "$epoch" > "$claim/owner"
    fi
    case "$(cat "$dir/result" 2>/dev/null || true)" in
      canceled|cancelled) DELIVERY_CANCEL_OUTCOME=cancelled; rm -rf "$claim"; return 0;;
      completed) DELIVERY_CANCEL_OUTCOME=completed; rm -rf "$claim"; return 0;;
      errored) DELIVERY_CANCEL_OUTCOME=errored; rm -rf "$claim"; return 0;;
    esac
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    born="$(cat "$lock/born" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)"
    IFS='|' read -r pid pstart _ _ <<< "$owner"
    live_start="$(delivery_process_start "$pid")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -n "$pstart" ] && [ "$live_start" = "$pstart" ]; then
      attempts=$((attempts + 1)); [ "$attempts" -lt "$lock_attempts" ] || { rm -rf "$claim"; return 1; }
      sleep "$lock_sleep"; continue
    fi
    age=$(( $(date +%s) - ${born:-0} ))
    if [ -z "$owner" ] && [ "$age" -lt 5 ]; then
      attempts=$((attempts + 1)); [ "$attempts" -lt "$lock_attempts" ] || { rm -rf "$claim"; return 1; }
      sleep "$lock_sleep"; continue
    fi
    stale_path="$dir/attempt.stale.$token"
    if mv "$lock" "$stale_path" 2>/dev/null; then
      # Claims are renamed only after their complete immutable owner record is
      # written, so an invalid identity cannot become live after this check.
      rm -rf "$stale_path"
    fi
  done
  case "$(cat "$dir/result" 2>/dev/null || true)" in
    canceled|cancelled) DELIVERY_CANCEL_OUTCOME=cancelled ;;
    completed) DELIVERY_CANCEL_OUTCOME=completed ;;
    errored) DELIVERY_CANCEL_OUTCOME=errored ;;
  esac
  if [ "$DELIVERY_CANCEL_OUTCOME" != none ]; then
    [ "$(cut -d'|' -f3 "$lock/owner" 2>/dev/null || true)" = "$token" ] && rm -rf "$lock"
    return 0
  fi
  [ -f "$dir/reason" ] || printf '%s\n' "$reason" > "$dir/reason"
  printf '%s|%s\n' "$(delivery_now)" "$reason" >> "$dir/attempts"
  [ -f "$dir/requested_at" ] || printf '%s\n' "$(delivery_now)" > "$dir/requested_at"
  response="$dir/response"; daemon_url="${OCEAN_DAEMON_URL:-http://127.0.0.1:4780}"
  cancel_deadline_seconds="${SP_DELIVERY_CANCEL_DEADLINE_SECONDS:-8}"
  case "$cancel_deadline_seconds" in ''|*[!0-9]*) cancel_deadline_seconds=8;; esac
  poll_deadline=$(( $(date +%s) + cancel_deadline_seconds ))
  http="$(curl -sS --connect-timeout 2 --max-time 5 -o "$response" -w '%{http_code}' -X POST \
    -H 'content-type: application/json' -d '{}' \
    "$daemon_url/v1/requests/$turn_id/cancel" 2>"$dir/error" || true)"
  printf '%s\n' "${http:-000}" > "$dir/http_status"
  cancel_state="$(python3 -c 'import json,sys
try:
 d=json.load(open(sys.argv[1])); print(str(d.get("state", "")).lower() if d.get("ok") is True else "rejected")
except Exception: print("invalid")' "$response" 2>/dev/null)"
  case "$http:$cancel_state" in
    2??:cancelled) terminal=cancelled ;;
    2??:cancelling) terminal=cancelling ;;
    *) terminal="$(delivery_ocean_turn_status "" "$turn_id")" ;;
  esac
  poll_attempts="${SP_DELIVERY_CANCEL_POLL_ATTEMPTS:-100}"
  poll_seconds="${SP_DELIVERY_CANCEL_POLL_SECONDS:-0.05}"
  attempts=0
  while :; do
    case "$terminal" in
      completed|errored|cancelled)
        printf '%s\n' "$terminal" > "$dir/result"; DELIVERY_CANCEL_OUTCOME="$terminal"; rc=0; break ;;
    esac
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$poll_attempts" ] || [ "$(date +%s)" -ge "$poll_deadline" ]; then
      printf 'cancel_pending\n' > "$dir/result"; DELIVERY_CANCEL_OUTCOME=pending; rc=1; break
    fi
    sleep "$poll_seconds"
    terminal="$(delivery_ocean_turn_status "" "$turn_id")"
  done
  [ "$(cut -d'|' -f3 "$lock/owner" 2>/dev/null || true)" = "$token" ] && rm -rf "$lock"
  return "$rc"
}

delivery_ocean_turn_status() {
  local target="$1" turn_id="$2" daemon_url body
  daemon_url="${OCEAN_DAEMON_URL:-http://127.0.0.1:4780}"
  body="$(curl -sf --max-time 3 "$daemon_url/v1/requests" 2>/dev/null || true)"
  [ -n "$body" ] || { printf 'unknown\n'; return; }
  printf '%s' "$body" | python3 -c 'import json,sys
turn=sys.argv[1]
try:
    body=json.load(sys.stdin)
    rows=body.get("requests", []) if body.get("ok") is True else []
    hit=next((r for r in rows if str(r.get("request_id", "")) == turn), None)
    print(str(hit.get("state", "unknown")).lower() if hit else "missing")
except Exception: print("unknown")' "$turn_id" 2>/dev/null || printf 'unknown\n'
}

delivery_ocean_reconcile_attempt() {
  local target="$1" attempted_at="$2" daemon_url body
  daemon_url="${OCEAN_DAEMON_URL:-http://127.0.0.1:4780}"
  body="$(curl -sf --max-time 3 "$daemon_url/v1/requests" 2>/dev/null || true)"
  [ -n "$body" ] || { printf 'unknown\n'; return; }
  printf '%s' "$body" | python3 -c 'import json,sys
sid,started=sys.argv[1:3]
try:
 d=json.load(sys.stdin)
 if d.get("ok") is not True: print("unknown"); raise SystemExit
 rows=[r for r in d.get("requests",[]) if str(r.get("session_id",""))==sid and str(r.get("started_at", ""))>=started]
 print("none" if len(rows)==0 else "unknown")
except Exception: print("unknown")' "$target" "$attempted_at" 2>/dev/null || printf 'unknown\n'
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
  local turn_status="${10:-cancelled}"
  delivery_tombstone "$name" "$generation" "$ordinal" "$message_id" "$task_id" "$reason" "$task_status" "$turn_id" || true
  if delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
    rm -f "$(delivery_pending_file "$name")"
    delivery_write_state "$name" tombstoned "$generation" "$ordinal" "$message_id" "$task_id" \
      "$accepted_at" "" "" "$(delivery_now)" "$reason:$task_status" "$turn_id" "$turn_status"
    [ -f "$(delivery_successor_file "$name")" ] \
      && mv "$(delivery_successor_file "$name")" "$(delivery_pending_file "$name")"
  fi
}

delivery_finalize_completed() {
  local name="$1" generation="$2" ordinal="$3" message_id="$4" task_id="$5"
  local accepted_at="$6" started_at="$7" turn_id="$8" reason="${9:-}"
  local error_code=""
  if delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
    delivery_advance_seen "$name" "$ordinal"
    rm -f "$(delivery_pending_file "$name")" "$(delivery_turn_file "$name" "$generation")" \
      "$(delivery_ack_file "$name" "$generation")" "$(delivery_submit_file "$name" "$generation")"
    [ -n "$reason" ] && error_code="completed_after_cancel:$reason"
    delivery_write_state "$name" completed "$generation" "$ordinal" "$message_id" "$task_id" \
      "$accepted_at" "$started_at" "$(delivery_now)" "" "$error_code" "$turn_id" completed
    DELIVERY_ACTIVE_TURN=""
    return 0
  fi
  # A stale generation may finish while a successor is current. Remove only
  # generation-bound evidence; never consume or overwrite the successor.
  rm -f "$(delivery_turn_file "$name" "$generation")" \
    "$(delivery_ack_file "$name" "$generation")" "$(delivery_submit_file "$name" "$generation")"
  return 1
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
  local name="$1" token="$2" lock owner
  lock="$(delivery_worker_lock "$name")"
  owner="$(cat "$lock/token" 2>/dev/null || true)"
  [ "$owner" = "$token" ] && rm -rf "$lock" 2>/dev/null || true
}

delivery_worker_signal() {
  local code="$1" ack_turn=""
  if [ -n "${DELIVERY_ADAPTER_PID:-}" ]; then
    pkill -TERM -P "$DELIVERY_ADAPTER_PID" 2>/dev/null || true
    kill "$DELIVERY_ADAPTER_PID" 2>/dev/null || true
  fi
  if [ "${DELIVERY_ACTIVE_ADAPTER:-}" = ocean ] && [ -z "${DELIVERY_ACTIVE_TURN:-}" ] \
     && [ -n "${DELIVERY_ACTIVE_GENERATION:-}" ]; then
    ack_turn="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("turn_id", ""))
except Exception: print("")' "$(delivery_ack_file "$DELIVERY_WORKER_NAME" "$DELIVERY_ACTIVE_GENERATION")" 2>/dev/null)"
  fi
  if [ "${DELIVERY_ACTIVE_ADAPTER:-}" = ocean ] && [ -n "${DELIVERY_ACTIVE_TURN:-$ack_turn}" ]; then
    delivery_cancel_ocean_turn "$DELIVERY_WORKER_NAME" "${DELIVERY_ACTIVE_TURN:-$ack_turn}" operator_stop || true
  fi
  delivery_worker_cleanup "$DELIVERY_WORKER_NAME" "$DELIVERY_WORKER_TOKEN"
  exit "$code"
}

delivery_worker() {
  local name="$1" token="$2" lock pending generation ordinal message_id task_id accepted_at adapter wake target
  local started rc retry_seconds="${SP_DELIVERY_RETRY_SECONDS:-2}"
  local turn_id turn_status meta current_ordinal current_sender current_id current_task ack_file tmp_turn
  local attempt_at reconcile acked_turn owner_tmp process_start
  lock="$(delivery_worker_lock "$name")"
  [ "$(cat "$lock/token" 2>/dev/null || true)" = "$token" ] || exit 0
  [ ! -f "$lock/stop-requested" ] || exit 0
  process_start="$(delivery_process_start "$$")"
  [ -n "$process_start" ] || { delivery_worker_cleanup "$name" "$token"; exit 1; }
  owner_tmp="$(mktemp "$PAD_STATE/.delivery-worker-owner.XXXXXX")"
  printf '%s|%s|%s|%s|%s\n' "$$" "$process_start" "$token" "$PAD_DIR" "$name" > "$owner_tmp"
  [ "$(cat "$lock/token" 2>/dev/null || true)" = "$token" ] && [ ! -f "$lock/stop-requested" ] \
    && mv "$owner_tmp" "$lock/owner" || { rm -f "$owner_tmp"; exit 0; }
  printf '%s' "$$" > "$lock/pid"
  # EXIT runs after this function's locals have gone out of scope, so retain the
  # seat name explicitly. Referring to local `$name` from the trap leaves every
  # successful/error worker lock behind and permanently wedges that seat.
  DELIVERY_WORKER_NAME="$name"
  DELIVERY_WORKER_TOKEN="$token"
  trap 'delivery_worker_cleanup "$DELIVERY_WORKER_NAME" "$DELIVERY_WORKER_TOKEN"' EXIT
  trap 'delivery_worker_signal 130' INT
  trap 'delivery_worker_signal 143' TERM
  while :; do
    pending="$(delivery_pending_file "$name")"; [ -f "$pending" ] || break
    IFS='|' read -r generation ordinal message_id task_id accepted_at adapter wake target < "$pending"
    turn_id="$(cat "$(delivery_turn_file "$name" "$generation")" 2>/dev/null || true)"
    DELIVERY_ACTIVE_ADAPTER="$adapter"; DELIVERY_ACTIVE_TURN="$turn_id"
    DELIVERY_ACTIVE_GENERATION="$generation"
    if [ "$adapter" = ocean ] && [ -z "$turn_id" ] && [ -s "$(delivery_ack_file "$name" "$generation")" ]; then
      turn_id="$(delivery_parse_ocean_ack "$(delivery_ack_file "$name" "$generation")" "$target")"
      if [ -n "$turn_id" ]; then
        printf '%s' "$turn_id" > "$(delivery_turn_file "$name" "$generation")"
        rm -f "$(delivery_submit_file "$name" "$generation")"
        continue
      fi
    fi
    if [ "$adapter" = ocean ] && [ -z "$turn_id" ] && [ -f "$(delivery_submit_file "$name" "$generation")" ]; then
      attempt_at="$(cut -d'|' -f1 "$(delivery_submit_file "$name" "$generation")")"
      reconcile="$(delivery_ocean_reconcile_attempt "$target" "$attempt_at")"
      case "$reconcile" in
        none) rm -f "$(delivery_submit_file "$name" "$generation")" "$(delivery_ack_file "$name" "$generation")" ;;
        *)
          delivery_write_state "$name" acceptance_unknown "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "" "" "$(delivery_now)" ack_incomplete
          break ;;
      esac
    fi
    [ -n "$turn_id" ] && started="$(sed -n 's/^started_at=//p' "$(delivery_state_file "$name")" 2>/dev/null | tail -1)"
    if sp_dnd_is_on "$name"; then
      if [ "$adapter" = ocean ] && [ -n "$turn_id" ]; then
        if ! delivery_cancel_ocean_turn "$name" "$turn_id" dnd; then
          delivery_write_state "$name" cancel_pending "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "" "$(delivery_now)" cancel_failed "$turn_id" active
          sleep "$retry_seconds"; continue
        fi
        case "$DELIVERY_CANCEL_OUTCOME" in
          completed)
            delivery_finalize_completed "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
              "$accepted_at" "$started" "$turn_id" dnd || true
            continue ;;
          errored)
            delivery_write_state "$name" errored "$generation" "$ordinal" "$message_id" "$task_id" \
              "$accepted_at" "$started" "" "$(delivery_now)" turn_errored "$turn_id" errored
            break ;;
          cancelled)
            rm -f "$(delivery_turn_file "$name" "$generation")" \
              "$(delivery_ack_file "$name" "$generation")" "$(delivery_submit_file "$name" "$generation")"
            DELIVERY_ACTIVE_TURN="" ;;
          *) sleep "$retry_seconds"; continue ;;
        esac
      fi
      delivery_write_state "$name" deferred_dnd "$generation" "$ordinal" "$message_id" "$task_id" \
        "$accepted_at" "" "" "" dnd "$turn_id" deferred
      sleep "${SP_DELIVERY_POLL_SECONDS:-0.2}"
      continue
    fi

    # Ocean delivery is ack-first so the exact daemon turn remains cancellable.
    # A restarted worker resumes this branch from the durable turn file instead
    # of submitting a duplicate request.
    if [ "$adapter" = ocean ] && [ -n "$turn_id" ]; then
      if ! delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
        until delivery_cancel_ocean_turn "$name" "$turn_id" superseded_generation; do
          sleep "$retry_seconds"
        done
        case "$DELIVERY_CANCEL_OUTCOME" in
          completed) delivery_finalize_completed "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "$turn_id" superseded_generation || true ;;
          cancelled|errored) rm -f "$(delivery_turn_file "$name" "$generation")" \
            "$(delivery_ack_file "$name" "$generation")" "$(delivery_submit_file "$name" "$generation")" ;;
        esac
        continue
      fi
      if ! delivery_task_valid "$name" "$task_id"; then
        if ! delivery_cancel_ocean_turn "$name" "$turn_id" "$DELIVERY_TASK_REASON"; then
          delivery_write_state "$name" cancel_pending "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "" "$(delivery_now)" cancel_failed "$turn_id" active
          sleep "$retry_seconds"; continue
        fi
        case "$DELIVERY_CANCEL_OUTCOME" in
          completed)
            delivery_finalize_completed "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
              "$accepted_at" "$started" "$turn_id" "$DELIVERY_TASK_REASON" || true
            continue ;;
          errored)
            delivery_drop_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
              "$accepted_at" "$DELIVERY_TASK_REASON" "$DELIVERY_TASK_STATUS" "$turn_id" errored ;;
          cancelled)
            delivery_drop_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
              "$accepted_at" "$DELIVERY_TASK_REASON" "$DELIVERY_TASK_STATUS" "$turn_id" cancelled ;;
        esac
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
          case "$DELIVERY_CANCEL_OUTCOME" in
            completed)
              delivery_finalize_completed "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
                "$accepted_at" "$started" "$turn_id" superseded_current || true ;;
            errored)
              delivery_drop_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
                "$accepted_at" superseded_current "$current_ordinal" "$turn_id" errored ;;
            cancelled)
              delivery_drop_current "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
                "$accepted_at" superseded_current "$current_ordinal" "$turn_id" cancelled ;;
          esac
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
        completed)
          delivery_finalize_completed "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "$turn_id" || true
          ;;
        queued|running|waiting_for_permission|cancelling)
          delivery_write_state "$name" in_flight "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "" "" "" "$turn_id" "$turn_status"
          sleep "${SP_DELIVERY_POLL_SECONDS:-0.2}"
          ;;
        errored|cancelled)
          delivery_write_state "$name" "$turn_status" "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "" "$(delivery_now)" "turn_$turn_status" "$turn_id" "$turn_status"
          break
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
    if [ "$adapter" = ocean ]; then
      ack_file="$(delivery_ack_file "$name" "$generation")"
      : > "$ack_file"
      printf '%s|%s\n' "$(delivery_now)" "$message_id" > "$(delivery_submit_file "$name" "$generation")"
    fi
    fire_adapter "$name" "$adapter" "$wake" "$target" "$ordinal" "$ack_file" || rc=$?
    acked_turn=""
    [ "$adapter" = ocean ] && acked_turn="$(delivery_parse_ocean_ack "$ack_file" "$target")"
    # A generation-bound valid daemon acknowledgement is stronger evidence than
    # the wrapper's process status. The child can write the ack and then exit
    # nonzero (or be terminated) after admission; persist and supervise that
    # exact turn instead of ever replaying it.
    if [ "$adapter" = ocean ] && [ -n "$acked_turn" ]; then
      turn_id="$acked_turn"; DELIVERY_ACTIVE_TURN="$turn_id"
      tmp_turn="$(mktemp "$PAD_STATE/.delivery-turn.XXXXXX")"
      printf '%s' "$turn_id" > "$tmp_turn" && mv "$tmp_turn" "$(delivery_turn_file "$name" "$generation")"
      rm -f "$(delivery_submit_file "$name" "$generation")"
      if ! delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id"; then
        if ! delivery_cancel_ocean_turn "$name" "$turn_id" superseded_after_accept; then
          delivery_write_state "$name" cancel_pending "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "" "$(delivery_now)" cancel_failed "$turn_id" cancelling
          break
        fi
        case "$DELIVERY_CANCEL_OUTCOME" in
          completed) delivery_finalize_completed "$name" "$generation" "$ordinal" "$message_id" "$task_id" \
            "$accepted_at" "$started" "$turn_id" superseded_after_accept || true ;;
          cancelled|errored) rm -f "$(delivery_turn_file "$name" "$generation")" \
            "$(delivery_ack_file "$name" "$generation")" "$(delivery_submit_file "$name" "$generation")" ;;
        esac
        continue
      fi
      if [ "$rc" -eq 0 ]; then
        delivery_write_state "$name" in_flight "$generation" "$ordinal" "$message_id" "$task_id" \
          "$accepted_at" "$started" "" "" "" "$turn_id" accepted
      else
        delivery_write_state "$name" in_flight "$generation" "$ordinal" "$message_id" "$task_id" \
          "$accepted_at" "$started" "" "" "adapter_exit_${rc}_after_ack" "$turn_id" accepted
      fi
      continue
    fi
    if [ "$rc" -eq 0 ]; then
      if [ "$adapter" = ocean ]; then
        delivery_write_state "$name" acceptance_unknown "$generation" "$ordinal" "$message_id" "$task_id" \
          "$accepted_at" "$started" "" "$(delivery_now)" invalid_or_missing_ack
        break
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
        if [ -f "$(delivery_successor_file "$name")" ]; then
          mv "$(delivery_successor_file "$name")" "$pending"
        fi
      fi
      continue
    fi
    if [ "$rc" -eq 3 ]; then
      [ -n "$ack_file" ] && rm -f "$ack_file" "$(delivery_submit_file "$name" "$generation")"
      # The adapter response belongs to the submitted generation. If a newer
      # generation arrived while it was running, loop directly to that work
      # instead of overwriting its accepted state with stale busy metadata.
      delivery_pending_matches "$name" "$generation" "$ordinal" "$message_id" || continue
      delivery_write_state "$name" busy "$generation" "$ordinal" "$message_id" "$task_id" \
        "$accepted_at" "$started" "" "$(delivery_now)" busy
      sleep "$retry_seconds"
      continue
    fi
    if [ "$adapter" = ocean ] && [ -f "$(delivery_submit_file "$name" "$generation")" ]; then
      attempt_at="$(cut -d'|' -f1 "$(delivery_submit_file "$name" "$generation")")"
      reconcile="$(delivery_ocean_reconcile_attempt "$target" "$attempt_at")"
      if [ "$reconcile" != none ]; then
        delivery_write_state "$name" acceptance_unknown "$generation" "$ordinal" "$message_id" "$task_id" \
          "$accepted_at" "$started" "" "$(delivery_now)" "adapter_exit_${rc}_after_submit"
        break
      fi
      rm -f "$ack_file" "$(delivery_submit_file "$name" "$generation")"
    elif [ -n "$ack_file" ]; then
      rm -f "$ack_file"
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
  local name="$1" lock pid token age now born command process_start owner_tmp owner owner_start owner_token owner_pad owner_name
  lock="$(delivery_worker_lock "$name")"
  if [ -d "$lock" ]; then
    token="$(cat "$lock/token" 2>/dev/null || true)"
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    IFS='|' read -r pid owner_start owner_token owner_pad owner_name <<< "$owner"
    process_start="$(delivery_process_start "$pid")"
    if [ -z "$owner_name" ] && [ "$owner_start" = "$token" ] \
       && [ "$owner_token" = "$PAD_DIR" ] && [ "$owner_pad" = "$name" ]; then
      # Rolling-upgrade compatibility with pid|token|pad|name owners.
      owner_start="$process_start"; owner_token="$token"; owner_pad="$PAD_DIR"; owner_name="$name"
    fi
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [ -n "$pid" ] && [ "$owner_start" = "$process_start" ] && [ "$owner_token" = "$token" ] \
       && [ "$owner_pad" = "$PAD_DIR" ] && [ "$owner_name" = "$name" ] && kill -0 "$pid" 2>/dev/null \
       && [[ "$command" == *"--delivery-worker $name $token"* ]]; then return 0; fi
    born="$(cat "$lock/born" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || date +%s)"
    now="$(date +%s)"; age=$((now-born))
    [ -z "$pid" ] && [ "$age" -lt 5 ] && return 0
    rm -rf "$lock" 2>/dev/null || true
  fi
  mkdir "$lock" 2>/dev/null || return 0
  token="$(date +%s)-$$-$RANDOM-$RANDOM"
  printf '%s' "$token" > "$lock/token"; date +%s > "$lock/born"
  [ -n "${SP_DELIVERY_TEST_PRE_SPAWN_DELAY:-}" ] && sleep "$SP_DELIVERY_TEST_PRE_SPAWN_DELAY"
  [ ! -f "$lock/stop-requested" ] || { delivery_worker_cleanup "$name" "$token"; return 0; }
  STITCHPAD_PAD_DIR="$PAD_DIR" SP_DELIVERY_RETRY_SECONDS="${SP_DELIVERY_RETRY_SECONDS:-2}" \
    bash "$BIN_DIR/watch.sh" --delivery-worker "$name" "$token" </dev/null \
      >> "$PAD_STATE/delivery.$name.log" 2>&1 &
  pid=$!; process_start="$(delivery_process_start "$pid")"
  owner_tmp="$(mktemp "$PAD_STATE/.delivery-worker-owner.XXXXXX")"
  printf '%s|%s|%s|%s|%s\n' "$pid" "$process_start" "$token" "$PAD_DIR" "$name" > "$owner_tmp"
  if [ "$(cat "$lock/token" 2>/dev/null || true)" = "$token" ] && [ ! -f "$lock/stop-requested" ]; then
    if [ -n "$process_start" ]; then
      mv "$owner_tmp" "$lock/owner"
      printf '%s' "$pid" > "$lock/pid"
    else
      # The child publishes its own complete identity before doing any work.
      # Never overwrite that record with a transiently empty parent-side ps read.
      rm -f "$owner_tmp"
    fi
  else
    rm -f "$owner_tmp"; kill "$pid" 2>/dev/null || true
  fi
}

delivery_enqueue() {
  local name="$1" qlock="$PAD_STATE/delivery.$1.queue.lock.d" tries=0 rc qpid qborn qage qstart current_start
  while ! mkdir "$qlock" 2>/dev/null; do
    qpid="$(cat "$qlock/pid" 2>/dev/null || true)"
    qstart="$(cat "$qlock/process-start" 2>/dev/null || true)"
    current_start="$(ps -p "$qpid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
    qborn="$(cat "$qlock/born" 2>/dev/null || stat -f %m "$qlock" 2>/dev/null || stat -c %Y "$qlock" 2>/dev/null || date +%s)"
    qage=$(( $(date +%s) - qborn ))
    if { [ -n "$qpid" ] && { ! kill -0 "$qpid" 2>/dev/null \
         || { [ -n "$qstart" ] && [ "$current_start" != "$qstart" ]; }; }; } \
       || { [ -z "$qpid" ] && [ "$qage" -ge 5 ]; }; then
      rm -rf "$qlock"; continue
    fi
    tries=$((tries + 1)); [ "$tries" -lt 700 ] || return 1
    sleep 0.01
  done
  date +%s > "$qlock/born"
  printf '%s|%s|%s\n' "$$" "$PAD_DIR" "$name" > "$qlock/owner"
  printf '%s' "$$" > "$qlock/pid"
  ps -p "$$" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$qlock/process-start"
  rc=0; delivery_enqueue_locked "$@" || rc=$?
  rm -rf "$qlock"
  return "$rc"
}

delivery_enqueue_locked() {
  local name="$1" adapter="$2" wake="$3" target="$4" seen=0 meta ordinal sender message_id task_id
  local pending old_generation old_ordinal old_message old_task old_accepted old_adapter old_wake old_target
  local old_turn old_state generation accepted tmp successor successor_message
  local keeper_ordinal keeper_message keeper_state keeper_attempt keeper_extra keeper_raw keeper_reason
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
  if [ -f "$(delivery_keeper_reservation "$name")" ]; then
    keeper_raw="$(cat "$(delivery_keeper_reservation "$name")" 2>/dev/null || true)"
    keeper_reason=""
    case "$keeper_raw" in *$'\n'*) keeper_reason=multiline;; esac
    IFS='|' read -r keeper_ordinal keeper_message keeper_state keeper_attempt keeper_extra <<< "$keeper_raw"
    [ -n "$keeper_reason" ] || case "$keeper_ordinal" in ''|*[!0-9]*) keeper_reason=bad_ordinal;; esac
    [ -n "$keeper_reason" ] || [ -n "$keeper_message" ] || keeper_reason=missing_message
    [ -n "$keeper_reason" ] || [ -n "$keeper_attempt" ] || keeper_reason=missing_attempt
    [ -n "$keeper_reason" ] || [ -z "$keeper_extra" ] || keeper_reason=extra_fields
    if [ -z "$keeper_reason" ]; then
      case "$keeper_state" in accepted|in_flight|completed|acceptance_unknown) ;;
        *) keeper_reason=bad_state;; esac
    fi
    [ -n "$keeper_reason" ] || [ "$keeper_ordinal" != 0 ] || case "$keeper_message" in
      keeper-task-*) ;;
      *) keeper_reason=bad_task_id;;
    esac
    if [ -n "$keeper_reason" ]; then
      delivery_report_invalid_keeper "$name" "$keeper_reason" "$keeper_raw" || true
      return 0
    fi
    rm -f "$(delivery_keeper_invalid "$name")"
    [ "$keeper_ordinal" = 0 ] && return 0
    [ "$keeper_ordinal" = "$ordinal" ] && [ "$keeper_message" = "$message_id" ] && return 0
  fi
  if [ ! -f "$pending" ] && [ -f "$(delivery_state_file "$name")" ] \
     && [ "$(sed -n 's/^state=//p' "$(delivery_state_file "$name")")" = tombstoned ] \
     && [ "$(sed -n 's/^message_id=//p' "$(delivery_state_file "$name")")" = "$message_id" ]; then
    return 0
  fi
  if [ -f "$pending" ]; then
    IFS='|' read -r old_generation old_ordinal old_message old_task old_accepted old_adapter old_wake old_target < "$pending"
    old_turn="$(cat "$(delivery_turn_file "$name" "$old_generation")" 2>/dev/null || true)"
    if [ "$old_ordinal" = "$ordinal" ] && [ "$old_message" = "$message_id" ]; then
      if ! delivery_task_valid "$name" "$old_task"; then
        if [ "$old_adapter" = ocean ] && ! delivery_cancel_ocean_turn "$name" "$old_turn" "$DELIVERY_TASK_REASON"; then
          delivery_start_worker "$name"; return 0
        fi
        if [ "$old_adapter" = ocean ]; then
          case "$DELIVERY_CANCEL_OUTCOME" in
            completed)
              delivery_finalize_completed "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
                "$old_accepted" "" "$old_turn" "$DELIVERY_TASK_REASON" || true
              return 0 ;;
            errored)
              delivery_drop_current "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
                "$old_accepted" "$DELIVERY_TASK_REASON" "$DELIVERY_TASK_STATUS" "$old_turn" errored ;;
            cancelled)
              delivery_drop_current "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
                "$old_accepted" "$DELIVERY_TASK_REASON" "$DELIVERY_TASK_STATUS" "$old_turn" cancelled ;;
            no_turn)
              delivery_drop_current "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
                "$old_accepted" "$DELIVERY_TASK_REASON" "$DELIVERY_TASK_STATUS" "$old_turn" not_submitted ;;
          esac
        else
          delivery_drop_current "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
            "$old_accepted" "$DELIVERY_TASK_REASON" "$DELIVERY_TASK_STATUS" "$old_turn"
        fi
        rm -f "$(delivery_turn_file "$name" "$old_generation")"
        return 0
      fi
      delivery_start_worker "$name"; return 0
    fi
    old_state="$(sed -n 's/^state=//p' "$(delivery_state_file "$name")" 2>/dev/null | tail -1)"
    if [ "$old_adapter" != ocean ] && [ "$old_state" = started ]; then
      successor="$(delivery_successor_file "$name")"
      if [ -f "$successor" ]; then
        IFS='|' read -r _ _ successor_message _ < "$successor"
        [ "$successor_message" = "$message_id" ] && return 0
      fi
      generation=$(( $(cat "$(delivery_generation_file "$name")" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$generation" > "$(delivery_generation_file "$name")"
      accepted="$(delivery_now)"; tmp="$(mktemp "$PAD_STATE/.delivery-successor.XXXXXX")"
      printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$generation" "$ordinal" "$message_id" "$task_id" \
        "$accepted" "$adapter" "$wake" "$target" > "$tmp"
      mv "$tmp" "$successor"
      delivery_start_worker "$name"
      return 0
    fi
    if [ "$old_adapter" = ocean ] && [ -n "$old_turn" ]; then
      if ! delivery_cancel_ocean_turn "$name" "$old_turn" superseded_by_newer; then
        delivery_start_worker "$name"; return 0
      fi
      case "$DELIVERY_CANCEL_OUTCOME" in
        completed)
          delivery_finalize_completed "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
            "$old_accepted" "" "$old_turn" superseded_by_newer || true ;;
        errored)
          delivery_drop_current "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
            "$old_accepted" superseded_by_newer "$ordinal" "$old_turn" errored ;;
        cancelled)
          delivery_drop_current "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
            "$old_accepted" superseded_by_newer "$ordinal" "$old_turn" cancelled ;;
      esac
    else
      delivery_tombstone "$name" "$old_generation" "$old_ordinal" "$old_message" "$old_task" \
        superseded_by_newer "$ordinal" "$old_turn" || true
    fi
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
  delivery_worker "${2:?missing delivery seat}" "${3:?missing delivery token}"
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
