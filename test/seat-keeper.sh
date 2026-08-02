#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d /tmp/stitchpad-seat-keeper.XXXXXX)"
trap 'for n in alice historical dnd busy recovery durable worker mismatch finished; do STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" heartbeat --stop "$n" >/dev/null 2>&1 || true; done; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"
export HOME="$tmp/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

cd "$tmp"
"$SP" init --name seat-keeper >/dev/null
for spec in \
  'alice sid-alice' \
  'historical sid-historical' \
  'dnd sid-dnd' \
  'busy sid-busy' \
  'recovery sid-recovery' \
  'durable sid-durable' \
  'worker sid-worker' \
  'mismatch sid-mismatch' \
  'finished sid-finished'; do
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
finished_done="$(new_task finished 'already complete' done)"
finished_canceled="$(new_task finished 'explicitly canceled' canceled)"

# A genuinely unread mention plus two current tasks must coalesce into one wake.
STITCHPAD_NAME=operator "$SP" say '@alice inspect current keeper state' >/dev/null
printf 'operator-pinned-model' > "$tmp/.stitchpad/.state/seat-model.alice"
printf 'runtime-reported-model' > "$tmp/.stitchpad/.state/model.alice"

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
mkdir "$tmp/.stitchpad/.state/delivery.worker.worker.lock.d"
printf '%s' "$$" > "$tmp/.stitchpad/.state/delivery.worker.worker.lock.d/pid"
printf 'state=started\ngeneration=1\nordinal=8\n' > "$tmp/.stitchpad/.state/delivery.worker.state"

STITCHPAD_NAME=operator "$SP" say '@mismatch stale noncanonical binding' >/dev/null
printf 'someone-else' > "$tmp/.stitchpad/.state/sessions/sid-mismatch"

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
contains "$call" 'unread mention ordinal' || fail "keeper omitted the real unread ordinal"
contains "$call" "$alice_current[in_progress] current implementation" || fail "keeper omitted current in-progress work"
contains "$call" "$alice_next[todo] next focused check" || fail "keeper omitted current todo work"
contains "$out" 'woke @alice' || fail "keeper did not report the eligible seat"

for sid in sid-historical sid-dnd sid-busy sid-recovery sid-durable sid-worker sid-mismatch sid-finished; do
  if contains "$call" "$sid"; then fail "keeper woke skipped seat $sid"; fi
done
if contains "$call" "$finished_done" || contains "$call" "$finished_canceled"; then
  fail "keeper included done/canceled work"
fi
[ ! -f "$tmp/.stitchpad/.state/keeper-last.historical" ] || fail "historical mention count created work"
[ "$(cat "$tmp/.stitchpad/.state/sessions/sid-alice")" = "alice" ] || fail "keeper changed canonical binding"

echo "seat keeper ok"
