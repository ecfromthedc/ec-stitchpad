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
  pkill -TERM -f "$TMP" 2>/dev/null || true
  sleep 0.1
  pkill -KILL -f "$TMP" 2>/dev/null || true
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
printf '%s|%s|%s|%s\n' "$name" "$count" "${SP_TARGET:-}" "$body" >> "$state/mock.calls"
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
  printf 'test-hold' > "$lock/token"
  date +%s > "$lock/born"
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
wait_state failover error || fail 'failed generic in-flight work was not held honestly'
[ -f "$(delivery_successor_file failover)" ] || fail 'generic successor was not queued behind uncertain work'
wait_no_worker failover || fail 'failed generic worker did not release'
delivery_start_worker failover
wait_state failover completed || fail 'old generation failure stranded newer accepted work'
[ "$(state_value failover generation)" = 2 ] || fail 'replacement generation did not own completion'
[ "$(cat "$PAD_STATE/mock.failover.count")" = 2 ] || fail 'explicit recovery did not drain queued successor honestly'
ok 'generic successor queues honestly behind uncertain in-flight work'

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
if [ -f "$state/ocean.valid_ack_nonzero" ]; then
  printf '%s' "$turn" > "$state/ocean.active"
  printf '{"ok":true,"session_id":"ocean-session","turn_id":"%s"}\n' "$turn"
  exit 7
fi
if [ "$count" -gt 1 ] && [ -s "$state/ocean.active" ]; then
  printf '%s' "$(cat "$state/ocean.active")" > "$state/ocean.overlap"
fi
printf '%s' "$turn" > "$state/ocean.active"
printf '%s\n' "$*" >> "$state/ocean.args"
[ -f "$state/ocean.pause_before_ack" ] && sleep 5
if [ -f "$state/ocean.invalid_ack" ]; then printf '{invalid ack\n'; exit 0; fi
printf '{"ok":true,"session_id":"ocean-session","turn_id":"%s"}\n' "$turn"
[ -f "$state/ocean.pause_after_ack" ] && sleep 5
exit 0
HEARTBEAT
cat > "$ocean_bin/curl" <<'CURL'
#!/usr/bin/env bash
state="$STITCHPAD_PAD_DIR/.state"
url="${!#}"
if [[ "$url" == */cancel ]]; then
  turn="${url%/cancel}"; turn="${turn##*/}"
  printf '%s\n' "$turn" >> "$state/ocean.cancels"
  if [ ! -f "$state/ocean.cancel_reject" ] \
     && [ "$(cat "$state/ocean.active" 2>/dev/null || true)" = "$turn" ]; then : > "$state/ocean.active"; fi
  if [ -f "$state/ocean.cancel_delay" ]; then
    printf '%s' "$turn" > "$state/ocean.active"
    printf '%s' "$turn" > "$state/ocean.cancel.requested"
  fi
  out=""
  while [ "$#" -gt 0 ]; do
    [ "$1" = -o ] && { shift; out="$1"; }
    shift
  done
  if [ -f "$state/ocean.cancel_reject" ]; then
    [ -n "$out" ] && printf '{"ok":false,"state":"errored","message":"request not found"}\n' > "$out"
  else
    [ -n "$out" ] && printf '{"ok":true,"state":"cancelling"}\n' > "$out"
  fi
  printf '202'
  exit 0
fi
if [ -f "$state/ocean.cancel.requested" ]; then
  turn="$(cat "$state/ocean.cancel.requested")"
  polls=$(( $(cat "$state/ocean.cancel.polls" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$polls" > "$state/ocean.cancel.polls"
  if [ "$polls" -lt 3 ]; then
    printf '{"ok":true,"requests":[{"request_id":"%s","session_id":"ocean-session","state":"cancelling","started_at":"2099-01-01T00:00:00Z"}]}\n' "$turn"
  else
    : > "$state/ocean.active"
    rm -f "$state/ocean.cancel.requested"
    printf '{"ok":true,"requests":[{"request_id":"%s","session_id":"ocean-session","state":"cancelled","started_at":"2099-01-01T00:00:00Z"}]}\n' "$turn"
  fi
  exit 0
fi
active="$(cat "$state/ocean.active" 2>/dev/null || true)"
if [ -f "$state/ocean.ambiguous" ]; then
  printf '{"ok":true,"requests":[{"request_id":"turn-a","session_id":"ocean-session","state":"running","started_at":"2099-01-01T00:00:00Z"},{"request_id":"turn-b","session_id":"ocean-session","state":"running","started_at":"2099-01-01T00:00:01Z"}]}\n'
  exit 0
fi
if [ -n "$active" ]; then
  printf '{"ok":true,"requests":[{"request_id":"%s","session_id":"ocean-session","state":"running","started_at":"2099-01-01T00:00:00Z"}]}\n' "$active"
else
  count="$(cat "$state/ocean.count" 2>/dev/null || echo 0)"
  if [ "$count" -gt 0 ]; then printf '{"ok":true,"requests":[{"request_id":"turn-%s","state":"completed"}]}\n' "$count"
  else printf '{"ok":true,"requests":[]}\n'; fi
fi
CURL
chmod +x "$ocean_bin/ocean-heartbeat" "$ocean_bin/curl"
old_path="$PATH"; export PATH="$ocean_bin:$PATH"
append_message operator '@oceanseat stale Ocean directive'
printf 'kimi-k2.5' > "$PAD_STATE/seat-model.oceanseat"
delivery_enqueue oceanseat ocean push ocean-session
wait_state oceanseat in_flight || fail 'Ocean turn did not persist accepted in-flight state'
[ "$(state_value oceanseat turn_id)" = turn-1 ] || fail 'Ocean turn_id was not persisted'
grep -q -- '--model kimi-k2.5' "$PAD_STATE/ocean.args" || fail 'per-seat Ocean model was not forwarded'
touch "$PAD_STATE/ocean.cancel_delay"
append_message operator '@oceanseat replacement Ocean directive'
delivery_enqueue oceanseat ocean push ocean-session
for _ in $(seq 1 100); do
  [ "$(cat "$PAD_STATE/ocean.count" 2>/dev/null || echo 0)" -eq 2 ] && break
  sleep 0.05
done
[ "$(grep -c '^turn-1$' "$PAD_STATE/ocean.cancels" 2>/dev/null || true)" = 1 ] \
  || fail 'superseded Ocean turn did not receive exactly one exact-id cancel'
[ "$(cat "$PAD_STATE/ocean.count")" = 2 ] || fail 'replacement Ocean turn was not accepted'
[ ! -s "$PAD_STATE/ocean.overlap" ] || fail 'replacement submitted before old Ocean cancellation became terminal'
: > "$PAD_STATE/ocean.active"
wait_state oceanseat completed || fail 'replacement Ocean turn did not complete'
[ "$(state_value oceanseat generation)" = 2 ] || {
  cat "$(delivery_state_file oceanseat)" >&2
  cat "$(delivery_tombstone_file oceanseat)" >&2 2>/dev/null || true
  cat "$PAD_STATE/delivery.oceanseat.log" >&2 2>/dev/null || true
  fail 'stale Ocean completion consumed successor generation'
}
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

new_case ocean_ack_crash 'ackseat | ocean | push | ocean-session'
export STITCHPAD_PAD_DIR="$PAD_DIR"
touch "$PAD_STATE/ocean.pause_after_ack"
append_message operator '@ackseat survive kill after daemon ack'
delivery_enqueue ackseat ocean push ocean-session
for _ in $(seq 1 100); do [ -s "$(delivery_ack_file ackseat 1)" ] && break; sleep 0.05; done
[ -s "$(delivery_ack_file ackseat 1)" ] || fail 'generation-bound ack was not durable before adapter returned'
worker_pid="$(cat "$(delivery_worker_lock ackseat)/pid")"
kill -KILL "$worker_pid" 2>/dev/null || true
wait "$worker_pid" 2>/dev/null || true
sleep 0.1; rm -f "$PAD_STATE/ocean.pause_after_ack"
delivery_start_worker ackseat
for _ in $(seq 1 100); do [ "$(state_value ackseat state)" = in_flight ] && break; sleep 0.05; done
[ "$(cat "$PAD_STATE/ocean.count")" = 1 ] || fail 'restart duplicated an already-acked Ocean turn'
: > "$PAD_STATE/ocean.active"
wait_state ackseat completed || fail 'restarted worker did not reconcile durable ack'

new_case ocean_unknown 'unknownseat | ocean | push | ocean-session'
export STITCHPAD_PAD_DIR="$PAD_DIR"
touch "$PAD_STATE/ocean.pause_before_ack" "$PAD_STATE/ocean.ambiguous"
append_message operator '@unknownseat quarantine ambiguous accepted turn'
delivery_enqueue unknownseat ocean push ocean-session
for _ in $(seq 1 100); do [ "$(cat "$PAD_STATE/ocean.count" 2>/dev/null || echo 0)" -eq 1 ] && break; sleep 0.05; done
unknown_worker="$(cat "$(delivery_worker_lock unknownseat)/pid")"
unknown_child="$(pgrep -P "$unknown_worker" 2>/dev/null | head -1 || true)"
[ -n "$unknown_child" ] && kill -KILL "$unknown_child" 2>/dev/null || true
kill -KILL "$unknown_worker" 2>/dev/null || true
wait "$unknown_worker" 2>/dev/null || true
sleep 0.1; rm -f "$PAD_STATE/ocean.pause_before_ack"
delivery_start_worker unknownseat
wait_state unknownseat acceptance_unknown || fail 'ambiguous accept window was not quarantined'
[ "$(cat "$PAD_STATE/ocean.count")" = 1 ] || fail 'ambiguous accept window auto-resubmitted'
[ ! -f "$PAD_STATE/seen.unknownseat" ] || fail 'ambiguous acceptance advanced seen'
if STITCHPAD_PAD_DIR="$PAD_DIR" "$ROOT/tool/bin/stitchpad" set-wake unknownseat push new-session ocean >/dev/null 2>&1; then
  fail 'retarget erased an unresolved Ocean acceptance outcome'
fi
[ -f "$(delivery_pending_file unknownseat)" ] || fail 'refused retarget discarded unresolved pending work'
grep -qF 'unknownseat | ocean | push | ocean-session' "$PAD_MD" \
  || fail 'refused retarget mutated the old Ocean target'

new_case ocean_bad_ack 'badackseat | ocean | push | ocean-session'
export STITCHPAD_PAD_DIR="$PAD_DIR"
touch "$PAD_STATE/ocean.invalid_ack"
append_message operator '@badackseat quarantine invalid ack after admission'
delivery_enqueue badackseat ocean push ocean-session
wait_state badackseat acceptance_unknown || fail 'invalid post-admission ack was not quarantined'
[ "$(cat "$PAD_STATE/ocean.count")" = 1 ] || fail 'invalid post-admission ack was replayed'
[ ! -f "$PAD_STATE/seen.badackseat" ] || fail 'invalid post-admission ack advanced seen'
[ -f "$(delivery_submit_file badackseat 1)" ] || fail 'invalid post-admission ack lost its durable submit marker'

new_case ocean_nonzero_ack 'nonzeroseat | ocean | push | ocean-session'
export STITCHPAD_PAD_DIR="$PAD_DIR"
touch "$PAD_STATE/ocean.valid_ack_nonzero"
append_message operator '@nonzeroseat supervise the admitted turn despite wrapper exit'
delivery_enqueue nonzeroseat ocean push ocean-session
wait_state nonzeroseat in_flight || fail 'valid ack did not dominate nonzero adapter exit'
[ "$(state_value nonzeroseat turn_id)" = turn-1 ] || fail 'nonzero valid ack turn id was not persisted'
[ "$(cat "$PAD_STATE/ocean.count")" = 1 ] || fail 'nonzero valid ack was replayed'
[ ! -f "$PAD_STATE/seen.nonzeroseat" ] || fail 'nonzero valid ack advanced seen before completion'
: > "$PAD_STATE/ocean.active"
wait_state nonzeroseat completed || fail 'nonzero valid ack did not remain supervised to completion'

new_case ocean_dnd 'oceandnd | ocean | push | ocean-session'
export STITCHPAD_PAD_DIR="$PAD_DIR"
append_message operator '@oceandnd cancel in-flight work while DND is on'
delivery_enqueue oceandnd ocean push ocean-session
wait_state oceandnd in_flight || fail 'Ocean DND fixture did not become in-flight'
touch "$(sp_dnd_file oceandnd)"
wait_state oceandnd deferred_dnd || fail 'DND did not cancel and defer the exact Ocean turn'
[ "$(grep -c '^turn-1$' "$PAD_STATE/ocean.cancels" 2>/dev/null || true)" = 1 ] \
  || fail 'Ocean DND did not cancel its exact turn once'
[ "$(cat "$PAD_STATE/ocean.count")" = 1 ] || fail 'Ocean DND rediscovered its durable ack and resubmitted'
[ ! -f "$PAD_STATE/seen.oceandnd" ] || fail 'Ocean DND consumed seen before resumed completion'
rm -f "$(sp_dnd_file oceandnd)"
for _ in $(seq 1 100); do [ "$(cat "$PAD_STATE/ocean.count" 2>/dev/null || echo 0)" -eq 2 ] && break; sleep 0.05; done
[ "$(cat "$PAD_STATE/ocean.count")" = 2 ] || fail 'Ocean DND-off did not submit one fresh turn'
: > "$PAD_STATE/ocean.active"
wait_state oceandnd completed || fail 'Ocean DND-off turn did not complete'

new_case cancel_contract 'cancelapi | ocean | push | ocean-session'
export STITCHPAD_PAD_DIR="$PAD_DIR"
printf 'turn-reject' > "$PAD_STATE/ocean.active"; touch "$PAD_STATE/ocean.cancel_reject"
if delivery_cancel_ocean_turn cancelapi turn-reject hostile_reject; then
  fail '2xx ok:false cancel response was accepted as canceled'
fi
[ "$(cat "$(delivery_cancel_dir cancelapi turn-reject)/result")" = cancel_pending ] \
  || fail 'rejected still-running cancel did not remain durably pending'

new_case cancel_lock 'lockseat | ocean | push | ocean-session'
export STITCHPAD_PAD_DIR="$PAD_DIR"
printf 'turn-lock' > "$PAD_STATE/ocean.active"
touch "$PAD_STATE/ocean.cancel_delay"
stale_lock="$(delivery_cancel_dir lockseat turn-lock)/attempt.lock.d"
mkdir -p "$stale_lock"
printf '%s|definitely-not-this-process-start|stale-token|1\n' "$$" > "$stale_lock/owner"
if ! delivery_cancel_ocean_turn lockseat turn-lock stale_pid_reuse; then
  fail 'stale cancel mutex with reused pid identity was not recovered'
fi
[ ! -e "$stale_lock" ] || fail 'recovered cancel mutex left its claim behind'
if compgen -G "$(delivery_cancel_dir lockseat turn-lock)/attempt.claim.*" >/dev/null \
   || compgen -G "$(delivery_cancel_dir lockseat turn-lock)/attempt.stale.*" >/dev/null; then
  fail 'recovered cancel mutex orphaned owner metadata'
fi
live_lock="$(delivery_cancel_dir lockseat turn-live)/attempt.lock.d"
mkdir -p "$live_lock"
live_start="$(delivery_process_start "$$")"
printf '%s|%s|live-token|%s\n' "$$" "$live_start" "$(date +%s)" > "$live_lock/owner"
SP_DELIVERY_CANCEL_LOCK_ATTEMPTS=5 SP_DELIVERY_CANCEL_LOCK_SLEEP_SECONDS=0.01 \
  delivery_cancel_ocean_turn lockseat turn-live live_owner && fail 'live cancel mutex admitted a second owner'
[ -d "$live_lock" ] || fail 'cancel mutex recovery deleted a verified live owner'
grep -qF "$$|$live_start|live-token|" "$live_lock/owner" || fail 'live cancel mutex owner metadata changed'
rm -rf "$live_lock"

export PATH="$old_path"
ok 'superseded directives and terminal tasks cancel exact in-flight Ocean turns'

new_case dnd 'dndseat | mock | push | dnd-target'
touch "$(sp_dnd_file dndseat)"
append_message operator '@dndseat wait until DND is off'
delivery_enqueue dndseat mock push dnd-target
wait_state dndseat deferred_dnd || fail 'DND did not durably defer push delivery'
[ ! -f "$PAD_STATE/mock.dndseat.count" ] || fail 'DND seat submitted adapter work'
[ ! -f "$PAD_STATE/seen.dndseat" ] || fail 'DND seat consumed seen cursor'
rm -f "$(sp_dnd_file dndseat)"
wait_state dndseat completed || fail 'DND-off did not resume pending delivery'
ok 'DND defers durably without submit or cursor consumption'

new_case controls 'controlseat | mock | push | old-target'
printf slow > "$PAD_STATE/mock.controlseat.mode"
append_message operator '@controlseat operator-controlled work'
delivery_enqueue controlseat mock push old-target
wait_state controlseat started || fail 'control worker never started'
STITCHPAD_PAD_DIR="$PAD_DIR" "$ROOT/tool/bin/stitchpad" stop >/dev/null
[ ! -d "$(delivery_worker_lock controlseat)" ] || fail 'operator stop left worker lock'
sleep 1.1
[ "$(state_value controlseat state)" != completed ] || fail 'work completed after operator stop'
printf success > "$PAD_STATE/mock.controlseat.mode"
printf '{"pid":%s}\n' "$$" > "$PAD_STATE/alive.test-operator"
STITCHPAD_PAD_DIR="$PAD_DIR" "$ROOT/tool/bin/stitchpad" restart >/dev/null
wait_state controlseat completed || fail 'operator restart did not resume pending work'
STITCHPAD_PAD_DIR="$PAD_DIR" "$ROOT/tool/bin/stitchpad" stop >/dev/null
rm -f "$PAD_STATE/alive.test-operator"
append_message operator '@controlseat retarget this directive'
printf slow > "$PAD_STATE/mock.controlseat.mode"
delivery_enqueue controlseat mock push old-target
wait_state controlseat started || fail 'retarget fixture did not start old target'
STITCHPAD_PAD_DIR="$PAD_DIR" "$ROOT/tool/bin/stitchpad" set-wake controlseat push new-target mock >/dev/null
[ ! -d "$(delivery_worker_lock controlseat)" ] || fail 'retarget left old worker alive'
[ ! -f "$(delivery_pending_file controlseat)" ] || fail 'retarget kept frozen old target pending'
printf success > "$PAD_STATE/mock.controlseat.mode"
delivery_enqueue controlseat mock push new-target
wait_state controlseat completed || fail 'retargeted worker did not complete'
grep -qF '|new-target|' "$PAD_STATE/mock.calls" || fail 'retargeted delivery used frozen old target'
printf slow > "$PAD_STATE/mock.controlseat.mode"
append_message operator '@controlseat leave stops this exact worker'
delivery_enqueue controlseat mock push new-target
wait_state controlseat started || fail 'leave fixture did not start worker'
STITCHPAD_PAD_DIR="$PAD_DIR" "$ROOT/tool/bin/stitchpad" leave controlseat >/dev/null
[ ! -d "$(delivery_worker_lock controlseat)" ] || fail 'leave left exact delivery worker alive'
if compgen -G "$PAD_STATE/delivery.controlseat.*" >/dev/null; then
  ls -ld "$PAD_STATE"/delivery.controlseat.* >&2
  fail 'leave retained delivery cruft'
fi
! sp_user_exists controlseat || fail 'leave retained roster seat'
sp_term_lock_release controlseat 2>/dev/null || true
ok 'stop, restart, leave, and retarget control exact workers safely'

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
[ ! -f "$PAD_STATE/seen.cancel" ] || fail 'terminal task cancellation consumed the seen cursor'
cancel_generation="$(cat "$(delivery_generation_file cancel)")"
delivery_enqueue cancel mock push cancel-target
[ "$(cat "$(delivery_generation_file cancel)")" = "$cancel_generation" ] || fail 'later watcher event rediscovered canceled directive'
ok 'terminal task cancels pending delivery before submit'

new_case keeper 'keeperseat | mock | push | keeper-target'
append_message operator '@keeperseat keeper accepted this mention'
keeper_meta="$(sp_current_to_meta keeperseat 0)"
IFS='|' read -r keeper_ord _ keeper_id _ <<< "$keeper_meta"
printf '%s|%s|accepted|keeper-attempt-1\n' "$keeper_ord" "$keeper_id" > "$(delivery_keeper_reservation keeperseat)"
delivery_enqueue keeperseat mock push keeper-target
[ ! -f "$(delivery_pending_file keeperseat)" ] || fail 'supervisor duplicated keeper-reserved mention'
[ ! -f "$PAD_STATE/mock.keeperseat.count" ] || fail 'keeper-reserved mention reached watcher adapter'
ok 'keeper reservation prevents a racing supervisor duplicate'

new_case keeper_task 'keepertask | mock | push | keeper-target'
append_message operator '@keepertask unrelated unread while keeper task admission is unresolved'
printf '0|keeper-task-TASK-7|accepted|keeper-attempt-task\n' > "$(delivery_keeper_reservation keepertask)"
delivery_enqueue keepertask mock push keeper-target
[ ! -f "$(delivery_pending_file keepertask)" ] || fail 'ordinal-0 keeper task reservation did not suppress watcher admission'
[ ! -f "$PAD_STATE/mock.keepertask.count" ] || fail 'watcher submitted while keeper task reservation owned the seat'

new_case keeper_bad 'keeperbad | mock | push | keeper-target'
append_message operator '@keeperbad malformed keeper record must fail closed'
printf 'malformed-reservation\n' > "$(delivery_keeper_reservation keeperbad)"
delivery_enqueue keeperbad mock push keeper-target
[ ! -f "$(delivery_pending_file keeperbad)" ] || fail 'malformed keeper reservation failed open'
[ -f "$(delivery_keeper_invalid keeperbad)" ] || fail 'malformed keeper reservation lacked durable evidence'
grep -q '^reason=bad_ordinal$' "$(delivery_keeper_invalid keeperbad)" \
  || fail 'malformed keeper evidence omitted its reason'
ok 'task and malformed keeper reservations quarantine watcher admission'

new_case publish_stop 'publishseat | mock | push | publish-target'
append_message operator '@publishseat stop during owner publication'
export SP_DELIVERY_TEST_PRE_SPAWN_DELAY=0.5
delivery_enqueue publishseat mock push publish-target & publish_enqueue=$!
for _ in $(seq 1 100); do [ -d "$(delivery_worker_lock publishseat)" ] && break; sleep 0.01; done
[ -d "$(delivery_worker_lock publishseat)" ] || fail 'publication race fixture never created worker claim'
STITCHPAD_PAD_DIR="$PAD_DIR" "$ROOT/tool/bin/stitchpad" stop >/dev/null
wait "$publish_enqueue"
unset SP_DELIVERY_TEST_PRE_SPAWN_DELAY
sleep 0.6
[ ! -d "$(delivery_worker_lock publishseat)" ] || fail 'stop during publication retained worker claim'
[ ! -f "$PAD_STATE/mock.publishseat.count" ] || fail 'worker delivered after stop during publication'
ok 'stop closes the pre-owner publication window'

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
