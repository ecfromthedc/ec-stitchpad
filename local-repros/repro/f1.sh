#!/bin/bash
# k3 F1: a watcher whose fswatch dies mid-life. Before: exits, promising a
# "supervisor restart" that does not exist. After: restarts its own fswatch.
set -u
RT="${1:-/Users/ecfromthedc/dev/rt/rt-stitchpad-prs/wt/tool}"
W="$(mktemp -d "${TMPDIR:-/tmp}/f1.XXXXXX")"
mkdir -p "$W/home" "$W/proj"
export HOME="$W/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID 2>/dev/null || true
SP="$RT/bin/stitchpad"
sp() { ( cd "$W/proj" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID \
   STITCHPAD_NAME="$1" STITCHPAD_TERMINAL_NAMESPACE="$2" STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" "${@:3}" ); }
sp larry a init --name f1 >/dev/null 2>&1
sp larry a join larry cli pull - >/dev/null 2>&1
sp dale  b join dale  cli pull - >/dev/null 2>&1

LOG="$W/watch.log"
( cd "$W/proj" && STITCHPAD_NAME=larry exec /bin/bash "$RT/bin/watch.sh" > "$LOG" 2>&1 ) &
WPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  FSW="$(pgrep -P "$WPID" fswatch 2>/dev/null | head -1)"
  [ -n "$FSW" ] && break
  perl -e 'select(undef,undef,undef,0.4)'
done
echo "watcher pid=$WPID  fswatch pid=${FSW:-none}"
if [ -z "${FSW:-}" ]; then echo "INVALID PROBE: no fswatch child"; kill "$WPID" 2>/dev/null; rm -rf "$W"; exit 1; fi

echo "--- killing ONLY the fswatch pid we captured ($FSW)"
kill "$FSW" 2>/dev/null
perl -e 'select(undef,undef,undef,8)'
if kill -0 "$WPID" 2>/dev/null; then
  echo "watcher SURVIVED"
else
  echo "watcher DIED"
fi
NEW="$(pgrep -P "$WPID" fswatch 2>/dev/null | head -1)"
echo "fswatch now: ${NEW:-none}  (was $FSW)"
echo "--- does the pad still deliver? post a mention and see if the watcher reacts"
sp larry a say "@dale after the fswatch death" >/dev/null 2>&1
perl -e 'select(undef,undef,undef,4)'
echo "--- watcher log:"; sed -n '1,40p' "$LOG" | grep -iE "fswatch|supervisor" | sed 's/^/    /'
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
[ -n "${NEW:-}" ] && kill "$NEW" 2>/dev/null
rm -rf "$W"
