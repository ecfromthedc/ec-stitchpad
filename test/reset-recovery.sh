#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d /tmp/stitchpad-reset-recovery.XXXXXX)"
trap 'for n in agent push-agent unbound; do STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" heartbeat --stop "$n" >/dev/null 2>&1 || true; done; rm -rf "$tmp"' EXIT
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

hook="$(printf '{"cwd":"%s","session_id":"reset-session","stop_hook_active":false}' "$tmp" | "$SP" hook)"
contains "$hook" '"decision":"block"' || fail "bound hook did not recover queued ordinal"
contains "$hook" 'second exact recovery target' || fail "bound hook recovered the wrong ordinal"
if contains "$hook" 'first historical delivery'; then
  fail "exact recovery replayed ordinal 1 history"
fi
[ "$(cat "$state/seen.agent")" = "2" ] || fail "hook recovery rewound seen cursor"

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

echo "reset recovery ok"
