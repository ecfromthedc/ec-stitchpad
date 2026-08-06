#!/usr/bin/env bash
# ocean-idle-guard-gate.sh — k3 F13: ocean.sh's idle-guard must fail CLOSED.
#
# THE PAIN: the guard computed busy|idle|unknown but only "busy" deferred. A 3s
# timeout, a dead daemon or an unparseable body all fell through to "idle" and
# the wake fired — precisely when the daemon is too sick to answer quickly but
# still accepting turns (overloaded, GC-paused, mid-restart with a half-up
# listener), which is exactly when a session is most likely to be mid-turn. The
# result is the parked-message bug the guard exists to prevent: a wake POSTed
# into a running turn is queued as stale pending input.
# Measured before the fix, with a mock daemon and a stub ocean-heartbeat:
#   unparseable body → rc=0, wake FIRED · daemon gone → rc=0, wake FIRED
#
# seat-keeper.sh already encodes the right policy: "a probe has three outcomes,
# not two: up, down, and unknown — unknown never moves a seat."
#
#   G1 unparseable body    → deferred (rc=3), no wake
#   G2 daemon unreachable  → deferred (rc=3), no wake
#   G3 no session object   → deferred (rc=3), no wake
#   G4 busy (control)      → deferred (rc=3), no wake — unchanged
#   G5 idle (control)      → WAKES (rc=0) — the guard did not just stop delivery
#   G6 the refusal names the reason, so an operator can tell why nothing moved
#   G7 MUTANT: collapse unknown back into idle → G1 goes RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
SID="fake-session-id"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-ocean.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
SRV=""
cleanup() {
  _rc=$?
  # Only the mock daemon this suite started, by the pid it captured (P9).
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null
  [ -n "$SRV" ] && wait "$SRV" 2>/dev/null
  rm -rf "$TMP" 2>/dev/null || true
  return $_rc
}
trap cleanup EXIT

mkdir -p "$TMP/home" "$TMP/proj" "$TMP/bin" "$TMP/srv/v1/agent/sessions"

# A stub ocean-heartbeat that records every wake it is asked to perform. If the
# guard leaks, this file is the evidence.
cat > "$TMP/bin/ocean-heartbeat" <<EOF
#!/bin/bash
printf 'INVOKED %s\n' "\$*" >> "$TMP/invocations.log"
printf '{"ok":true,"turn_id":"fake-turn-1"}\n'
exit 0
EOF
chmod +x "$TMP/bin/ocean-heartbeat"

# The mock daemon is python3's stdlib file server: GET /v1/agent/sessions/<id>
# returns whatever we write into that path. No fixtures, no extra dependency.
PORT="$(python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)"
case "${PORT:-}" in ''|*[!0-9]*)
  echo "  INVALID PROBE: could not reserve a port for the mock daemon"
  echo "  passed: 0  failed: 1"; exit 1 ;;
esac
printf '%s' '{"session":{"active_turn":null}}' > "$TMP/srv/v1/agent/sessions/$SID"
( cd "$TMP/srv" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV=$!
_up=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  curl -sf -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/v1/agent/sessions/$SID" 2>/dev/null && { _up=1; break; }
  sleep 0.2
done
if [ "$_up" -ne 1 ]; then
  echo "  INVALID PROBE: the mock daemon never came up — nothing below would be measuring the guard"
  echo "  passed: 0  failed: 1"; exit 1
fi

export HOME="$TMP/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
( cd "$TMP/proj" && env -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u HERDR_PANE_ID \
    "$TOP/tool/bin/stitchpad" init --name oceang >/dev/null 2>&1
  cd "$TMP/proj" && env -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u HERDR_PANE_ID \
    STITCHPAD_NAME=eve "$TOP/tool/bin/stitchpad" join eve ocean push "$SID" >/dev/null 2>&1 ) || true
PAD="$TMP/proj/.stitchpad/stitchpad.md"
printf 'a mention body\n' > "$TMP/taskfile"

# probe <tool-root> <body|--nodaemon>  → sets RC and FIRED and OUT
probe() {
  local rt="$1" body="$2" url="http://127.0.0.1:$PORT"
  if [ "$body" = "--nodaemon" ]; then
    url="http://127.0.0.1:1"     # nothing listens: the timeout/dead-daemon case
  else
    printf '%s' "$body" > "$TMP/srv/v1/agent/sessions/$SID"
  fi
  : > "$TMP/invocations.log"
  OUT="$( PATH="$TMP/bin:$PATH" SP_TARGET="$SID" OCEAN_DAEMON_URL="$url" \
    /bin/bash "$rt/adapters/ocean.sh" mention eve "$PAD" "$TMP/taskfile" 2>&1 )"
  RC=$?
  FIRED="$(grep -c INVOKED "$TMP/invocations.log" 2>/dev/null | tr -d ' ')"
  FIRED="${FIRED:-0}"
}

echo "=== k3 F13: an unanswerable probe must never fire a wake ==="
echo ""

probe "$TOP/tool" 'not json at all'
[ "$RC" = 3 ] && [ "$FIRED" = 0 ] \
  && ok "G1 unparseable daemon body → deferred (rc=3), no wake fired" \
  || bad "G1 unparseable body: rc=$RC, wakes fired=$FIRED — the guard still fails OPEN"
case "$OUT" in
  *UNKNOWN*unparseable*) ok "G6 the refusal names the reason (unparseable)" ;;
  *) bad "G6 the refusal does not say why: $(printf '%s' "$OUT" | tail -1)" ;;
esac

probe "$TOP/tool" --nodaemon
[ "$RC" = 3 ] && [ "$FIRED" = 0 ] \
  && ok "G2 unreachable daemon → deferred (rc=3), no wake fired" \
  || bad "G2 dead daemon: rc=$RC, wakes fired=$FIRED — a wake fired into a session nobody could ask about"

probe "$TOP/tool" '{"nothing":"useful"}'
[ "$RC" = 3 ] && [ "$FIRED" = 0 ] \
  && ok "G3 no session object → deferred (rc=3), no wake fired" \
  || bad "G3 no session object: rc=$RC, wakes fired=$FIRED"

probe "$TOP/tool" '{"session":{"active_turn":"t1"}}'
[ "$RC" = 3 ] && [ "$FIRED" = 0 ] \
  && ok "G4 busy → deferred (rc=3), no wake fired (control, unchanged)" \
  || bad "G4 busy control broke: rc=$RC, wakes fired=$FIRED"

probe "$TOP/tool" '{"session":{"active_turn":null}}'
[ "$RC" = 0 ] && [ "$FIRED" = 1 ] \
  && ok "G5 idle → the wake FIRES (rc=0) — failing closed did not stop delivery" \
  || bad "G5 an idle session no longer gets woken: rc=$RC, wakes fired=$FIRED — this fix would deafen every ocean seat"

# ── G7 MUTANT: collapse unknown back into idle ────────────────────────────
echo "  -- mutant: unknown treated as idle --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/adapters/ocean.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='''  idle) ;;
  *)'''
new='''  idle) ;;
  *) : ;;
  __never__)'''
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "G7 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  probe "$MUT" 'not json at all'
  if [ "$RC" = 0 ] && [ "$FIRED" = 1 ]; then
    ok "G7 with unknown collapsed into idle the wake fires again (rc=0, fired=1) — G1 detects it"
  else
    bad "G7 mutant applied but nothing leaked (rc=$RC, fired=$FIRED) — G1 may be testing nothing"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "F13 GREEN — unknown never wakes"
