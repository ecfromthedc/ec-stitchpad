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

# Atomic publication stages are pure litter once their exact named publisher
# is dead and the file is old.  Reaping must preserve live-publisher, fresh,
# symlinked, directory-shaped, oversized and malformed-name evidence.
printf 'generation-stage' > "$state/.watch-generation.99999991.1"
printf 'launcher-stage' > "$state/.watch-launcher.99999991.2"
printf 'transfer-stage' > "$state/.watch-launcher-transfer.99999991.3"
printf 'owner-stage' > "$state/.watch-owner.99999991.4"
printf 'live-owner-stage' > "$state/.watch-owner.$$.5"
printf 'fresh-launcher-stage' > "$state/.watch-launcher.99999991.6"
printf 'malformed-stage' > "$state/.watch-generation.bad.7"
mkdir "$state/.watch-owner.99999991.8"
printf 'outside' > "$base/stage-outside"
ln -s "$base/stage-outside" "$state/.watch-generation.99999991.9"
dd if=/dev/zero of="$state/.watch-owner.99999991.10" bs=4097 count=1 >/dev/null 2>&1
touch -t 202001010000 \
  "$state/.watch-generation.99999991.1" \
  "$state/.watch-launcher.99999991.2" \
  "$state/.watch-launcher-transfer.99999991.3" \
  "$state/.watch-owner.99999991.4" \
  "$state/.watch-owner.$$.5" \
  "$state/.watch-generation.bad.7" \
  "$state/.watch-owner.99999991.10"
"$SP" stop >/dev/null
for stage in .watch-generation.99999991.1 .watch-launcher.99999991.2 \
             .watch-launcher-transfer.99999991.3 .watch-owner.99999991.4; do
  [ ! -e "$state/$stage" ] || fail "old dead-publisher stage survived: $stage"
done
[ -f "$state/.watch-owner.$$.5" ] || fail "reaper removed a live-publisher stage"
[ -f "$state/.watch-launcher.99999991.6" ] || fail "reaper removed a fresh stage"
[ -f "$state/.watch-generation.bad.7" ] || fail "reaper removed a malformed-name stage"
[ -d "$state/.watch-owner.99999991.8" ] || fail "reaper removed a directory-shaped stage"
[ -L "$state/.watch-generation.99999991.9" ] && [ "$(cat "$base/stage-outside")" = outside ] \
  || fail "reaper traversed or removed a symlinked stage"
[ -f "$state/.watch-owner.99999991.10" ] || fail "reaper removed an oversized stage"
STITCHPAD_WATCH_STAGE_STALE_SECONDS=0 "$SP" stop >/dev/null
[ ! -e "$state/.watch-launcher.99999991.6" ] || fail "zero-grace reaper left a dead stage"
rm -f "$state/.watch-owner.$$.5" "$state/.watch-generation.bad.7" \
  "$state/.watch-generation.99999991.9" "$state/.watch-owner.99999991.10"
rmdir "$state/.watch-owner.99999991.8"

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
custom_grace_json="$(STITCHPAD_WATCH_START_GRACE=0 "$SP" health --json)"
python3 - "$custom_grace_json" <<'PY'
import json, sys
watcher = json.loads(sys.argv[1])["pad"]["watcher"]
assert watcher["status"] == "stale_lock", watcher
assert watcher["start_grace_seconds"] == 0, watcher
PY
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

# Accidentally exported test barriers must fail boundedly and retire their own
# exact generation instead of wedging ensure, daemon, or direct-watch forever.
for surface in ensure daemon direct; do
  barrier="$base/bounded-$surface"
  case "$surface" in
    ensure)
      if STITCHPAD_WATCH_TEST_BARRIER_TICKS=2 \
          STITCHPAD_WATCH_TEST_AFTER_GENERATION_BARRIER="$barrier" \
          "$SP" ensure-watcher >"$base/bounded-$surface.out" 2>&1; then
        fail "ensure generation barrier timeout reported success"
      fi
      ;;
    daemon)
      if STITCHPAD_WATCH_TEST_BARRIER_TICKS=2 \
          STITCHPAD_WATCH_TEST_AFTER_GENERATION_BARRIER="$barrier" \
          "$SP" daemon start >"$base/bounded-$surface.out" 2>&1; then
        fail "daemon generation barrier timeout reported success"
      fi
      ;;
    direct)
      if STITCHPAD_WATCH_TEST_BARRIER_TICKS=2 \
          STITCHPAD_WATCH_TEST_AFTER_GENERATION_BARRIER="$barrier" \
          "$SP" watch >"$base/bounded-$surface.out" 2>&1; then
        fail "direct watch generation barrier timeout reported success"
      fi
      ;;
  esac
  [ -f "$barrier.ready" ] || fail "$surface generation barrier was not reached"
  grep -q 'test barrier timed out' "$base/bounded-$surface.out" \
    || fail "$surface generation barrier timeout was not diagnosed"
  [ ! -d "$lock" ] && [ -z "$(watch_processes)" ] \
    || fail "$surface generation barrier timeout left lock or process residue"
done

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
if STITCHPAD_WATCH_START_GRACE=0 "$SP" daemon stop >"$base/malformed-daemon-stop.out" 2>&1; then
  fail "daemon stop reported success for unverified watcher ownership evidence"
fi
grep -q '^stopped$' "$base/malformed-daemon-stop.out" \
  && fail "daemon stop printed a false success message for malformed ownership" \
  || true
[ -f "$lock/generation" ] && [ -f "$lock/junk" ] \
  || fail "daemon stop mutated malformed watcher evidence"
if STITCHPAD_WATCH_START_GRACE=0 "$SP" daemon restart >"$base/malformed-daemon-restart.out" 2>&1; then
  fail "daemon restart proceeded past unverified watcher ownership evidence"
fi
grep -q 'started stitchpad watcher' "$base/malformed-daemon-restart.out" \
  && fail "daemon restart started after a refused stop" \
  || true
[ -f "$lock/generation" ] && [ -f "$lock/junk" ] \
  || fail "daemon restart mutated malformed watcher evidence"
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
