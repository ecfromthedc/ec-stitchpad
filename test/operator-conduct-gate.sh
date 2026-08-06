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
# Wait for the watcher to actually be RUNNING instead of assuming it comes up
# inside a fixed 2s. That assumption is why this suite flaked roughly one run in
# three: `watch start` returns before the watcher has taken its singleton lock,
# so a mention posted immediately after could land with "watchers: 0" and no ack
# ever arrived. Polling the same status the operator would read makes the wait a
# fact rather than a guess; the assertions below are unchanged.
wait_watcher() { # $1=pad dir, $2=home, $3=namespace
  local i
  for i in $(seq 1 60); do
    if HOME="$2" STITCHPAD_TERMINAL_NAMESPACE="$3" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
       STITCHPAD_PAD_DIR="$1" "$SP" watch status 2>/dev/null | grep -q 'running'; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}


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

wait_watcher "$G1_PAD/.stitchpad" "$G1_HOME" "$NS" || echo "  WARNING: watcher did not report running"
echo "  pad ready, watcher started, pro5 is busy"

# Send mention as operator
HOME="$G1_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G1_PAD/.stitchpad" \
  "$SP" say "@pro5 what lane are you on and what is your ETA?" >/dev/null 2>&1 || true

echo "  mention sent: @pro5 what lane..."

# Wait for ack
_ack=0
for i in $(seq 1 90); do
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

# G1d: EXACTLY ONE ack per mention, even though the busy seat keeps retrying.
# The "ack once per ordinal" guard used to test only the staged marker — and
# posting DELETES that marker, so once the ack was posted immediately (P49) every
# retry staged and posted again: 31 identical blocks from one mention, still
# climbing. Found by the deepseek attacker seat. A durable tombstone now carries
# the guarantee. Counted after the retry window so a regression cannot hide.
sleep 12
_ack_n="$(grep -c 'mid-lane' "$G1_PAD/.stitchpad/stitchpad.md" 2>/dev/null || echo 0)"
[ "$_ack_n" -eq 1 ] \
  && ok "G1d: exactly one ack despite repeated busy retries" \
  || bad "G1d: ack posted $_ack_n times for one mention (spam loop)"
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
for i in $(seq 1 80); do
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

wait_watcher "$G3_PAD/.stitchpad" "$G3_HOME" "$NS" || echo "  WARNING: watcher did not report running"
echo "  agent echo joined (free), watcher started"

HOME="$G3_HOME" STITCHPAD_TERMINAL_NAMESPACE="$NS3" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G3_PAD/.stitchpad" \
  "$SP" say "@echo status?" >/dev/null 2>&1 || true

_done3=0
for i in $(seq 1 80); do
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
# G4: MUTANT — disable the ack MECHANISM -> no ack
# ===========================================================================
# This used to race the mechanism: a background loop deleted .busy-ack.* every
# 0.3s and the test asserted no ack appeared. That only ever won because posting
# was DEFERRED to the next react() cycle, seconds later. Now the ack is posted
# immediately at stage time (that deferral WAS the ~50% flake — the marker was
# written and the pad line never landed), so a deleter can no longer win the race
# and the mutant stopped proving anything.
# A mutant must disable the MECHANISM, not out-run it: _busy_ack_stage is
# stubbed to a no-op in a copied tool tree. The assertion is unchanged and
# stronger — with staging disabled, no ack may appear by any path.
echo ""
echo "--- G4: mutant — no ack when staging is disabled ---"

G4_HOME="$TMP/g4-home"
G4_PAD="$TMP/g4-pad"
MUT4="$TMP/g4-tool"
mkdir -p "$G4_HOME" "$G4_PAD" "$MUT4"
cp -R "$ROOT/tool/." "$MUT4/"
if python3 - "$MUT4/bin/watch.sh" <<'MUTPY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = "_busy_ack_stage() {"
if s.count(old) != 1:
    sys.stderr.write("MUTANT DID NOT APPLY\n"); sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(old, "_busy_ack_stage() { return 0; #", 1))
MUTPY
then
  G4_STATE="$G4_PAD/.stitchpad/.state"
  NS4="conduct-g4-$$"
  SP4="$MUT4/bin/stitchpad"
  M4() { env HOME="$G4_HOME" STITCHPAD_HOME="$MUT4" STITCHPAD_TERMINAL_NAMESPACE="$NS4" \
             STITCHPAD_HEARTBEAT_AUTOSTART=0 "$@"; }

  M4 "$SP4" init "$G4_PAD" --force --name conduct-g4 >/dev/null 2>&1
  mkdir -p "$G4_STATE"
  echo "busy" > "$G4_STATE/.test-busy.control"
  M4 env STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G4_PAD/.stitchpad" "$SP4" join operator codex pull - >/dev/null 2>&1
  M4 env STITCHPAD_NAME=pro5 STITCHPAD_PAD_DIR="$G4_PAD/.stitchpad" "$SP4" join pro5 test-busy push term-pro5 >/dev/null 2>&1
  _write_alive "$G4_STATE" operator
  _write_alive "$G4_STATE" pro5
  M4 env STITCHPAD_PAD_DIR="$G4_PAD/.stitchpad" "$SP4" watch start >/dev/null 2>&1
  wait_watcher "$G4_PAD/.stitchpad" "$G4_HOME" "$NS4" || echo "  WARNING: mutant watcher did not report running"

  M4 env STITCHPAD_NAME=operator STITCHPAD_PAD_DIR="$G4_PAD/.stitchpad" "$SP4" say "@pro5 status?" >/dev/null 2>&1 || true
  sleep 12

  grep -qi 'mid-lane' "$G4_PAD/.stitchpad/stitchpad.md" 2>/dev/null \
    && bad "G4a: ack appeared despite mutant" \
    || ok "G4a: no ack when staging is disabled (mutant)"
else
  bad "G4a: MUTANT DID NOT APPLY -- INCONCLUSIVE, not a pass"
fi

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
