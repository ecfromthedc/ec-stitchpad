#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-delivery.XXXXXX")"
TEST_TOOL="$TMP/tool"
pass=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

ok() {
  printf '  PASS %s\n' "$1"
  pass=$((pass + 1))
}

cleanup() {
  local pid_file pid
  for pid_file in "$TMP"/case-*/.stitchpad/.state/delivery.*.worker.lock.d/pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TEST_TOOL/adapters"
ln -s "$ROOT/tool/bin" "$TEST_TOOL/bin"

# The mock records every actual adapter submission. Its modes provide a slow
# seat, transient busy response, and hard failure without depending on Herdr or
# Ocean being installed on the test machine.
cat > "$TEST_TOOL/adapters/mock.sh" <<'MOCK'
#!/usr/bin/env bash
set -u
name="$2"
state="$SP_PAD_DIR/.state"
mode="$(cat "$state/mock.$name.mode" 2>/dev/null || printf success)"
count_file="$state/mock.$name.count"
count=$(( $(cat "$count_file" 2>/dev/null || printf 0) + 1 ))
printf '%s' "$count" > "$count_file"
body="$(tr '\n' ' ' < "$4")"
printf '%s|%s|%s\n' "$name" "$count" "$body" >> "$state/mock.calls"
case "$mode" in
  slow) sleep 1 ;;
  busy-once) [ "$count" -eq 1 ] && exit 3 ;;
  fail-slow) sleep 0.5; exit 9 ;;
  fail) exit 9 ;;
esac
exit 0
MOCK
chmod +x "$TEST_TOOL/adapters/mock.sh"
ln -s "$ROOT/tool/adapters/ocean.sh" "$TEST_TOOL/adapters/ocean.sh"
export STITCHPAD_HOME="$TEST_TOOL"
BIN_DIR="$ROOT/tool/bin"
source "$ROOT/tool/bin/lib.sh"

new_case() {
  local label="$1" roster="$2"
  CASE_DIR="$TMP/case-$label"
  CASE_PAD="$CASE_DIR/.stitchpad"
  mkdir -p "$CASE_PAD/.state"
  {
    printf '# delivery fixture\n\n```roster\n'
    printf '%s\n' "$roster"
    printf '```\n'
  } > "$CASE_PAD/stitchpad.md"
  unset PAD_DIR PAD_MD PAD_GIT PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
  sp_init_paths "$CASE_PAD" >/dev/null
}

append_message() {
  local author="$1" body="$2"
  printf '\n## @%s · 00:00\n\n%s\n' "$author" "$body" >> "$PAD_MD"
}

state_value() {
  local name="$1" key="$2"
  sed -n "s/^${key}=//p" "$(delivery_state_file "$name")" 2>/dev/null | tail -1
}

wait_state() {
  local name="$1" expected="$2" tries="${3:-200}" actual
  while [ "$tries" -gt 0 ]; do
    actual="$(state_value "$name" state)"
    [ "$actual" = "$expected" ] && return 0
    tries=$((tries - 1))
    sleep 0.05
  done
  printf 'state for %s: expected %s, got %s\n' "$name" "$expected" "${actual:-missing}" >&2
  [ -f "$(delivery_state_file "$name")" ] && cat "$(delivery_state_file "$name")" >&2
  [ -f "$PAD_STATE/delivery.$name.log" ] && cat "$PAD_STATE/delivery.$name.log" >&2
  return 1
}

wait_no_worker() {
  local name="$1" tries=200
  while [ "$tries" -gt 0 ]; do
    [ ! -d "$(delivery_worker_lock "$name")" ] && return 0
    tries=$((tries - 1))
    sleep 0.05
  done
  return 1
}

hold_worker() {
  local name="$1" lock
  lock="$(delivery_worker_lock "$name")"
  mkdir -p "$lock"
  printf '%s' "$$" > "$lock/pid"
}

release_worker() {
  rm -rf "$(delivery_worker_lock "$1")"
}

# Source the watcher as a function library. Spawned workers receive the test
# tool home but not this library-only flag.
new_case bootstrap 'bootstrap | mock | push | bootstrap-target'
STITCHPAD_WATCH_LIB_ONLY=1
source "$ROOT/tool/bin/watch.sh"
unset STITCHPAD_WATCH_LIB_ONLY
export SP_DELIVERY_RETRY_SECONDS=0.05

printf 'delivery supervision regressions\n'

# A blocking seat must not serialize other seats behind it.
new_case parallel $'slowseat | mock | push | slow-target\nfastseat | mock | push | fast-target'
printf slow > "$PAD_STATE/mock.slowseat.mode"
append_message operator '@slowseat slow directive'
append_message operator '@fastseat fast directive'
delivery_enqueue slowseat mock push slow-target
delivery_enqueue fastseat mock push fast-target
wait_state fastseat completed || fail 'fast seat did not complete while another seat was blocked'
[ "$(state_value slowseat state)" != completed ] || fail 'slow seat completed before the parallelism assertion'
wait_state slowseat completed || fail 'slow seat never completed'
for key in accepted_at started_at completed_at; do
  [ -n "$(state_value fastseat "$key")" ] || fail "completed state omitted $key"
done
ok 'slow seat A does not block seat B and lifecycle timestamps persist'

# Repeated wake cycles for one unchanged directive must coalesce behind one
# per-seat worker generation and submit once.
new_case singleton 'solo | mock | push | solo-target'
append_message operator '@solo singleton directive'
hold_worker solo
delivery_enqueue solo mock push solo-target
delivery_enqueue solo mock push solo-target
[ "$(cat "$(delivery_generation_file solo)")" = 1 ] || fail 'same directive created another generation'
release_worker solo
delivery_start_worker solo
wait_state solo completed || fail 'coalesced singleton directive did not complete'
[ "$(cat "$PAD_STATE/mock.solo.count")" = 1 ] || fail 'same directive reached adapter more than once'
ok 'singleton worker coalesces duplicate watcher events'

# Busy is retryable supervision state; it must not need another pad write.
new_case busy 'busyseat | mock | push | busy-target'
printf busy-once > "$PAD_STATE/mock.busyseat.mode"
append_message operator '@busyseat retry without another write'
delivery_enqueue busyseat mock push busy-target
wait_state busyseat completed || fail 'busy seat did not retry to completion'
[ "$(cat "$PAD_STATE/mock.busyseat.count")" = 2 ] || fail 'busy response did not cause exactly one retry'
ok 'busy-to-idle retry completes without a pad mutation'

# A hard adapter crash/failure records the error but retains accepted work. A
# replacement supervisor can resume that same generation.
new_case crash 'crashseat | mock | push | crash-target'
printf fail > "$PAD_STATE/mock.crashseat.mode"
append_message operator '@crashseat durable pending after adapter crash'
delivery_enqueue crashseat mock push crash-target
wait_state crashseat error || fail 'adapter failure was not recorded'
[ -f "$(delivery_pending_file crashseat)" ] || fail 'adapter failure discarded pending work'
wait_no_worker crashseat || fail 'failed worker did not release its singleton lock'
printf success > "$PAD_STATE/mock.crashseat.mode"
delivery_start_worker crashseat
wait_state crashseat completed || fail 'replacement worker did not resume pending work'
[ "$(cat "$PAD_STATE/mock.crashseat.count")" = 2 ] || fail 'resumed generation had unexpected submission count'
ok 'adapter crash preserves pending generation for supervised recovery'

# A newer current directive supersedes an older generation before submit. The
# tombstone proves why it was dropped and the adapter sees only bounded current
# work, not the intervening history.
new_case supersede 'fresh | mock | push | fresh-target'
hold_worker fresh
append_message operator '@fresh old directive must not run'
delivery_enqueue fresh mock push fresh-target
append_message operator '@fresh new directive wins'
delivery_enqueue fresh mock push fresh-target
[ "$(cat "$(delivery_generation_file fresh)")" = 2 ] || fail 'new directive did not advance generation'
grep -qF '|superseded_by_newer|' "$(delivery_tombstone_file fresh)" || fail 'superseded generation was not tombstoned'
release_worker fresh
delivery_start_worker fresh
wait_state fresh completed || fail 'newer directive did not complete'
[ "$(cat "$PAD_STATE/mock.fresh.count")" = 1 ] || fail 'superseded directive reached adapter'
grep -qF 'new directive wins' "$PAD_STATE/mock.calls" || fail 'adapter did not receive newest directive'
! grep -qF 'old directive must not run' "$PAD_STATE/mock.calls" || fail 'adapter replayed superseded history'
ok 'stale generation is rejected and newer directive supersedes old work'

# A hard failure from the old in-flight generation must not make the singleton
# exit after a newer generation has been accepted behind it.
new_case failover 'failover | mock | push | failover-target'
printf fail-slow > "$PAD_STATE/mock.failover.mode"
append_message operator '@failover old in-flight generation'
delivery_enqueue failover mock push failover-target
wait_state failover started || fail 'old failover generation never started'
append_message operator '@failover replacement generation survives old failure'
delivery_enqueue failover mock push failover-target
printf success > "$PAD_STATE/mock.failover.mode"
wait_state failover completed || fail 'old generation failure stranded newer accepted work'
[ "$(state_value failover generation)" = 2 ] || fail 'replacement generation did not own completion'
[ "$(cat "$PAD_STATE/mock.failover.count")" = 2 ] || fail 'failover did not submit old and replacement exactly once each'
ok 'old in-flight failure cannot strand a newer accepted generation'

# Ocean's daemon ack exposes the exact cancellable turn. Keep the first turn
# active, supersede it, and prove one exact cancel occurs before the replacement
# can complete. The fake curl/heartbeat implement only the documented local
# daemon contracts and never touch a real Ocean process.
new_case ocean_cancel 'oceanseat | ocean | push | ocean-session'
export STITCHPAD_PAD_DIR="$PAD_DIR"
ocean_bin="$TMP/ocean-bin"
mkdir -p "$ocean_bin"
cat > "$ocean_bin/ocean-heartbeat" <<'HEARTBEAT'
#!/usr/bin/env bash
state="$STITCHPAD_PAD_DIR/.state"
count=$(( $(cat "$state/ocean.count" 2>/dev/null || printf 0) + 1 ))
printf '%s' "$count" > "$state/ocean.count"
turn="turn-$count"
printf '%s' "$turn" > "$state/ocean.active"
printf '{"ok":true,"session_id":"ocean-session","turn_id":"%s"}\n' "$turn"
HEARTBEAT
cat > "$ocean_bin/curl" <<'CURL'
#!/usr/bin/env bash
state="$STITCHPAD_PAD_DIR/.state"
url="${!#}"
if [[ "$url" == */cancel ]]; then
  turn="${url%/cancel}"; turn="${turn##*/}"
  printf '%s\n' "$turn" >> "$state/ocean.cancels"
  [ "$(cat "$state/ocean.active" 2>/dev/null || true)" = "$turn" ] && : > "$state/ocean.active"
  out=""
  while [ "$#" -gt 0 ]; do
    [ "$1" = -o ] && { shift; out="$1"; }
    shift
  done
  [ -n "$out" ] && printf '{"ok":true}\n' > "$out"
  printf '202'
  exit 0
fi
active="$(cat "$state/ocean.active" 2>/dev/null || true)"
if [ -n "$active" ]; then
  printf '{"session":{"active_turn":"%s"}}\n' "$active"
else
  printf '{"session":{"active_turn":null}}\n'
fi
CURL
chmod +x "$ocean_bin/ocean-heartbeat" "$ocean_bin/curl"
old_path="$PATH"; export PATH="$ocean_bin:$PATH"
append_message operator '@oceanseat stale Ocean directive'
delivery_enqueue oceanseat ocean push ocean-session
wait_state oceanseat in_flight || fail 'Ocean turn did not persist accepted in-flight state'
[ "$(state_value oceanseat turn_id)" = turn-1 ] || fail 'Ocean turn_id was not persisted'
append_message operator '@oceanseat replacement Ocean directive'
delivery_enqueue oceanseat ocean push ocean-session
for _ in $(seq 1 100); do
  [ "$(cat "$PAD_STATE/ocean.count" 2>/dev/null || echo 0)" -eq 2 ] && break
  sleep 0.05
done
[ "$(grep -c '^turn-1$' "$PAD_STATE/ocean.cancels" 2>/dev/null || true)" = 1 ] \
  || fail 'superseded Ocean turn did not receive exactly one exact-id cancel'
[ "$(cat "$PAD_STATE/ocean.count")" = 2 ] || fail 'replacement Ocean turn was not accepted'
: > "$PAD_STATE/ocean.active"
wait_state oceanseat completed || fail 'replacement Ocean turn did not complete'
[ "$(state_value oceanseat generation)" = 2 ] || fail 'stale Ocean completion consumed successor generation'
[ "$(state_value oceanseat turn_id)" = turn-2 ] || fail 'successor Ocean turn_id was not retained at completion'
new_case ocean_task_cancel 'taskocean | ocean | push | ocean-session'
export STITCHPAD_PAD_DIR="$PAD_DIR"
cat > "$PAD_TASKS" <<'OCEANTASK'
# tasks

```task TASK-17
title: cancel in flight
status: in_progress
priority: high
assignee: taskocean
---
cancel this exact daemon turn
```
OCEANTASK
append_message operator '@taskocean execute TASK-17'
delivery_enqueue taskocean ocean push ocean-session
wait_state taskocean in_flight || fail 'task Ocean turn did not become in-flight'
sed -i.bak 's/status: in_progress/status: canceled/' "$PAD_TASKS"
rm -f "$PAD_TASKS.bak"
wait_state taskocean tombstoned || fail 'terminal task did not cancel in-flight Ocean turn'
[ "$(grep -c '^turn-1$' "$PAD_STATE/ocean.cancels" 2>/dev/null || true)" = 1 ] \
  || fail 'terminal task did not cancel its exact Ocean turn once'
[ ! -f "$(delivery_pending_file taskocean)" ] || fail 'canceled Ocean task remained pending'
export PATH="$old_path"
ok 'superseded directives and terminal tasks cancel exact in-flight Ocean turns'

# A terminal task invalidates its directive before adapter submission.
new_case cancel 'cancel | mock | push | cancel-target'
cat > "$PAD_TASKS" <<'TASKS'
# tasks

```task TASK-9
title: canceled delivery
status: done
priority: high
assignee: cancel
---
must never submit
```
TASKS
append_message operator '@cancel stop work on TASK-9'
delivery_enqueue cancel mock push cancel-target
wait_state cancel tombstoned || fail 'terminal task was not tombstoned'
[ ! -f "$(delivery_pending_file cancel)" ] || fail 'terminal task remained pending'
[ ! -f "$PAD_STATE/mock.cancel.count" ] || fail 'terminal task reached adapter'
grep -qF '|task_terminal|done' "$(delivery_tombstone_file cancel)" || fail 'task cancellation reason/status missing'
[ "$(cat "$PAD_STATE/seen.cancel")" -gt 0 ] || fail 'terminal task tombstone did not drain its directive cursor'
cancel_generation="$(cat "$(delivery_generation_file cancel)")"
delivery_enqueue cancel mock push cancel-target
[ "$(cat "$(delivery_generation_file cancel)")" = "$cancel_generation" ] || fail 'later watcher event rediscovered canceled directive'
ok 'terminal task cancels pending delivery before submit'

# Pull-seat ownership remains with lifecycle hooks; watcher react must not create
# any push-supervisor artifacts for it.
new_case pull 'pullseat | mock | pull | pull-target'
append_message operator '@pullseat lifecycle owns this'
react
if compgen -G "$PAD_STATE/delivery.pullseat.*" >/dev/null; then
  fail 'watcher created delivery state for a pull seat'
fi
ok 'pull-seat ownership remains unchanged'

printf 'PASS: %s delivery supervision assertions\n' "$pass"
