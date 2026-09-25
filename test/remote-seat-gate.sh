#!/usr/bin/env bash
# remote-seat-gate.sh — opt-in REMOTE Ocean seats, and proof that every other
# seat is untouched.
#
# A seat can now live on another Ocean daemon (an ssh tunnel to another
# machine): .state/seat-daemon-url.<name> routes the ocean adapter's probe and
# wake (and watch.sh's turn supervision) there, and .state/seat-remote-cwd.<name>
# is a path ON THAT HOST passed as --cwd verbatim. The feature is only safe if
# it is strictly opt-in, so most of this gate is about the seats that did NOT
# opt in.
#
#   D1-D9  DIFFERENTIAL: for nine no-file seat shapes, the adapter at this tree
#          and the adapter at the pre-feature commit ($BASE) produce the SAME
#          exit code, stdout, stderr, ocean-heartbeat argv (byte-for-byte) and
#          the same daemon requests. D9 is a no-file seat on a pad where ANOTHER
#          seat is remote.
#   R1     remote seat: probe goes to the seat daemon, never the global one
#   R2     remote seat: --daemon-url precedes `wake`, --cwd is the remote path
#          verbatim (it does not exist here), the prompt says REMOTE and carries
#          no pad CLI command
#   R3     busy on the SEAT daemon defers (rc 3) even though the global one is idle
#   R4     seat-daemon-url alone: routed there, but local cwd + ordinary prompt
#   R5     seat-remote-cwd alone is ignored (warned), argv identical to no-file
#   R6     unusable seat-daemon-url (malformed / symlink / empty) refuses the
#          wake, rc 1, and never falls back to the local daemon
#   R7     unusable seat-remote-cwd (relative) refuses the wake
#   W1     watch.sh has no hard-coded daemon URL left; all three supervision
#          helpers resolve per seat
#   W2     sp_seat_daemon_url: no file → the global URL, exactly as before
#   K1     seat-keeper skips a remote seat with a voice, never probes it
#   M1     MUTANT: drop the --daemon-url prefix → R2 goes RED
#   M2     MUTANT: perturb the no-file wake argv → the D-differential goes RED
#
# LIVE MODE (manual, read-only on live pads): SP_REMOTE_SEAT_KEEPER_CONF=<conf>
# snapshots every pad named in that keeper.conf (pad file + regular .state
# files, copied to a temp dir — the live pads are never written) and runs the
# D-differential for every no-file ocean seat on every roster.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
BASE="${SP_REMOTE_SEAT_BASE_REF:-717736d}"
SID="fake-remote-sid"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-remote.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
SRV_A=""; SRV_B=""
cleanup() {
  _rc=$?
  # Only the mock daemons this suite started, by the pids it captured.
  for _p in $SRV_A $SRV_B; do kill "$_p" 2>/dev/null; wait "$_p" 2>/dev/null; done
  rm -rf "$TMP" 2>/dev/null || true
  return $_rc
}
trap cleanup EXIT

mkdir -p "$TMP/home" "$TMP/proj" "$TMP/bin" "$TMP/srvA/v1/agent/sessions" \
  "$TMP/srvB/v1/agent/sessions" "$TMP/seatwt"
printf 'ok' > "$TMP/srvA/health"; printf 'ok' > "$TMP/srvB/health"

# Stub ocean-heartbeat: records its exact argv, NUL-separated, so a prompt
# with newlines is compared byte-for-byte.
cat > "$TMP/bin/ocean-heartbeat" <<EOF
#!/bin/bash
printf '%s\0' "\$@" >> "$TMP/argv.bin"
printf '{"ok":true,"turn_id":"fake-turn-1"}\n'
exit 0
EOF
chmod +x "$TMP/bin/ocean-heartbeat"

free_port() { python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null; }
start_mock() { # $1=dir $2=port $3=log → pid on stdout
  ( cd "$1" && exec python3 -u -m http.server "$2" --bind 127.0.0.1 ) >/dev/null 2>"$3" &
  printf '%s' "$!"
}
wait_up() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    curl -s -o /dev/null --max-time 1 "$1/" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
PORT_A="$(free_port)"; PORT_B="$(free_port)"
case "${PORT_A:-}${PORT_B:-}" in ''|*[!0-9]*)
  echo "  INVALID PROBE: could not reserve ports for the mock daemons"
  echo "  passed: 0  failed: 1"; exit 1 ;;
esac
URL_A="http://127.0.0.1:$PORT_A"; URL_B="http://127.0.0.1:$PORT_B"
SRV_A="$(start_mock "$TMP/srvA" "$PORT_A" "$TMP/srvA.log")"
SRV_B="$(start_mock "$TMP/srvB" "$PORT_B" "$TMP/srvB.log")"
if ! wait_up "$URL_A" || ! wait_up "$URL_B"; then
  echo "  INVALID PROBE: a mock daemon never came up — nothing below would measure routing"
  echo "  passed: 0  failed: 1"; exit 1
fi
set_session() { # $1=A|B $2=body
  printf '%s' "$2" > "$TMP/srv$1/v1/agent/sessions/$SID"
}
IDLE='{"session":{"active_turn":null}}'
BUSY='{"session":{"active_turn":"t1"}}'
set_session A "$IDLE"; set_session B "$IDLE"

export HOME="$TMP/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
( cd "$TMP/proj" && env -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u HERDR_PANE_ID \
    "$TOP/tool/bin/stitchpad" init --name remoteg >/dev/null 2>&1
  cd "$TMP/proj" && env -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u HERDR_PANE_ID \
    STITCHPAD_NAME=eve "$TOP/tool/bin/stitchpad" join eve ocean push "$SID" >/dev/null 2>&1 ) || true
PAD="$TMP/proj/.stitchpad/stitchpad.md"
ST="$TMP/proj/.stitchpad/.state"
[ -f "$PAD" ] && [ -d "$ST" ] || {
  echo "  INVALID PROBE: fixture pad was not created"; echo "  passed: 0  failed: 1"; exit 1; }
printf 'a mention body: write ~/tides-review/reports/review-eve.md\n' > "$TMP/taskfile"

reset_seat_state() {
  rm -f "$ST"/seat-daemon-url.* "$ST"/seat-remote-cwd.* "$ST"/seat-cwd.* \
    "$ST"/seat-model.* "$ST"/resolved-model* "$ST"/resolved-provider.* \
    "$ST"/model-mismatch.* 2>/dev/null
  set_session A "$IDLE"; set_session B "$IDLE"
}

# run_adapter <tool-root> <outprefix> [env...] → rc in $RC; files <outprefix>.{out,err,argv,reqA,reqB}
run_adapter() {
  local rt="$1" o="$2"; shift 2
  : > "$TMP/argv.bin"; : > "$TMP/srvA.log"; : > "$TMP/srvB.log"
  ( env PATH="$TMP/bin:$PATH" SP_TARGET="$SID" OCEAN_DAEMON_URL="$URL_A" "$@" \
      /bin/bash "$rt/adapters/ocean.sh" mention eve "$PAD" "$TMP/taskfile" ) >"$o.out" 2>"$o.err"
  RC=$?
  sleep 0.1
  cp "$TMP/argv.bin" "$o.argv"
  sed -n 's/.*"\(GET [^ ]*\).*/\1/p' "$TMP/srvA.log" > "$o.reqA"
  sed -n 's/.*"\(GET [^ ]*\).*/\1/p' "$TMP/srvB.log" > "$o.reqB"
}
argv_has() { tr '\0' '\n' < "$1" | grep -qxF -- "$2"; }
argv_first() { tr '\0' '\n' < "$1" | head -1; }
argv_after() { tr '\0' '\n' < "$1" | awk -v k="$2" 'p{print; exit} $0==k{p=1}'; }
prompt_of() { tr '\0' '\n' < "$1" | awk '$0=="--prompt"{p=1;next} p&&/^--(model|no-wait)$/{exit} p'; }

# ── D: the differential against the pre-feature adapter ───────────────────
BASE_TREE="$TMP/base"
have_base=0
if git -C "$TOP" rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1; then
  mkdir -p "$BASE_TREE"
  git -C "$TOP" archive "$BASE" tool/adapters tool/bin tool/instructions 2>/dev/null \
    | tar -x -C "$BASE_TREE" 2>/dev/null && [ -f "$BASE_TREE/tool/adapters/ocean.sh" ] && have_base=1
fi

# differential <label> <setup-fn> [env...]
differential() {
  local label="$1" setup="$2"; shift 2
  reset_seat_state; "$setup"
  run_adapter "$BASE_TREE/tool" "$TMP/old" "$@"; local orc=$RC
  reset_seat_state; "$setup"
  run_adapter "${NEW_TREE:-$TOP/tool}" "$TMP/new" "$@"; local nrc=$RC
  local diffs=""
  [ "$orc" = "$nrc" ] || diffs="$diffs rc(${orc}→${nrc})"
  local k; for k in out err argv reqA reqB; do
    cmp -s "$TMP/old.$k" "$TMP/new.$k" || diffs="$diffs $k"
  done
  if [ -z "$diffs" ]; then ok "$label — identical to $BASE (rc=$nrc, argv $(wc -c < "$TMP/new.argv" | tr -d ' ')B, probes A=$(wc -l < "$TMP/new.reqA" | tr -d ' ') B=$(wc -l < "$TMP/new.reqB" | tr -d ' '))"
  else bad "$label — DIFFERS from $BASE in:$diffs"; fi
}
s_plain()    { :; }
s_model()    { printf 'glm-5.3' > "$ST/seat-model.eve"; }
s_cwd()      { printf '%s' "$TMP/seatwt" > "$ST/seat-cwd.eve"; }
s_cwd_bad()  { printf '%s' "$TMP/no-such-dir" > "$ST/seat-cwd.eve"; }
s_busy()     { set_session A "$BUSY"; }
s_unknown()  { set_session A 'not json'; }
s_other_remote() {
  printf '%s' "$URL_B" > "$ST/seat-daemon-url.zed"
  printf '/remote/zed' > "$ST/seat-remote-cwd.zed"
}

echo "=== remote seats: every seat that did not opt in is byte-identical ==="
if [ "$have_base" -eq 1 ]; then
  differential "D1 plain chat seat"                 s_plain
  differential "D2 pinned model"                    s_model
  differential "D3 seat-cwd (existing worktree)"    s_cwd
  differential "D4 seat-cwd pointing nowhere"       s_cwd_bad
  differential "D5 supervised (ack file, --no-wait)" s_plain SP_DELIVERY_ACK_FILE="$TMP/ack.json"
  differential "D6 busy session defers"             s_busy
  differential "D7 unknown probe defers"            s_unknown
  differential "D8 SP_MODEL roster fallback"        s_plain SP_MODEL=deepseek-v4-pro
  differential "D9 no-file seat on a pad where ANOTHER seat is remote" s_other_remote
else
  bad "D* base ref $BASE is not in this checkout — the no-file differential could not run (set SP_REMOTE_SEAT_BASE_REF)"
fi

echo ""
echo "=== remote seats: the opt-in path ==="
reset_seat_state
printf '%s\n' "$URL_B" > "$ST/seat-daemon-url.eve"
printf '/Users/remote/tides-review\n' > "$ST/seat-remote-cwd.eve"
printf 'glm-5.3' > "$ST/seat-model.eve"
set_session A 'not json'     # would defer if the probe went to A
run_adapter "$TOP/tool" "$TMP/r"
if [ "$RC" = 0 ] && [ -s "$TMP/r.reqB" ] && [ ! -s "$TMP/r.reqA" ]; then
  ok "R1 remote seat probed the SEAT daemon only (A untouched), rc=0"
else bad "R1 routing wrong: rc=$RC reqA=$(tr '\n' ' ' < "$TMP/r.reqA") reqB=$(tr '\n' ' ' < "$TMP/r.reqB") err=$(tail -1 "$TMP/r.err")"; fi
r2=""
[ "$(argv_first "$TMP/r.argv")" = "--daemon-url" ] || r2="$r2 first-arg"
[ "$(argv_after "$TMP/r.argv" --daemon-url)" = "$URL_B" ] || r2="$r2 daemon-url-value"
[ "$(tr '\0' '\n' < "$TMP/r.argv" | sed -n 3p)" = "wake" ] || r2="$r2 wake-position"
[ "$(argv_after "$TMP/r.argv" --cwd)" = "/Users/remote/tides-review" ] || r2="$r2 cwd"
[ "$(argv_after "$TMP/r.argv" --model)" = "glm-5.3" ] || r2="$r2 model"
p="$(prompt_of "$TMP/r.argv")"
case "$p" in *"REMOTE seat"*) ;; *) r2="$r2 prompt-not-remote" ;; esac
case "$p" in *"CANNOT run the stitchpad"*) ;; *) r2="$r2 prompt-no-cli-warning" ;; esac
case "$p" in *"stitchpad read"*|*"stitchpad say"*) r2="$r2 prompt-has-pad-cli" ;; esac
case "$p" in *"review-eve.md"*) ;; *) r2="$r2 prompt-lost-card" ;; esac
[ -z "$r2" ] && ok "R2 --daemon-url precedes wake, --cwd is the remote path verbatim, prompt is REMOTE with no pad CLI" \
  || bad "R2 remote wake argv/prompt wrong:$r2"

set_session B "$BUSY"; set_session A "$IDLE"
run_adapter "$TOP/tool" "$TMP/r3"
[ "$RC" = 3 ] && [ ! -s "$TMP/r3.argv" ] \
  && ok "R3 busy on the seat daemon defers (rc=3) although the global daemon says idle" \
  || bad "R3 busy remote session: rc=$RC, argv bytes=$(wc -c < "$TMP/r3.argv" | tr -d ' ') — a wake fired into a mid-turn remote seat"

reset_seat_state
printf '%s' "$URL_B" > "$ST/seat-daemon-url.eve"
set_session A 'not json'
run_adapter "$TOP/tool" "$TMP/r4"
p="$(prompt_of "$TMP/r4.argv")"
if [ "$RC" = 0 ] && [ ! -s "$TMP/r4.reqA" ] && [ "$(argv_after "$TMP/r4.argv" --daemon-url)" = "$URL_B" ] \
   && [ "$(argv_after "$TMP/r4.argv" --cwd)" = "$(cd "$TMP/proj" && pwd)" ] \
   && case "$p" in *"REMOTE seat"*) false ;; *"stitchpad say"*) true ;; *) false ;; esac; then
  ok "R4 seat-daemon-url alone: routed to that daemon with the local pad cwd and the ordinary prompt"
else bad "R4 daemon-url-only seat: rc=$RC cwd=$(argv_after "$TMP/r4.argv" --cwd) reqA=$(wc -l < "$TMP/r4.reqA" | tr -d ' ')"; fi

if [ "$have_base" -eq 1 ]; then
  reset_seat_state; run_adapter "$BASE_TREE/tool" "$TMP/o5"
  reset_seat_state; printf '/remote/x' > "$ST/seat-remote-cwd.eve"
  run_adapter "$TOP/tool" "$TMP/r5"
  if [ "$RC" = 0 ] && cmp -s "$TMP/o5.argv" "$TMP/r5.argv" && cmp -s "$TMP/o5.reqA" "$TMP/r5.reqA" \
     && grep -q 'seat-remote-cwd.eve ignored' "$TMP/r5.err"; then
    ok "R5 seat-remote-cwd without seat-daemon-url is ignored with a warning; argv identical to $BASE"
  else bad "R5 lone seat-remote-cwd changed the wake (rc=$RC) or was not warned about"; fi
fi

r6=""
for kind in malformed symlink empty dir; do
  reset_seat_state
  case "$kind" in
    malformed) printf 'ftp://nope/x y' > "$ST/seat-daemon-url.eve" ;;
    symlink)   printf '%s' "$URL_B" > "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$ST/seat-daemon-url.eve" ;;
    empty)     : > "$ST/seat-daemon-url.eve" ;;
    dir)       mkdir "$ST/seat-daemon-url.eve" ;;
  esac
  run_adapter "$TOP/tool" "$TMP/r6"
  { [ "$RC" = 1 ] && [ ! -s "$TMP/r6.argv" ] && [ ! -s "$TMP/r6.reqA" ] && [ ! -s "$TMP/r6.reqB" ]; } \
    || r6="$r6 $kind(rc=$RC)"
  rm -rf "$ST/seat-daemon-url.eve"
done
[ -z "$r6" ] && ok "R6 an unusable seat-daemon-url (malformed/symlink/empty/dir) refuses rc=1 — no probe, no wake, no local fallback" \
  || bad "R6 unusable seat-daemon-url did not refuse cleanly:$r6"

reset_seat_state
printf '%s' "$URL_B" > "$ST/seat-daemon-url.eve"
printf 'relative/path' > "$ST/seat-remote-cwd.eve"
run_adapter "$TOP/tool" "$TMP/r7"
[ "$RC" = 1 ] && [ ! -s "$TMP/r7.argv" ] \
  && ok "R7 a relative seat-remote-cwd refuses the wake (rc=1)" \
  || bad "R7 relative seat-remote-cwd: rc=$RC, argv bytes=$(wc -c < "$TMP/r7.argv" | tr -d ' ')"

echo ""
echo "=== remote seats: supervision and keeper ==="
W="$TOP/tool/bin/watch.sh"
if ! grep -q 'OCEAN_DAEMON_URL' "$W" \
   && [ "$(grep -c 'daemon_url="$(sp_seat_daemon_url "$PAD_STATE" "$name")"' "$W")" = 3 ] \
   && [ "$(grep -c 'delivery_ocean_turn_status "[^"]*" "$turn_id" "$name"' "$W")" = 3 ] \
   && [ "$(grep -c 'delivery_ocean_reconcile_attempt "$target" "$attempt_at" "$name"' "$W")" = 2 ]; then
  ok "W1 watch.sh: no hard-coded daemon URL; cancel, turn-status and reconcile all resolve per seat"
else bad "W1 watch.sh still reads the global daemon for some supervision path — a remote turn would read as missing and be redelivered"; fi

w2="$(
  BIN_DIR="$TOP/tool/bin"; PAD_DIR="$TMP/proj/.stitchpad"
  # shellcheck disable=SC1091
  source "$TOP/tool/bin/lib.sh" >/dev/null 2>&1
  reset_seat_state
  a="$(OCEAN_DAEMON_URL="$URL_A" sp_seat_daemon_url "$ST" eve)"
  b="$(env -u OCEAN_DAEMON_URL bash -c 'BIN_DIR="$1/tool/bin"; source "$1/tool/bin/lib.sh" >/dev/null 2>&1; sp_seat_daemon_url "$2" eve' _ "$TOP" "$ST")"
  printf '%s/' "$URL_B" > "$ST/seat-daemon-url.eve"
  c="$(OCEAN_DAEMON_URL="$URL_A" sp_seat_daemon_url "$ST" eve)"
  printf '%s|%s|%s' "$a" "$b" "$c"
)"
[ "$w2" = "$URL_A|http://127.0.0.1:4780|$URL_B" ] \
  && ok "W2 sp_seat_daemon_url: no file → \$OCEAN_DAEMON_URL / :4780 exactly as before; file → the seat daemon" \
  || bad "W2 sp_seat_daemon_url resolved '$w2'"

reset_seat_state
printf '%s' "$SID" > "$ST/ocean-session.eve"
printf '%s' "$URL_B" > "$ST/seat-daemon-url.eve"
printf '%s\n' "$TMP/proj" > "$TMP/keeper.conf"
: > "$TMP/srvA.log"; : > "$TMP/srvB.log"; : > "$TMP/argv.bin"
( cd "$TMP" && PATH="$TMP/bin:$PATH" SEAT_KEEPER_CONF="$TMP/keeper.conf" SEAT_KEEPER_LOG="$TMP/keeper.log" \
    SEAT_KEEPER_RELOG_S=0 OCEAN_DAEMON_URL="$URL_A" OCEAN_HEARTBEAT_BIN="$TMP/bin/ocean-heartbeat" \
    SEAT_KEEPER_SP="$TOP/tool/bin/stitchpad" /bin/bash "$TOP/tool/bin/seat-keeper.sh" ) >/dev/null 2>&1
sleep 0.1
if grep -q "REMOTE SEAT SKIPPED: eve" "$TMP/keeper.log" 2>/dev/null \
   && ! grep -q "sessions/$SID" "$TMP/srvA.log" && [ ! -s "$TMP/argv.bin" ]; then
  ok "K1 seat-keeper skips a remote seat with a voice — never probes it on the local daemon, never wakes it"
else bad "K1 keeper handled a remote seat wrongly: log=$(tail -1 "$TMP/keeper.log" 2>/dev/null) probesA=$(grep -c "sessions/$SID" "$TMP/srvA.log")"; fi
rm -f "$ST/ocean-session.eve"

# ── M1 MUTANT: drop the --daemon-url prefix ────────────────────────────────
echo "  -- mutant: the wake forgets --daemon-url --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/adapters" "$TOP/tool/bin" "$TOP/tool/instructions" "$MUT/"
python3 - "$MUT/adapters/ocean.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='[ -n "$seat_daemon_url" ] && wake_args=(--daemon-url "$seat_daemon_url" "${wake_args[@]}")'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,':'))
PY
if [ $? -eq 9 ]; then bad "M1 mutant anchor not found — the gate no longer pins the --daemon-url prefix"
else
  reset_seat_state
  printf '%s' "$URL_B" > "$ST/seat-daemon-url.eve"; printf '/r' > "$ST/seat-remote-cwd.eve"
  run_adapter "$MUT" "$TMP/m1"
  [ "$(argv_first "$TMP/m1.argv")" != "--daemon-url" ] \
    && ok "M1 mutant (no --daemon-url) is caught: the wake would go to the global daemon" \
    || bad "M1 mutant survived"
fi

# ── M2 MUTANT: a no-file behaviour change must not pass the differential ──
if [ "$have_base" -eq 1 ]; then
  echo "  -- mutant: a no-file seat's wake changes by one argument --"
  MUT2="$TMP/mutant2"; mkdir -p "$MUT2"; cp -R "$TOP/tool/adapters" "$TOP/tool/bin" "$TOP/tool/instructions" "$MUT2/"
  sed -i.bak 's/--timeout-seconds 600 --prompt/--timeout-seconds 601 --prompt/' "$MUT2/adapters/ocean.sh"
  if cmp -s "$MUT2/adapters/ocean.sh" "$MUT2/adapters/ocean.sh.bak"; then
    bad "M2 mutant anchor not found"
  else
    _p=$pass; _f=$fail
    NEW_TREE="$MUT2" differential "M2-probe (expected to differ)" s_plain >/dev/null
    if [ "$fail" -gt "$_f" ]; then pass=$_p; fail=$_f; ok "M2 mutant (no-file argv perturbed) is caught by the differential"
    else pass=$_p; fail=$_f; bad "M2 the differential passed a changed no-file wake — it is not measuring anything"; fi
  fi
fi

# ── LIVE MODE: every no-file ocean seat on every keeper pad ───────────────
if [ -n "${SP_REMOTE_SEAT_KEEPER_CONF:-}" ] && [ "$have_base" -eq 1 ]; then
  echo ""
  echo "=== LIVE differential over $SP_REMOTE_SEAT_KEEPER_CONF (snapshots; live pads are read, never written) ==="
  i=0
  while IFS= read -r repo; do
    case "$repo" in ''|\#*) continue ;; esac
    lp="$repo/.stitchpad/stitchpad.md"; ls_="$repo/.stitchpad/.state"
    [ -f "$lp" ] && [ -d "$ls_" ] || { echo "  (skip $repo: no pad)"; continue; }
    i=$((i+1)); snap="$TMP/live$i"; mkdir -p "$snap/.stitchpad/.state"
    cp "$lp" "$snap/.stitchpad/stitchpad.md"
    find "$ls_" -maxdepth 1 -type f -size -1024k -exec cp -p {} "$snap/.stitchpad/.state/" \; 2>/dev/null
    seats="$(awk '/^```roster/{r=1;next} /^```/{r=0} r && /\|/ && $0 !~ /^#/' "$lp" \
      | awk -F'|' '{gsub(/[[:space:]]/,"",$1); gsub(/[[:space:]]/,"",$2); gsub(/[[:space:]]/,"",$4); if ($2=="ocean") print $1"|"$4}')"
    n=0; same=0; ds=""; rcs=""
    while IFS='|' read -r sname starget; do
      [ -n "$sname" ] || continue
      if [ -e "$snap/.stitchpad/.state/seat-daemon-url.$sname" ]; then continue; fi
      n=$((n+1))
      for side in old new; do
        [ "$side" = old ] && rt="$BASE_TREE/tool" || rt="$TOP/tool"
        rm -rf "$snap/.stitchpad/.state.run"; cp -Rp "$snap/.stitchpad/.state" "$snap/.stitchpad/.state.run.keep"
        printf '%s' "$IDLE" > "$TMP/srvA/v1/agent/sessions/${starget:-x}"
        : > "$TMP/argv.bin"; : > "$TMP/srvA.log"
        ( env PATH="$TMP/bin:$PATH" SP_TARGET="$starget" OCEAN_DAEMON_URL="$URL_A" \
            /bin/bash "$rt/adapters/ocean.sh" mention "$sname" "$snap/.stitchpad/stitchpad.md" "$TMP/taskfile" ) \
            >"$TMP/l.$side.out" 2>"$TMP/l.$side.err"
        echo "$?" > "$TMP/l.$side.rc"
        sleep 0.05
        cp "$TMP/argv.bin" "$TMP/l.$side.argv"
        sed -n 's/.*"\(GET [^ ]*\).*/\1/p' "$TMP/srvA.log" > "$TMP/l.$side.req"
        rm -rf "$snap/.stitchpad/.state"; mv "$snap/.stitchpad/.state.run.keep" "$snap/.stitchpad/.state"
      done
      d=""; for k in rc out err argv req; do cmp -s "$TMP/l.old.$k" "$TMP/l.new.$k" || d="$d $k"; done
      if [ -z "$d" ]; then same=$((same+1)); else ds="$ds $sname:[$d ]"; fi
      rcs="$rcs $(cat "$TMP/l.new.rc")"
    done <<< "$seats"
    if [ -z "$ds" ]; then ok "LIVE $repo — $same/$n no-file ocean seats identical to $BASE (exit codes:$([ -n "$rcs" ] && printf '%s\n' $rcs | sort | uniq -c | awk '{printf " rc%s×%s", $2, $1}'))"
    else bad "LIVE $repo — differs:$ds"; fi
  done < "$SP_REMOTE_SEAT_KEEPER_CONF"
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
