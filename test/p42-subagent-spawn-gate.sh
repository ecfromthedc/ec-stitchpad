#!/usr/bin/env bash
# p42-subagent-spawn-gate.sh — an agent must be able to spawn its own sub-agents,
# and every sub-agent must stay SCOREABLE, ATTRIBUTABLE and BOUNDED.
#
# THE PAIN (EC): "when we're deploying these agents they're not doing certain
# things that they should. They also need the ability to spawn their own
# sub-agents if they need to ... and it should always be following the
# orchestrator's request."
#
# Spawning alone is the easy half and the dangerous one. An unconstrained spawn
# recreates, one level down, the most expensive defect of this whole build: a
# seat that produces nothing looking exactly like a seat that is working. So the
# contract is what is gated here, not the mechanism.
#
#   G1  spawn creates a real roster seat
#   G2  spawn WITHOUT --artifact is REFUSED (the contract is mandatory)
#   G3  the artifact contract is recorded, so `lanes` can score the sub-agent
#   G4  lineage is durable — a silent seat is attributable to whoever spawned it
#   G5  the orchestrator's directive reaches the sub-agent VERBATIM
#   G6  depth is bounded (STITCHPAD_SPAWN_MAX_DEPTH)
#   G7  fan-out is bounded (STITCHPAD_SPAWN_MAX_CHILDREN)
#   G8  a delegation cycle is refused
#   G9  spawn without an identity is refused (nothing could be held accountable)
#   G10 MUTANT: make --artifact optional -> G2 goes RED
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/p42-spawn.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# $1=tool root, $2=identity, rest=args
sp() {
  local root="$1" who="$2"; shift 2
  ( cd "$TMP/proj"
    env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_ENV -u HERDR_SOCKET_PATH \
        -u HERDR_WORKSPACE_ID -u CLAUDE_CODE_SESSION_ID -u STITCHPAD_SESSION \
        HOME="$TMP/home" STITCHPAD_HOME="$root" STITCHPAD_NAME="$who" \
        STITCHPAD_TERMINAL_NAMESPACE=p42gate STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        STITCHPAD_SPAWN_MAX_DEPTH="${SPAWN_DEPTH:-3}" \
        STITCHPAD_SPAWN_MAX_CHILDREN="${SPAWN_KIDS:-5}" \
        "$root/bin/stitchpad" "$@" ) 2>&1
}

echo "=== P42: sub-agent spawning under contract ==="
echo ""

mkdir -p "$TMP/proj" "$TMP/home"
sp "$ROOT/tool" tester init --name p42gate >/dev/null 2>&1 || true
sp "$ROOT/tool" tester join lead cli pull - >/dev/null 2>&1 || true
STATE="$TMP/proj/.stitchpad/.state"

# ── G1: a spawn produces a real roster seat ─────────────────────────
out="$(sp "$ROOT/tool" lead spawn helper --brief 'audit the tripwire' --artifact "$TMP/out/helper.md" || true)"
if sp "$ROOT/tool" lead roster 2>/dev/null | grep -q 'helper'; then
  ok "G1 spawn creates a roster seat"
else
  bad "G1 spawn did not create a roster seat -- $out"
fi

# ── G2: the artifact contract is MANDATORY ──────────────────────────
if out="$(sp "$ROOT/tool" lead spawn nocontract --brief 'do something' 2>&1)"; then
  bad "G2 spawn WITHOUT --artifact was ACCEPTED (unscoreable seat created)"
else
  case "$out" in
    *artifact*) ok "G2 spawn without --artifact refused, and the message names the fix" ;;
    *) bad "G2 refused, but the message never mentions the artifact: $out" ;;
  esac
fi

# ── G3: the contract is recorded where lanes reads it ───────────────
if [ -f "$STATE/artifact-expect.helper" ] && grep -q 'helper.md' "$STATE/artifact-expect.helper"; then
  ok "G3 artifact contract recorded -- the sub-agent is scoreable"
else
  bad "G3 no artifact contract recorded for @helper"
fi

# ── G4: lineage is durable and attributable ─────────────────────────
if [ -f "$STATE/spawn.helper.parent" ] && [ "$(head -1 "$STATE/spawn.helper.parent")" = "lead" ]; then
  ok "G4 lineage durable -- @helper attributable to @lead"
else
  bad "G4 lineage not recorded for @helper"
fi

# ── G5: the orchestrator's directive reaches the sub-agent VERBATIM ─
DIRECTIVE='ship nothing that is not gated and mutant-proved'
sp "$ROOT/tool" lead directive "$DIRECTIVE" >/dev/null 2>&1 || true
sp "$ROOT/tool" lead spawn scout --brief 'find gaps' --artifact "$TMP/out/scout.md" >/dev/null 2>&1 || true
if grep -qF "$DIRECTIVE" "$TMP/proj/.stitchpad/stitchpad.md" 2>/dev/null; then
  ok "G5 orchestrator directive delivered to the sub-agent verbatim"
else
  bad "G5 the directive never reached @scout's brief"
fi

# ── G6: depth is bounded ────────────────────────────────────────────
SPAWN_DEPTH=1
if out="$(sp "$ROOT/tool" helper spawn toodeep --brief x --artifact "$TMP/out/d.md" 2>&1)"; then
  bad "G6 depth limit NOT enforced -- a depth-2 spawn was accepted under MAX_DEPTH=1"
else
  case "$out" in
    *DEPTH*|*depth*) ok "G6 depth bounded -- runaway delegation refused" ;;
    *) bad "G6 refused for the wrong reason: $out" ;;
  esac
fi
SPAWN_DEPTH=3

# ── G7: fan-out is bounded ──────────────────────────────────────────
SPAWN_KIDS=2
sp "$ROOT/tool" lead spawn k1 --brief x --artifact "$TMP/out/k1.md" >/dev/null 2>&1 || true
if out="$(sp "$ROOT/tool" lead spawn k2 --brief x --artifact "$TMP/out/k2.md" 2>&1)"; then
  bad "G7 fan-out limit NOT enforced -- @lead exceeded MAX_CHILDREN=2"
else
  case "$out" in
    *limit*|*sub-agents*) ok "G7 fan-out bounded -- no fork bomb" ;;
    *) bad "G7 refused for the wrong reason: $out" ;;
  esac
fi
SPAWN_KIDS=5

# ── G8: a delegation cycle is refused ───────────────────────────────
if out="$(sp "$ROOT/tool" helper spawn lead --brief x --artifact "$TMP/out/c.md" 2>&1)"; then
  bad "G8 delegation CYCLE accepted (@helper spawning its own ancestor @lead)"
else
  ok "G8 delegation cycle refused"
fi

# ── G9: an anonymous spawn is refused ───────────────────────────────
if out="$(sp "$ROOT/tool" '' spawn orphan --brief x --artifact "$TMP/out/o.md" 2>&1)"; then
  bad "G9 anonymous spawn ACCEPTED -- @orphan's silence would be unattributable"
else
  ok "G9 anonymous spawn refused"
fi

# ── G11/G12: the push-seat terminal fix, and its security half ─────
# Spawning required loosening ONE TERMINAL = ONE PAD for push seats (a push seat
# is driven by the daemon and occupies no terminal). G12 is the assertion that
# matters: the guard must still bite for PULL seats, which really do occupy one.
out="$(sp "$ROOT/tool" lead join pushseat ocean push - || true)"
case "$out" in
  *joined*) ok "G11 a push seat joins from a terminal already held by @lead" ;;
  *) bad "G11 push seat could not join -- sub-agent spawning is blocked at the root: $(printf '%s' "$out" | head -2)" ;;
esac
out="$(sp "$ROOT/tool" lead join pullseat cli pull - 2>&1 || true)"
case "$out" in
  *REFUSED*|*"one terminal"*|*"One terminal"*)
    ok "G12 a PULL seat is STILL refused -- one terminal = one pad intact" ;;
  *) bad "G12 the terminal guard no longer bites for pull seats: $out" ;;
esac

# ── G10: MUTANT — make the artifact contract optional ───────────────
echo ""
echo "  -- mutant: --artifact becomes optional --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$ROOT/tool/." "$MUT/"
python3 - "$MUT/bin/stitchpad" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='''    [ -n "$_arts" ] || { echo "stitchpad: spawn refused'''
new='''    [ -n "$_arts" ] || _arts="/dev/null
"
    true || { echo "stitchpad: spawn refused'''
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
mrc=$?
if [ "$mrc" -eq 9 ]; then
  bad "G10 MUTANT DID NOT APPLY -- INCONCLUSIVE, not a pass"
else
  mkdir -p "$TMP/proj2" "$TMP/home2"
  ( cd "$TMP/proj2"
    env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID HOME="$TMP/home2" \
        STITCHPAD_HOME="$MUT" STITCHPAD_NAME=lead STITCHPAD_TERMINAL_NAMESPACE=p42mut \
        STITCHPAD_HEARTBEAT_AUTOSTART=0 "$MUT/bin/stitchpad" init --name p42mut ) >/dev/null 2>&1 || true
  ( cd "$TMP/proj2"
    env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID HOME="$TMP/home2" \
        STITCHPAD_HOME="$MUT" STITCHPAD_NAME=lead STITCHPAD_TERMINAL_NAMESPACE=p42mut \
        STITCHPAD_HEARTBEAT_AUTOSTART=0 "$MUT/bin/stitchpad" join lead cli pull - ) >/dev/null 2>&1 || true
  if ( cd "$TMP/proj2"
       env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID HOME="$TMP/home2" \
           STITCHPAD_HOME="$MUT" STITCHPAD_NAME=lead STITCHPAD_TERMINAL_NAMESPACE=p42mut \
           STITCHPAD_HEARTBEAT_AUTOSTART=0 "$MUT/bin/stitchpad" spawn nocontract --brief 'do something' ) >/dev/null 2>&1; then
    ok "G10 mutant reintroduces the unscoreable seat -- G2 detects it"
  else
    bad "G10 mutant applied but the gate did not change behaviour -- G2 may not be testing the contract"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "P42 GREEN — sub-agents spawn under an enforced contract"
