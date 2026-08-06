#!/usr/bin/env bash
# session-start-identity-claim-gate.sh — k3 F18: two concurrent session starts
# must never both adopt one handle.
#
# THE PAIN: the auto-rejoin hook's rule (3) decides "nobody is @name" from
# alive.<name>, a file the winner does not refresh until AFTER its heartbeat
# ticker forks. Two starts in the same window (herdr opening two panes, a
# workspace restore, a launcher double-spawn) therefore both saw a stale
# heartbeat, both adopted, both bound their session id. Two live agents then
# answer to one handle and seen.<name> makes mention delivery first-hook-wins —
# the 02:53 fable incident, re-opened by concurrency.
# Measured before the fix: 5/5 paired rounds ended with 2 bindings and 2 hooks
# printing "you are @fable".
#
#   G1  paired concurrent starts → exactly ONE binding and ONE adopter (3 rounds)
#   G1b the loser says why, instead of silently half-adopting
#   G2  a lone start on a stale heartbeat still adopts (the feature still works)
#   G3  a TRUE RESUME still adopts even when the heartbeat is live
#   G4  a different session does NOT adopt while the heartbeat is live
#   G5  a claim left by a crashed hook is reclaimed — no permanent wedge
#   G6  MUTANT: drop the claim → G1 goes RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-f18.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
# Only ever kill pids this suite captured from a heartbeat lock it created (P9).
_reap() {
  local st hp lk
  for st in "$TMP"/*/proj/.stitchpad/.state; do
    [ -d "$st" ] || continue
    for lk in "$st"/heartbeat.*.lock; do
      [ -d "$lk" ] || continue
      hp="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$lk/owner" 2>/dev/null || true)"
      case "$hp" in ''|*[!0-9]*) continue ;; esac
      kill "$hp" 2>/dev/null || true
    done
  done
}
cleanup() { _rc=$?; _reap; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

# jq is how the hook reads cwd/session_id from its stdin JSON. Without it the
# hook falls back to $PWD and an EMPTY sid, which cannot bind anything — the
# suite would then "pass" while testing nothing. Refuse loudly instead.
if ! command -v jq >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/jq ]; then
  echo "  INVALID PROBE: jq is absent — the hook cannot parse a session id, so"
  echo "  nothing here would be measuring the claim. Not scoring this suite."
  echo "  passed: 0  failed: 1"
  exit 1
fi

mkpad() {  # $1 = tool root, $2 = tag → prints the pad dir; leaves a STALE heartbeat
  local rt="$1" d="$TMP/$2"
  mkdir -p "$d/home" "$d/proj"
  ln -sfn "$rt" "$d/home/.stitchpad"
  ( cd "$d/proj" || exit 1
    env -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u HERDR_PANE_ID -u HERDR_ENV \
      HOME="$d/home" STITCHPAD_HEARTBEAT_AUTOSTART=0 "$rt/bin/stitchpad" init --name "$2" >/dev/null 2>&1
    env -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u HERDR_PANE_ID -u HERDR_ENV \
      HOME="$d/home" STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=fable \
      "$rt/bin/stitchpad" join fable cli pull - >/dev/null 2>&1 ) || true
  printf 'fable' > "$d/proj/.stitchpad/.state/autoname.claude"
  printf '{"name":"fable","ts":1,"pid":999999,"parentPid":1}' > "$d/proj/.stitchpad/.state/alive.fable"
  /usr/bin/touch -t 202001010000 "$d/proj/.stitchpad/.state/alive.fable" 2>/dev/null || true
  rm -rf "$d/proj/.stitchpad/.state/sessions"; mkdir -p "$d/proj/.stitchpad/.state/sessions"
  printf '%s' "$d"
}
hook() {  # $1 = tool root, $2 = pad root dir, $3 = sid
  printf '{"cwd":"%s","session_id":"%s"}' "$2/proj" "$3" \
    | env -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u HERDR_PANE_ID -u HERDR_ENV \
        HOME="$2/home" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        /bin/bash "$1/adapters/session-start-hook.sh" 2>&1
}

# paired concurrent starts; echoes "<bindings> <adopters> <skips>"
paired() {  # $1 = tool root, $2 = tag
  local rt="$1" d p1 p2
  d="$(mkpad "$rt" "$2")"
  ( hook "$rt" "$d" "sid-A" > "$d/a.out" 2>&1 ) & p1=$!
  ( hook "$rt" "$d" "sid-B" > "$d/b.out" 2>&1 ) & p2=$!
  wait "$p1" 2>/dev/null || true; wait "$p2" 2>/dev/null || true
  printf '%s %s %s' \
    "$(ls "$d/proj/.stitchpad/.state/sessions" 2>/dev/null | wc -l | tr -d ' ')" \
    "$(grep -l 'you are @fable' "$d/a.out" "$d/b.out" 2>/dev/null | wc -l | tr -d ' ')" \
    "$(grep -l 'SKIPPED' "$d/a.out" "$d/b.out" 2>/dev/null | wc -l | tr -d ' ')"
}

echo "=== k3 F18: one handle, one adopter, even under concurrency ==="
echo ""

_bad=0; _skips=0
for r in 1 2 3; do
  read -r _b _a _s <<EOF
$(paired "$TOP/tool" "r$r")
EOF
  [ "$_b" = "1" ] && [ "$_a" = "1" ] || { _bad=$(( _bad + 1 )); echo "    round $r: bindings=$_b adopters=$_a"; }
  _skips=$(( _skips + ${_s:-0} ))
done
if [ "$_bad" -eq 0 ]; then
  ok "G1 3 rounds of paired concurrent starts: one binding, one adopter every time"
else
  bad "G1 $_bad/3 rounds duplicated the identity — the claim is not holding"
fi
if [ "$_skips" -ge 1 ]; then
  ok "G1b the losing session says it stood down ($_skips of 3 rounds printed SKIPPED)"
else
  bad "G1b nobody printed the stand-down line — the loser half-adopted in silence"
fi

D="$(mkpad "$TOP/tool" solo)"
out="$(hook "$TOP/tool" "$D" sid-1)"
case "$out" in
  *"you are @fable"*) ok "G2 a lone start on a stale heartbeat still adopts" ;;
  *) bad "G2 the claim broke plain auto-rejoin: [$(printf '%s' "$out" | head -2)]" ;;
esac
out="$(hook "$TOP/tool" "$D" sid-1)"
case "$out" in
  *"you are @fable"*) ok "G3 a true resume adopts even with the heartbeat now live" ;;
  *) bad "G3 a resuming session was locked out of its own handle" ;;
esac
out="$(hook "$TOP/tool" "$D" sid-9)"
case "$out" in
  *"you are @fable"*) bad "G4 a stranger adopted @fable while its heartbeat was live" ;;
  *) ok "G4 a different session does not adopt a live handle" ;;
esac

mkdir -p "$D/proj/.stitchpad/.state/identity-claim.fable.d"
printf '999999\n' > "$D/proj/.stitchpad/.state/identity-claim.fable.d/owner"
out="$(hook "$TOP/tool" "$D" sid-1)"
_left="$(ls -d "$D/proj/.stitchpad/.state"/identity-claim.* 2>/dev/null | wc -l | tr -d ' ')"
if printf '%s' "$out" | grep -q 'you are @fable' && [ "${_left:-1}" -eq 0 ]; then
  ok "G5 a claim from a crashed hook is reclaimed, not a permanent wedge"
else
  bad "G5 a dead claim blocked auto-rejoin (left=$_left) — the wedge is back"
fi

# ── G6 MUTANT: take the claim away ─────────────────────────────────────────
echo "  -- mutant: identity claim removed --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/adapters/session-start-hook.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='_claim_try() { mkdir "$_claim" 2>/dev/null && printf \'%s\\n\' "$$" > "$_claim/owner" 2>/dev/null; }'
new='_claim_try() { return 0; }'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "G6 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  _mbad=0
  for r in 1 2 3; do
    read -r _b _a _s <<EOF
$(paired "$MUT" "m$r")
EOF
    [ "$_b" = "2" ] || [ "$_a" = "2" ] && _mbad=$(( _mbad + 1 ))
  done
  if [ "$_mbad" -gt 0 ]; then
    ok "G6 without the claim the identity duplicates again ($_mbad/3 rounds) — G1 detects it"
  else
    bad "G6 mutant applied but nothing duplicated — G1 may be testing nothing"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "F18 GREEN — one handle can only be adopted once"
