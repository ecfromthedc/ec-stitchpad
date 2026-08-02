#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d /tmp/stitchpad-seat-keeper.XXXXXX)"
keeper_one=""
keeper_two=""
cleanup() {
  for pid in "$keeper_one" "$keeper_two"; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  done
  for n in alice historical mentiononly dnd busy recovery durable worker mismatch finished acceptedcrash ambiguity; do
    STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" heartbeat --stop "$n" >/dev/null 2>&1 || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/home"
export HOME="$tmp/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

if grep -Eq '\$SP" wake|wake[^#]*--peek' "$ROOT/tool/bin/seat-keeper.sh"; then
  fail "task-only keeper contains an unread wake/peek call"
fi

cd "$tmp"
"$SP" init --name seat-keeper >/dev/null
for spec in \
  'alice sid-alice' \
  'historical sid-historical' \
  'mentiononly sid-mentiononly' \
  'dnd sid-dnd' \
  'busy sid-busy' \
  'recovery sid-recovery' \
  'durable sid-durable' \
  'worker sid-worker' \
  'mismatch sid-mismatch' \
  'finished sid-finished' \
  'acceptedcrash sid-acceptedcrash' \
  'ambiguity sid-ambiguity'; do
  set -- $spec
  "$SP" join "$1" ocean push "$2" >/dev/null
  "$SP" heartbeat --stop "$1" >/dev/null 2>&1 || true
done
"$SP" daemon stop >/dev/null 2>&1 || true

new_task() {
  local who="$1" title="$2" status="$3" id
  id="$(STITCHPAD_NAME=operator "$SP" task new "$title" --to "$who" | awk 'NR==1{print $1}')"
  "$SP" wake "$who" >/dev/null 2>&1 || true
  [ "$status" = "todo" ] || "$SP" task move "$id" "$status" >/dev/null
  printf '%s\n' "$id"
}

alice_current="$(new_task alice 'current implementation' in_progress)"
alice_next="$(new_task alice 'next focused check' todo)"
worker_task="$(new_task worker 'supervisor-owned task' in_progress)"
finished_done="$(new_task finished 'already complete' done)"
finished_canceled="$(new_task finished 'explicitly canceled' canceled)"

# A genuinely unread mention plus two current tasks produces a task-only wake.
# The keeper must neither inspect nor advance the delivery cursor.
STITCHPAD_NAME=operator "$SP" say '@alice inspect current keeper state' >/dev/null
alice_seen_before="$(cat "$tmp/.stitchpad/.state/seen.alice" 2>/dev/null || echo 0)"
printf 'operator-pinned-model' > "$tmp/.stitchpad/.state/seat-model.alice"
printf 'runtime-reported-model' > "$tmp/.stitchpad/.state/model.alice"

# An unread-only seat belongs exclusively to the watcher/supervisor and must
# never become keeper work.
STITCHPAD_NAME=operator "$SP" say '@mentiononly watcher owns this unread' >/dev/null
mention_seen_before="$(cat "$tmp/.stitchpad/.state/seen.mentiononly" 2>/dev/null || echo 0)"

# Historical mention exists in the transcript but has already crossed seen.*.
STITCHPAD_NAME=operator "$SP" say '@historical old mention already delivered' >/dev/null
"$SP" wake historical >/dev/null

STITCHPAD_NAME=operator "$SP" say '@dnd do not disturb' >/dev/null
touch "$tmp/.stitchpad/.state/dnd.dnd"

STITCHPAD_NAME=operator "$SP" say '@busy active turn owns this seat' >/dev/null
STITCHPAD_NAME=operator "$SP" say '@recovery pending delivery owns this seat' >/dev/null
printf '1' > "$tmp/.stitchpad/.state/pending.recovery"

STITCHPAD_NAME=operator "$SP" say '@durable supervisor owns accepted generation' >/dev/null
printf '1|7|message-7|TASK-7|0|ocean|push|sid-durable' > "$tmp/.stitchpad/.state/delivery.durable.pending"

STITCHPAD_NAME=operator "$SP" say '@worker live delivery worker owns this seat' >/dev/null
worker_seen_before="$(cat "$tmp/.stitchpad/.state/seen.worker" 2>/dev/null || echo 0)"
mkdir "$tmp/.stitchpad/.state/delivery.worker.worker.lock.d"
printf '%s' "$$" > "$tmp/.stitchpad/.state/delivery.worker.worker.lock.d/pid"
printf 'state=started\ngeneration=1\nordinal=8\n' > "$tmp/.stitchpad/.state/delivery.worker.state"

STITCHPAD_NAME=operator "$SP" say '@mismatch stale noncanonical binding' >/dev/null
printf 'someone-else' > "$tmp/.stitchpad/.state/sessions/sid-mismatch"

# Hostile roster rows are injected directly to exercise the consumer boundary.
# No state path may be constructed from any of these names.
awk '
  /^```roster/ { inroster=1 }
  inroster && /^```$/ {
    print "../escape | ocean | push | sid-escape"
    print "bad/name | ocean | push | sid-bad"
    print ".hidden | ocean | push | sid-hidden"
    print "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | ocean | push | sid-long"
    inroster=0
  }
  { print }
' "$tmp/.stitchpad/stitchpad.md" > "$tmp/.stitchpad/stitchpad.md.hostile"
mv "$tmp/.stitchpad/stitchpad.md.hostile" "$tmp/.stitchpad/stitchpad.md"

mockbin="$tmp/mockbin"
mkdir "$mockbin"
calls="$tmp/heartbeat.calls"
cat > "$mockbin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *sid-busy*) printf '{"session":{"active_turn":{"id":"turn-1"}}}\n' ;;
  *)          printf '{"session":{"active_turn":null}}\n' ;;
esac
EOF
cat > "$mockbin/ocean-heartbeat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KEEPER_CALLS"
[ "${KEEPER_MOCK_BLOCK:-0}" = "0" ] || {
  while [ ! -f "$KEEPER_MOCK_RELEASE" ]; do sleep 0.05; done
}
[ "${KEEPER_MOCK_SLEEP:-0}" = "0" ] || sleep "$KEEPER_MOCK_SLEEP"
printf '{"ok": true}\n'
EOF
chmod +x "$mockbin/curl" "$mockbin/ocean-heartbeat"

out="$(PATH="$mockbin:$PATH" KEEPER_CALLS="$calls" \
  OCEAN_HEARTBEAT_BIN="$mockbin/ocean-heartbeat" \
  STITCHPAD_KEEPER_MIN_SECONDS=0 \
  "$SP" keeper "$tmp")"

[ -f "$calls" ] || fail "keeper made no wake call"
[ "$(wc -l < "$calls" | tr -d ' ')" = "1" ] || fail "keeper did not coalesce to one eligible-seat wake"
call="$(cat "$calls")"
contains "$call" '--session-id sid-alice' || fail "keeper did not use Alice's canonical roster target"
contains "$call" '--model operator-pinned-model' || fail "keeper did not use operator-owned seat model"
if contains "$call" 'runtime-reported-model'; then fail "keeper trusted mutable runtime model metadata"; fi
if contains "$call" 'unread mention ordinal' || contains "$call" 'read --new'; then
  fail "task keeper attempted to own unread delivery"
fi
contains "$call" 'delivery supervisor exclusively owns unread mentions' \
  || fail "task keeper prompt omitted the ownership boundary"
contains "$call" "$alice_current[in_progress] current implementation" || fail "keeper omitted current in-progress work"
contains "$call" "$alice_next[todo] next focused check" || fail "keeper omitted current todo work"
contains "$out" 'woke @alice' || fail "keeper did not report the eligible seat"

for sid in sid-historical sid-mentiononly sid-dnd sid-busy sid-recovery sid-durable sid-worker sid-mismatch sid-finished sid-ambiguity; do
  if contains "$call" "$sid"; then fail "keeper woke skipped seat $sid"; fi
done
if contains "$call" "$finished_done" || contains "$call" "$finished_canceled"; then
  fail "keeper included done/canceled work"
fi
[ ! -f "$tmp/.stitchpad/.state/keeper-last.historical" ] || fail "historical mention count created work"
[ ! -f "$tmp/.stitchpad/.state/keeper-last.mentiononly" ] || fail "unread-only mention created keeper work"
[ "$(cat "$tmp/.stitchpad/.state/seen.alice" 2>/dev/null || echo 0)" = "$alice_seen_before" ] \
  || fail "keeper advanced Alice's seen cursor"
[ "$(cat "$tmp/.stitchpad/.state/seen.mentiononly" 2>/dev/null || echo 0)" = "$mention_seen_before" ] \
  || fail "keeper advanced unread-only seat cursor"
[ "$(cat "$tmp/.stitchpad/.state/seen.worker" 2>/dev/null || echo 0)" = "$worker_seen_before" ] \
  || fail "keeper advanced watcher-owned cursor"
[ "$(cat "$tmp/.stitchpad/.state/sessions/sid-alice")" = "alice" ] || fail "keeper changed canonical binding"
[ -z "$(find "$tmp/.stitchpad/.state" -maxdepth 2 -name '*escape*' -o -name '*bad*' -o -name '*hidden*' 2>/dev/null)" ] \
  || fail "malformed roster name reached a state path"
[ ! -e "$tmp/escape" ] && [ ! -e "$tmp/.stitchpad/escape" ] || fail "roster path traversal escaped state"
[ ! -f "$tmp/.stitchpad/.state/delivery.alice.keeper-reservation" ] \
  || fail "successful keeper left durable reservation residue"

# Two keepers that observe the same eligible seat concurrently must reserve it
# with one atomic mkdir. Hold the first external call open until the second has
# attempted acquisition; exactly one accepted wake and one timestamp may result.
rm -f "$tmp/.stitchpad/.state/keeper-last.alice"
: > "$calls"
PATH="$mockbin:$PATH" KEEPER_CALLS="$calls" KEEPER_MOCK_SLEEP=1 \
  OCEAN_HEARTBEAT_BIN="$mockbin/ocean-heartbeat" STITCHPAD_KEEPER_MIN_SECONDS=600 \
  "$SP" keeper "$tmp" > "$tmp/concurrent-1.out" 2>&1 &
keeper_one=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -d "$tmp/.stitchpad/.state/keeper.alice.lock.d" ] && break
  sleep 0.05
done
[ -d "$tmp/.stitchpad/.state/keeper.alice.lock.d" ] || fail "first keeper never acquired its reservation"
PATH="$mockbin:$PATH" KEEPER_CALLS="$calls" KEEPER_MOCK_SLEEP=1 \
  OCEAN_HEARTBEAT_BIN="$mockbin/ocean-heartbeat" STITCHPAD_KEEPER_MIN_SECONDS=600 \
  "$SP" keeper "$tmp" > "$tmp/concurrent-2.out" 2>&1 &
keeper_two=$!
wait "$keeper_one" || fail "first concurrent keeper failed"
wait "$keeper_two" || fail "second concurrent keeper failed"
[ "$(wc -l < "$calls" | tr -d ' ')" = "1" ] || fail "concurrent keepers sent duplicate external wakes"
[ -f "$tmp/.stitchpad/.state/keeper-last.alice" ] || fail "accepted concurrent wake was not persisted"
[ ! -d "$tmp/.stitchpad/.state/keeper.alice.lock.d" ] || fail "successful keeper left its reservation behind"

# Even with a zero stale threshold, a PID whose process-start identity matches
# is live and must never be stolen.
rm -f "$tmp/.stitchpad/.state/keeper-last.alice"
mkdir "$tmp/.stitchpad/.state/keeper.alice.lock.d"
live_start="$(ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
printf '%s|%s|1' "$$" "$live_start" > "$tmp/.stitchpad/.state/keeper.alice.lock.d/owner"
: > "$calls"
PATH="$mockbin:$PATH" KEEPER_CALLS="$calls" \
  OCEAN_HEARTBEAT_BIN="$mockbin/ocean-heartbeat" STITCHPAD_KEEPER_MIN_SECONDS=600 \
  STITCHPAD_KEEPER_LOCK_STALE_SECONDS=0 "$SP" keeper "$tmp" >/dev/null
[ ! -s "$calls" ] || fail "keeper stole a live reservation"
[ -d "$tmp/.stitchpad/.state/keeper.alice.lock.d" ] || fail "keeper deleted a live reservation"
rm -f "$tmp/.stitchpad/.state/keeper.alice.lock.d/owner"
rmdir "$tmp/.stitchpad/.state/keeper.alice.lock.d"

# A dead owner is recoverable only through the stale-owner path. With a zero
# test threshold, its PID/start identity is proven dead, removed, and replaced.
rm -f "$tmp/.stitchpad/.state/keeper-last.alice"
mkdir "$tmp/.stitchpad/.state/keeper.alice.lock.d"
printf '99999999|dead-process|1' > "$tmp/.stitchpad/.state/keeper.alice.lock.d/owner"
: > "$calls"
PATH="$mockbin:$PATH" KEEPER_CALLS="$calls" \
  OCEAN_HEARTBEAT_BIN="$mockbin/ocean-heartbeat" STITCHPAD_KEEPER_MIN_SECONDS=600 \
  STITCHPAD_KEEPER_LOCK_STALE_SECONDS=0 "$SP" keeper "$tmp" >/dev/null
[ "$(wc -l < "$calls" | tr -d ' ')" = "1" ] || fail "stale keeper reservation was not safely recovered"
[ ! -d "$tmp/.stitchpad/.state/keeper.alice.lock.d" ] || fail "stale recovery left a keeper lock"
[ -z "$(find "$tmp/.stitchpad/.state" -maxdepth 1 -name 'keeper-last.alice.tmp.*' -print -quit)" ] \
  || fail "keeper left an atomic-write temp file"

# Accept-before-persist / SIGKILL ambiguity: the pre-submit reservation must
# exist before the mock accepts. Killing the keeper in that window may not
# produce a second wake. The next run converts in_flight to acceptance_unknown,
# fails closed, and leaves the unread cursor untouched.
accepted_task="$(new_task acceptedcrash 'accepted-phase crash task' in_progress)"
accepted_seen_before="$(cat "$tmp/.stitchpad/.state/seen.acceptedcrash" 2>/dev/null || echo 0)"
printf '0|keeper-task-seeded|accepted|attempt-seeded' \
  > "$tmp/.stitchpad/.state/delivery.acceptedcrash.keeper-reservation"
touch "$tmp/.stitchpad/.state/dnd.alice"
: > "$calls"
if PATH="$mockbin:$PATH" KEEPER_CALLS="$calls" \
  OCEAN_HEARTBEAT_BIN="$mockbin/ocean-heartbeat" STITCHPAD_KEEPER_MIN_SECONDS=0 \
  "$SP" keeper "$tmp" > "$tmp/accepted-crash.out" 2>&1; then
  fail "accepted-phase crash state did not fail closed"
fi
[ ! -s "$calls" ] || fail "accepted-phase crash state was automatically resubmitted"
[ "$(cat "$tmp/.stitchpad/.state/delivery.acceptedcrash.keeper-reservation")" \
    = '0|keeper-task-seeded|accepted|attempt-seeded' ] \
  || fail "accepted-phase crash state was inferred or cleared"
[ "$(cat "$tmp/.stitchpad/.state/seen.acceptedcrash" 2>/dev/null || echo 0)" = "$accepted_seen_before" ] \
  || fail "accepted-phase crash reconciliation advanced seen"
[ ! -f "$tmp/.stitchpad/.state/keeper-last.acceptedcrash" ] \
  || fail "accepted-phase crash reconciliation advanced keeper-last"
touch "$tmp/.stitchpad/.state/dnd.acceptedcrash"

ambiguity_task="$(new_task ambiguity 'crash-window task' in_progress)"
: > "$calls"
release="$tmp/release-ambiguity"
ambiguity_seen_before="$(cat "$tmp/.stitchpad/.state/seen.ambiguity" 2>/dev/null || echo 0)"
PATH="$mockbin:$PATH" KEEPER_CALLS="$calls" KEEPER_MOCK_BLOCK=1 KEEPER_MOCK_RELEASE="$release" \
  OCEAN_HEARTBEAT_BIN="$mockbin/ocean-heartbeat" STITCHPAD_KEEPER_MIN_SECONDS=0 \
  "$SP" keeper "$tmp" > "$tmp/ambiguity-1.out" 2>&1 &
keeper_one=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
  [ -f "$tmp/.stitchpad/.state/delivery.ambiguity.keeper-reservation" ] && break
  sleep 0.05
done
[ -f "$tmp/.stitchpad/.state/delivery.ambiguity.keeper-reservation" ] \
  || fail "keeper called without a durable pre-submit reservation"
case "$(cat "$tmp/.stitchpad/.state/delivery.ambiguity.keeper-reservation")" in
  '0|'*'|in_flight|'*) ;;
  *) fail "pre-submit reservation was not in_flight" ;;
esac
kill -KILL "$keeper_one" 2>/dev/null || fail "could not kill keeper in ambiguity window"
wait "$keeper_one" 2>/dev/null || true
keeper_one=""
touch "$release"
sleep 0.1
if PATH="$mockbin:$PATH" KEEPER_CALLS="$calls" \
  OCEAN_HEARTBEAT_BIN="$mockbin/ocean-heartbeat" STITCHPAD_KEEPER_MIN_SECONDS=0 \
  STITCHPAD_KEEPER_LOCK_STALE_SECONDS=0 "$SP" keeper "$tmp" > "$tmp/ambiguity-2.out" 2>&1; then
  fail "uncertain acceptance did not fail closed"
fi
[ "$(grep -c -- '--session-id sid-ambiguity' "$calls" || true)" = "1" ] \
  || fail "uncertain acceptance was submitted more than once"
case "$(cat "$tmp/.stitchpad/.state/delivery.ambiguity.keeper-reservation")" in
  '0|'*'|acceptance_unknown|'*) ;;
  *) fail "stale in-flight reservation was not quarantined as acceptance_unknown" ;;
esac
[ "$(cat "$tmp/.stitchpad/.state/seen.ambiguity" 2>/dev/null || echo 0)" = "$ambiguity_seen_before" ] \
  || fail "ambiguous task wake advanced the unread cursor"
[ ! -f "$tmp/.stitchpad/.state/keeper-last.ambiguity" ] \
  || fail "ambiguous acceptance advanced keeper-last"

# Repeated runs remain quarantined: no automatic resubmit and no state advance.
if PATH="$mockbin:$PATH" KEEPER_CALLS="$calls" \
  OCEAN_HEARTBEAT_BIN="$mockbin/ocean-heartbeat" STITCHPAD_KEEPER_MIN_SECONDS=0 \
  STITCHPAD_KEEPER_LOCK_STALE_SECONDS=0 "$SP" keeper "$tmp" >/dev/null 2>&1; then
  fail "acceptance_unknown did not remain fail-closed"
fi
[ "$(grep -c -- '--session-id sid-ambiguity' "$calls" || true)" = "1" ] \
  || fail "acceptance_unknown was automatically resubmitted"
[ "$(cat "$tmp/.stitchpad/.state/seen.ambiguity" 2>/dev/null || echo 0)" = "$ambiguity_seen_before" ] \
  || fail "repeated ambiguity handling advanced seen"

[ -z "$(find "$tmp/.stitchpad/.state" -maxdepth 1 -name '*.tmp.*' -print -quit)" ] \
  || fail "keeper left atomic-write residue"

echo "seat keeper ok"
