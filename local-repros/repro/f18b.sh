#!/bin/bash
# F18 regression checks: the claim must not break the paths that worked.
set -u
RT="${1:-/Users/ecfromthedc/dev/rt/rt-stitchpad-prs/wt/tool}"
W="$(mktemp -d "${TMPDIR:-/tmp}/f18b.XXXXXX")"
mkdir -p "$W/home" "$W/proj"; ln -sfn "$RT" "$W/home/.stitchpad"
export HOME="$W/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID HERDR_ENV 2>/dev/null || true
( cd "$W/proj" && "$RT/bin/stitchpad" init --name f18b >/dev/null 2>&1 )
( cd "$W/proj" && STITCHPAD_NAME=fable "$RT/bin/stitchpad" join fable cli pull - >/dev/null 2>&1 )
S="$W/proj/.stitchpad/.state"; printf 'fable' > "$S/autoname.claude"
hook() { printf '{"cwd":"%s","session_id":"%s"}' "$W/proj" "$1" | /bin/bash "$RT/adapters/session-start-hook.sh" 2>&1; }

printf '{"name":"fable","ts":1,"pid":999999}' > "$S/alive.fable"; /usr/bin/touch -t 202001010000 "$S/alive.fable"
rm -rf "$S/sessions"; mkdir -p "$S/sessions"
echo "A) lone start on a stale heartbeat (must adopt):"
hook sid-1 | head -1 | cut -c1-70

echo "B) true resume of the SAME sid while the heartbeat is now LIVE (must adopt):"
hook sid-1 | head -1 | cut -c1-70

echo "C) a DIFFERENT sid while @fable's heartbeat is live (must NOT adopt):"
out="$(hook sid-2)"; [ -z "$out" ] && echo "   (silent, no adoption) — correct" || echo "   $out" | cut -c1-70

echo "D) a stale claim dir left by a crashed hook must not wedge auto-rejoin:"
mkdir -p "$S/identity-claim.fable.d"; printf '999999\n' > "$S/identity-claim.fable.d/owner"
hook sid-1 | head -1 | cut -c1-70
echo "   claim dir left behind: $(ls -d "$S"/identity-claim.* 2>/dev/null | wc -l | tr -d ' ') (want 0)"

for lk in "$S"/heartbeat.*.lock; do
  [ -d "$lk" ] || continue
  hp="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$lk/owner" 2>/dev/null || true)"
  [ -n "$hp" ] && kill "$hp" 2>/dev/null
done
sleep 0.2; rm -rf "$W"
