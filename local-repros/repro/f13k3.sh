#!/bin/bash
# k3 F13 reproduction: ocean.sh's idle-guard fails OPEN on an unanswerable probe.
# Usage: f13k3.sh [tool-root]
set -u
RT="${1:-/Users/ecfromthedc/dev/rt/rt-stitchpad-prs/wt/tool}"
W="$(mktemp -d "${TMPDIR:-/tmp}/f13k3.XXXXXX")"
SID="fake-session-id"
mkdir -p "$W/home" "$W/proj" "$W/bin" "$W/srv/v1/agent/sessions"

# stub ocean-heartbeat: records every wake it is asked to perform
cat > "$W/bin/ocean-heartbeat" <<EOF
#!/bin/bash
printf 'INVOKED %s\n' "\$*" >> "$W/invocations.log"
printf '{"ok":true,"turn_id":"fake-turn-1"}\n'
exit 0
EOF
chmod +x "$W/bin/ocean-heartbeat"

# mock daemon: python3's stdlib file server, so GET /v1/agent/sessions/<id>
# returns whatever we put in that file. No dependencies, no fixtures.
PORT=0
for p in 18991 18992 18993 18994; do
  if ! nc -z 127.0.0.1 "$p" 2>/dev/null; then PORT="$p"; break; fi
done
[ "$PORT" = 0 ] && { echo "no free port"; exit 1; }
( cd "$W/srv" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.2; done

export HOME="$W/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID 2>/dev/null || true
( cd "$W/proj" && "$RT/bin/stitchpad" init --name f13k3 >/dev/null 2>&1 )
( cd "$W/proj" && STITCHPAD_NAME=eve "$RT/bin/stitchpad" join eve ocean push "$SID" >/dev/null 2>&1 )
PAD="$W/proj/.stitchpad/stitchpad.md"
printf 'a mention body\n' > "$W/taskfile"

probe() {  # $1 = label, $2 = body served by the mock daemon
  printf '%s' "$2" > "$W/srv/v1/agent/sessions/$SID"
  : > "$W/invocations.log"
  out="$( PATH="$W/bin:$PATH" SP_TARGET="$SID" OCEAN_DAEMON_URL="http://127.0.0.1:$PORT" \
      /bin/bash "$RT/adapters/ocean.sh" mention eve "$PAD" "$W/taskfile" 2>&1 )"
  rc=$?
  fired="$(grep -c INVOKED "$W/invocations.log" 2>/dev/null | tr -d ' ')"
  printf '  %-28s rc=%s  wake fired=%s\n' "$1" "$rc" "$fired"
  [ -n "$out" ] && printf '      %s\n' "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
}

echo "--- ocean.sh idle-guard, three daemon answers ---"
probe "A: unparseable body"      'not json at all'
probe "B: busy (control)"        '{"session":{"active_turn":"t1"}}'
probe "C: idle (control)"        '{"session":{"active_turn":null}}'
printf '%s' '{"session":{"active_turn":null}}' > "$W/srv/v1/agent/sessions/$SID"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
probe "D: daemon gone (timeout)" ''
rm -rf "$W"
