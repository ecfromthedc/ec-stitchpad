#!/usr/bin/env bash
# operator-conduct-gate.sh — P22: the operator must be able to conduct from
# the sides. A mention to a BUSY agent is acknowledged on the pad within
# seconds; the agent answers in lane context when freed.
#
# Gate structure:
#   G1: mention busy agent → busy-ack on pad within 15s
#   G2: agent freed → queued mention delivered, answer logged
#   G3: idle agent → immediate answer (no mid-lane ack)
#   G4: MUTANT — delete ack markers → no ack, RED
#
# The watcher starts via 'stitchpad watch start' after alive files are written.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  \033[0;31mFAIL\033[0m %s: %s\n' "$1" "${2:-}" >&2; }

_MY_PIDS=""
_record_pid() { _MY_PIDS="$_MY_PIDS $1"; }
_cleanup_pids() {
  for _pid in $_MY_PIDS; do
    kill "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true
  done
}
_kill_path() {
  for _pid in $(ps aux 2>/dev/null | grep "$1" | grep -v grep | awk '{print $2}'); do
    kill "$_pid" 2>/dev/null || true
  done
  sleep 0.5
}

_write_alive() {
  local state="$1" who="$2" pid="${3:-$$}"
  printf '{"who":"%s","pid":%s,"ts":%s}\n' "$who" "$pid" "$(date +%s)" > "$state/alive.$who"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-operator-conduct.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

[ -x "$ROOT/tool/adapters/test-busy.sh" ] || chmod +x "$ROOT/tool/adapters/test-busy.sh"

echo ""
echo "=== P22: operator-conduct-gate ==="
echo ""

# ===========================================================================
# G1: BUSY AGENT — mention acked within seconds
# ===========================================================================
echo "--- G1: busy agent — ack within 15s ---"

G1_HOME="$TMP/g1-home"
G1_PAD="$TMP/g1-pad"
mkdir -p "$G1_HOME" "$G1_PAD"
G1_STATE="$G1_PAD/.stitchpad/.state"
NS="conduct-g1-$$"

HOME="$G1_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$SP" init "$G1_PAD" --force --name conduct-g1 >/dev/null 2>&1
mkdir -p "$G1_STATE"

echo "busy" > "$G1_STATE/.test-busy.control"

HOME="$G1_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G1_PAD/.stitchpad" \
  "$SP" join operator codex pull - >/dev/null 2>&1

HOME="$G1_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=pro5 STITCHPAD_PAD_DIR="$G1_PAD/.stitchpad" \
  "$SP" join pro5 test-busy push term-pro5 >/dev/null 2>&1

# Write alive files then start the watcher
_write_alive "$G1_STATE" operator
_write_alive "$G1_STATE" pro5

HOME="$G1_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_PAD_DIR="$G1_PAD/.stitchpad" \
  "$SP" watch start >/dev/null 2>&1

sleep 2
echo "  pad ready, watcher started, pro5 is busy"

# Send mention as operator
HOME="$G1_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G1_PAD/.stitchpad" \
  "$SP" say "@pro5 what lane are you on and what is your ETA?" >/dev/null 2>&1 || true

echo "  mention sent: @pro5 what lane..."

# Wait for ack
_ack=0
for i in $(seq 1 30); do
  if grep -q 'mid-lane' "$G1_PAD/.stitchpad/stitchpad.md" 2>/dev/null; then
    _ack=1
    break
  fi
  sleep 0.5
done

if [ "$_ack" -eq 1 ]; then
  ok "G1a: busy-ack appeared on pad within ${i}0s"
  _line="$(grep 'mid-lane' "$G1_PAD/.stitchpad/stitchpad.md" | tail -1)"
  echo "       ack: $_line"
else
  bad "G1a: no ack after 15s"
  echo "       watchers: $(ps aux | grep "watch.sh.*$TMP" | grep -v grep | wc -l | tr -d ' ')"
  echo "       delivery files: $(ls "$G1_STATE"/delivery.* 2>/dev/null || echo none)"
  echo "       ack markers: $(ls "$G1_STATE"/.busy-ack.* 2>/dev/null || echo none)"
  echo "       watcher log (last 20 lines):"
  tail -20 "$G1_STATE/watch.log" 2>/dev/null || echo "       (none)"
fi

if grep -q 'pro5.*mid-lane' "$G1_PAD/.stitchpad/stitchpad.md" 2>/dev/null; then
  ok "G1b: ack names @pro5"
else
  bad "G1b: ack does not name @pro5"
fi

if grep -qi 'queued' "$G1_PAD/.stitchpad/stitchpad.md" 2>/dev/null; then
  ok "G1c: ack says queued"
else
  bad "G1c: ack missing 'queued'"
fi

# ===========================================================================
# G2: AGENT FREE — queued mention delivered with lane context
# ===========================================================================
echo ""
echo "--- G2: agent freed — queued mention delivered ---"

echo "free:lane fix is 60% done, ETA 2 min" > "$G1_STATE/.test-busy.control"

HOME="$G1_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G1_PAD/.stitchpad" \
  "$SP" say "ping" >/dev/null 2>&1 || true

_done=0
for i in $(seq 1 20); do
  [ -f "$G1_STATE/.test-busy.done" ] && { _done=1; break; }
  sleep 0.5
done

if [ "$_done" -eq 1 ]; then
  ok "G2a: agent processed queued mention (in ${i}0s)"
else
  bad "G2a: agent did not process after 10s"
fi

if [ -f "$G1_STATE/.test-busy.last" ]; then
  _log="$(cat "$G1_STATE/.test-busy.last")"
  echo "       agent log: $_log"
  echo "$_log" | grep -q 'ETA' && ok "G2b: agent received question" || bad "G2b: agent missed question"
else
  bad "G2b: agent log missing"
fi

_kill_path "$G1_PAD"
_cleanup_pids
sleep 1

# ===========================================================================
# G3: IDLE AGENT — immediate answer
# ===========================================================================
echo ""
echo "--- G3: idle agent — immediate answer ---"

G3_HOME="$TMP/g3-home"
G3_PAD="$TMP/g3-pad"
mkdir -p "$G3_HOME" "$G3_PAD"
G3_STATE="$G3_PAD/.stitchpad/.state"
NS3="conduct-g3-$$"

HOME="$G3_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS3" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$SP" init "$G3_PAD" --force --name conduct-g3 >/dev/null 2>&1
mkdir -p "$G3_STATE"
echo "free:echo ready" > "$G3_STATE/.test-busy.control"

HOME="$G3_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS3" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G3_PAD/.stitchpad" \
  "$SP" join operator codex pull - >/dev/null 2>&1

HOME="$G3_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS3" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=echo STITCHPAD_PAD_DIR="$G3_PAD/.stitchpad" \
  "$SP" join echo test-busy push term-echo >/dev/null 2>&1

_write_alive "$G3_STATE" operator
_write_alive "$G3_STATE" echo

HOME="$G3_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS3" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_PAD_DIR="$G3_PAD/.stitchpad" \
  "$SP" watch start >/dev/null 2>&1

sleep 2
echo "  agent echo joined (free), watcher started"

HOME="$G3_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS3" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G3_PAD/.stitchpad" \
  "$SP" say "@echo status?" >/dev/null 2>&1 || true

_done3=0
for i in $(seq 1 20); do
  [ -f "$G3_STATE/.test-busy.done" ] && { _done3=1; break; }
  sleep 0.5
done

[ "$_done3" -eq 1 ] && ok "G3a: idle agent answered immediately (in ${i}0s)" \
  || bad "G3a: idle agent did not answer within 10s"

grep -qi 'mid-lane' "$G3_PAD/.stitchpad/stitchpad.md" 2>/dev/null \
  && bad "G3b: spurious mid-lane ack for idle agent" \
  || ok "G3b: no spurious mid-lane ack"

_kill_path "$G3_PAD"
_cleanup_pids
sleep 1

# ===========================================================================
# G4: MUTANT — delete ack markers → no ack
# ===========================================================================
echo ""
echo "--- G4: mutant — no ack when markers deleted ---"

G4_HOME="$TMP/g4-home"
G4_PAD="$TMP/g4-pad"
mkdir -p "$G4_HOME" "$G4_PAD"
G4_STATE="$G4_PAD/.stitchpad/.state"
NS4="conduct-g4-$$"

HOME="$G4_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS4" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$SP" init "$G4_PAD" --force --name conduct-g4 >/dev/null 2>&1
mkdir -p "$G4_STATE"
echo "busy" > "$G4_STATE/.test-busy.control"

HOME="$G4_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS4" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G4_PAD/.stitchpad" \
  "$SP" join operator codex pull - >/dev/null 2>&1

HOME="$G4_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS4" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=pro5 STITCHPAD_PAD_DIR="$G4_PAD/.stitchpad" \
  "$SP" join pro5 test-busy push term-pro5 >/dev/null 2>&1

_write_alive "$G4_STATE" operator
_write_alive "$G4_STATE" pro5

HOME="$G4_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS4" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_PAD_DIR="$G4_PAD/.stitchpad" \
  "$SP" watch start >/dev/null 2>&1

sleep 2

# Continuous marker deletion
(
  for _i in $(seq 1 30); do
    rm -f "$G4_STATE"/.busy-ack.* 2>/dev/null || true
    sleep 0.3
  done
) &
_cleaner=$!
_record_pid "$_cleaner"

HOME="$G4_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS4" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G4_PAD/.stitchpad" \
  "$SP" say "@pro5 status?" >/dev/null 2>&1 || true

sleep 8
kill "$_cleaner" 2>/dev/null || true
wait "$_cleaner" 2>/dev/null || true

grep -qi 'mid-lane' "$G4_PAD/.stitchpad/stitchpad.md" 2>/dev/null \
  && bad "G4a: ack appeared despite mutant" \
  || ok "G4a: no ack with markers deleted (mutant)"

_kill_path "$G4_PAD"
_cleanup_pids

# ===========================================================================
echo ""
cd "$ROOT"
_cleanup_pids

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll operator-conduct gates PASSED.\n'; exit 0; }
printf '\nSome operator-conduct gates FAILED.\n'; exit 1
