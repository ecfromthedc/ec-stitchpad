#!/bin/bash
# k3 F18 reproduction: two CONCURRENT session starts both adopt one handle.
# Usage: f18.sh [tool-root] [rounds]
set -u
RT="${1:-/Users/ecfromthedc/dev/rt/rt-stitchpad-prs/wt/tool}"
ROUNDS="${2:-5}"
dup_rounds=0
for r in $(seq 1 "$ROUNDS"); do
  W="$(mktemp -d "${TMPDIR:-/tmp}/f18.XXXXXX")"
  mkdir -p "$W/home" "$W/proj"
  ln -sfn "$RT" "$W/home/.stitchpad"
  export HOME="$W/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
  unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID HERDR_ENV 2>/dev/null || true
  ( cd "$W/proj" && "$RT/bin/stitchpad" init --name f18 >/dev/null 2>&1 )
  ( cd "$W/proj" && STITCHPAD_NAME=fable "$RT/bin/stitchpad" join fable cli pull - >/dev/null 2>&1 )
  S="$W/proj/.stitchpad/.state"
  printf 'fable' > "$S/autoname.claude"
  # a STALE heartbeat: 10 minutes old, pid that cannot be alive
  printf '{"name":"fable","ts":1,"pid":999999,"parentPid":1,"session":"","surface":"","target":"","generation":"x"}' > "$S/alive.fable"
  /usr/bin/touch -t 202001010000 "$S/alive.fable"
  rm -rf "$S/sessions"; mkdir -p "$S/sessions"
  # two session starts, launched together
  A="sid-A$r"; B="sid-B$r"
  outa="$W/a.out"; outb="$W/b.out"
  ( printf '{"cwd":"%s","session_id":"%s"}' "$W/proj" "$A" | /bin/bash "$RT/adapters/session-start-hook.sh" >"$outa" 2>&1 ) &
  p1=$!
  ( printf '{"cwd":"%s","session_id":"%s"}' "$W/proj" "$B" | /bin/bash "$RT/adapters/session-start-hook.sh" >"$outb" 2>&1 ) &
  p2=$!
  wait "$p1" 2>/dev/null; wait "$p2" 2>/dev/null
  binds="$(ls "$S/sessions" 2>/dev/null | wc -l | tr -d ' ')"
  claims="$(grep -l 'you are @fable' "$outa" "$outb" 2>/dev/null | wc -l | tr -d ' ')"
  echo "round $r: session bindings=$binds  hooks claiming the handle=$claims"
  [ "$claims" -gt 1 ] && dup_rounds=$((dup_rounds+1))
  # stop any ticker we started, by the pid the lock recorded — never a bare pkill
  for lk in "$S"/heartbeat.*.lock; do
    [ -d "$lk" ] || continue
    hp="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$lk/owner" 2>/dev/null || true)"
    [ -n "$hp" ] && kill "$hp" 2>/dev/null
  done
  sleep 0.2
  rm -rf "$W"
done
echo "rounds with a DUPLICATED identity: $dup_rounds / $ROUNDS"
