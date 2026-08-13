#!/usr/bin/env bash
# leave-lane-cleanup-gate.sh — a seat that left must leave the board.
#
# THE PAIN (field-reported, 12-hour multi-agent session): `leave` removes the
# roster row and nothing else. `sp_lanes_names` builds the board from
# roster ∪ session-registry ∪ .state/artifact-expect.*, so the departed seat's
# leftover artifact claim kept it on `stitchpad lanes` reading
# `ARTIFACT: NO  VERDICT: FAILED` — for the rest of the night. Worse, `leave`
# itself appends the seat's `terminal` lifecycle event, so even after the claim
# is gone the registry alone keeps the row alive.
#
# Two dead seats sat there as FAILED until morning. This repo has already paid
# for this exact class of bug once: see test/bridge-heartbeat-interval.sh, where
# doctor flagged a perfectly healthy bridge as stale on every single check —
# "a health check that always warns is worse than none — it trains everyone to
# ignore doctor output". A board with permanent phantom failures trains everyone
# to stop reading the board.
#
#   G1  a seat with an unmet artifact contract reads FAILED (the fixture is real)
#   G2  after `leave`, the seat is gone from the text board entirely
#   G3  ... and from `lanes --json`, which is what dashboards read
#   G4  the departed seat's per-seat lane state is removed from .state
#   G5  a DIFFERENT seat's state is untouched — leave removes one seat, not a class
#   G6  the durable audit trail survives: the registry terminal event and the
#       pad's "@dale left" line are still there
#   G7  `leave` on a name that was never in the roster says so, instead of
#       claiming the edit failed and the name "is still in roster"
#   G8  MUTANT: put the leftover artifact claim back → G2 goes RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-leaveclean.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

sp() {  # $1 = tool root, $2 = pad dir, $3 = namespace tag, rest = args
  ( cd "$2" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=lead \
      STITCHPAD_TERMINAL_NAMESPACE="$3" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$1/bin/stitchpad" "${@:4}" )
}

build() {  # $1 = tool root, $2 = tag → prints pad dir
  local rt="$1" tag="$2" d="$TMP/pad.$2" s
  mkdir -p "$d"
  ( cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=lead \
      STITCHPAD_TERMINAL_NAMESPACE="lv$tag-l" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$rt/bin/stitchpad" init --name "lv$tag" >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=dale \
      STITCHPAD_TERMINAL_NAMESPACE="lv$tag-d" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$rt/bin/stitchpad" join dale cli pull - >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=nan \
      STITCHPAD_TERMINAL_NAMESPACE="lv$tag-n" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$rt/bin/stitchpad" join nan cli pull - >/dev/null 2>&1 ) || true
  s="$d/.stitchpad/.state"
  # dale is under contract for an artifact that will never appear — the shape
  # that renders FAILED. nan is the control: same state, never leaves.
  printf '%s\n' "$d/dale-report.md" > "$s/artifact-expect.dale"
  printf '%s\n' "$d/nan-report.md"  > "$s/artifact-expect.nan"
  printf '{"name":"dale","ts":1,"pid":%s}' "$$" > "$s/alive.dale"
  printf '{"name":"nan","ts":1,"pid":%s}'  "$$" > "$s/alive.nan"
  printf 'builder\n' > "$s/role.dale";  printf 'builder\n' > "$s/role.nan"
  printf 'sonnet\n'  > "$s/model.dale"; printf 'sonnet\n'  > "$s/model.nan"
  printf 'lead\n'    > "$s/spawn.dale.parent"
  printf 'write the report\n' > "$s/spawn.dale.brief"
  printf '1\n' > "$s/keeper-strike.dale"
  printf '%s' "$d"
}

echo "=== a departed seat must not haunt the lanes board ==="
echo ""

P="$(build "$TOP/tool" 1)"
S="$P/.stitchpad/.state"

_row="$(sp "$TOP/tool" "$P" lv1-l lanes 2>/dev/null | grep '^dale' || true)"
case "$_row" in
  *FAILED*) ok "G1 a seat with an unmet artifact contract reads FAILED (fixture is real)" ;;
  '')       bad "G1 INVALID FIXTURE — dale is not on the board at all; nothing below measures anything" ;;
  *)        bad "G1 dale does not read FAILED before leaving: $_row" ;;
esac

_leave="$(sp "$TOP/tool" "$P" lv1-d leave dale 2>&1)"; _lrc=$?
[ "$_lrc" -eq 0 ] || bad "G0 INVALID FIXTURE — leave itself failed (rc=$_lrc): $(printf '%s' "$_leave" | head -2)"

_row="$(sp "$TOP/tool" "$P" lv1-l lanes 2>/dev/null | grep '^dale' || true)"
if [ -z "$_row" ]; then
  ok "G2 after leave, the departed seat is gone from the board"
else
  bad "G2 the departed seat still has a lane: $_row"
fi

_json="$(sp "$TOP/tool" "$P" lv1-l lanes --json 2>/dev/null)"
if printf '%s' "$_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  if printf '%s' "$_json" | grep -q '"name":"dale"'; then
    bad "G3 --json still lists the departed seat — every dashboard keeps the phantom"
  else
    ok "G3 --json agrees with the text board: no lane for the departed seat"
  fi
else
  bad "G3 --json stopped parsing: $(printf '%s' "$_json" | head -3)"
fi

_left=""
for _f in artifact-expect.dale role.dale model.dale keeper-strike.dale \
          spawn.dale.parent spawn.dale.brief alive.dale; do
  [ -e "$S/$_f" ] && _left="${_left:+$_left }$_f"
done
if [ -z "$_left" ]; then
  ok "G4 the departed seat's per-seat lane state is gone from .state"
else
  bad "G4 per-seat state survived leave: $_left"
fi

_missing=""
for _f in artifact-expect.nan role.nan model.nan alive.nan; do
  [ -e "$S/$_f" ] || _missing="${_missing:+$_missing }$_f"
done
_nrow="$(sp "$TOP/tool" "$P" lv1-l lanes 2>/dev/null | grep '^nan' || true)"
if [ -z "$_missing" ] && [ -n "$_nrow" ]; then
  ok "G5 the seat that did NOT leave keeps its state and its lane"
else
  bad "G5 leave took out a bystander — missing:[$_missing] nan row:[$_nrow]"
fi

_audit_ok=1
grep -q '"name":"dale"' "$S/session-registry.jsonl" 2>/dev/null || _audit_ok=0
grep -q '@dale left the stitchpad' "$P/.stitchpad/stitchpad.md" 2>/dev/null || _audit_ok=0
if [ "$_audit_ok" -eq 1 ]; then
  ok "G6 the audit trail survives: registry terminal event + the pad's departure line"
else
  bad "G6 cleanup ate history — the record that @dale was ever here is incomplete"
fi

_out="$(sp "$TOP/tool" "$P" lv1-l leave ghost 2>&1)"; _rc=$?
case "$_out" in
  *"still in roster"*|*"roster edit failed"*)
    bad "G7 leaving a name that was never rostered still claims the edit failed: $_out" ;;
  *"not in the roster"*)
    ok "G7 leaving a name that was never rostered says exactly that" ;;
  *)
    bad "G7 unexpected message for an unrostered name (rc=$_rc): $_out" ;;
esac

# ── G8 MUTANT: leave stops clearing the artifact claim ────────────────────
echo "  -- mutant: leave keeps the departed seat's lane state --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/bin/stitchpad" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = '    sp_leave_purge_seat_state "$who"'
if s.count(old) != 1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(old, '    : # mutant: no purge', 1))
PY
if [ $? -eq 9 ]; then
  bad "G8 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  P2="$(build "$MUT" 2)"
  sp "$MUT" "$P2" lv2-d leave dale >/dev/null 2>&1
  _mrow="$(sp "$MUT" "$P2" lv2-l lanes 2>/dev/null | grep '^dale' || true)"
  if [ -n "$_mrow" ]; then
    ok "G8 without the purge the departed seat is back on the board — G2 detects it"
  else
    bad "G8 mutant applied but the seat still vanished — G2 may be testing nothing"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "GREEN — leave clears the lane it owned, so the board stops inventing failures"
