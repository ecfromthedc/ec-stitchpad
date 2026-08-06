#!/usr/bin/env bash
# watcher-fswatch-restart-gate.sh — k3 F1: the watcher promised a restart that
# never came.
#
# THE PAIN: when fswatch died on a live pad, watch.sh logged
#     [stitchpad] fswatch died on a live pad — exiting for supervisor restart
# and exited 1. There is no supervisor. Nothing was watching that process, so
# the pad simply went deaf until a human happened to run a stitchpad command
# (ensure_watcher on any subcommand was the only thing that ever revived it) —
# while the log line said recovery was on its way. `watch start` refusing when
# fswatch is ABSENT was fixed earlier; this is the mid-life death.
#
# Either build the restart or stop claiming it. This builds it, bounded.
#
#   G1  the watcher SURVIVES its fswatch being killed
#   G2  ... with a new fswatch child actually running
#   G3  ... and the log says what happened, without promising a supervisor
#   G4  events flow again: a pad write after the death is still auto-committed
#   G5  a SUPERVISED watcher still exits, so bin/daemon.sh can restart it
#       (the half of F1 that was wrong: that supervisor really does exist)
#   G6  MUTANT: remove the restart → the watcher dies again
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

command -v fswatch >/dev/null 2>&1 || {
  echo "  INVALID PROBE: fswatch is not installed — this suite is about fswatch dying,"
  echo "  and without it the watcher refuses to start at all. Not scoring."
  echo "  passed: 0  failed: 1"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-fsw.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
WPIDS=""; FPIDS=""
cleanup() {
  _rc=$?
  # Only pids this suite captured itself, and only after confirming identity (P9).
  for _p in $WPIDS $FPIDS; do
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    kill "$_p" 2>/dev/null || true
    wait "$_p" 2>/dev/null || true
  done
  rm -rf "$TMP" 2>/dev/null || true
  return $_rc
}
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
naptime() { perl -e 'select(undef,undef,undef,'"$1"')'; }   # macOS has no `timeout`

build() {  # $1 = tool root, $2 = tag → pad dir
  local rt="$1" d="$TMP/pad.$2"
  mkdir -p "$d"
  ( cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="f$2-a" "$rt/bin/stitchpad" init --name "f$2" >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="f$2-a" "$rt/bin/stitchpad" join larry cli pull - >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=dale \
      STITCHPAD_TERMINAL_NAMESPACE="f$2-b" "$rt/bin/stitchpad" join dale cli pull - >/dev/null 2>&1 ) || true
  printf '%s' "$d"
}
start_watcher() {  # $1 = tool root, $2 = pad dir, $3 = log → sets WPID
  ( cd "$2" && STITCHPAD_NAME=larry exec /bin/bash "$1/bin/watch.sh" > "$3" 2>&1 ) &
  WPID=$!; WPIDS="$WPIDS $WPID"
}
wait_fswatch() {  # $1 = watcher pid → prints the child pid, or empty
  local i=0 p=""
  while [ "$i" -lt 20 ]; do
    p="$(pgrep -P "$1" fswatch 2>/dev/null | head -1)"
    [ -n "$p" ] && { printf '%s' "$p"; return 0; }
    naptime 0.4; i=$(( i + 1 ))
  done
  return 1
}
commits() { git --git-dir="$1/.stitchpad/stitchpad-git" rev-list --count HEAD 2>/dev/null || echo 0; }

echo "=== k3 F1: the watcher must not promise a rescue nobody performs ==="
echo ""

P="$(build "$TOP/tool" 1)"
LOG="$TMP/w1.log"
start_watcher "$TOP/tool" "$P" "$LOG"
FSW="$(wait_fswatch "$WPID" || true)"
if [ -z "${FSW:-}" ]; then
  bad "INVALID PROBE — the watcher never spawned an fswatch child; nothing below measures anything"
else
  FPIDS="$FPIDS $FSW"
  kill "$FSW" 2>/dev/null || true
  naptime 8
  if kill -0 "$WPID" 2>/dev/null; then
    ok "G1 the watcher survived its fswatch being killed"
  else
    bad "G1 the watcher exited when fswatch died — the pad is deaf until someone runs a command"
  fi
  NEW="$(pgrep -P "$WPID" fswatch 2>/dev/null | head -1 || true)"
  FPIDS="$FPIDS $NEW"
  if [ -n "${NEW:-}" ] && [ "${NEW:-}" != "$FSW" ]; then
    ok "G2 a NEW fswatch is running (pid $NEW, was $FSW) — the watcher has eyes again"
  else
    bad "G2 no replacement fswatch — the watcher is alive but blind, which is worse than dead"
  fi
  if grep -q 'restarted it' "$LOG" 2>/dev/null; then
    ok "G3 the log records the restart"
  else
    bad "G3 the restart is not in the log: $(tail -2 "$LOG" | tr '\n' ' ')"
  fi
  if grep -q 'supervisor restart' "$LOG" 2>/dev/null; then
    bad "G3b the log still promises a supervisor restart that does not exist"
  else
    ok "G3b the log no longer promises a supervisor that does not exist"
  fi
  # G4 — the restart is only worth anything if events actually flow again.
  _c0="$(commits "$P")"
  ( cd "$P" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE=f1-a "$TOP/tool/bin/stitchpad" say "after the fswatch death" >/dev/null 2>&1 ) || true
  printf '\n<!-- poke -->\n' >> "$P/.stitchpad/stitchpad.md"
  naptime 6
  _c1="$(commits "$P")"
  if [ "$_c1" -gt "$_c0" ]; then
    ok "G4 a pad write after the death still reaches the watcher (commits $_c0 → $_c1)"
  else
    bad "G4 the watcher stopped reacting to pad writes (commits stuck at $_c0) — the restart is cosmetic"
  fi
  kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true
fi

# G5 — a SUPERVISED watcher must still exit and let bin/daemon.sh restart it.
# This is the half of k3 F1 that was wrong: `stitchpad daemon start` really does
# run a supervisor loop, so exiting there is correct and recovering in place
# would rob it of the restart (and break watcher-races.sh's ownerless gap).
P5="$(build "$TOP/tool" 5)"
LOG5="$TMP/w5.log"
( cd "$P5" && STITCHPAD_NAME=larry STITCHPAD_WATCH_SUPERVISED=1 \
    exec /bin/bash "$TOP/tool/bin/watch.sh" > "$LOG5" 2>&1 ) &
WPID=$!; WPIDS="$WPIDS $WPID"
SFSW="$(wait_fswatch "$WPID" || true)"
if [ -z "${SFSW:-}" ]; then
  bad "G5 INVALID PROBE — the supervised watcher never spawned fswatch"
else
  FPIDS="$FPIDS $SFSW"
  kill "$SFSW" 2>/dev/null || true
  naptime 8
  if kill -0 "$WPID" 2>/dev/null; then
    bad "G5 a SUPERVISED watcher stayed alive — it stole the restart from bin/daemon.sh"
    kill "$WPID" 2>/dev/null || true
  else
    ok "G5 a supervised watcher exits and leaves the restart to bin/daemon.sh"
  fi
  if grep -q 'supervisor will restart' "$LOG5" 2>/dev/null; then
    ok "G5b ... and says so, which is TRUE in that mode"
  else
    bad "G5b the supervised exit did not explain itself: $(tail -2 "$LOG5" | tr '\n' ' ')"
  fi
fi

# ── G6 MUTANT: take the restart away ──────────────────────────────────────
echo "  -- mutant: no fswatch restart --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/bin/watch.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='      if [ "$_fsw_restarts" -le "${STITCHPAD_FSWATCH_MAX_RESTARTS:-5}" ]; then'
new='      if false; then'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "G6 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  P2="$(build "$MUT" 2)"
  LOG2="$TMP/w2.log"
  start_watcher "$MUT" "$P2" "$LOG2"
  MFSW="$(wait_fswatch "$WPID" || true)"
  if [ -z "${MFSW:-}" ]; then
    bad "G6 INVALID PROBE — the mutant watcher never spawned fswatch"
  else
    FPIDS="$FPIDS $MFSW"
    kill "$MFSW" 2>/dev/null || true
    naptime 8
    if kill -0 "$WPID" 2>/dev/null; then
      bad "G6 mutant applied but the watcher survived anyway — G1 may be testing nothing"
      kill "$WPID" 2>/dev/null || true
    else
      ok "G6 without the restart the watcher dies on fswatch's death — G1 detects it"
    fi
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "F1 GREEN — the watcher puts its own eyes back, and says so honestly when it cannot"
