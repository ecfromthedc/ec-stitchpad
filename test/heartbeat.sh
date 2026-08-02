#!/usr/bin/env bash
# Regression test for per-agent heartbeat ticker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
FIXTURE_DIR="$(mktemp -d)"
cleanup() {
  for name in alice legacy; do
    STITCHPAD_PAD_DIR="$FIXTURE_DIR/.stitchpad" "$SP" heartbeat --stop "$name" >/dev/null 2>&1 || true
  done
  STITCHPAD_PAD_DIR="$FIXTURE_DIR/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT
mkdir -p "$FIXTURE_DIR/home"
export HOME="$FIXTURE_DIR/home"

cd "$FIXTURE_DIR"
"$SP" init --name heartbeat >/dev/null
PAD_CANON="$(cd -P "$FIXTURE_DIR/.stitchpad" && pwd)"

export STITCHPAD_NAME="alice"
export STITCHPAD_SESSION="session-test"
export STITCHPAD_HEARTBEAT_INTERVAL="1"
# Pin the ticker parent to this test shell. Under harnessed/non-interactive runs,
# relying on the stitchpad subprocess PPID can point at a transient wrapper and
# make the ticker exit before the mtime refresh assertion.
export STITCHPAD_HEARTBEAT_PARENT_PID="$$"
"$SP" join alice herdr push term-alice >/dev/null

"$SP" heartbeat start >/dev/null

alive="$FIXTURE_DIR/.stitchpad/.state/alive.alice"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$alive" ] && break
  sleep 0.2
done
[ -f "$alive" ]

owner="$FIXTURE_DIR/.stitchpad/.state/heartbeat.alice.lock/owner"
[ -s "$owner" ]
jq -e --arg pad "$PAD_CANON" \
  '.name == "alice" and .pad == $pad and (.generation | length > 0) and (.pid | type == "number") and (.processStart | length > 0) and (.command | contains(" heartbeat start"))' \
  "$owner" >/dev/null

jq -e '.name == "alice" and .session == "session-test" and .surface == "term-alice" and .target == "term-alice" and (.pid | type == "number") and (.ts | type == "number")' "$alive" >/dev/null
pid="$(jq -r '.pid' "$alive")"
kill -0 "$pid"

mtime1="$(stat -f %m "$alive" 2>/dev/null || stat -c %Y "$alive")"
sleep 2
mtime2="$(stat -f %m "$alive" 2>/dev/null || stat -c %Y "$alive")"
[ "$mtime2" -gt "$mtime1" ]

"$SP" heartbeat --stop alice >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ ! -e "$alive" ] && [ ! -d "$FIXTURE_DIR/.stitchpad/.state/heartbeat.alice.lock" ] && break
  sleep 0.1
done
if [ -e "$alive" ] || [ -d "$FIXTURE_DIR/.stitchpad/.state/heartbeat.alice.lock" ]; then
  echo "heartbeat state still present after --stop" >&2
  exit 1
fi
if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o stat= 2>/dev/null | grep -vq 'Z'; then
  echo "heartbeat ticker still running after --stop" >&2
  exit 1
fi

# Existing pads can have roster entries created before heartbeat tickers existed.
# Read-only commands must not backfill runtime state, while the next normal
# mutating command from an identified agent should restore the ticker.
"$SP" join legacy herdr push term-legacy >/dev/null
STITCHPAD_NAME=legacy "$SP" heartbeat --stop legacy >/dev/null
legacy_alive="$FIXTURE_DIR/.stitchpad/.state/alive.legacy"
[ ! -e "$legacy_alive" ]

(
  unset STITCHPAD_SESSION STITCHPAD_HEARTBEAT_PARENT_PID STITCHPAD_HEARTBEAT_INTERVAL
  export STITCHPAD_HEARTBEAT_AUTOSTART=1
  export STITCHPAD_NAME=legacy
  "$SP" read -n 1 >/dev/null
  [ ! -e "$legacy_alive" ]
  "$SP" say 'heartbeat backfill probe' >/dev/null
)

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$legacy_alive" ] && break
  sleep 0.2
done
[ -f "$legacy_alive" ]
jq -e '.name == "legacy" and .target == "term-legacy" and .surface == "term-legacy" and (.pid | type == "number")' "$legacy_alive" >/dev/null
legacy_pid="$(jq -r '.pid' "$legacy_alive")"
kill -0 "$legacy_pid"

STITCHPAD_NAME=legacy "$SP" heartbeat --stop legacy >/dev/null

echo "heartbeat ok"
