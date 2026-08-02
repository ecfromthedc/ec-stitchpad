#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d /tmp/stitchpad-reset-recovery.XXXXXX)"
foreign_pid=""
cleanup() {
  if [ -n "$foreign_pid" ]; then
    kill -KILL "$foreign_pid" 2>/dev/null || true
    wait "$foreign_pid" 2>/dev/null || true
  fi
  # Stop watcher producers before the watcher so a late ensure-watcher call
  # cannot recreate it during teardown.
  for n in agent push-agent unbound racer heal legacy genuine ownerfail ghost; do
    STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" heartbeat --stop "$n" >/dev/null 2>&1 || true
  done
  STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/home"
export HOME="$tmp/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

cd "$tmp"
"$SP" init --name reset-recovery >/dev/null
"$SP" join agent codex pull - >/dev/null
"$SP" heartbeat --stop agent >/dev/null 2>&1 || true

STITCHPAD_NAME=alpha "$SP" say '@agent first historical delivery' >/dev/null
STITCHPAD_NAME=beta "$SP" say '@agent second exact recovery target' >/dev/null
"$SP" wake agent >/dev/null
"$SP" wake agent >/dev/null

state="$tmp/.stitchpad/.state"
pad_canon="$(cd -P "$tmp/.stitchpad" && pwd)"
[ "$(cat "$state/seen.agent")" = "2" ] || fail "setup did not advance seen to 2"
touch "$state/dnd.agent"
STITCHPAD_PAD_DIR="$tmp" "$SP" bind-session reset-session agent >/dev/null
"$SP" heartbeat --stop agent >/dev/null 2>&1 || true

out="$("$SP" reset agent)"
contains "$out" 'cursor preserved at 2' || fail "reset did not report the preserved cursor"
[ "$(cat "$state/seen.agent")" = "2" ] || fail "default reset rewound seen cursor"
[ -f "$state/dnd.agent" ] || fail "default reset cleared DND"
[ "$(cat "$state/sessions/reset-session")" = "agent" ] || fail "default reset changed session binding"
[ ! -f "$state/pending.agent" ] || fail "default reset invented a redelivery"

rm -f "$state/dnd.agent"
[ -z "$("$SP" wake agent --peek)" ] || fail "default reset replayed delivered history"

if "$SP" reset agent --redeliver 0 >/dev/null 2>&1; then
  fail "ordinal 0 redelivery was accepted"
fi
[ "$(cat "$state/seen.agent")" = "2" ] || fail "rejected ordinal 0 changed seen cursor"
[ ! -f "$state/pending.agent" ] || fail "rejected ordinal 0 queued recovery"

out="$("$SP" reset agent --redeliver 2)"
contains "$out" 'queued exact redelivery ordinal 2' || fail "exact redelivery was not reported"
[ "$(cat "$state/seen.agent")" = "2" ] || fail "exact redelivery rewound seen cursor"
[ "$(cat "$state/pending.agent")" = "2" ] || fail "exact redelivery did not queue ordinal 2"
case "$(cat "$state/pending.agent.reset" 2>/dev/null || true)" in
  '2|'?*) ;;
  *) fail "exact redelivery omitted message-bound reset provenance" ;;
esac

hook="$(printf '{"cwd":"%s","session_id":"reset-session","stop_hook_active":false}' "$tmp" | "$SP" hook)"
contains "$hook" '"decision":"block"' || fail "bound hook did not recover queued ordinal"
contains "$hook" 'second exact recovery target' || fail "bound hook recovered the wrong ordinal"
if contains "$hook" 'first historical delivery'; then
  fail "exact recovery replayed ordinal 1 history"
fi
[ "$(cat "$state/seen.agent")" = "2" ] || fail "hook recovery rewound seen cursor"
[ ! -f "$state/pending.agent.reset" ] || fail "successful hook recovery left reset provenance"

# A same-sender addressed reply closes the canonical gate. Reject the answered
# ordinal before reset can touch ticker files or any other seat state.
STITCHPAD_NAME=agent "$SP" say '@beta handled the recovery target' >/dev/null
mkdir "$state/heartbeat.agent.lock"
printf '99999999' > "$state/heartbeat.agent.lock/pid"
printf '{"pid":99999999}' > "$state/alive.agent"
if err="$("$SP" reset agent --redeliver 2 2>&1)"; then
  fail "answered ordinal redelivery was accepted"
fi
contains "$err" 'already answered' || fail "answered ordinal rejection was not explicit"
[ -f "$state/alive.agent" ] || fail "answered validation mutated alive state"
[ -f "$state/heartbeat.agent.lock/pid" ] || fail "answered validation mutated ticker state"
[ "$(cat "$state/seen.agent")" = "2" ] || fail "answered validation changed seen cursor"
[ ! -f "$state/pending.agent" ] || fail "answered validation queued recovery"

# An unbound pull seat has no canonical Stop-hook session that could consume a
# pending marker. Reject before reset activity so the seat cannot wedge forever.
"$SP" join unbound codex pull - >/dev/null
"$SP" heartbeat --stop unbound >/dev/null 2>&1 || true
STITCHPAD_NAME=alpha "$SP" say '@unbound no bound recovery surface' >/dev/null
mkdir "$state/heartbeat.unbound.lock"
printf '99999998' > "$state/heartbeat.unbound.lock/pid"
printf '{"pid":99999998}' > "$state/alive.unbound"
if err="$("$SP" reset unbound --redeliver 1 2>&1)"; then
  fail "unbound pull-seat redelivery was accepted"
fi
contains "$err" 'requires a canonical sessions/<id> binding' || fail "unbound rejection was not explicit"
[ -f "$state/alive.unbound" ] || fail "unbound validation mutated alive state"
[ -f "$state/heartbeat.unbound.lock/pid" ] || fail "unbound validation mutated ticker state"
[ ! -f "$state/pending.unbound" ] || fail "unbound validation queued permanent recovery"

# Push seats are owned by the durable delivery supervisor, which intentionally
# clears legacy pending.<name> stamps. Reject this incompatible request instead
# of reporting a redelivery that the supervisor can silently erase.
"$SP" join push-agent ocean push push-session >/dev/null
"$SP" heartbeat --stop push-agent >/dev/null 2>&1 || true
STITCHPAD_NAME=alpha "$SP" say '@push-agent supervised delivery' >/dev/null
if err="$("$SP" reset push-agent --redeliver 1 2>&1)"; then
  fail "push-seat legacy redelivery was accepted"
fi
contains "$err" 'only supported for pull/hook seats' || fail "push-seat rejection was not explicit"
[ ! -f "$state/pending.push-agent" ] || fail "rejected push redelivery wrote a legacy pending stamp"

# A same-sender reply landing after the first validation but before the locked
# queue must win. The deterministic barrier opens that race window; the second
# validation runs under the same pad lock as `say`, queues nothing, and leaves
# neither a replay nor a permanent pending marker.
"$SP" join racer codex pull - >/dev/null
"$SP" heartbeat --stop racer >/dev/null 2>&1 || true
STITCHPAD_PAD_DIR="$tmp" "$SP" bind-session racer-session racer >/dev/null
STITCHPAD_NAME=alpha "$SP" say '@racer reply-race target' >/dev/null
racer_ord="$("$SP" wake racer --peek-ordinal)"
barrier="$tmp/reset-reply-race"
(
  trap - EXIT
  STITCHPAD_RESET_TEST_BEFORE_QUEUE_BARRIER="$barrier" \
    exec "$SP" reset racer --redeliver "$racer_ord"
) > "$tmp/reset-racer.out" 2>&1 &
reset_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
  [ -f "$barrier.ready" ] && break
  sleep 0.02
done
[ -f "$barrier.ready" ] || fail "reply-race reset never reached pre-queue barrier"
STITCHPAD_NAME=racer "$SP" say '@alpha answered during reset queue window' >/dev/null
touch "$barrier.release"
if wait "$reset_pid"; then
  fail "reply-race reset reported a queued redelivery after the gate closed"
fi
[ ! -f "$state/pending.racer" ] || fail "reply race left a permanent pending ordinal"
[ ! -f "$state/pending.racer.reset" ] || fail "reply race left reset provenance"
[ -z "$("$SP" wake racer --peek)" ] || fail "reply race replayed the answered mention"

# Once a queue is durable, a later same-sender reply closes it. The bound hook
# may self-heal both files only because the reset provenance still matches the
# pending ordinal and exact message digest.
"$SP" join heal codex pull - >/dev/null
"$SP" heartbeat --stop heal >/dev/null 2>&1 || true
STITCHPAD_PAD_DIR="$tmp" "$SP" bind-session heal-session heal >/dev/null
STITCHPAD_NAME=alpha "$SP" say '@heal queued then answered' >/dev/null
heal_ord="$("$SP" wake heal --peek-ordinal)"
"$SP" reset heal --redeliver "$heal_ord" >/dev/null
STITCHPAD_NAME=heal "$SP" say '@alpha handled after queue' >/dev/null
heal_hook="$(printf '{"cwd":"%s","session_id":"heal-session","stop_hook_active":false}' "$tmp" | "$SP" hook)"
[ -z "$heal_hook" ] || fail "closed reset-owned recovery replayed through hook"
[ ! -f "$state/pending.heal" ] && [ ! -f "$state/pending.heal.reset" ] \
  || fail "hook did not self-heal closed reset-owned recovery"

# A malformed reset provenance file is not authority to delete a pre-existing
# legacy pending marker. Fail closed and leave both visible for health/manual
# reconciliation.
"$SP" join legacy codex pull - >/dev/null
"$SP" heartbeat --stop legacy >/dev/null 2>&1 || true
STITCHPAD_PAD_DIR="$tmp" "$SP" bind-session legacy-session legacy >/dev/null
STITCHPAD_NAME=alpha "$SP" say '@legacy preserve unrelated recovery' >/dev/null
legacy_ord="$("$SP" wake legacy --peek-ordinal)"
"$SP" wake legacy >/dev/null
printf '%s' "$legacy_ord" > "$state/pending.legacy"
printf '%s' 'malformed-reset-provenance' > "$state/pending.legacy.reset"
legacy_hook="$(printf '{"cwd":"%s","session_id":"legacy-session","stop_hook_active":false}' "$tmp" | "$SP" hook)"
[ -z "$legacy_hook" ] || fail "malformed reset provenance unexpectedly recovered legacy pending"
[ "$(cat "$state/pending.legacy")" = "$legacy_ord" ] \
  || fail "hook cleared unrelated legacy pending"
[ -f "$state/pending.legacy.reset" ] || fail "hook hid malformed provenance needed for repair"

# PID reuse/legacy safety: a live unrelated process recorded in a legacy lock
# has no start/command/pad/name proof. Neither reset nor heartbeat --stop may
# signal it or delete the evidence operators need to reconcile it.
( trap - EXIT; exec sleep 60 ) &
foreign_pid=$!
mkdir -p "$state/heartbeat.racer.lock"
printf '%s' "$foreign_pid" > "$state/heartbeat.racer.lock/pid"
foreign_command="$(ps -p "$foreign_pid" -o command= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
python3 - "$state/heartbeat.racer.lock/owner" "$foreign_pid" "$foreign_command" "$pad_canon" <<'PY'
import json, sys
path, pid, command, pad = sys.argv[1:]
json.dump({"pid": int(pid), "processStart": "mismatched-start", "command": command,
           "pad": pad, "name": "racer"}, open(path, "w"), separators=(",", ":"))
PY
if "$SP" reset racer >/dev/null 2>&1; then
  fail "reset accepted a live PID with mismatched process-start proof"
fi
kill -0 "$foreign_pid" 2>/dev/null || fail "reset killed an unrelated reused PID"
[ -d "$state/heartbeat.racer.lock" ] || fail "reset removed unverified live PID evidence"
rm -f "$state/heartbeat.racer.lock/owner"
if "$SP" heartbeat --stop racer >/dev/null 2>&1; then
  fail "heartbeat stop accepted a live legacy PID without ownership proof"
fi
kill -0 "$foreign_pid" 2>/dev/null || fail "heartbeat stop killed an unrelated reused PID"
kill -KILL "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
foreign_pid=""
rm -rf "$state/heartbeat.racer.lock"

# A genuine newly-started ticker carries exact owner metadata. Reset may stop
# that proven process and restart one for the same targeted seat.
"$SP" join genuine codex push genuine-target >/dev/null
"$SP" heartbeat start genuine >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$state/heartbeat.genuine.lock/owner" ] \
    && [ -s "$state/heartbeat.genuine.lock/pid" ] && break
  sleep 0.05
done
[ -s "$state/heartbeat.genuine.lock/owner" ] \
  && [ -s "$state/heartbeat.genuine.lock/pid" ] \
  || fail "genuine ticker omitted owner metadata"
genuine_old="$(cat "$state/heartbeat.genuine.lock/pid")"
"$SP" reset genuine >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  genuine_new="$(cat "$state/heartbeat.genuine.lock/pid" 2>/dev/null || true)"
  [ -n "$genuine_new" ] && [ "$genuine_new" != "$genuine_old" ] && break
  sleep 0.05
done
[ -n "${genuine_new:-}" ] && [ "$genuine_new" != "$genuine_old" ] || fail "reset did not restart the proven ticker"
kill -0 "$genuine_old" 2>/dev/null && fail "reset left the proven old ticker running"
kill -0 "$genuine_new" 2>/dev/null || fail "reset replacement ticker is not live"
python3 - "$state/heartbeat.genuine.lock/owner" "$genuine_new" "$pad_canon" <<'PY' || fail "replacement owner metadata is not exact"
import json, sys
owner = json.load(open(sys.argv[1]))
assert owner["pid"] == int(sys.argv[2])
assert owner["pad"] == sys.argv[3]
assert owner["name"] == "genuine"
assert owner["generation"]
assert owner["processStart"]
assert owner["command"].endswith(" heartbeat start genuine")
PY
"$SP" heartbeat --stop genuine >/dev/null

# Owner publication is part of admission, not best-effort metadata. A forced
# publication failure must kill the just-forked child and remove its empty lock
# instead of exposing a live unverified ticker.
"$SP" join ownerfail codex pull - >/dev/null
"$SP" heartbeat --stop ownerfail >/dev/null 2>&1 || true
if STITCHPAD_HEARTBEAT_TEST_OWNER_WRITE_FAIL=1 "$SP" heartbeat start ownerfail >/dev/null 2>&1; then
  fail "heartbeat start masked owner publication failure"
fi
[ ! -d "$state/heartbeat.ownerfail.lock" ] || fail "owner publication failure left a lock"
[ ! -f "$state/alive.ownerfail" ] || fail "owner publication failure left live metadata"

# Whole-pad ghost cleanup also fails closed around an unverified live PID, then
# removes the same stale record once the foreign process is proven dead.
( trap - EXIT; exec sleep 60 ) &
foreign_pid=$!
mkdir -p "$state/heartbeat.ghost.lock"
printf '%s' "$foreign_pid" > "$state/heartbeat.ghost.lock/pid"
if "$SP" reset >/dev/null 2>&1; then
  fail "ghost sweep accepted an unverified live PID"
fi
kill -0 "$foreign_pid" 2>/dev/null || fail "ghost sweep killed an unrelated PID"
[ -d "$state/heartbeat.ghost.lock" ] || fail "ghost sweep deleted live unverified evidence"
kill -KILL "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
foreign_pid=""
"$SP" reset >/dev/null
[ ! -d "$state/heartbeat.ghost.lock" ] || fail "ghost sweep did not clean a dead stale lock"

echo "reset recovery ok"
