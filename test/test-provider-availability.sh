#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-provider-test.XXXXXX")"
PAD="$TMP/project/.stitchpad"
STATE="$PAD/.state"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$STATE/sessions" "$STATE/watch.lock.d"

# ── Pad with one Ocean seat ──
cat > "$PAD/stitchpad.md" <<'EOF'
# provider test fixture

```roster
probe | ocean | push | ocean-session
```
EOF
printf 'probe' > "$STATE/sessions/ocean-session"

# ── HTTP fixture helpers ──
start_fixture() {
  local _mode="$1" _port_file="$2" _hits_file="${3:-}"
  python3 - "$_port_file" "$_mode" "$_hits_file" <<'PY' &
import http.server, json, sys, time
mode = sys.argv[2]
hits_file = sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    hits = 0
    def do_GET(self):
        type(self).hits += 1
        if mode == "healthy":
            body = json.dumps({"ok": True, "current": {"provider": "deepseek", "model": "v4-pro"},
                               "models": [{"id": "deepseek-v4-pro", "provider": "deepseek", "ready": True}]})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())
        elif mode == "rate_limited":
            self.send_response(429)
            self.send_header("Retry-After", "30")
            self.send_header("X-Ratelimit-Remaining", "0")
            self.end_headers()
            self.wfile.write(b'{"error":"rate limited"}')
        elif mode == "k3_outage":
            # /v1/models returns ok (daemon is up), /ready hangs.
            # The handler sleeps past the client's 1.5s deadline — the
            # client's socket timeout fires a clean TimeoutError.
            if "/ready" in self.path:
                time.sleep(5)  # > client's 1.5s deadline
                return
            body = json.dumps({"ok": True, "current": {"provider": "kimi", "model": "k3"},
                               "models": [{"id": "kimi-k3", "provider": "kimi", "ready": True}]})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())
        elif mode == "empty_catalog":
            body = json.dumps({"ok": True, "current": {}, "models": []})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())
        elif mode == "multi_endpoint":
            if "/v1/models" in self.path:
                body = json.dumps({"ok": True, "current": {"provider": "deepseek", "model": "v4-pro"},
                                   "models": [{"id": "deepseek-v4-pro", "provider": "deepseek", "ready": True}]})
            elif "/ready" in self.path:
                body = json.dumps({"ok": True, "primary": {"provider": "deepseek", "model": "v4-pro",
                                   "credential_present": True, "ok": True},
                                   "fallback_providers": []})
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())
        self.log_message = lambda *a: None
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_port))
if mode == "k3_outage":
    # Handle exactly 2 requests (v1/models + ready timeout) then stop
    for _ in range(2):
        server.timeout = 3.0
        server.handle_request()
else:
    # Handle all requests within a timeout
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        server.timeout = max(0.1, deadline - time.monotonic())
        server.handle_request()
PY
  SERVER_PID=$!
  for _ in $(seq 1 100); do [ -s "$_port_file" ] && return; sleep 0.02; done
  fail "HTTP fixture did not start"
}

# ── Provider availability: healthy daemon ──
port_file="$TMP/healthy.port"
start_fixture healthy "$port_file"
port="$(cat "$port_file")"
healthy_json="$(cd "$TMP/project" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$PAD" \
  OCEAN_DAEMON_URL="http://127.0.0.1:$port" "$SP" health --deep --json)"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

python3 - "$healthy_json" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
p = s["provider"]
assert p is not None, "provider missing"
assert p["summary"] == "actively_responding", f"expected actively_responding, got {p['summary']}"
states = [st["state"] for st in p["states"]]
assert "configured" in states
assert "catalog_ready" in states
assert "probe_successful" in states
assert "rate_limited" not in states
assert "actively_responding" in states, f"states: {states}"
assert p["stale"] is False
assert p["age_seconds"] == 0
# Both endpoints should be ok
for ep_name in ("/v1/models", "/ready"):
    assert p["endpoints"][ep_name]["status"] == "ok", f"{ep_name} not ok: {p['endpoints'][ep_name]}"
print("PASS: healthy daemon -> actively_responding")
PY

# ── Provider availability: rate-limited ──
port_file="$TMP/rate.port"
start_fixture rate_limited "$port_file"
port="$(cat "$port_file")"
rate_json="$(cd "$TMP/project" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$PAD" \
  OCEAN_DAEMON_URL="http://127.0.0.1:$port" "$SP" health --deep --json)"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

python3 - "$rate_json" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
p = s["provider"]
states = [st["state"] for st in p["states"]]
assert "configured" in states
assert "rate_limited" in states, f"expected rate_limited, states: {states}"
assert "actively_responding" not in states, "rate-limited must not be actively_responding"
# At least one endpoint hit 429
rate_endpoints = [ep for ep, v in p["endpoints"].items() if v.get("status") == "rate_limited"]
assert rate_endpoints, f"no rate_limited endpoint: {p['endpoints']}"
# Rate-limit headers should be captured
rl_ep = p["endpoints"][rate_endpoints[0]]
assert rl_ep.get("rate_limit_headers"), "rate_limit_headers missing"
assert rl_ep["http_status"] == 429
print("PASS: rate-limited daemon -> rate_limited, not actively_responding")
PY

# ── Provider availability: empty catalog ──
port_file="$TMP/empty.port"
start_fixture empty_catalog "$port_file"
port="$(cat "$port_file")"
empty_json="$(cd "$TMP/project" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$PAD" \
  OCEAN_DAEMON_URL="http://127.0.0.1:$port" "$SP" health --deep --json)"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

python3 - "$empty_json" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
p = s["provider"]
states = [st["state"] for st in p["states"]]
assert "configured" in states
# Empty catalog: probe_successful (endpoints returned ok) but NOT catalog_ready
assert "probe_successful" in states, f"states: {states}"
assert "catalog_ready" not in states, f"empty catalog should not be catalog_ready: {states}"
print("PASS: empty catalog -> probe_successful, not catalog_ready")
PY

# ── K3 OUTAGE ACCEPTANCE SCENARIO ──────────────────────────────────────
# Tonight's k3 outage: 0ms completed turns while /health said ok.
# /v1/models returns green (daemon up), but /ready hangs forever
# (the provider is degraded/unreachable through the proxy layer).
# The provider must land in probe_successful at best, NEVER actively_responding.
port_file="$TMP/k3.port"
start_fixture k3_outage "$port_file"
port="$(cat "$port_file")"
k3_start_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
k3_json="$(cd "$TMP/project" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$PAD" \
  OCEAN_DAEMON_URL="http://127.0.0.1:$port" "$SP" health --deep --json)"
k3_end_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
k3_elapsed_ms=$(( (k3_end_ns - k3_start_ns) / 1000000 ))

python3 - "$k3_json" "$k3_elapsed_ms" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
elapsed_ms = int(sys.argv[2])
p = s["provider"]
states = [st["state"] for st in p["states"]]
# /v1/models should return ok, /ready should timeout
models_ep = p["endpoints"].get("/v1/models", {})
ready_ep = p["endpoints"].get("/ready", {})
assert models_ep.get("status") == "ok", f"v1/models should be ok: {models_ep}"
# /ready must NOT be ok — either timeout or unavailable both prove the provider is bad
assert ready_ep.get("status") != "ok", f"ready must not be ok during k3 outage: {ready_ep}"
assert "configured" in states
assert "catalog_ready" in states, f"catalog should be ready, states: {states}"
assert "probe_successful" in states, f"should be probe_successful, states: {states}"
assert "actively_responding" not in states, \
    "K3 OUTAGE REGRESSION: provider marked actively_responding when /ready timed out. " \
    "0ms completed turns while /health says ok MUST NOT route to this provider."
assert p["summary"] != "actively_responding", f"summary must not be actively_responding: {p['summary']}"
# Must finish within the probe deadline + buffer
assert elapsed_ms < 3500, f"k3 probe took {elapsed_ms}ms, expected < 3500ms (1.5s deadline + buffer)"
print("PASS: k3 outage -> probe_successful at best, never actively_responding")
PY

# ── Provider availability: both endpoints ok (multi_endpoint) ──
port_file="$TMP/multi.port"
start_fixture multi_endpoint "$port_file"
port="$(cat "$port_file")"
multi_json="$(cd "$TMP/project" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$PAD" \
  OCEAN_DAEMON_URL="http://127.0.0.1:$port" "$SP" health --deep --json)"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

python3 - "$multi_json" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
p = s["provider"]
assert p["summary"] == "actively_responding", f"expected actively_responding, got {p['summary']}"
states = [st["state"] for st in p["states"]]
assert "configured" in states
assert "catalog_ready" in states
assert "probe_successful" in states
assert "actively_responding" in states
for ep_name in ("/v1/models", "/ready"):
    assert p["endpoints"][ep_name]["status"] == "ok"
    assert isinstance(p["endpoints"][ep_name].get("body"), dict)
print("PASS: multi-endpoint healthy -> actively_responding with body inspection")
PY

# ── Staleness: a probe timestamp older than 90s must mark stale ──
port_file="$TMP/stale.port"
start_fixture healthy "$port_file"
port="$(cat "$port_file")"
# Use a custom daemon-url arg to test staleness
stale_json="$(cd "$TMP/project" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$PAD" \
  OCEAN_DAEMON_URL="http://127.0.0.1:$port" "$SP" health --deep --json)"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

python3 - "$stale_json" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
p = s["provider"]
assert p["stale"] is False, "fresh probe should not be stale"
assert p["age_seconds"] == 0, f"fresh probe age should be 0, got {p['age_seconds']}"
# Verify probed_at is a reasonable timestamp
probed_at = p["probed_at"]
assert probed_at > 1700000000, f"probed_at too far in past: {probed_at}"
print("PASS: staleness guard: fresh probe not stale")
PY

# ── Local mode (no --deep): provider must be null ──
port_file="$TMP/local.port"
start_fixture healthy "$port_file"
port="$(cat "$port_file")"
local_json="$(cd "$TMP/project" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$PAD" \
  OCEAN_DAEMON_URL="http://127.0.0.1:$port" "$SP" health --json)"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

python3 - "$local_json" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
assert s["mode"] == "local"
assert s.get("provider") is None, "local mode must not probe provider"
print("PASS: local mode -> provider is None")
PY

# ── Human output includes provider line ──
port_file="$TMP/human.port"
start_fixture multi_endpoint "$port_file"
port="$(cat "$port_file")"
human="$(cd "$TMP/project" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$PAD" \
  OCEAN_DAEMON_URL="http://127.0.0.1:$port" "$SP" health --deep)"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

case "$human" in
  *"provider: actively_responding"*) ;;
  *) fail "human output missing provider line" ;;
esac
echo "PASS: human output includes provider availability line"

echo ""
echo "ALL PROVIDER AVAILABILITY TESTS PASSED"
