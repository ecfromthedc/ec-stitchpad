#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
base="$(mktemp -d /tmp/stitchpad-watcher-races.XXXXXX)"
tmp="$base/pipe | restart"
ensure_pid=""
orphan_pid=""
canary_pid=""
cleanup() {
  [ -z "$ensure_pid" ] || { kill "$ensure_pid" 2>/dev/null || true; wait "$ensure_pid" 2>/dev/null || true; }
  [ -z "$canary_pid" ] || { kill "$canary_pid" 2>/dev/null || true; wait "$canary_pid" 2>/dev/null || true; }
  if [ -d "$tmp/.stitchpad" ]; then
    STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
    STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" heartbeat --stop watcher >/dev/null 2>&1 || true
  fi
  if [ -n "$orphan_pid" ] && kill -0 "$orphan_pid" 2>/dev/null; then
    orphan_command="$(ps -p "$orphan_pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ "$orphan_command" = "$real_fswatch -0 ${pad_md:-}" ] \
      && kill "$orphan_pid" 2>/dev/null || true
    wait "$orphan_pid" 2>/dev/null || true
  fi
  rm -rf "$base"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
wait_file() {
  local path="$1" i=0
  while [ ! -f "$path" ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$((i + 1)); done
  [ -f "$path" ] || fail "timed out waiting for $path"
}
watch_processes() {
  STITCHPAD_PAD_DIR="$tmp/.stitchpad" bash -c \
    'source "$1"; sp_init_paths >/dev/null; sp_watch_processes_for_pad' _ "$ROOT/tool/bin/lib.sh"
}
watch_pairs() {
  STITCHPAD_PAD_DIR="$tmp/.stitchpad" bash -c \
    'source "$1"; sp_init_paths >/dev/null; sp_watch_pairs_for_pad' _ "$ROOT/tool/bin/lib.sh"
}

mkdir -p "$tmp/home" "$base/mockbin"
export HOME="$tmp/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
cd "$tmp"
"$SP" init --name watcher-races >/dev/null
"$SP" join watcher codex pull - >/dev/null
STITCHPAD_NAME=watcher "$SP" heartbeat --touch watcher "$$" >/dev/null
state="$tmp/.stitchpad/.state"
lock="$state/watch.lock.d"
real_fswatch="$(command -v fswatch)"
pad_md="$(STITCHPAD_PAD_DIR="$tmp/.stitchpad" bash -c \
  'source "$1"; sp_init_paths >/dev/null; printf "%s" "$PAD_MD"' _ "$ROOT/tool/bin/lib.sh")"
count="$base/fswatch.count"

cat > "$base/mockbin/fswatch" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$STITCHPAD_TEST_FSWATCH_COUNT" 2>/dev/null || echo 0)"
n=$((n + 1))
printf '%s' "$n" > "$STITCHPAD_TEST_FSWATCH_COUNT"
if [ "$n" -eq 1 ]; then exit 42; fi
exec "$STITCHPAD_TEST_REAL_FSWATCH" "$@"
EOF
chmod +x "$base/mockbin/fswatch"

# A daemon whose first child exits retains its exact generation through the
# ownerless restart gap. ensure-watcher/reaper must not cancel the supervisor.
PATH="$base/mockbin:$PATH" STITCHPAD_TEST_FSWATCH_COUNT="$count" \
  STITCHPAD_TEST_REAL_FSWATCH="$real_fswatch" "$SP" daemon start >/dev/null
for _ in $(seq 1 500); do
  [ "$(cat "$count" 2>/dev/null || echo 0)" = 1 ] && [ ! -e "$lock/owner" ] && break
  sleep 0.01
done
[ "$(cat "$count" 2>/dev/null || echo 0)" = 1 ] && [ ! -e "$lock/owner" ] \
  || fail "daemon never entered the ownerless restart gap"
generation="$(cat "$lock/generation")"
launcher_before="$(shasum -a 256 "$lock/launcher")"
"$SP" ensure-watcher >/dev/null
[ "$(cat "$lock/generation")" = "$generation" ] \
  && [ "$(shasum -a 256 "$lock/launcher")" = "$launcher_before" ] \
  || fail "ensure-watcher cancelled or replaced the live supervisor gap"
for _ in $(seq 1 600); do
  [ "$(cat "$count" 2>/dev/null || echo 0)" -ge 2 ] && [ -s "$lock/owner" ] && break
  sleep 0.01
done
[ "$(cat "$count" 2>/dev/null || echo 0)" -ge 2 ] && [ -s "$lock/owner" ] \
  || fail "daemon did not restart a real watcher"
[ "$(cat "$lock/generation")" = "$generation" ] \
  || fail "daemon restart changed generation"

# A killed watch.sh can leave its exact fswatch child orphaned.  A healthy
# generation plus that residue is still a duplicate: ensure must tear down both
# exact children and converge to one owned watcher.
"$real_fswatch" -0 "$pad_md" >/dev/null 2>&1 &
orphan_pid=$!
for _ in $(seq 1 200); do
  [ "$(watch_pairs | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 0.01
done
[ "$(watch_pairs | wc -l | tr -d ' ')" -ge 2 ] \
  || fail "exact orphan fswatch fixture was not observed"
"$SP" ensure-watcher >/dev/null
for _ in $(seq 1 500); do
  [ "$(watch_pairs | wc -l | tr -d ' ')" = 1 ] && [ -s "$lock/owner" ] && break
  sleep 0.01
done
[ "$(watch_pairs | wc -l | tr -d ' ')" = 1 ] && [ -s "$lock/owner" ] \
  || fail "ensure-watcher did not reap orphan and restore one exact pair"
wait "$orphan_pid" 2>/dev/null || true
kill -0 "$orphan_pid" 2>/dev/null \
  && fail "ensure-watcher left the exact orphan alive" \
  || true
orphan_pid=""
"$SP" daemon stop >/dev/null
[ -z "$(watch_processes)" ] && [ ! -d "$lock" ] \
  || fail "restart-gap stop left exact watcher processes"

# Stop during the gap must cancel the exact supervisor. Releasing its test seam
# cannot resurrect watch.sh or create a new direct generation.
printf '0' > "$count"
barrier="$base/restart-stop"
PATH="$base/mockbin:$PATH" STITCHPAD_TEST_FSWATCH_COUNT="$count" \
  STITCHPAD_TEST_REAL_FSWATCH="$real_fswatch" \
  STITCHPAD_DAEMON_TEST_BEFORE_RESTART_BARRIER="$barrier" \
  "$SP" daemon start >/dev/null
wait_file "$barrier.ready"
[ "$(cat "$count")" = 1 ] || fail "restart barrier was not reached after first child"
"$SP" daemon stop >/dev/null
touch "$barrier.release"
sleep 2.5
[ "$(cat "$count")" = 1 ] || fail "cancelled supervisor resurrected a watcher"
[ -z "$(watch_processes)" ] && [ ! -d "$lock" ] \
  || fail "cancelled restart left process or lock residue"

# SIGKILL between singleton mkdir and generation publication leaves an empty
# lock only. After the bounded startup grace, ensure-watcher reclaims it and
# converges to one exact process set.
barrier="$base/watch-mkdir-kill"
STITCHPAD_WATCH_TEST_AFTER_MKDIR_BARRIER="$barrier" "$SP" ensure-watcher >/dev/null 2>&1 &
ensure_pid=$!
wait_file "$barrier.ready"
kill -KILL "$ensure_pid" 2>/dev/null || true
wait "$ensure_pid" 2>/dev/null || true
ensure_pid=""
[ -d "$lock" ] && [ -z "$(find "$lock" -mindepth 1 -maxdepth 1 -print -quit)" ] \
  || fail "watch admission SIGKILL did not leave an empty lock"
STITCHPAD_WATCH_START_GRACE=0 "$SP" ensure-watcher >/dev/null
for _ in $(seq 1 500); do
  [ -s "$lock/owner" ] && [ -n "$(watch_processes)" ] && break
  sleep 0.01
done
[ -s "$lock/owner" ] && [ -n "$(watch_processes)" ] \
  || fail "watcher did not recover from empty admission lock"
"$SP" daemon stop >/dev/null
[ ! -d "$lock" ] && [ -z "$(watch_processes)" ] \
  || fail "recovered watcher left lock or process residue"

# SIGKILL after generation publication but before launcher publication leaves
# a generation-only lock.  Once its bounded admission grace expires, both CLI
# ensure and daemon start must retire that exact generation without signalling
# any PID, then converge to one supervised watcher.
barrier="$base/watch-generation-kill"
STITCHPAD_WATCH_TEST_AFTER_GENERATION_BARRIER="$barrier" "$SP" ensure-watcher >/dev/null 2>&1 &
ensure_pid=$!
wait_file "$barrier.ready"
kill -KILL "$ensure_pid" 2>/dev/null || true
wait "$ensure_pid" 2>/dev/null || true
ensure_pid=""
[ -d "$lock" ] && [ -f "$lock/generation" ] \
  && [ "$(find "$lock" -mindepth 1 -maxdepth 1 -print)" = "$lock/generation" ] \
  || fail "watch admission SIGKILL did not leave the exact generation-only shape"
fresh_before="$(find "$lock" -mindepth 1 -maxdepth 1 -type f -exec cksum {} \; | sort)"
[ "$("$SP" status)" = stopped ] || fail "readonly status hid the ownerless admission state"
health_json="$("$SP" health --json)"
[ "$(printf '%s' "$health_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pad"]["watcher"]["status"])')" = starting ] \
  || fail "health did not classify a fresh generation-only admission as starting"
fresh_after="$(find "$lock" -mindepth 1 -maxdepth 1 -type f -exec cksum {} \; | sort)"
[ "$fresh_before" = "$fresh_after" ] || fail "readonly status/health mutated a fresh admission lock"
"$SP" ensure-watcher >/dev/null
[ "$fresh_before" = "$(find "$lock" -mindepth 1 -maxdepth 1 -type f -exec cksum {} \; | sort)" ] \
  || fail "default grace reclaimed a fresh generation-only admission"
STITCHPAD_WATCH_START_GRACE=0 "$SP" ensure-watcher >/dev/null
for _ in $(seq 1 500); do
  [ -s "$lock/owner" ] && [ "$(watch_pairs | wc -l | tr -d ' ')" = 1 ] && break
  sleep 0.01
done
[ -s "$lock/owner" ] && [ "$(watch_pairs | wc -l | tr -d ' ')" = 1 ] \
  || fail "ensure-watcher did not recover a generation-only admission lock"
"$SP" daemon stop >/dev/null
[ ! -d "$lock" ] && [ -z "$(watch_processes)" ] \
  || fail "generation-only ensure recovery left lock or process residue"

barrier="$base/daemon-generation-kill"
STITCHPAD_WATCH_TEST_AFTER_GENERATION_BARRIER="$barrier" "$SP" daemon start >/dev/null 2>&1 &
ensure_pid=$!
wait_file "$barrier.ready"
kill -KILL "$ensure_pid" 2>/dev/null || true
wait "$ensure_pid" 2>/dev/null || true
ensure_pid=""
[ -d "$lock" ] && [ -f "$lock/generation" ] \
  && [ "$(find "$lock" -mindepth 1 -maxdepth 1 -print)" = "$lock/generation" ] \
  || fail "daemon admission SIGKILL did not leave the exact generation-only shape"
STITCHPAD_WATCH_START_GRACE=0 "$SP" daemon start >/dev/null
for _ in $(seq 1 500); do
  [ -s "$lock/owner" ] && [ "$(watch_pairs | wc -l | tr -d ' ')" = 1 ] && break
  sleep 0.01
done
[ -s "$lock/owner" ] && [ "$(watch_pairs | wc -l | tr -d ' ')" = 1 ] \
  || fail "daemon start did not recover a generation-only admission lock"
"$SP" daemon stop >/dev/null
[ ! -d "$lock" ] && [ -z "$(watch_processes)" ] \
  || fail "generation-only daemon recovery left lock or process residue"

# Generation strings contain a PID-shaped component but are never signal
# authority.  Reclaiming an aged ownerless generation must not touch a live
# foreign process whose PID happens to appear in that string.
sleep 30 &
canary_pid=$!
mkdir "$lock"
printf '1.%s.1' "$canary_pid" > "$lock/generation"
touch -t 202001010000 "$lock" "$lock/generation"
STITCHPAD_WATCH_START_GRACE=0 "$SP" stop >/dev/null
kill -0 "$canary_pid" 2>/dev/null || fail "generation-only reclaim signalled a foreign PID"
[ ! -d "$lock" ] || fail "stop did not reclaim an aged generation-only lock"
kill "$canary_pid" 2>/dev/null || true
wait "$canary_pid" 2>/dev/null || true
canary_pid=""

# Any richer or aliased shape remains fail-closed evidence.
mkdir "$lock"
printf '1.2.3' > "$lock/generation"
printf 'evidence' > "$lock/junk"
touch -t 202001010000 "$lock" "$lock/generation" "$lock/junk"
STITCHPAD_WATCH_START_GRACE=0 "$SP" ensure-watcher >/dev/null
[ -f "$lock/generation" ] && [ -f "$lock/junk" ] \
  || fail "reclaim removed a richer malformed watcher lock"
if STITCHPAD_WATCH_START_GRACE=0 "$SP" stop >"$base/malformed-stop.out" 2>&1; then
  fail "stop reported success for unverified watcher ownership evidence"
fi
grep -q 'watcher stopped' "$base/malformed-stop.out" \
  && fail "stop printed a false success message for malformed ownership" \
  || true
rm -f "$lock/generation" "$lock/junk"
rmdir "$lock"

[ -z "$(find "$state" -maxdepth 1 -name 'watch.lock.d.retired.*' -print -quit)" ] \
  || fail "watcher race scenarios left a retired generation alias"

echo "watcher races ok"
