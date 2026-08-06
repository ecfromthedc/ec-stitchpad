#!/usr/bin/env bash
# setwake-bind-truth-gate.sh — bind-session's exit status is the BINDING's
# status, never the heartbeat autostart's.
#
# THE BUG (NEXT-SESSION-PROMPT OPEN #2, observed live re-pointing @glm):
# `set-wake glm push <sid>` printed
#   stitchpad: failed to bind Ocean session <sid> to @glm
# and exited 1 — while the binding HAD landed (an immediate `bind-session`
# answered "already bound (no-op)"). Mechanism: the bind-session arm ended in
#   heartbeat start "$nm" >/dev/null 2>&1 && echo "✓ heartbeat for @$nm"
# so a heartbeat-autostart failure became the arm's exit code after a
# successful bind. A false FAILURE report — the mirror image of the
# false-success class — that makes an operator retry an operation that
# already worked.
#
#   G0 fixture proof: the poisoned lock really makes `heartbeat start` fail
#   G1 set-wake exits 0 when the bind lands despite the heartbeat failure
#   G2 no "failed to bind" in that output
#   G3 the binding file actually contains the name (the bind landed)
#   G4 the heartbeat miss is still reported truthfully (not silenced)
#   G5 a REAL bind failure (sid bound to another name) still fails loudly
#   G6 MUTANT: restore the `&& echo` tail → the false failure reappears
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-setwake-truth.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
export TMPDIR="$TMP"
export HOME="$TMP/home"; mkdir -p "$HOME"
# Every probe runs against a POISONED heartbeat lock (heartbeat start fails
# before spawning) or fails before the heartbeat block, so no ticker is ever
# started and nothing needs killing (ledger P9).
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT
unset STITCHPAD_NAME CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID HERDR_ENV 2>/dev/null || true

# make_pad <dir> <toolroot> — fresh pad with @glm as an ocean/pull seat and a
# poisoned heartbeat lock (unknown file, no generation) so heartbeat start
# refuses with "malformed heartbeat lock left untouched".
make_pad() {
  local d="$1" rt="$2"
  mkdir -p "$d"
  ( cd "$d" && "$rt/bin/stitchpad" init --name setwake-gate >/dev/null 2>&1 ) || return 1
  ( cd "$d" && STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=glm \
      "$rt/bin/stitchpad" join glm ocean pull - >/dev/null 2>&1 ) || return 1
  mkdir -p "$d/.stitchpad/.state/heartbeat.glm.lock"
  printf 'junk' > "$d/.stitchpad/.state/heartbeat.glm.lock/unknown-evidence"
}

echo "=== set-wake / bind-session: exit status tells the truth about the bind ==="

PAD="$TMP/proj"
make_pad "$PAD" "$TOP/tool" || { bad "setup: init/join"; echo "=== RESULTS: $pass PASS, $((fail+1)) FAIL ==="; exit 1; }
S="$PAD/.stitchpad/.state"

# G0 — fixture proof: with the poisoned lock, heartbeat start itself fails.
_hb_out="$( cd "$PAD" && STITCHPAD_NAME=glm "$TOP/tool/bin/stitchpad" heartbeat start glm 2>&1 )"; _hb_rc=$?
if [ "$_hb_rc" -ne 0 ] && printf '%s' "$_hb_out" | grep -q "malformed heartbeat"; then
  ok "G0: poisoned lock really makes heartbeat start fail (rc=$_hb_rc) — fixture is live"
else
  bad "G0: heartbeat start did not fail as arranged (rc=$_hb_rc: $_hb_out) — every assertion below is vacuous"
fi

# G1–G4 — the observed defect, asserted on the fixed tree.
SID="sid-truth-1"
_out="$( cd "$PAD" && STITCHPAD_NAME=glm "$TOP/tool/bin/stitchpad" set-wake glm push "$SID" 2>&1 )"; _rc=$?
_bound="$(cat "$S/sessions/$SID" 2>/dev/null || true)"

[ "$_rc" -eq 0 ] \
  && ok "G1: set-wake exits 0 when the bind lands despite the heartbeat failure" \
  || bad "G1: set-wake exited $_rc on a bind that landed (false failure)"

if printf '%s' "$_out" | grep -q "failed to bind"; then
  bad "G2: output still claims 'failed to bind' after a successful bind"
else
  ok "G2: no false 'failed to bind' report"
fi

[ "$_bound" = "glm" ] \
  && ok "G3: binding file .state/sessions/$SID contains glm (the bind landed)" \
  || bad "G3: binding did not land (got '${_bound:-<missing>}') — G1/G2 are testing nothing"

if printf '%s' "$_out" | grep -q "heartbeat did not start"; then
  ok "G4: the heartbeat miss is still reported, not silenced"
else
  bad "G4: heartbeat failure was silenced entirely — a miss the operator can no longer see"
fi

# G5 — a REAL bind failure must still fail loudly: sid pre-bound to another name.
PAD2="$TMP/proj2"
make_pad "$PAD2" "$TOP/tool" || { bad "setup: pad2"; echo "=== RESULTS: $pass PASS, $((fail+1)) FAIL ==="; exit 1; }
SID2="sid-truth-2"
( cd "$PAD2" && STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    "$TOP/tool/bin/stitchpad" bind-session "$SID2" somebodyelse >/dev/null 2>&1 )
_out5="$( cd "$PAD2" && STITCHPAD_NAME=glm "$TOP/tool/bin/stitchpad" set-wake glm push "$SID2" 2>&1 )"; _rc5=$?
if [ "$_rc5" -ne 0 ] && printf '%s' "$_out5" | grep -q "failed to bind"; then
  ok "G5: a real bind failure (sid bound to @somebodyelse) still fails loudly (rc=$_rc5)"
else
  bad "G5: real bind failure not reported (rc=$_rc5: $_out5) — the guard no longer fires"
fi

# G6 — MUTANT: restore the `&& echo` tail; the false failure must reappear,
# proving G1/G2 can actually go red.
echo "  -- mutant: heartbeat status leaks back into bind-session's exit code --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/bin/stitchpad" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = '''    if [ "${STITCHPAD_HEARTBEAT_AUTOSTART:-1}" != "0" ]; then
      if STITCHPAD_NAME="$nm" STITCHPAD_HEARTBEAT_PARENT_PID="${STITCHPAD_HEARTBEAT_PARENT_PID:-$PPID}" \\
        "$BIN_DIR/stitchpad" heartbeat start "$nm" >/dev/null 2>&1; then
        echo "✓ heartbeat for @$nm"
      else
        echo "stitchpad: heartbeat did not start for @$nm — the session binding itself landed" >&2
      fi
    fi'''
new = '''    if [ "${STITCHPAD_HEARTBEAT_AUTOSTART:-1}" != "0" ]; then
      STITCHPAD_NAME="$nm" STITCHPAD_HEARTBEAT_PARENT_PID="${STITCHPAD_HEARTBEAT_PARENT_PID:-$PPID}" \\
        "$BIN_DIR/stitchpad" heartbeat start "$nm" >/dev/null 2>&1 \\
        && echo "✓ heartbeat for @$nm"
    fi'''
if s.count(old) != 1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once (%d)\n" % s.count(old)); sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY
if [ $? -ne 0 ]; then
  bad "G6 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  PADM="$TMP/projm"
  if make_pad "$PADM" "$MUT"; then
    SIDM="sid-truth-m"
    _outm="$( cd "$PADM" && STITCHPAD_NAME=glm "$MUT/bin/stitchpad" set-wake glm push "$SIDM" 2>&1 )"; _rcm=$?
    _boundm="$(cat "$PADM/.stitchpad/.state/sessions/$SIDM" 2>/dev/null || true)"
    if [ "$_rcm" -ne 0 ] && printf '%s' "$_outm" | grep -q "failed to bind" && [ "$_boundm" = "glm" ]; then
      ok "G6: mutant re-creates the false failure (rc=$_rcm, bind landed) — G1/G2 detect it"
    else
      bad "G6: mutant applied but the false failure did not reappear (rc=$_rcm, bound='$_boundm') — G1/G2 may be testing nothing"
    fi
  else
    bad "G6: mutant pad setup failed — INCONCLUSIVE"
  fi
fi

echo ""
echo "=== RESULTS: $pass PASS, $fail FAIL ==="
[ "$fail" -eq 0 ] || exit 1
