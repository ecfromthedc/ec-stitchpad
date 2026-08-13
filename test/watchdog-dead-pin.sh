#!/usr/bin/env bash
# Regression test for dead model-pin detection.
#
# The failure it exists for: a seat pinned to a model the daemon no longer
# offers goes permanently dark — every wake fails preflight, the watchdog
# discarded the error, and the seat looked "stalled" for hours while the real
# cause was an engine that had been removed. The watchdog must NAME the dead
# pin instead of retrying into silence.
#
#   bash test/watchdog-dead-pin.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$HERE/../tool/bin/stitchpad-watchdog"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-pin.XXXXXX")"
trap 'kill "${FAKE_PID:-}" 2>/dev/null; rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }

PAD="$WORK/repo"; STATE="$PAD/.stitchpad/.state"
mkdir -p "$STATE"
: > "$PAD/.stitchpad/tasks.md"
printf 'sid-alive' > "$STATE/ocean-session.goodseat"
printf 'sid-dark'  > "$STATE/ocean-session.deadseat"
printf 'live-model' > "$STATE/seat-model.goodseat"
printf 'retired-model' > "$STATE/seat-model.deadseat"

# A daemon that offers exactly one model, and not the one deadseat is pinned to.
PORT=$(( 45000 + RANDOM % 2000 ))
python3 - "$PORT" <<'PY' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"current": {"model": "retired-model"},
                           "models": [{"id": "live-model", "ready": True},
                                      {"id": "other-model", "ready": True}]}).encode()
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
FAKE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf -m 1 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break
  sleep 0.3
done

OUT="$(OCEAN_DAEMON_URL="http://127.0.0.1:$PORT" "$WD" --pad "$PAD" --check-pins 2>&1)"

grep -q 'DEAD MODEL PIN: @deadseat' <<<"$OUT" \
  && ok "the seat with a retired pin is named" \
  || bad "the seat with a retired pin is named (got: $OUT)"

grep -q "retired-model" <<<"$OUT" \
  && ok "the report says WHICH pin is dead" \
  || bad "the report says which pin is dead"

grep -q 'goodseat' <<<"$OUT" \
  && bad "a healthy seat must not be reported" \
  || ok "a healthy seat is left alone"

# Reporting is once-per-pin, not once-per-sweep: a warning that repeats every
# 90 seconds is a warning the operator learns to scroll past.
OUT2="$(OCEAN_DAEMON_URL="http://127.0.0.1:$PORT" "$WD" --pad "$PAD" --check-pins 2>&1)"
grep -q 'DEAD MODEL PIN' <<<"$OUT2" \
  && bad "the same dead pin must not re-report every sweep" \
  || ok "the same dead pin reports once, then stays quiet"

# Re-pin to something real: the marker clears so a FUTURE break can report again.
printf 'other-model' > "$STATE/seat-model.deadseat"
OCEAN_DAEMON_URL="http://127.0.0.1:$PORT" "$WD" --pad "$PAD" --check-pins >/dev/null 2>&1
[ -f "$STATE/.watchdog-deadpin.deadseat" ] \
  && bad "re-pinning must clear the marker" \
  || ok "re-pinning clears the marker so the next break is heard"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
