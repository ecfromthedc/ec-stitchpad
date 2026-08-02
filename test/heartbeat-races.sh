#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d /tmp/stitchpad-heartbeat-races.XXXXXX)"
bg=""
foreign=""
cleanup() {
  [ -z "$bg" ] || { kill "$bg" 2>/dev/null || true; wait "$bg" 2>/dev/null || true; }
  [ -z "$foreign" ] || { kill "$foreign" 2>/dev/null || true; wait "$foreign" 2>/dev/null || true; }
  for who in alice bob carol dave reuse malformed reaper; do
    STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" heartbeat --stop "$who" >/dev/null 2>&1 || true
  done
  STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
wait_file() {
  local path="$1" i=0
  while [ ! -f "$path" ] && [ "$i" -lt 300 ]; do sleep 0.01; i=$((i + 1)); done
  [ -f "$path" ] || fail "timed out waiting for $path"
}
wait_alive() {
  local who="$1" i=0 path="$state/alive.$1"
  while [ ! -s "$path" ] && [ "$i" -lt 300 ]; do sleep 0.01; i=$((i + 1)); done
  [ -s "$path" ] || fail "@$who never published alive metadata"
}
json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)[sys.argv[2]])
PY
}

mkdir -p "$tmp/home"
export HOME="$tmp/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export STITCHPAD_HEARTBEAT_PARENT_PID="$$"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
cd "$tmp"
"$SP" init --name heartbeat-races >/dev/null
state="$tmp/.stitchpad/.state"
pad="$(cd -P "$tmp/.stitchpad" && pwd)"
for who in alice bob carol dave reuse malformed reaper; do
  "$SP" join "$who" codex pull - >/dev/null
done

# A pre-owner contender cannot overwrite the admitted launcher's generation.
barrier="$tmp/pre-owner"
STITCHPAD_HEARTBEAT_TEST_BEFORE_OWNER_BARRIER="$barrier" "$SP" heartbeat start alice >/dev/null 2>&1 &
bg=$!
wait_file "$barrier.ready"
launcher_before="$(shasum -a 256 "$state/heartbeat.alice.lock/launcher")"
"$SP" heartbeat start alice >/dev/null
[ "$(shasum -a 256 "$state/heartbeat.alice.lock/launcher")" = "$launcher_before" ] \
  || fail "concurrent start replaced the admitted launcher"
touch "$barrier.release"
wait "$bg" || fail "admitted pre-owner start failed"
bg=""
wait_alive alice
alice_gen="$(cat "$state/heartbeat.alice.lock/generation")"
[ "$(json_field "$state/heartbeat.alice.lock/owner" generation)" = "$alice_gen" ] \
  && [ "$(json_field "$state/alive.alice" generation)" = "$alice_gen" ] \
  || fail "owner/alive generations diverged"
"$SP" heartbeat --stop alice >/dev/null

# Stop and reset cancel a child paused before owner publication. The old child
# never gains a chance to address a successor generation.
for who in bob carol; do
  barrier="$tmp/cancel-$who"
  STITCHPAD_HEARTBEAT_TEST_BEFORE_OWNER_BARRIER="$barrier" "$SP" heartbeat start "$who" >/dev/null 2>&1 &
  bg=$!
  wait_file "$barrier.ready"
  if [ "$who" = bob ]; then
    "$SP" heartbeat --stop "$who" >/dev/null
  else
    "$SP" reset "$who" >/dev/null
  fi
  wait "$bg" 2>/dev/null && fail "cancelled @$who start reported success"
  bg=""
  [ ! -d "$state/heartbeat.$who.lock" ] || fail "cancelled @$who left its lock"
  [ ! -e "$state/alive.$who" ] || fail "cancelled @$who published alive metadata"
done

# A stopping generation keeps the canonical name busy. A replacement can start
# only after the old child has drained, and old cleanup cannot delete its alive.
"$SP" heartbeat start dave >/dev/null
wait_alive dave
old_pid="$(json_field "$state/heartbeat.dave.lock/owner" pid)"
barrier="$tmp/stop-dave"
STITCHPAD_HEARTBEAT_TEST_STOP_AFTER_CANCEL_BARRIER="$barrier" "$SP" heartbeat --stop dave >/dev/null 2>&1 &
bg=$!
wait_file "$barrier.ready"
if "$SP" heartbeat start dave >/dev/null 2>&1; then
  fail "replacement started before cancelled generation drained"
fi
touch "$barrier.release"
wait "$bg" || fail "verified stop failed"
bg=""
"$SP" heartbeat start dave >/dev/null
wait_alive dave
new_pid="$(json_field "$state/heartbeat.dave.lock/owner" pid)"
[ "$new_pid" != "$old_pid" ] && kill -0 "$new_pid" 2>/dev/null \
  || fail "replacement ticker is not the sole live generation"
[ "$(json_field "$state/alive.dave" generation)" = "$(cat "$state/heartbeat.dave.lock/generation")" ] \
  || fail "old stop deleted or corrupted replacement alive metadata"
"$SP" heartbeat --stop dave >/dev/null

# Structurally valid stale ownership may be reclaimed even when its numeric PID
# belongs to an unrelated live process; that process is never signalled.
( trap - EXIT; exec sleep 60 ) &
foreign=$!
sleep_start="$(ps -p "$foreign" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
sleep_command="$(ps -p "$foreign" -o command= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
lock="$state/heartbeat.reuse.lock"; generation="reuse.1"
mkdir "$lock"; printf '%s' "$generation" > "$lock/generation"
python3 - "$lock/launcher" "$generation" "$pad" <<'PY'
import json, sys
path, generation, pad = sys.argv[1:]
json.dump({"generation": generation, "pid": 99999991, "processStart": "dead",
           "command": "dead", "pad": pad, "name": "reuse"}, open(path, "w"), separators=(",", ":"))
PY
python3 - "$lock/owner" "$generation" "$foreign" "$sleep_command" "$pad" <<'PY'
import json, sys
path, generation, pid, command, pad = sys.argv[1:]
json.dump({"generation": generation, "pid": int(pid), "processStart": "mismatched-start",
           "command": command, "pad": pad, "name": "reuse"}, open(path, "w"), separators=(",", ":"))
PY
"$SP" heartbeat --stop reuse >/dev/null
kill -0 "$foreign" 2>/dev/null || fail "valid mismatch signalled a reused PID"
[ ! -d "$lock" ] || fail "valid mismatched generation was not reclaimed"

# Malformed evidence is fail-closed and byte-preserving.
lock="$state/heartbeat.malformed.lock"
mkdir "$lock"; printf '%s' "$foreign" > "$lock/pid"; printf '%s' '{bad-json' > "$lock/owner"
before="$(find "$lock" -type f -maxdepth 1 -print0 | sort -z | xargs -0 shasum -a 256)"
if "$SP" heartbeat --stop malformed >/dev/null 2>&1; then
  fail "malformed live ownership was accepted"
fi
after="$(find "$lock" -type f -maxdepth 1 -print0 | sort -z | xargs -0 shasum -a 256)"
[ "$after" = "$before" ] || fail "malformed evidence was partially mutated"
kill "$foreign" 2>/dev/null || true; wait "$foreign" 2>/dev/null || true; foreign=""
rm -f "$lock/pid" "$lock/owner"; rmdir "$lock"

# The generic dead-presence reaper cannot delete a live pre-owner generation.
barrier="$tmp/reaper-pre-owner"
STITCHPAD_HEARTBEAT_TEST_BEFORE_OWNER_BARRIER="$barrier" "$SP" heartbeat start reaper >/dev/null 2>&1 &
bg=$!
wait_file "$barrier.ready"
launcher_before="$(shasum -a 256 "$state/heartbeat.reaper.lock/launcher")"
printf '%s' '{"pid":99999993}' > "$state/alive.reaper"
touch -t 200001010000 "$state/alive.reaper"
STITCHPAD_PAD_DIR="$tmp/.stitchpad" bash -c 'source "$1"; sp_init_paths; sp_reap_dead' _ "$ROOT/tool/bin/lib.sh"
[ -d "$state/heartbeat.reaper.lock" ] \
  && [ "$(shasum -a 256 "$state/heartbeat.reaper.lock/launcher")" = "$launcher_before" ] \
  || fail "dead-presence reaper destroyed a live pre-owner generation"
"$SP" heartbeat --stop reaper >/dev/null
wait "$bg" 2>/dev/null || true; bg=""

# SIGKILL between mkdir and generation publication leaves only an empty lock,
# which the next start can reclaim without destructive unknown-state cleanup.
barrier="$tmp/mkdir-kill"
STITCHPAD_HEARTBEAT_TEST_AFTER_MKDIR_BARRIER="$barrier" "$SP" heartbeat start alice >/dev/null 2>&1 &
bg=$!
wait_file "$barrier.ready"
kill -KILL "$bg" 2>/dev/null || true; wait "$bg" 2>/dev/null || true; bg=""
STITCHPAD_HEARTBEAT_START_GRACE=0 "$SP" heartbeat start alice >/dev/null
wait_alive alice
[ -z "$(find "$state" -maxdepth 1 \( -name '.heartbeat-*' -o -name 'heartbeat.*.retired.*' \) -print -quit)" ] \
  || fail "heartbeat lifecycle left publication or retired residue"
"$SP" heartbeat --stop alice >/dev/null

echo "heartbeat races ok"
