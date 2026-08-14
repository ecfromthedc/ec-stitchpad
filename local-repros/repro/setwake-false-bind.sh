#!/bin/bash
# OPEN #2 reproduction: `set-wake <who> push <sid>` prints "failed to bind"
# while the binding actually LANDS. Mechanism: bind-session's trailing
# heartbeat-autostart block is `heartbeat start && echo`, so a heartbeat
# failure becomes bind-session's exit status even after a successful bind.
# Deterministic heartbeat failure: malformed heartbeat lock (unknown file,
# no generation) -> sp_ticker_stop_owned refuses -> heartbeat start exit 1.
# Usage: setwake-false-bind.sh [tool-root]
set -u
RT="${1:-/Users/ecfromthedc/dev/rt/rt-stitchpad-prs/wt/tool}"
W="$(mktemp -d "${TMPDIR:-/tmp}/setwake.XXXXXX")"
mkdir -p "$W/home" "$W/proj"
ln -sfn "$RT" "$W/home/.stitchpad"
export HOME="$W/home"
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID HERDR_ENV STITCHPAD_NAME 2>/dev/null || true

cd "$W/proj" || exit 2
"$RT/bin/stitchpad" init --name setwake-repro >/dev/null 2>&1
# join glm as an ocean seat, pull, no target, no heartbeat side effects at join
STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=glm \
  "$RT/bin/stitchpad" join glm ocean pull - >/dev/null 2>&1
S="$W/proj/.stitchpad/.state"

# Poison: malformed heartbeat lock for @glm — unknown file, no generation file.
mkdir -p "$S/heartbeat.glm.lock"
printf 'junk' > "$S/heartbeat.glm.lock/unknown-evidence"

SID="sid-repro-1"
out="$W/setwake.out"
STITCHPAD_NAME=glm "$RT/bin/stitchpad" set-wake glm push "$SID" >"$out" 2>&1
rc=$?

bound="$(cat "$S/sessions/$SID" 2>/dev/null || echo '(missing)')"
echo "--- set-wake output (rc=$rc) ---"
cat "$out"
echo "--- binding file .state/sessions/$SID: $bound ---"

if grep -q 'failed to bind' "$out" && [ "$bound" = "glm" ]; then
  echo "REPRODUCED: set-wake reported bind failure while the binding landed"
  status=0
else
  echo "NOT REPRODUCED"
  status=1
fi
rm -rf "$W"
exit $status
