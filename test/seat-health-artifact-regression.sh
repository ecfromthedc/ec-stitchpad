#!/usr/bin/env bash
# seat-health-artifact-regression.sh — turns since last ARTIFACT change
#
# WHY. stitchpad-seat-health's own header has always argued that turn count is
# a leading indicator and an artifact is the only proof — and then the table
# printed turns and state and nothing else. On 2026-08-23 four seats reached
# 150-180 turns having written ZERO bytes to their report files; the daemon
# said `running` throughout and the tool said `watch — rotate at next clean
# break`. Turn count could not have caught it: a seat can be fine at 210 and
# dead at 150.
#
# So the table now carries the proof. Register the file a seat is supposed to
# be writing, and IDLE reports TURNS SINCE THAT ARTIFACT LAST CHANGED.
#
# Gates:
#   S1  --artifact registers a path and persists it
#   S2  BYTES/IDLE columns appear
#   S3  a young seat with an empty artifact is not yet accused
#   S4  an artifact still 0 bytes past the stall gate is called out, exit 3
#   S5  a seat whose artifact just changed is healthy at the same turn count
#   S6  an artifact unchanged across the stall gate is STALLED
#   S7  IDLE is turns-since-change, not turns
#   S8  --forget-artifact unregisters
#   S9  with nothing registered the footer says how to register
#   S10 a bad seat name never reaches a path
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$ROOT/tool/bin/stitchpad-seat-health"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  FAIL %s: %s\n' "$1" "${2:-}" >&2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-sha.XXXXXX")"
STUB_PID=""
cleanup() {
  if [ -n "$STUB_PID" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

STATE="$TMP/state"; mkdir -p "$STATE" "$TMP/turns"
printf 'sid-a\n' > "$STATE/ocean-session.seatA"
printf 'sid-b\n' > "$STATE/ocean-session.seatB"
set_turns() { printf '%s' "$2" > "$TMP/turns/$1"; }
set_turns sid-a 5; set_turns sid-b 5

# ── stub ocean daemon: turns come from a file so the test can advance them ──
cat > "$TMP/stub.py" <<'PYEOF'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
TURNS = sys.argv[1]; PORTFILE = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        sid = self.path.rsplit('/', 1)[-1]
        try:
            with open(os.path.join(TURNS, sid)) as f: turns = int(f.read().strip())
        except Exception:
            self.send_response(404); self.end_headers(); return
        body = json.dumps({"session": {"turns": turns, "state": "running"}}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORTFILE, "w") as f: f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
/usr/bin/python3 "$TMP/stub.py" "$TMP/turns" "$TMP/port" &
STUB_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.2; done
[ -s "$TMP/port" ] || { echo "stub daemon never came up" >&2; exit 1; }
export OCEAN_DAEMON="http://127.0.0.1:$(cat "$TMP/port")"

REPORT_A="$TMP/reports/a.md"; REPORT_B="$TMP/reports/b.md"
mkdir -p "$TMP/reports"
: > "$REPORT_A"                       # the wedge: a seat that writes nothing
printf 'first findings\n' > "$REPORT_B"

sh() { "$SH" --state "$STATE" --stale-turns 10 "$@" 2>&1; }

echo "=== seat-health-artifact-regression ==="
echo ""

OUT="$(sh --artifact "seatA=$REPORT_A")"
if [ -f "$STATE/artifact-path.seatA" ] &&
   [ "$(cat "$STATE/artifact-path.seatA")" = "$REPORT_A" ]; then
  ok "S1: --artifact registers and persists the path"
else bad "S1: registration did not persist" "$OUT"; fi
sh --artifact "seatB=$REPORT_B" >/dev/null

OUT="$(sh)"
case "$OUT" in *BYTES*IDLE*) ok "S2: BYTES and IDLE columns present" ;;
  *) bad "S2: columns missing" "$(printf '%s' "$OUT" | head -2)" ;; esac

OUT="$(sh)"; RC=$?
if [ "$RC" -eq 0 ] && case "$OUT" in *"NO ARTIFACT"*) false ;; *) true ;; esac; then
  ok "S3: a 5-turn seat with an empty artifact is not yet accused (rc=$RC)"
else bad "S3: accused too early (rc=$RC)" "$OUT"; fi

# Advance both seats well past the stall gate. seatB's artifact grows;
# seatA's never does.
set_turns sid-a 60; set_turns sid-b 60
printf 'second findings\n' >> "$REPORT_B"
OUT="$(sh)"; RC=$?
if case "$OUT" in *"NO ARTIFACT"*) true ;; *) false ;; esac && [ "$RC" -eq 3 ]; then
  ok "S4: 0-byte artifact at 60 turns is called out, hot exit (rc=$RC)"
else bad "S4: silent on a seat that wrote nothing (rc=$RC)" "$OUT"; fi

SEATB_LINE="$(printf '%s\n' "$OUT" | grep '^seatB' || true)"
case "$SEATB_LINE" in
  *STALLED*|*"NO ARTIFACT"*) bad "S5: healthy seat flagged" "$SEATB_LINE" ;;
  *) ok "S5: seat whose artifact just changed is healthy at the same 60 turns" ;;
esac

# Now let seatB go quiet: turns climb, artifact does not move.
set_turns sid-b 75
OUT="$(sh)"; RC=$?
SEATB_LINE="$(printf '%s\n' "$OUT" | grep '^seatB' || true)"
case "$SEATB_LINE" in
  *STALLED*) ok "S6: artifact unchanged across the stall gate is STALLED" ;;
  *) bad "S6: stall not detected" "$SEATB_LINE" ;;
esac
case "$SEATB_LINE" in
  *"unchanged for 15 turns"*) ok "S7: IDLE is turns-since-change (15), not turns (75)" ;;
  *) bad "S7: IDLE is not turns-since-change" "$SEATB_LINE" ;;
esac

sh --forget-artifact seatB >/dev/null
[ ! -f "$STATE/artifact-path.seatB" ] \
  && ok "S8: --forget-artifact unregisters" \
  || bad "S8: registration survived --forget-artifact"

sh --forget-artifact seatA >/dev/null
OUT="$(sh)"
case "$OUT" in *"No artifact is registered"*) ok "S9: footer explains how to register when none is" ;;
  *) bad "S9: no guidance when nothing is registered" "$(printf '%s' "$OUT" | tail -4)" ;; esac

OUT="$("$SH" --state "$STATE" --artifact "../../evil=$REPORT_A" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && [ ! -e "$STATE/../../artifact-path.evil" ]; then
  ok "S10: a bad seat name is refused before it reaches a path (rc=$RC)"
else bad "S10: bad seat name accepted (rc=$RC)" "$OUT"; fi

echo ""
echo "=== RESULTS ==="
echo "Passed:  $PASSED"
echo "Failed:  $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
echo "All seat-health artifact gates PASSED."
