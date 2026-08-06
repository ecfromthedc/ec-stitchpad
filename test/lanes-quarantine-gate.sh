#!/usr/bin/env bash
# lanes-quarantine-gate.sh — k3 F0: a seat the watchdog has given up on must
# not render as healthy on the operator's board.
#
# THE PAIN: seat-keeper quarantines a seat after MAX_STRIKES consecutive wakes
# that left the same mention unanswered, writes .state/keeper-strike.<name>, and
# stops waking it "until someone looks". `lanes` is the board the operator looks
# AT — and it did not know the state existed. A quarantined seat with a live
# heartbeat rendered WORKING. `keeper --report` and `health --strict` were taught
# about quarantine in an earlier round; the primary board was not.
#
# Second half, found while fixing the first: `lanes --json` iterated
# artifact-expect.* only, so a seat with no artifact claim never appeared at all
# — a quarantined seat was invisible to every dashboard and cron reading it.
#
#   G1  3 strikes + live heartbeat → QUARANTINED on the text board, not WORKING
#   G2  ... and in --json, as a first-class field, not only inside the verdict
#   G3  a healthy seat still reads WORKING (the rule is not a blanket)
#   G4  strikes below the threshold annotate without condemning
#   G5  clearing the strike file restores the seat — the documented un-quarantine
#       path (rm keeper-strike.<name>) actually works
#   G6  --json is still valid JSON with empty stderr (the machine contract)
#   G7  --json lists a seat that has no artifact claim
#   G8  MUTANT: drop the strike check → G1 goes RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-quar.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT   # nothing here spawns (P9)
export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

build() {  # $1 = tool root → pad dir
  local rt="$1" d="$TMP/pad.$2"
  mkdir -p "$d"
  ( cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="q$2-a" STITCHPAD_HEARTBEAT_AUTOSTART=0 "$rt/bin/stitchpad" init --name "q$2" >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="q$2-a" STITCHPAD_HEARTBEAT_AUTOSTART=0 "$rt/bin/stitchpad" join larry cli pull - >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=dale \
      STITCHPAD_TERMINAL_NAMESPACE="q$2-b" STITCHPAD_HEARTBEAT_AUTOSTART=0 "$rt/bin/stitchpad" join dale cli push "sess-$2" >/dev/null 2>&1 ) || true
  # The push TARGET is a terminal id and "one terminal = one pad": reusing
  # sess-1 for the mutant pad made the second join REFUSE, leaving dale off the
  # board — the mutant then looked like it had killed nothing.
  # a live heartbeat: without this the seat reads UNKNOWN and the gate would
  # pass for the wrong reason — WORKING is the verdict that must be displaced.
  printf '{"name":"dale","ts":1,"pid":%s}' "$$" > "$d/.stitchpad/.state/alive.dale"
  printf '%s' "$d"
}
lanes() {  # $1 = tool root, $2 = pad dir, rest = args
  ( cd "$2" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE=qa STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$1/bin/stitchpad" lanes "${@:3}" )
}

echo "=== k3 F0: the board must show a seat the watchdog abandoned ==="
echo ""

P="$(build "$TOP/tool" 1)"
_row="$(lanes "$TOP/tool" "$P" 2>/dev/null | grep '^dale' || true)"
case "$_row" in
  *WORKING*) ok "G3 a healthy heartbeating seat reads WORKING" ;;
  '') bad "G3 INVALID FIXTURE — dale is not on the board at all: nothing below measures anything" ;;
  *) bad "G3 a healthy seat no longer reads WORKING: $_row" ;;
esac

printf 1 > "$P/.stitchpad/.state/keeper-strike.dale"
_row="$(lanes "$TOP/tool" "$P" 2>/dev/null | grep '^dale' || true)"
case "$_row" in
  *QUARANTINED*) bad "G4 one strike condemned the seat — the watchdog has not given up yet" ;;
  *"WORKING!1"*) ok "G4 one strike annotates (WORKING!1) without condemning" ;;
  *) bad "G4 a strike left no trace on the board: $_row" ;;
esac

printf 3 > "$P/.stitchpad/.state/keeper-strike.dale"
_row="$(lanes "$TOP/tool" "$P" 2>/dev/null | grep '^dale' || true)"
case "$_row" in
  *QUARANTINED*) ok "G1 a quarantined seat renders QUARANTINED, not WORKING" ;;
  *WORKING*) bad "G1 the board still says WORKING for a seat the keeper abandoned: $_row" ;;
  *) bad "G1 unexpected row: $_row" ;;
esac

_jerr="$TMP/j.err"
_json="$(lanes "$TOP/tool" "$P" --json 2>"$_jerr")"
if printf '%s' "$_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "G6 --json is still valid JSON"
else
  bad "G6 --json stopped parsing: $(printf '%s' "$_json" | head -3)"
fi
if [ ! -s "$_jerr" ]; then
  ok "G6b --json still leaves stderr empty (the machine contract)"
else
  bad "G6b --json wrote to stderr: $(head -2 "$_jerr" | tr '\n' ' ')"
fi
_probe="$(printf '%s' "$_json" | python3 -c '
import json,sys
try: rows=json.load(sys.stdin)
except Exception: print("badjson"); raise SystemExit(0)
d=[r for r in rows if r.get("name")=="dale"]
if not d: print("missing"); raise SystemExit(0)
d=d[0]
print("%s|%s|%s" % (d.get("quarantined"), d.get("keeper_strikes"), d.get("verdict")))' 2>/dev/null)"
case "$_probe" in
  "True|3|QUARANTINED") ok "G2 --json carries quarantined=true, keeper_strikes=3 and the verdict" ;;
  missing) bad "G2 dale is absent from --json entirely — a dashboard can never see the quarantine" ;;
  *) bad "G2 --json says [$_probe] (want True|3|QUARANTINED)" ;;
esac
if printf '%s' "$_json" | grep -q '"name":"larry"'; then
  ok "G7 --json lists a seat with no artifact claim (it used to list only claims)"
else
  bad "G7 --json still hides seats without an artifact claim"
fi

rm -f "$P/.stitchpad/.state/keeper-strike.dale"
_row="$(lanes "$TOP/tool" "$P" 2>/dev/null | grep '^dale' || true)"
case "$_row" in
  *WORKING*) ok "G5 removing keeper-strike.dale restores the seat — the documented fix works" ;;
  *) bad "G5 the seat stayed condemned after the strike file was removed: $_row" ;;
esac

# ── G8 MUTANT: the board stops asking the watchdog ────────────────────────
echo "  -- mutant: lanes ignores keeper-strike --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/bin/lib.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='    if [ "$_lane_strikes" -ge "${SEAT_KEEPER_MAX_STRIKES:-3}" ]; then'
new='    if false; then'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "G8 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  P2="$(build "$MUT" 2)"
  printf 3 > "$P2/.stitchpad/.state/keeper-strike.dale"
  _mrow="$(lanes "$MUT" "$P2" 2>/dev/null | grep '^dale' || true)"
  [ -n "$_mrow" ] || bad "G8 INVALID PROBE — dale is not on the mutant board at all"
  case "$_mrow" in
    *QUARANTINED*) bad "G8 mutant applied but the row still says QUARANTINED — G1 may be testing nothing" ;;
    *WORKING*) ok "G8 without the check the abandoned seat reads WORKING again — G1 detects it" ;;
    *) bad "G8 mutant produced an unreadable row: $_mrow" ;;
  esac
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "F0 GREEN — the board no longer hides a seat the watchdog gave up on"
