#!/usr/bin/env bash
# p43-wake-push-misdirect-gate.sh — `wake` must never silently swallow a PUSH
# seat's message.
#
# THE PAIN, measured on the live pad: an orchestrator ran `stitchpad wake kimi`
# to dispatch work. The command RENDERED the message to the orchestrator's own
# terminal, advanced .state/seen.kimi to 5, and exited 0. The daemon showed no
# turn for that session since the previous DAY. The agent was never told
# anything, and because the cursor had moved the message was never retried.
# It looks exactly like success. This is the shape EC keeps hitting as "the
# agents aren't deploying".
#
# Push delivery belongs to the watcher (mention -> fire_adapter -> adapter).
#
#   G1  waking someone else's PUSH seat is REFUSED (non-zero)
#   G2  the refusal does NOT advance that seat's cursor -- the message survives
#   G3  the refusal names the command that actually works
#   G4  --peek on a push seat still works (inspection is not delivery)
#   G5  a PULL seat is unaffected -- renders and advances, as designed
#   G6  self-wake is unaffected (an agent draining its own mailbox)
#   G7  MUTANT: drop the guard -> G2 goes RED (cursor burns, message lost)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/p43-wake.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

setup() { # $1=tool root, $2=proj dir, $3=ns
  mkdir -p "$2" "$TMP/home.$3"
  RT="$1"; PJ="$2"; NS="$3"
}
sp() { # $1=identity, rest=args
  local who="$1"; shift
  ( cd "$PJ"
    env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_ENV -u HERDR_SOCKET_PATH \
        -u HERDR_WORKSPACE_ID -u CLAUDE_CODE_SESSION_ID -u STITCHPAD_SESSION \
        HOME="$TMP/home.$NS" STITCHPAD_HOME="$RT" STITCHPAD_NAME="$who" \
        STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        "$RT/bin/stitchpad" "$@" ) 2>&1
}

build_pad() {
  sp boss init --name "$NS" >/dev/null 2>&1 || true
  sp boss join boss cli pull - >/dev/null 2>&1 || true
  sp boss join pusher ocean push - >/dev/null 2>&1 || true
  sp boss join puller cli pull - >/dev/null 2>&1 || true
  sp boss say "@pusher please audit the tripwire" >/dev/null 2>&1 || true
  sp boss say "@puller please audit the adapters" >/dev/null 2>&1 || true
}

echo "=== P43: wake must not swallow a push seat's message ==="
echo ""
setup "$ROOT/tool" "$TMP/proj" p43gate
build_pad
STATE="$PJ/.stitchpad/.state"

# ── G1/G3: refusal, and it names the fix ────────────────────────────
if out="$(sp boss wake pusher)"; then
  bad "G1 waking another agent's PUSH seat was ACCEPTED (message swallowed)"
else
  ok "G1 waking another agent's push seat is refused"
  case "$out" in
    *'stitchpad say'*) ok "G3 the refusal names the command that actually delivers" ;;
    *) bad "G3 refusal does not tell the operator what to do instead: $out" ;;
  esac
fi

# ── G2: the cursor MUST NOT have moved ──────────────────────────────
cur=0; [ -f "$STATE/seen.pusher" ] && cur="$(cat "$STATE/seen.pusher" 2>/dev/null || echo 0)"
if [ "$cur" = "0" ]; then
  ok "G2 the push seat's cursor did not move -- the message survives for the watcher"
else
  bad "G2 seen.pusher advanced to $cur despite the refusal -- message LOST"
fi

# ── G4: inspection is not delivery ──────────────────────────────────
out="$(sp boss wake pusher --peek || true)"
case "$out" in
  *'audit the tripwire'*) ok "G4 --peek on a push seat still shows the message" ;;
  *) bad "G4 --peek on a push seat stopped working: $out" ;;
esac
cur=0; [ -f "$STATE/seen.pusher" ] && cur="$(cat "$STATE/seen.pusher" 2>/dev/null || echo 0)"
[ "$cur" = "0" ] || bad "G4b --peek advanced the cursor to $cur (it must not)"

# ── G5: PULL seats are protected too ────────────────────────────────
# This originally asserted the opposite — that a third party waking a pull seat
# "still renders", which was the half-fixed design. k3 proved the other half:
# @boss ran `wake dale` on a PULL seat, the message rendered on BOSS's terminal
# and seen.dale advanced 0 -> 1, so dale could never see it. The seat's wake mode
# is irrelevant; what matters is that the caller is not the seat.
out="$(sp boss wake puller 2>&1 || true)"
case "$out" in
  *REFUSED*) ok "G5 a third party waking a PULL seat is refused too" ;;
  *) bad "G5 pull-seat wake by a third party was allowed: $out" ;;
esac
cur=0; [ -f "$STATE/seen.puller" ] && cur="$(cat "$STATE/seen.puller" 2>/dev/null || echo 0)"
[ "$cur" = "0" ] && ok "G5b the pull seat's cursor did not move either" \
                 || bad "G5b seen.puller advanced to $cur -- message LOST"

# ── G6: self-wake unaffected ────────────────────────────────────────
sp boss say "@pusher second message" >/dev/null 2>&1 || true
out="$(sp pusher wake pusher || true)"
case "$out" in
  *message*|*audit*) ok "G6 a seat waking ITSELF is unaffected" ;;
  *) bad "G6 self-wake regressed: $out" ;;
esac

# ── G7: MUTANT — remove the guard ───────────────────────────────────
echo ""
echo "  -- mutant: guard removed --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$ROOT/tool/." "$MUT/"
python3 - "$MUT/bin/stitchpad" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='''      if [ "$_caller" != "$who" ]; then'''
new='''      if false; then'''
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
mrc=$?
if [ "$mrc" -eq 9 ]; then
  bad "G7 MUTANT DID NOT APPLY -- INCONCLUSIVE, not a pass"
else
  setup "$MUT" "$TMP/proj2" p43mut
  build_pad
  sp boss wake pusher >/dev/null 2>&1 || true
  mcur=0; [ -f "$PJ/.stitchpad/.state/seen.pusher" ] && mcur="$(cat "$PJ/.stitchpad/.state/seen.pusher" 2>/dev/null || echo 0)"
  if [ "$mcur" != "0" ]; then
    ok "G7 without the guard the cursor burns (seen.pusher=$mcur) -- G2 detects it"
  else
    bad "G7 mutant applied but the cursor did not burn -- G2 may not be testing the guard"
  fi
fi

# ── G8: the RELAY path had the same hole ────────────────────────────────────
# k3 F4 close-out. The guard was written as `relay_mode -eq 0 && peek -eq 0`, so
# `wake <someone-else> --relay` walked straight past it, rendered their message
# to the caller's terminal and burned seen.relay.<padkey>.<name>. Relay wake also
# legitimately runs on a coworker's machine where NO caller identity resolves, so
# the rule there is: refuse only when a caller identity exists and is someone else.
#
# Scope of this probe, stated rather than implied: it proves the refusal happens
# BEFORE any relay work, and G9's mutant proves the guard is what produces it. It
# does not stand up a relay server, so the cursor burn itself is measured on the
# local path (G2/G5b), which shares every line of this code after the guard.
echo ""
echo "  -- relay path --"
RS="$TMP/relaystate"; mkdir -p "$RS"
relay_wake() {  # $1=identity ("" for none) $2...=args
  local id="$1"; shift
  ( cd "$PJ" 2>/dev/null || cd "$TMP"
    if [ -n "$id" ]; then
      env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID -u STITCHPAD_SESSION \
        HOME="$TMP/home.$NS" STITCHPAD_HOME="$RT" STITCHPAD_NAME="$id" \
        STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        STITCHPAD_RELAY_STATE_DIR="$RS" STITCHPAD_RELAY=http://127.0.0.1:1 \
        STITCHPAD_TOKEN=t STITCHPAD_PAD=padname "$RT/bin/stitchpad" wake "$@"
    else
      env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID -u STITCHPAD_SESSION -u STITCHPAD_NAME \
        HOME="$TMP/home.nobody" STITCHPAD_HOME="$RT" \
        STITCHPAD_TERMINAL_NAMESPACE=nobody STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        STITCHPAD_RELAY_STATE_DIR="$RS" STITCHPAD_RELAY=http://127.0.0.1:1 \
        STITCHPAD_TOKEN=t STITCHPAD_PAD=padname "$RT/bin/stitchpad" wake "$@"
    fi ) 2>&1
}
setup "$ROOT/tool" "$TMP/proj" p43gate
out="$(relay_wake boss puller --relay || true)"
case "$out" in
  *REFUSED*) ok "G8 a third party waking someone else over the RELAY is refused too" ;;
  *) bad "G8 relay wake by a third party was allowed: [$out]" ;;
esac
out="$(relay_wake puller --relay; printf 'rc=%s' "$?")"
case "$out" in
  *REFUSED*) bad "G8b a seat's own relay wake was refused — relay delivery is now broken" ;;
  *) ok "G8b a seat waking ITSELF over the relay is unaffected" ;;
esac
out="$(relay_wake '' puller --relay || true)"
case "$out" in
  *REFUSED*) bad "G8c relay wake from a machine with no identity was refused — the coworker path is broken" ;;
  *) ok "G8c relay wake with no resolvable caller identity still runs (the coworker case)" ;;
esac

# ── G9: MUTANT — put the relay exemption back ──────────────────────────────
echo "  -- mutant: relay exempted from the guard --"
MUT2="$TMP/mutant2"; mkdir -p "$MUT2"; cp -R "$ROOT/tool/." "$MUT2/"
python3 - "$MUT2/bin/stitchpad" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='''    if [ "$peek" -eq 0 ]; then'''
new='''    if [ "$relay_mode" -eq 0 ] && [ "$peek" -eq 0 ]; then'''
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "G9 MUTANT DID NOT APPLY -- INCONCLUSIVE, not a pass"
else
  setup "$MUT2" "$TMP/proj3" p43mut2
  build_pad
  out="$(relay_wake boss puller --relay || true)"
  case "$out" in
    *REFUSED*) bad "G9 mutant applied but the relay wake was still refused -- G8 may be testing nothing" ;;
    *) ok "G9 with the relay exempted the third-party wake sails through -- G8 detects it" ;;
  esac
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "P43 GREEN — a push seat's message can no longer be swallowed by wake"
