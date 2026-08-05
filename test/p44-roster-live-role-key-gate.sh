#!/usr/bin/env bash
# p44-roster-live-role-key-gate.sh — the live roster must not drop operators.
#
# THE PAIN: a writer and a reader that disagree about the key. `stitchpad join
# --role operator` writes .state/role.<name>. sp_roster_live read
# .state/runtime.<name> — a path NOTHING in the tree ever writes. Its own comment
# promised "Operators/humans have no heartbeat and are always kept (they read,
# not woken)". That guarantee was silently false: with no runtime.* file the
# operator fell through to the heartbeat check, had no heartbeat (by design), and
# was dropped from the live roster entirely.
#
# This is the "oh, it didn't write to the right spot" shape: both halves look
# correct in isolation and there is no error anywhere.
#
#   G1  join --role operator writes role.<name>
#   G2  nothing writes runtime.<name> (the key the reader used to depend on)
#   G3  an operator with NO heartbeat appears in sp_roster_live
#   G4  a normal agent with no heartbeat is still correctly EXCLUDED
#   G5  runtime.<name> still wins when something external writes it
#   G6  MUTANT: read only runtime.* again -> G3 goes RED
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/p44-live.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

build() { # $1=tool root, $2=proj, $3=ns
  RT="$1"; PJ="$2"; NS="$3"; mkdir -p "$PJ" "$TMP/home.$NS"
  sp boss init --name "$NS" >/dev/null 2>&1 || true
  sp boss join boss cli pull - --role operator >/dev/null 2>&1 || true
  # worker must be a PUSH seat: two PULL seats cannot share one terminal
  # (ONE TERMINAL = ONE PAD, correctly enforced), so joining it as pull left it
  # OUT OF THE ROSTER ENTIRELY and G4 passed against a seat that did not exist.
  # A gate that passes on an absent fixture is a gate that lies -- G0 below now
  # asserts the seat is really there.
  sp boss join worker ocean push - >/dev/null 2>&1 || true
  rm -f "$PJ/.stitchpad/.state"/alive.* 2>/dev/null || true
}
sp() { local who="$1"; shift
  ( cd "$PJ"; env -u HERDR_PANE_ID -u HERDR_TAB_ID -u CLAUDE_CODE_SESSION_ID -u STITCHPAD_SESSION \
      HOME="$TMP/home.$NS" STITCHPAD_HOME="$RT" STITCHPAD_NAME="$who" \
      STITCHPAD_TERMINAL_NAMESPACE="$NS" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$RT/bin/stitchpad" "$@" ) 2>&1; }
live() {
  ( cd "$PJ"; env HOME="$TMP/home.$NS" STITCHPAD_HOME="$RT" /bin/bash -c '
      source "$STITCHPAD_HOME/bin/lib.sh" 2>/dev/null
      sp_init_paths >/dev/null 2>&1
      sp_roster_live' ) 2>/dev/null; }

echo "=== P44: the live roster must not drop operators ==="
echo ""
build "$ROOT/tool" "$TMP/proj" p44gate
ST="$PJ/.stitchpad/.state"

if sp boss roster 2>/dev/null | grep -q '^worker|'; then
  ok "G0 the worker fixture is really in the roster"
else
  bad "G0 worker never joined -- every assertion about it would be vacuous"
fi

[ -f "$ST/role.boss" ] && ok "G1 join --role writes role.boss=[$(cat "$ST/role.boss")]" \
  || bad "G1 join --role did not write role.boss"

if [ -f "$ST/runtime.boss" ]; then
  bad "G2 something DOES write runtime.boss -- re-check this gate's premise"
else
  ok "G2 nothing writes runtime.boss (the key the reader used to depend on)"
fi

out="$(live)"
case "$out" in
  *boss*) ok "G3 an operator with no heartbeat appears in the live roster" ;;
  *) bad "G3 the operator was DROPPED from sp_roster_live: [$out]" ;;
esac

case "$out" in
  *worker*) bad "G4 a heartbeat-less normal agent was wrongly kept -- liveness broken" ;;
  *) ok "G4 a heartbeat-less normal agent is still correctly excluded" ;;
esac

printf 'human' > "$ST/runtime.worker"
out2="$(live)"
case "$out2" in
  *worker*) ok "G5 an externally written runtime.<name> still wins" ;;
  *) bad "G5 runtime.<name> no longer honoured: [$out2]" ;;
esac
rm -f "$ST/runtime.worker"

echo ""
echo "  -- mutant: reader goes back to runtime.* only --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$ROOT/tool/." "$MUT/"
python3 - "$MUT/bin/lib.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='''    [ -n "$rt" ] || rt="$(cat "$PAD_STATE/role.$name" 2>/dev/null || true)"'''
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,'    :'))
PY
mrc=$?
if [ "$mrc" -eq 9 ]; then
  bad "G6 MUTANT DID NOT APPLY -- INCONCLUSIVE, not a pass"
else
  build "$MUT" "$TMP/proj2" p44mut
  mout="$(live)"
  case "$mout" in
    *boss*) bad "G6 mutant applied but the operator survived -- G3 is not testing the key" ;;
    *) ok "G6 with the old key the operator vanishes again -- G3 detects it" ;;
  esac
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "P44 GREEN — writer and reader agree on the key"
