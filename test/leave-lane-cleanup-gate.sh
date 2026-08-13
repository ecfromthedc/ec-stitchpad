#!/usr/bin/env bash
# leave-lane-cleanup-gate.sh — a seat that left must leave the board.
#
# THE PAIN (field-reported, 12-hour multi-agent session): two seats that had
# formally left kept a row on `stitchpad lanes` reading
#   dale   terminal   ...   NO   FAILED
# for the rest of the night. `terminal` is a fixed point in the status
# projection — nothing ages it out — so once a departed seat's unmet artifact
# contract was still on disk, its verdict was FAILED permanently.
#
# There were TWO independent causes, and fixing either alone leaves the row:
#
#   1. `leave` dropped the roster row and stopped. .state/artifact-expect.<name>
#      survived, and the board is roster ∪ session-registry ∪ artifact-expect.*
#      — so the seat kept a lane, and kept failing a contract it could no
#      longer possibly fulfil.
#   2. `leave` PUT THE SEAT BACK. sp_commit auto-registers any resolvable
#      identity missing from the roster (V1, so an agent working invisibly
#      becomes visible). A seat that retires itself — `stitchpad leave dale`
#      run by dale, the normal case — is the process doing the committing, so
#      the very commit that removed dale's row re-added it. "✓ dale left"
#      printed, and dale was still a member.
#
# Cause 2 is why this gate makes the seat leave ITSELF. A gate that has the
# lead evict someone else never resolves the departing identity during the
# commit, so it sails past the bug that kept the board haunted.
#
# This repo has already paid for this exact class once: test/bridge-heartbeat-
# interval.sh, where doctor flagged a perfectly healthy bridge as stale on every
# check — "a health check that always warns is worse than none — it trains
# everyone to ignore doctor output". A board with permanent phantom failures
# trains everyone to stop reading the board.
#
#   G1  the fixture is real: a seat with a bound session and an unmet artifact
#       contract holds a lane before it leaves
#   G2  a seat that retires ITSELF is actually off the roster afterwards
#   G3  ... and gone from the text board
#   G4  ... and from `lanes --json`, which is what dashboards read
#   G5  the departed seat's per-seat lane state is removed from .state
#   G6  a DIFFERENT seat is untouched — leave removes one seat, not a class
#   G7  the durable record survives: registry terminal event, the pad's
#       departure line, and the sticky scope-violation incident record
#   G8  a rejoining seat gets its lane back — the departure is reversible
#   G9  `leave` on a name that was never in the roster says so, instead of
#       claiming the edit failed and the name "is still in roster"
#   G10 MUTANT A: drop the state purge → the seat returns to the board reading
#       exactly the reported verdict, FAILED
#   G11 MUTANT B: drop the SP_LEAVING guard → the seat re-registers itself into
#       the roster during its own departure commit
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

# $1 = tool root, $2 = pad dir, $3 = identity, $4 = terminal namespace, rest = args
sp() {
  ( cd "$2" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME="$3" \
      STITCHPAD_TERMINAL_NAMESPACE="$4" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$1/bin/stitchpad" "${@:5}" )
}

# One roster name per LINE. `tr -d '[:space:]'` is wrong here and was wrong
# once: it deletes the newlines too, so the whole roster collapses to "nandale"
# and `grep -qx dale` can never match — G2 would pass no matter what leave did.
# sed strips the padding within each line and leaves the line breaks alone.
roster_names() {  # $1 = pad dir
  sed -n '/^```roster/,/^```$/p' "$1/.stitchpad/stitchpad.md" \
    | grep -v '^```' | grep -v '^#' | cut -d'|' -f1 | sed 's/[[:space:]]//g' | grep -v '^$'
}

build() {  # $1 = tool root, $2 = tag → prints pad dir
  local rt="$1" tag="$2" d="$TMP/pad.$2" s
  mkdir -p "$d"
  sp "$rt" "$d" lead "lv$tag-l" init --name "lv$tag" >/dev/null 2>&1
  sp "$rt" "$d" dale "lv$tag-d" join dale cli pull - >/dev/null 2>&1
  sp "$rt" "$d" nan  "lv$tag-n" join nan  cli pull - >/dev/null 2>&1
  # A BOUND SESSION is what makes this fixture the reported one. `leave` writes
  # session-end.<sid>, the projection derives status `terminal` from that
  # marker, and terminal + an unmet contract is the FAILED that never cleared.
  # Without a session id there is no marker, the status just ages, and the
  # incident cannot reproduce at all.
  sp "$rt" "$d" dale "lv$tag-d" bind-session "sess-$tag-dale" dale >/dev/null 2>&1
  sp "$rt" "$d" nan  "lv$tag-n" bind-session "sess-$tag-nan"  nan  >/dev/null 2>&1
  s="$d/.stitchpad/.state"
  # dale is under contract for an artifact that will never appear. nan is the
  # control: same shape, never leaves.
  printf '%s\n' "$d/dale-report.md" > "$s/artifact-expect.dale"
  printf '%s\n' "$d/nan-report.md"  > "$s/artifact-expect.nan"
  # A real seat is heartbeating when it leaves; without these the alive.<name>
  # assertions below would be vacuously true.
  printf '{"name":"dale","ts":1,"pid":%s}' "$$" > "$s/alive.dale"
  printf '{"name":"nan","ts":1,"pid":%s}'  "$$" > "$s/alive.nan"
  printf 'builder\n' > "$s/role.dale";  printf 'builder\n' > "$s/role.nan"
  printf 'sonnet\n'  > "$s/model.dale"; printf 'sonnet\n'  > "$s/model.nan"
  printf 'lead\n'    > "$s/spawn.dale.parent"
  printf 'write the report\n' > "$s/spawn.dale.brief"
  printf '1\n' > "$s/keeper-strike.dale"
  printf 'wrote outside scope: /etc/hosts\n' > "$s/scope-violation.dale"
  printf '%s' "$d"
}

echo "=== a departed seat must not haunt the lanes board ==="
echo ""

P="$(build "$TOP/tool" 1)"
S="$P/.stitchpad/.state"

_row="$(sp "$TOP/tool" "$P" lead lv1-l lanes 2>/dev/null | grep '^dale' || true)"
case "$_row" in
  '') bad "G1 INVALID FIXTURE — dale has no lane before leaving; nothing below measures anything" ;;
  *NO*) ok "G1 fixture is real: dale holds a lane with an unmet artifact contract" ;;
  *)  bad "G1 dale's lane shows no outstanding contract: $_row" ;;
esac

# dale retires ITSELF, from its own terminal — the case the fleet actually runs.
_leave="$(sp "$TOP/tool" "$P" dale lv1-d leave dale 2>&1)"; _lrc=$?
[ "$_lrc" -eq 0 ] || bad "G0 INVALID FIXTURE — leave itself failed (rc=$_lrc): $(printf '%s' "$_leave" | head -2)"

if roster_names "$P" | grep -qx 'dale'; then
  bad "G2 dale is STILL on the roster after leaving — the departure commit re-added it"
else
  ok "G2 a seat that retires itself is actually off the roster"
fi

_row="$(sp "$TOP/tool" "$P" lead lv1-l lanes 2>/dev/null | grep '^dale' || true)"
if [ -z "$_row" ]; then
  ok "G3 after leave, the departed seat is gone from the board"
else
  bad "G3 the departed seat still has a lane: $_row"
fi

_json="$(sp "$TOP/tool" "$P" lead lv1-l lanes --json 2>/dev/null)"
if printf '%s' "$_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  if printf '%s' "$_json" | grep -q '"name":"dale"'; then
    bad "G4 --json still lists the departed seat — every dashboard keeps the phantom"
  else
    ok "G4 --json agrees with the text board: no lane for the departed seat"
  fi
else
  bad "G4 --json stopped parsing: $(printf '%s' "$_json" | head -3)"
fi

_left=""
for _f in artifact-expect.dale role.dale model.dale keeper-strike.dale \
          spawn.dale.parent spawn.dale.brief alive.dale; do
  [ -e "$S/$_f" ] && _left="${_left:+$_left }$_f"
done
if [ -z "$_left" ]; then
  ok "G5 the departed seat's per-seat lane state is gone from .state"
else
  bad "G5 per-seat state survived leave: $_left"
fi

_missing=""
for _f in artifact-expect.nan role.nan model.nan alive.nan; do
  [ -e "$S/$_f" ] || _missing="${_missing:+$_missing }$_f"
done
_nrow="$(sp "$TOP/tool" "$P" lead lv1-l lanes 2>/dev/null | grep '^nan' || true)"
if [ -z "$_missing" ] && [ -n "$_nrow" ]; then
  ok "G6 the seat that did NOT leave keeps its state and its lane"
else
  bad "G6 leave took out a bystander — missing:[$_missing] nan row:[$_nrow]"
fi

# The audit trail, including the ONE piece of per-seat state the purge keeps on
# purpose: scope-authority.sh calls a violation record "sticky" and `scope
# --violations` reports it for the pad's life. Departure is not an acquittal.
_audit_ok=1; _audit_why=""
grep -q '"name":"dale"' "$S/session-registry.jsonl" 2>/dev/null \
  || { _audit_ok=0; _audit_why="$_audit_why registry-terminal-event"; }
grep -q '@dale left the stitchpad' "$P/.stitchpad/stitchpad.md" 2>/dev/null \
  || { _audit_ok=0; _audit_why="$_audit_why pad-departure-line"; }
[ -f "$S/scope-violation.dale" ] \
  || { _audit_ok=0; _audit_why="$_audit_why sticky-scope-violation"; }
if [ "$_audit_ok" -eq 1 ]; then
  ok "G7 the record survives: registry terminal event, pad departure line, sticky violation"
else
  bad "G7 cleanup ate history —$_audit_why"
fi

# A departure must be reversible. The board hides a departed seat on the
# strength of departed.<name>; if `join` did not retire that receipt, a seat
# that came back and later lost its roster row to a rewrite would be silently
# invisible. Rejoin, and the lane must come straight back.
sp "$TOP/tool" "$P" dale lv1-d join dale cli pull - >/dev/null 2>&1
_rejoined="$(sp "$TOP/tool" "$P" lead lv1-l lanes 2>/dev/null | grep '^dale' || true)"
if [ -n "$_rejoined" ] && [ ! -e "$S/departed.dale" ]; then
  ok "G8 a rejoining seat gets its lane back and the departure receipt is retired"
else
  bad "G8 rejoin left the seat off the board or kept a stale receipt — row:[$_rejoined] receipt:[$([ -e "$S/departed.dale" ] && echo present || echo gone)]"
fi

_out="$(sp "$TOP/tool" "$P" lead lv1-l leave ghost 2>&1)"; _rc=$?
case "$_out" in
  *"still in roster"*|*"roster edit failed"*)
    bad "G9 leaving a name that was never rostered still claims the edit failed: $_out" ;;
  *"not in the roster"*)
    ok "G9 leaving a name that was never rostered says exactly that" ;;
  *)
    bad "G9 unexpected message for an unrostered name (rc=$_rc): $_out" ;;
esac

# ── G10 MUTANT A: leave stops clearing the departed seat's lane state ──────
echo "  -- mutant A: leave keeps the departed seat's lane state --"
MUT="$TMP/mutantA"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/bin/stitchpad" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = '    sp_leave_purge_seat_state "$who"'
if s.count(old) != 1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(old, '    : # mutant: no purge', 1))
PY
if [ $? -eq 9 ]; then
  bad "G10 MUTANT A DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  P2="$(build "$MUT" 2)"
  sp "$MUT" "$P2" dale lv2-d leave dale >/dev/null 2>&1
  _mrow="$(sp "$MUT" "$P2" lead lv2-l lanes 2>/dev/null | grep '^dale' || true)"
  case "$_mrow" in
    *FAILED*) ok "G10 without the purge the departed seat reads FAILED — the incident, reproduced" ;;
    '')       bad "G10 mutant applied but the seat still vanished — G3 may be testing nothing" ;;
    *)        bad "G10 mutant kept the lane but not the reported verdict: $_mrow" ;;
  esac
fi

# ── G11 MUTANT B: the departure commit re-registers the departing seat ────
echo "  -- mutant B: no SP_LEAVING guard, so V1 auto-register undoes the leave --"
MUTB="$TMP/mutantB"; mkdir -p "$MUTB"; cp -R "$TOP/tool/." "$MUTB/"
python3 - "$MUTB/bin/stitchpad" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = '    export SP_LEAVING="$who"'
if s.count(old) != 1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(old, '    : # mutant: no leave guard', 1))
PY
if [ $? -eq 9 ]; then
  bad "G11 MUTANT B DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  P3="$(build "$MUTB" 3)"
  sp "$MUTB" "$P3" dale lv3-d leave dale >/dev/null 2>&1
  if roster_names "$P3" | grep -qx 'dale'; then
    ok "G11 without the guard the seat re-adds itself while leaving — G2 detects it"
  else
    bad "G11 mutant applied but the seat still left cleanly — G2 may be testing nothing"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "GREEN — leave clears the lane it owned, so the board stops inventing failures"
