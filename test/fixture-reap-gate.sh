#!/usr/bin/env bash
# TASK-10 v6 — defense-in-depth reap gate (port to candidate 6e11b75).
#
# Three independent detectors for fixture process residue:
#   (a) GROUP:  recorded PGID → catches ordinary children
#   (b) MARKER: ps eww scan → catches setsid/reparented escapes
#   (c) FS:     lsof +D sweep → catches env-scrubbed evaders still
#               holding cwd/open handle under the fixture root
#
# Two independent evaders prove layer isolation:
#   marker-evader:  cwd=/tmp,    has STITCHPAD_FIXTURE_ID → ONLY (b) catches
#   fs-evader:      cwd=fixture, NO STITCHPAD_FIXTURE_ID  → ONLY (c) catches
#
# Dual-mode:
#   Runner mode (STITCHPAD_FIXTURE_ID + STITCHPAD_FIXTURE_ROOT set):
#     Spawns both evaders, exits — runner reaps via all three layers.
#   Standalone mode (unset):
#     Self-provisions marker+root, extracts production reap functions
#     from tool/bin/stitchpad, spawns both evaders, calls production
#     reaps, asserts zero survivors across all layers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"

# ── production function loader ─────────────────────────────────────────────
_load_production_reap() {
  local extracted
  extracted="$(sed -n '
    /^    _runner_marker_pids()/,/^    }$/p
    /^    _runner_reap_by_marker()/,/^    }$/p
    /^    _runner_reap_by_filesystem()/,/^    }$/p
    /^    _runner_assert_zero_tmpdir_handles()/,/^    }$/p
    /^    _runner_assert_zero_filesystem_survivors()/,/^    }$/p
  ' "$SP")"
  [ -n "$extracted" ] || { echo "fixture-reap-gate: FATAL — could not extract production reap functions" >&2; exit 1; }
  eval "$extracted"
}

# ── main ───────────────────────────────────────────────────────────────────

if [ -n "${STITCHPAD_FIXTURE_ID:-}" ] && [ -n "${STITCHPAD_FIXTURE_ROOT:-}" ]; then
  echo "fixture-reap-gate: runner mode marker=${STITCHPAD_FIXTURE_ID} root=${STITCHPAD_FIXTURE_ROOT}"
  EDIR="$STITCHPAD_FIXTURE_ROOT/evaders"; mkdir -p "$EDIR"

  # marker evader: cwd=/tmp, marker inherited → (b) catches it
  python3 -c "
import os,sys,time
os.chdir('/tmp'); os.setsid()
if os.fork()!=0: sys.exit(0)
with open('$EDIR/marker-eader.pid','w') as f: f.write(str(os.getpid()))
time.sleep(300)
" &
  sleep 0.5
  M1="$(cat "$EDIR/marker-eader.pid" 2>/dev/null || echo NONE)"
  echo "fixture-reap-gate: marker-evader pid=$M1 cwd=/tmp marker=yes"

  # fs evader: cwd=fixture root, env -u strips marker → (c) catches it
  env -u STITCHPAD_FIXTURE_ID -u STITCHPAD_FIXTURE_ROOT python3 -c "
import os,sys,time
os.chdir('$EDIR'); os.setsid()
if os.fork()!=0: sys.exit(0)
with open('$EDIR/fs-eader.pid','w') as f: f.write(str(os.getpid()))
time.sleep(300)
" &
  sleep 0.5
  M2="$(cat "$EDIR/fs-eader.pid" 2>/dev/null || echo NONE)"
  echo "fixture-reap-gate: fs-evader pid=$M2 cwd=$EDIR marker=no"

  trap - EXIT
  echo "fixture-reap-gate: ok — both evaders alive, exiting for runner reap"
  exit 0
fi

# ── Standalone mode ─────────────────────────────────────────────────────
echo "fixture-reap-gate: standalone"
MARKER="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || uuidgen 2>/dev/null || echo "pro6-$$-$RANDOM")"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-fixture.XXXXXX")"
EDIR="$FIXTURE_ROOT/evaders"; mkdir -p "$EDIR"
echo "fixture-reap-gate: marker=$MARKER root=$FIXTURE_ROOT"

_load_production_reap "$SP"
_runner_fixture_id="$MARKER"
_runner_fixture_root="$FIXTURE_ROOT"
_runner_reap_count=0
export STITCHPAD_FIXTURE_ID="$MARKER"

# Spawn marker evader
python3 -c "
import os,sys,time
os.chdir('/tmp'); os.setsid()
if os.fork()!=0: sys.exit(0)
with open('$EDIR/marker-eader.pid','w') as f: f.write(str(os.getpid()))
time.sleep(300)
" &
sleep 0.5
M1="$(cat "$EDIR/marker-eader.pid" 2>/dev/null || echo NONE)"
echo "fixture-reap-gate: marker-evader pid=$M1 cwd=/tmp"

# Spawn fs evader
env -u STITCHPAD_FIXTURE_ID -u STITCHPAD_FIXTURE_ROOT python3 -c "
import os,sys,time
os.chdir('$EDIR'); os.setsid()
if os.fork()!=0: sys.exit(0)
with open('$EDIR/fs-eader.pid','w') as f: f.write(str(os.getpid()))
time.sleep(300)
" &
sleep 0.5
M2="$(cat "$EDIR/fs-eader.pid" 2>/dev/null || echo NONE)"
echo "fixture-reap-gate: fs-evader pid=$M2 cwd=$EDIR (no marker)"

sleep 0.3
echo "fixture-reap-gate: calling production reaps..."

_runner_reap_by_marker       && echo "  marker reap OK"       || echo "  marker reap FAILED"
_runner_reap_by_filesystem    && echo "  fs reap OK"           || echo "  fs reap FAILED"

F=0
_runner_assert_zero_tmpdir_handles "" "" ""  || { echo "  marker assertion FIRED"; F=$((F+1)); }
_runner_assert_zero_filesystem_survivors     || { echo "  fs assertion FIRED";     F=$((F+1)); }

if [ "$F" -eq 0 ]; then
  echo "fixture-reap-gate: PASS (reaped $_runner_reap_count, zero survivors across all layers)"
  rm -rf "$FIXTURE_ROOT"
  exit 0
else
  echo "fixture-reap-gate: FAIL ($F layer(s) had survivors)" >&2
  rm -rf "$FIXTURE_ROOT"
  exit 1
fi
