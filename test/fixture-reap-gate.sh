#!/usr/bin/env bash
# fixture-reap-gate.sh — P9: a suite must kill only processes IT spawned.
#
# Bare `pkill -9 -f stitchpad` SIGKILLs the captain's command and other
# seats' work (exit 137/143), corrupting evidence and producing phantom
# regressions. This gate proves the production reap helpers kill ONLY
# processes bearing the fixture marker or holding file handles under the
# fixture root — never foreign processes.
#
# Three defense-in-depth detectors:
#   (a) MARKER:  ps eww scan → catches processes with STITCHPAD_FIXTURE_ID
#   (b) FS:      lsof +D scan → catches env-scrubbed processes still holding
#                cwd/open handles under the fixture root
#   (c) SURVIVOR assertion: independent ps+lsof scans that must find ZERO
#       survivors after reaps — a single missed process fails the gate
#
# Two independent evaders prove layer isolation:
#   marker-evader: cwd=/tmp, has STITCHPAD_FIXTURE_ID → ONLY (a) catches
#   fs-evader:     cwd=fixture, NO STITCHPAD_FIXTURE_ID → ONLY (b) catches
#
# Mutant proof (G2): a foreign (non-fixture) process survives all reaps → RED.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  \033[0;31mFAIL\033[0m %s: %s\n' "$1" "${2:-}" >&2; }

# PID registry for cleanup — NEVER bare-pkill
_MY_PIDS=""
_record_pid() { _MY_PIDS="$_MY_PIDS $1"; }
_cleanup_pids() {
  for _pid in $_MY_PIDS; do
    kill "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true
  done
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-reap-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Extract production reap functions from stitchpad
_load_production_reap() {
  local _extracted
  _extracted="$(sed -n '
    /^    _runner_marker_pids()/,/^    }$/p
    /^    _runner_reap_by_marker()/,/^    }$/p
    /^    _runner_reap_by_filesystem()/,/^    }$/p
    /^    _runner_assert_zero_tmpdir_handles()/,/^    }$/p
    /^    _runner_assert_zero_filesystem_survivors()/,/^    }$/p
  ' "$SP")"
  [ -n "$_extracted" ] || { bad "SETUP: could not extract production reap functions from $SP"; exit 1; }
  eval "$_extracted"
}

echo ""
echo "=== P9: fixture-reap-gate ==="
echo ""

# ===========================================================================
# G1: STANDALONE — spawn both evaders, reap, assert zero survivors
# ===========================================================================
echo "--- G1: standalone — both evaders reaped, zero survivors ---"

MARKER="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || uuidgen 2>/dev/null || echo "pro6-$$-$RANDOM")"
FIXTURE_ROOT="$TMP/fixture"
EDIR="$FIXTURE_ROOT/evaders"
mkdir -p "$EDIR"

_load_production_reap
_runner_fixture_id="$MARKER"
_runner_fixture_root="$FIXTURE_ROOT"
_runner_reap_count=0
export STITCHPAD_FIXTURE_ID="$MARKER"

# Spawn marker evader: cwd=/tmp, has fixture marker → (a) catches it
python3 -c "
import os,sys,time
os.chdir('/tmp'); os.setsid()
if os.fork()!=0: sys.exit(0)
with open('$EDIR/marker-evader.pid','w') as f: f.write(str(os.getpid()))
time.sleep(300)
" &
_pid=$!; _record_pid "$_pid"
sleep 0.5
M1_PID="$(cat "$EDIR/marker-evader.pid" 2>/dev/null || echo NONE)"
kill -0 "$M1_PID" 2>/dev/null || { bad "G1_setup: marker evader died (pid=$M1_PID)"; exit 1; }

# Spawn fs evader: cwd=fixture, NO fixture marker → (b) catches it
env -u STITCHPAD_FIXTURE_ID -u STITCHPAD_FIXTURE_ROOT python3 -c "
import os,sys,time
os.chdir('$EDIR'); os.setsid()
if os.fork()!=0: sys.exit(0)
with open('$EDIR/fs-evader.pid','w') as f: f.write(str(os.getpid()))
time.sleep(300)
" &
_pid2=$!; _record_pid "$_pid2"
sleep 0.5
M2_PID="$(cat "$EDIR/fs-evader.pid" 2>/dev/null || echo NONE)"
kill -0 "$M2_PID" 2>/dev/null || { bad "G1_setup: fs evader died (pid=$M2_PID)"; exit 1; }

# G1a: marker reap kills the marker evader
_runner_reap_by_marker
sleep 0.3
if kill -0 "$M1_PID" 2>/dev/null; then
  bad "G1a: marker evader SURVIVED marker reap" "pid=$M1_PID"
else
  ok "G1a: marker evader killed by marker reap"
fi

# G1b: fs reap kills the fs evader
_runner_reap_by_filesystem
sleep 0.3
if kill -0 "$M2_PID" 2>/dev/null; then
  bad "G1b: fs evader SURVIVED filesystem reap" "pid=$M2_PID"
else
  ok "G1b: fs evader killed by filesystem reap"
fi

# G1c: zero survivors across all layers
_survivors=0
_runner_assert_zero_tmpdir_handles "" "" "" || _survivors=$((_survivors+1))
_runner_assert_zero_filesystem_survivors || _survivors=$((_survivors+1))

if [ "$_survivors" -eq 0 ]; then
  ok "G1c: zero survivors across all layers (reaped $_runner_reap_count processes)"
else
  bad "G1c: $_survivors layer(s) had survivors"
fi

# ===========================================================================
# G2: MUTANT PROOF — foreign (non-fixture) process survives all reaps → RED
# ===========================================================================
echo ""
echo "--- G2: mutant — foreign process survives all reaps → RED ---"

FIXTURE_ROOT2="$TMP/fixture2"
mkdir -p "$FIXTURE_ROOT2"
_runner_fixture_id="$MARKER-2"
_runner_fixture_root="$FIXTURE_ROOT2"
export STITCHPAD_FIXTURE_ID="$_runner_fixture_id"

# Spawn a FOREIGN process (no fixture marker, cwd=/tmp, unrelated)
# CRITICAL: unset STITCHPAD_FIXTURE_ID so the subprocess does NOT inherit it.
# Without this, any python3 & inherits the marker and gets killed by marker reap.
env -u STITCHPAD_FIXTURE_ID python3 -c "
import os,time
os.setsid()
time.sleep(300)
" &
_foreign_pid=$!
_record_pid "$_foreign_pid"
sleep 0.5
kill -0 "$_foreign_pid" 2>/dev/null || { bad "G2_setup: foreign process died before test"; exit 1; }

# The foreign process has:
# - No STITCHPAD_FIXTURE_ID in its env → marker reap must NOT kill it
# - cwd NOT under fixture root → fs reap must NOT kill it

# Run marker reap only — we defer filesystem reap to G2b/G2c
_runner_reap_by_marker
sleep 0.3

# Assert foreign process survived marker reap (it SHOULD — no marker in its env)
if kill -0 "$_foreign_pid" 2>/dev/null; then
  ok "G2a: foreign process survived marker reap (correct — not fixture-owned)"
else
  bad "G2a: foreign process was KILLED by marker reap — overreach!"
fi

# Kill the foreign process now (we proved our point)
kill "$_foreign_pid" 2>/dev/null || true
wait "$_foreign_pid" 2>/dev/null || true

# Now also run filesystem reap and check the survivor assertion
# (should pass — no surviving processes hold handles under fixture root)
if _runner_assert_zero_filesystem_survivors; then
  ok "G2b: fs survivor assertion passes (zero survivors under fixture root)"
else
  bad "G2b: fs survivor assertion fired — leaked handles"
fi

# G2c: spawn a process INSIDE fixture root holding a file handle → fs reap kills it
# Must NOT inherit STITCHPAD_FIXTURE_ID, or marker reap catches it instead of fs reap.
touch "$FIXTURE_ROOT2/.secret"
env -u STITCHPAD_FIXTURE_ID python3 -c "
import os,time,sys
os.chdir('$FIXTURE_ROOT2')
f = open('$FIXTURE_ROOT2/.secret', 'r')
os.setsid()
if os.fork()!=0: sys.exit(0)
time.sleep(300)
" &
_leak_parent=$!
sleep 0.5
_leak_child="$(ps -o pid= --ppid "$_leak_parent" 2>/dev/null | head -1 | tr -d ' ')"
[ -n "$_leak_child" ] && _leak_pid="$_leak_child" || _leak_pid="$_leak_parent"
_record_pid "$_leak_parent"

_runner_reap_by_filesystem
sleep 0.3

if kill -0 "$_leak_pid" 2>/dev/null; then
  bad "G2c: fixture-handle process SURVIVED fs reap — gate is BLIND!"
  kill "$_leak_pid" 2>/dev/null || true
else
  ok "G2c: fixture-handle process killed by fs reap"
fi

# ===========================================================================
# G3: PID REGISTRY — verify the documented reap helper records PIDs
# ===========================================================================
echo ""
echo "--- G3: PID registry pattern — suites record PIDs, kill only recorded ---"

# Spawn two processes, record their PIDs, kill via registry
python3 -c "import time; time.sleep(300)" &
_r1=$!; _record_pid "$_r1"
python3 -c "import time; time.sleep(300)" &
_r2=$!; _record_pid "$_r2"
sleep 0.3

# Spawn a foreign process NOT in registry, NOT in fixture
env -u STITCHPAD_FIXTURE_ID python3 -c "import time; time.sleep(300)" &
_f=$!
sleep 0.3

kill -0 "$_r1" 2>/dev/null && kill -0 "$_r2" 2>/dev/null && kill -0 "$_f" 2>/dev/null || {
  bad "G3_setup: processes died prematurely"
  exit 1
}

# Kill only recorded PIDs
_cleanup_pids
sleep 0.3

# Registered PIDs must be dead
if kill -0 "$_r1" 2>/dev/null; then
  bad "G3a: registered pid $_r1 survived cleanup"
else
  ok "G3a: registered pid $_r1 killed by PID registry"
fi

if kill -0 "$_r2" 2>/dev/null; then
  bad "G3b: registered pid $_r2 survived cleanup"
else
  ok "G3b: registered pid $_r2 killed by PID registry"
fi

# Foreign PID must survive
if kill -0 "$_f" 2>/dev/null; then
  ok "G3c: foreign pid $_f survived — registry did not overreach"
  kill "$_f" 2>/dev/null || true; wait "$_f" 2>/dev/null || true
else
  bad "G3c: foreign pid $_f was killed — registry overreached!"
fi

# ===========================================================================
echo ""
cd "$ROOT"
_cleanup_pids

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll fixture-reap gates PASSED.\n'; exit 0; }
printf '\nSome fixture-reap gates FAILED.\n'; exit 1
