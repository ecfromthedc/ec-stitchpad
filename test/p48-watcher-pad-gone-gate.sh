#!/usr/bin/env bash
# p48-watcher-pad-gone-gate.sh — a watcher must not outlive its pad.
#
# THE PAIN, measured: 219 live watch.sh processes on the operator's laptop, every
# one belonging to a pad that no longer existed, growing ~10 per test run. The
# event loop was `fswatch -0 "$PAD_MD" | while read -r -d "" _ev; do react; done`,
# which has NO TICK: once the pad directory is deleted fswatch can never deliver
# another event, so react() — which holds every liveness check — is never called
# again. The watcher is not hung; it is correctly waiting for something that
# cannot arrive.
#
# Two earlier attempts failed and are recorded in the ledger: a check inside
# react() is a no-op (react never runs), and signalling the worker just gets it
# respawned, because watch.sh is its own launcher/worker supervisor.
#
#   G1  a watcher starts on a healthy pad
#   G2  deleting the pad DIRECTORY makes the watcher exit on its own
#   G3  it does not leave an orphan fswatch child behind
#   G4  a missing pad FILE alone is TOLERATED (an outer `git stash -u` does this)
#   G5  MUTANT: restore the tickless pipeline -> G2 goes RED
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/p48.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
STARTED_PIDS=""
cleanup() { _rc=$?
  for _p in $STARTED_PIDS; do kill -KILL "$_p" 2>/dev/null || true; done
  rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

napp() { perl -e "select(undef,undef,undef,$1)" 2>/dev/null || true; }

# $1 = tool root, $2 = tag -> echoes the pad dir
make_pad() {
  # Separate statements on purpose: in a single `local a=$1 b=$2 c=$TMP/$b`, all
  # right-hand sides are expanded BEFORE the builtin assigns anything, so $b is
  # still unset and `set -u` aborts the function.
  local rt="$1" tag="$2"
  local pj="$TMP/$tag"
  mkdir -p "$pj/proj" "$pj/home"
  ( cd "$pj/proj"
    env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID HOME="$pj/home" STITCHPAD_HOME="$rt" \
        STITCHPAD_TERMINAL_NAMESPACE="p48$tag" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        "$rt/bin/stitchpad" init --name "p48$tag" >/dev/null 2>&1
    env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID HOME="$pj/home" STITCHPAD_HOME="$rt" \
        STITCHPAD_TERMINAL_NAMESPACE="p48$tag" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        STITCHPAD_NAME=a "$rt/bin/stitchpad" join a cli pull - >/dev/null 2>&1 )
  printf '{"who":"a","pid":%s,"ts":%s}\n' "$$" "$(date +%s)" > "$pj/proj/.stitchpad/.state/alive.a"
  echo "$pj/proj/.stitchpad"
}
start_watch() { # $1=tool root $2=tag $3=pad
  ( cd "$TMP/$2/proj"
    env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID HOME="$TMP/$2/home" STITCHPAD_HOME="$1" \
        STITCHPAD_TERMINAL_NAMESPACE="p48$2" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        STITCHPAD_PAD_DIR="$3" "$1/bin/stitchpad" watch start ) >/dev/null 2>&1
}
# Count only OUR OWN watcher pids. Counting every process under the tool root
# made the gate depend on whatever else on the machine happened to be running —
# it failed against leftovers from unrelated manual testing, which is a gate
# lying about the code under test.
count_mine() { local n=0 p; for p in $1; do kill -0 "$p" 2>/dev/null && n=$((n+1)); done; echo "$n"; }
pids_for() { pgrep -f "$1/bin/watch\.sh" 2>/dev/null | tr '\n' ' '; }

echo "=== P48: a watcher must not outlive its pad ==="
echo ""

RT="$ROOT/tool"
PAD="$(make_pad "$RT" a)"
PRE_PIDS="$(pids_for "$RT")"     # whatever was already running, not ours
start_watch "$RT" a "$PAD"
napp 4
# Take the DELTA, not every watcher under the tool root: other suites (and the
# release gate running them in sequence) leave watchers of their own around, and
# counting those made this gate fail on unrelated activity — a gate lying about
# the code under test, for the second time in this file.
MINE=""
for _p in $(pids_for "$RT"); do
  case " $PRE_PIDS " in *" $_p "*) ;; *) MINE="$MINE $_p" ;; esac
done
STARTED_PIDS="$MINE"
n="$(count_mine "$MINE")"
[ "$n" -gt 0 ] && ok "G1 a watcher started on a healthy pad (n=$n)" || bad "G1 no watcher started"

fsw_before="$(pgrep -f 'fswatch -0' 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$PAD"
napp 30
n="$(count_mine "$MINE")"
[ "$n" -eq 0 ] && ok "G2 the watcher exited on its own once the pad was gone" \
                || bad "G2 $n watcher(s) still running 30s after the pad was deleted"
fsw_after="$(pgrep -f 'fswatch -0' 2>/dev/null | wc -l | tr -d ' ')"
[ "$fsw_after" -le "$fsw_before" ] && ok "G3 no orphan fswatch left behind ($fsw_before -> $fsw_after)" \
                                    || bad "G3 orphan fswatch leaked ($fsw_before -> $fsw_after)"

# G4 — a missing FILE alone must NOT kill the watcher
PAD2="$(make_pad "$RT" b)"
start_watch "$RT" b "$PAD2"
napp 4
PRE2="$PRE_PIDS $MINE"
MINE2=""
for _p in $(pids_for "$RT"); do
  case " $PRE2 " in *" $_p "*) ;; *) MINE2="$MINE2 $_p" ;; esac
done
STARTED_PIDS="$STARTED_PIDS $MINE2"
mv "$PAD2/stitchpad.md" "$TMP/stashed.md" 2>/dev/null || true
napp 20
n="$(count_mine "$MINE2")"
mv "$TMP/stashed.md" "$PAD2/stitchpad.md" 2>/dev/null || true
[ "$n" -gt 0 ] && ok "G4 a missing pad FILE alone is tolerated (a stash must not kill it)" \
               || bad "G4 the watcher died on a transiently missing pad file"
for _p in $(pgrep -f "$RT/bin/watch\.sh" 2>/dev/null); do kill -KILL "$_p" 2>/dev/null; done
napp 2

# ── G6: a missing fswatch must FAIL LOUDLY, not silently ────────────
# Found by k3 reviewing its own P48 fix. Without fswatch on PATH the watcher used
# to start, take its lock, log "fswatch: command not found", and then BOTH
# `watch start` and `watch status` reported success — while no mention was ever
# delivered. Silence class, on the first-run path of anyone who has not installed
# fswatch.
PADF="$(make_pad "$RT" f)"
printf '{"who":"a","pid":%s,"ts":%s}\n' "$$" "$(date +%s)" > "$PADF/.state/alive.a"
out="$( cd "$TMP/f/proj" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID HOME="$TMP/f/home" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin STITCHPAD_HOME="$RT" STITCHPAD_TERMINAL_NAMESPACE=p48f \
        STITCHPAD_PAD_DIR="$PADF" "$RT/bin/stitchpad" watch start 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'fswatch'; then
  ok "G6 a missing fswatch fails loudly and names the fix (rc=$rc)"
else
  bad "G6 missing fswatch did not fail loudly (rc=$rc): $(printf '%s' "$out" | head -1)"
fi

# G5 — MUTANT: restore the tickless pipeline
echo ""
echo "  -- mutant: the tickless fswatch pipeline --"
MUT="$TMP/mut"; mkdir -p "$MUT"; cp -R "$RT/." "$MUT/"
python3 - "$MUT/bin/watch.sh" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
i = s.index('WATCH_EVENT_FIFO="$PAD_STATE/.watch-events.$$"')
s = s[:i] + 'fswatch -0 "$PAD_MD" | while read -r -d "" _ev; do react </dev/null; done\n'
open(p, 'w', encoding='utf-8').write(s)
PY
if [ $? -ne 0 ]; then
  bad "G5 MUTANT DID NOT APPLY -- INCONCLUSIVE, not a pass"
else
  PAD3="$(make_pad "$MUT" c)"
  start_watch "$MUT" c "$PAD3"
  napp 4
  STARTED_PIDS="$STARTED_PIDS $(pgrep -f "$MUT/bin/watch\.sh" 2>/dev/null | tr '\n' ' ')"
  MMINE="$(pids_for "$MUT")"; m0="$(count_mine "$MMINE")"
  rm -rf "$PAD3"
  napp 30
  m1="$(count_mine "$MMINE")"
  if [ "$m0" -gt 0 ] && [ "$m1" -gt 0 ]; then
    ok "G5 the tickless loop leaves the watcher alive ($m1) — G2 detects it"
  else
    bad "G5 mutant did not reproduce the leak (started=$m0 after=$m1)"
  fi
  for _p in $(pgrep -f "$MUT/bin/watch\.sh" 2>/dev/null); do kill -KILL "$_p" 2>/dev/null; done
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "P48 GREEN — watchers do not outlive their pads"
