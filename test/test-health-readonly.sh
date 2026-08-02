#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
TMP="$(mktemp -d /tmp/stitchpad-health-test.XXXXXX)"
PAD="$TMP/project/.stitchpad"
STATE="$PAD/.state"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$STATE/sessions" "$STATE/heartbeat.alice.lock" \
  "$STATE/delivery.bob.worker.lock.d" "$STATE/delivery.frank.worker.lock.d" \
  "$STATE/watch.lock.d"
cat > "$PAD/stitchpad.md" <<'EOF'
# health fixture

```roster
alice | herdr | pull | -
bob | ocean | push | ocean-session
carol | ocean | push | ocean-session
dave | missing-adapter | push | -
erin | codex | pull | -
frank | codex | pull | -
bad/name | codex | pull | -
quote"name | codex | pull | -
operator | human | pull | -
```

## @operator · 01:00 PM

@bob please review the delivery worker

## @alice · 01:01 PM

working locally

## @operator · 01:02 PM

@erin first request

## @erin · 01:03 PM

@operator first request handled

## @operator · 01:04 PM

@erin second request is still open

## @erin · 01:05 PM

@operator second request handled too

## @alice · 01:06 PM

@erin different sender request

## @erin · 01:07 PM

@alice different sender handled

## @bob · 01:08 PM

@erin only this final request is open
EOF

# Give `read --new` two real Git generations. Its cursor acknowledgement is the
# sole intentional mutation exercised by this test; all diagnostics remain
# byte- and metadata-stable.
git --git-dir="$PAD/stitchpad-git" --work-tree="$PAD" init -q
git --git-dir="$PAD/stitchpad-git" --work-tree="$PAD" add stitchpad.md
git --git-dir="$PAD/stitchpad-git" --work-tree="$PAD" \
  -c user.name=stitchpad -c user.email=pad@local commit -q -m "health fixture base"
READREF_OLD="$(git --git-dir="$PAD/stitchpad-git" rev-parse HEAD)"
cat >> "$PAD/stitchpad.md" <<'EOF'

## @alice · 01:05 PM

health cursor delta
EOF
git --git-dir="$PAD/stitchpad-git" --work-tree="$PAD" add stitchpad.md
git --git-dir="$PAD/stitchpad-git" --work-tree="$PAD" \
  -c user.name=stitchpad -c user.email=pad@local commit -q -m "health fixture delta"
READREF_HEAD="$(git --git-dir="$PAD/stitchpad-git" rev-parse HEAD)"
printf 'must not be replayed by a diagnostic' > "$PAD/stitchpad.md.ready"
python3 - "$PAD/stitchpad.md.ready" <<'PY'
import os, sys, time
old = time.time() - 10
os.utime(sys.argv[1], (old, old))
PY

printf 'alice' > "$STATE/sessions/alice-a"
printf 'alice' > "$STATE/sessions/alice-b"
printf 'bob' > "$STATE/sessions/ocean-session"
printf 'ghost' > "$STATE/sessions/orphan-session"
printf 'erin' > "$STATE/sessions/erin-session"
printf 'frank' > "$STATE/sessions/frank-session"
ln -s "$PAD/stitchpad.md" "$STATE/sessions/leaky-session"
printf 'operator' > "$STATE/runtime.operator"
printf '0' > "$STATE/seen.bob"
printf '99999999999999999999' > "$STATE/seen.dave"
printf '1' > "$STATE/pending.bob"
printf '%s' "$READREF_OLD" > "$STATE/readref.bob"
: > "$STATE/dnd.bob"

python3 - "$STATE" "$$" "$PPID" <<'PY'
import json, os, sys, time
state, live, parent = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def put(name, value):
    with open(os.path.join(state, name), "w", encoding="utf-8") as f:
        json.dump(value, f, separators=(",", ":"))
put("alive.alice", {"name":"alice","ts":int(time.time()),"pid":live,"parentPid":parent,"session":"alice-a","surface":"term-alice","target":"term-alice"})
put("alive.bob", {"name":"bob","ts":int(time.time())-300,"pid":999999,"parentPid":999998,"session":"ocean-session","target":"ocean-session"})
old = time.time() - 300
os.utime(os.path.join(state, "alive.bob"), (old, old))
put("alive.carol", {"name":"carol","ts":99999999999999999999,"pid":"9"*100,"parentPid":-2,"session":"carol-session"})
put("alive.frank", {"name":"frank","ts":float("inf"),"pid":live,"parentPid":parent,"session":"frank-session"})
PY

printf '%s' "$$" > "$STATE/heartbeat.alice.lock/pid"
printf '99999999999999999999' > "$STATE/watch.lock.d/pid"
printf '2026-08-02T12:00:00Z' > "$STATE/watch.lock.d/ts"
printf '%s\n' '1|1|m-1|TASK-1|2026-08-02T12:00:00|ocean|push|ocean-session' > "$STATE/delivery.bob.pending"
cat > "$STATE/delivery.bob.state" <<'EOF'
state=in_flight
generation=1
ordinal=1
message_id=m-1
task_id=TASK-1
accepted_at=2026-08-02T12:00:00
started_at=2026-08-02T12:00:01
completed_at=
error_at=
error_code=
turn_id=turn-1
turn_status=accepted
EOF
printf '%s' "$$" > "$STATE/delivery.bob.worker.lock.d/pid"
printf 'turn-1' > "$STATE/delivery.bob.turn.1"
printf '%s' '1|m-1|acceptance_unknown|attempt-1' > "$STATE/delivery.bob.keeper-reservation"
printf '%s' '0||accepted|' > "$STATE/delivery.carol.keeper-reservation"
printf '%s' '|||||||' > "$STATE/delivery.dave.pending"
printf '%s\n' 'state=accepted' > "$STATE/delivery.dave.state"
printf '%s' '0|task-message|accepted|attempt-zero' > "$STATE/delivery.dave.keeper-reservation"
printf '%s' '0|keeper-task-12345-67|accepted|attempt-zero' > "$STATE/delivery.frank.keeper-reservation"
printf '%s' '1|1|m-frank|TASK-F|2026-08-02T12:00:00|ocean|push|frank-target' > "$STATE/delivery.frank.pending"
cat > "$STATE/delivery.frank.state" <<'EOF'
state=accepted
generation=99999999999999999999
ordinal=1
accepted_at=2026-08-02T12:00:00
EOF
printf '%s' '99999999999999999999' > "$STATE/delivery.frank.worker.lock.d/pid"

snapshot() {
  python3 - "${1:-$STATE}" "${2:-}" <<'PY'
import hashlib, json, os, stat, sys
root, ignored = sys.argv[1:3]
rows = []
for base, dirs, files in os.walk(root):
    dirs.sort(); files.sort()
    for name in dirs + files:
        path = os.path.join(base, name); rel = os.path.relpath(path, root)
        if ignored and rel in {ignored, os.path.dirname(ignored)}:
            continue
        st = os.lstat(path)
        row = [rel, stat.S_IFMT(st.st_mode), stat.S_IMODE(st.st_mode), st.st_size, st.st_mtime_ns]
        if stat.S_ISREG(st.st_mode):
            with open(path, "rb") as f: row.append(hashlib.sha256(f.read()).hexdigest())
        elif stat.S_ISLNK(st.st_mode): row.append(os.readlink(path))
        rows.append(row)
print(hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest())
PY
}

process_snapshot() {
  ps -axo pid=,command= | awk -v root="$ROOT" '
    index($0, root "/tool/bin/watch.sh") ||
    (index($0, root "/tool/bin/stitchpad") && $0 ~ /heartbeat/) ||
    index($0, root "/tool/bin/health.py") {print}'
}

before="$(snapshot "$TMP/project")"
processes_before="$(process_snapshot)"
ready_before="$(cksum < "$PAD/stitchpad.md.ready")|$(stat -f %m "$PAD/stitchpad.md.ready" 2>/dev/null || stat -c %Y "$PAD/stitchpad.md.ready")"
cd "$TMP/project"
export STITCHPAD_HOME="$ROOT/tool" STITCHPAD_PAD_DIR="$PAD" STITCHPAD_NAME=bob
local_json="$(OCEAN_DAEMON_URL=http://example.invalid "$SP" health --json)"
human="$($SP health)"
doctor_json="$($SP doctor --json)"
doctor_human="$($SP doctor 2>&1 || true)"
status="$($SP status)"
roster="$($SP roster)"
who="$($SP who)"
read_window="$($SP read -n 5)"
deep_json="$(OCEAN_DAEMON_URL=http://127.0.0.1:1 "$SP" health --deep --json)"
hostname_json="$(OCEAN_DAEMON_URL=http://localhost:1 "$SP" health --deep --json)"
bad_url_json="$(OCEAN_DAEMON_URL='http://[::1]@evil.test' "$SP" health --deep --json)"

# A loopback daemon may be compromised or misconfigured. Refuse its redirect
# instead of following a nominally local health request onto the network.
start_http_fixture() {
  _mode="$1"; _port_file="$2"
  python3 - "$_port_file" "$_mode" <<'PY' &
import http.server, sys
mode = sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://example.invalid/stitchpad-health-leak")
        elif mode == "slow":
            body = b"x" * 100
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
        else:
            body = b'{"session":null}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if mode == "slow":
            import time
            try:
                for byte in body:
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                    time.sleep(0.15)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif mode != "redirect":
            self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as stream:
    stream.write(str(server.server_port))
server.handle_request()
PY
  SERVER_PID=$!
  for _ in $(seq 1 100); do [ -s "$_port_file" ] && return; sleep 0.02; done
  fail "HTTP fixture did not start"
}

redirect_port_file="$TMP/redirect.port"
start_http_fixture redirect "$redirect_port_file"
redirect_json="$(OCEAN_DAEMON_URL="http://127.0.0.1:$(cat "$redirect_port_file")" "$SP" health --deep --json)"
wait "$SERVER_PID"
SERVER_PID=""
malformed_port_file="$TMP/malformed.port"
start_http_fixture malformed "$malformed_port_file"
malformed_deep_json="$(OCEAN_DAEMON_URL="http://127.0.0.1:$(cat "$malformed_port_file")" "$SP" health --deep --json)"
wait "$SERVER_PID"
SERVER_PID=""
slow_port_file="$TMP/slow.port"
start_http_fixture slow "$slow_port_file"
slow_start_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
slow_deep_json="$(OCEAN_DAEMON_URL="http://127.0.0.1:$(cat "$slow_port_file")" "$SP" health --deep --json)"
slow_end_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
wait "$SERVER_PID"
SERVER_PID=""
slow_elapsed_ms=$(( (slow_end_ns - slow_start_ns) / 1000000 ))
after="$(snapshot "$TMP/project")"
ready_after="$(cksum < "$PAD/stitchpad.md.ready")|$(stat -f %m "$PAD/stitchpad.md.ready" 2>/dev/null || stat -c %Y "$PAD/stitchpad.md.ready")"

[ "$before" = "$after" ] || fail "read-only commands changed .state content or metadata"
[ "$ready_before" = "$ready_after" ] || fail "read-only commands replayed or changed a recovery artifact"
[ "$status" = "stopped" ] || fail "malformed watcher lock should report stopped"
[ "$roster" = "$who" ] || fail "roster/who compatibility changed"
[ -n "$read_window$human" ] || fail "read/human health unexpectedly empty"
case "$doctor_human" in *'# health fixture'*) fail "doctor followed a symlinked session file" ;; esac

# `read --new` is an explicit acknowledgement, not a passive diagnostic. It
# may advance exactly its own readref; a second read must observe that advance
# and must not rewrite the cursor again.
other_before_new="$(snapshot "$TMP/project" '.stitchpad/.state/readref.bob')"
read_new_first="$($SP read --new)"
[ "$(cat "$STATE/readref.bob")" = "$READREF_HEAD" ] || fail "read --new did not advance its own cursor"
printf '%s\n' "$read_new_first" | grep -Fq 'health cursor delta' || fail "read --new did not return the committed delta"
other_after_new="$(snapshot "$TMP/project" '.stitchpad/.state/readref.bob')"
[ "$other_before_new" = "$other_after_new" ] || fail "read --new changed state outside readref.bob"
state_after_first="$(snapshot "$TMP/project")"
read_new_second="$($SP read --new)"
[ "$read_new_second" = "(nothing new since your last read)" ] || fail "second read --new replayed an acknowledged delta"
state_after_second="$(snapshot "$TMP/project")"
[ "$state_after_first" = "$state_after_second" ] || fail "second read --new rewrote an unchanged cursor or other state"

python3 - "$local_json" "$deep_json" "$hostname_json" "$bad_url_json" \
  "$redirect_json" "$malformed_deep_json" "$slow_deep_json" "$slow_elapsed_ms" "$doctor_json" <<'PY'
import json, sys
local, deep, hostname, bad_url, redirect, malformed_deep, slow_deep = map(json.loads, sys.argv[1:8])
slow_elapsed_ms = int(sys.argv[8])
doctor = json.loads(sys.argv[9])
assert local["schema_version"] == 1 and local["mode"] == "local"
assert all(seat["deep_ocean"] is None for seat in local["seats"])
assert local["pad"]["watcher"]["status"] == "malformed_lock"
assert any(x.startswith("orphan_session:") for x in local["pad"]["issues"])
assert "session:leaky-session:symlink_refused" in local["pad"]["issues"]
seats = {seat["name"]: seat for seat in local["seats"]}
assert seats["alice"]["heartbeat"]["fresh"] is True
assert seats["alice"]["heartbeat"]["pid_alive"] is True
assert seats["alice"]["ticker"]["pid_alive"] is True
assert "duplicate_session_bindings:2" in seats["alice"]["issues"]
assert seats["bob"]["heartbeat"]["progress"] == "stale"
assert seats["bob"]["heartbeat"]["pid_alive"] is False
assert seats["bob"]["dnd"] is True
assert seats["bob"]["seen_cursor"]["value"] == 0
assert seats["bob"]["open_pending_ordinal"]["value"] == 1
assert seats["bob"]["recovery_pending_ordinal"]["value"] == 1
assert seats["bob"]["delivery"]["active"] is True
assert seats["bob"]["delivery"]["last_result"]["turn_id"] == "turn-1"
assert seats["bob"]["delivery"]["keeper_reservation"]["state"] == "acceptance_unknown"
assert "keeper_reservation:acceptance_unknown" in seats["bob"]["issues"]
assert any("never auto-retry" in item for item in seats["bob"]["repair"])
assert any(x.startswith("duplicate_target:") for x in seats["bob"]["issues"])
assert seats["carol"]["heartbeat"]["pid_parse"] == "malformed"
assert "heartbeat:malformed_pid" in seats["carol"]["issues"]
assert "heartbeat:malformed_time" in seats["carol"]["issues"]
assert seats["carol"]["delivery"]["keeper_reservation"]["parse"] == "malformed"
assert seats["frank"]["heartbeat"]["parse_error"].startswith("malformed_json:")
assert seats["frank"]["delivery"]["keeper_reservation"]["ordinal"] == 0
assert seats["frank"]["delivery"]["keeper_reservation"]["parse"] == "ok"
assert seats["frank"]["delivery"]["worker"]["parse"] == "malformed"
assert seats["frank"]["delivery"]["recoverable"] is False
assert "delivery_state:malformed_lines" in seats["frank"]["issues"]
assert seats["dave"]["delivery"]["pending"]["parse"] == "malformed"
assert seats["dave"]["delivery"]["keeper_reservation"]["parse"] == "malformed"
assert seats["dave"]["delivery"]["recoverable"] is False
assert "keeper_reservation:malformed" in seats["dave"]["issues"]
assert seats["dave"]["seen_cursor"]["parse"] == "malformed"
invalid = seats["bad/name"]
assert invalid["heartbeat"]["progress"] == "unavailable"
assert {"ticker","dnd","seen_cursor","delivery","deep_ocean"} <= set(invalid)
assert "missing_target" in seats["dave"]["issues"]
assert any(x.startswith("missing_adapter:") for x in seats["dave"]["issues"])
assert seats["erin"]["open_pending_ordinal"]["value"] == 9
deep_seats = {seat["name"]: seat for seat in deep["seats"]}
assert deep["mode"] == "deep"
assert deep_seats["bob"]["deep_ocean"]["status"] == "unavailable"
hostname_seats = {seat["name"]: seat for seat in hostname["seats"]}
assert hostname_seats["bob"]["deep_ocean"]["status"] == "refused_non_loopback"
bad_url_seats = {seat["name"]: seat for seat in bad_url["seats"]}
assert bad_url_seats["bob"]["deep_ocean"]["status"] == "malformed_url"
redirect_seats = {seat["name"]: seat for seat in redirect["seats"]}
assert redirect_seats["bob"]["deep_ocean"]["status"] == "unavailable"
assert redirect_seats["bob"]["deep_ocean"]["detail"] == "HTTPError"
malformed_deep_seats = {seat["name"]: seat for seat in malformed_deep["seats"]}
assert malformed_deep_seats["bob"]["deep_ocean"]["status"] == "malformed_response"
assert malformed_deep_seats["bob"]["deep_ocean"]["detail"] == "session_not_object"
slow_deep_seats = {seat["name"]: seat for seat in slow_deep["seats"]}
assert slow_deep_seats["bob"]["deep_ocean"]["status"] == "timeout"
assert slow_elapsed_ms <= 2500, slow_elapsed_ms
assert isinstance(doctor, list) and doctor
assert {"name","adapter","wake","target","status","health"} <= set(doctor[0])
PY

python3 - "$local_json" <<'PY'
import json, sys
def reject(value):
    raise ValueError(value)
json.loads(sys.argv[1], parse_constant=reject)
PY

# Broadcast indexing stays O(pad + seats), not O(broadcasts * seats).
python3 - "$ROOT/tool/bin/health.py" <<'PY'
import runpy, sys, time
sys.dont_write_bytecode = True
module = runpy.run_path(sys.argv[1])
names = [f"seat{i}" for i in range(128)]
start = time.monotonic()
raw = "## @sender\n\n@all ping\n" * 350_000  # 7,700,000 bytes / 7.343 MiB
assert len(raw.encode("utf-8")) == 7_700_000  # Keep the hostile fixture honest.
index = module["engagement_index"](raw, names)
opened = module["precompute_open"](index, names, {name: 0 for name in names})
elapsed = time.monotonic() - start
assert len(index["broadcasts"]) == 350_000
assert sum(len(seat["mentions"]) for seat in index["seats"].values()) == 0
assert all(value == 1 for value in opened["true"].values())
assert elapsed < 4.0, elapsed  # Independent gate measured 2.743s.
PY

# Keep health's delivery vocabulary aligned with every state emitted by the
# supervised-delivery writer. Terminal daemon outcomes are valid state, not
# corrupt input; only retry-safe durable states advertise recovery.
python3 - "$ROOT/tool/bin/health.py" <<'PY'
import runpy, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode = True
module = runpy.run_path(sys.argv[1])
parse_delivery = module["parse_delivery"]
severity = module["severity"]
states = {
    "accepted", "started", "busy", "error", "in_flight", "cancel_pending",
    "deferred_dnd", "acceptance_unknown", "completed", "tombstoned",
    "errored", "cancelled",
}
assert module["DELIVERY_STATES"] == states
recoverable = {"accepted", "busy", "error", "cancel_pending", "deferred_dnd"}
attention = {"cancel_pending", "deferred_dnd"}
errors = {"error", "errored", "cancelled", "acceptance_unknown"}
with tempfile.TemporaryDirectory() as root:
    state = Path(root)
    pending = "1|1|m-1|TASK-1|2026-08-02T12:00:00Z|ocean|push|session-1"
    for value in sorted(states | {"garbage_state"}):
        name = value
        (state / f"delivery.{name}.pending").write_text(pending, encoding="utf-8")
        (state / f"delivery.{name}.state").write_text(
            f"state={value}\ngeneration=1\nordinal=1\naccepted_at=2026-08-02T12:00:00Z\n",
            encoding="utf-8",
        )
        delivery, issues = parse_delivery(state, name)
        assert delivery is not None
        if value == "garbage_state":
            assert f"delivery_state:unknown:{value}" in issues
            assert delivery["recoverable"] is False
            continue
        assert not any(issue.startswith("delivery_state:unknown:") or "malformed" in issue
                       for issue in issues), (value, issues)
        assert delivery["recoverable"] is (value in recoverable), value
        if value in attention | errors:
            assert f"delivery_state:{value}" in issues
        if value in errors:
            assert severity(issues) == "error", (value, issues)
        elif value in attention:
            assert severity(issues) == "warn", (value, issues)
PY

# A read-only command on a pad with no runtime state must not create `.state`,
# sessions, pad git, or any watcher/heartbeat scaffolding as a side effect.
BARE="$TMP/bare/.stitchpad"
mkdir -p "$BARE"
cat > "$BARE/stitchpad.md" <<'EOF'
# bare fixture
```roster
```
EOF
(cd "$TMP/bare" && STITCHPAD_PAD_DIR="$BARE" "$SP" roster >/dev/null)
(cd "$TMP/bare" && STITCHPAD_PAD_DIR="$BARE" "$SP" status >/dev/null)
(cd "$TMP/bare" && STITCHPAD_PAD_DIR="$BARE" "$SP" read -n 5 >/dev/null)
bare_doctor="$(cd "$TMP/bare" && STITCHPAD_PAD_DIR="$BARE" "$SP" doctor --json)"
(cd "$TMP/bare" && STITCHPAD_PAD_DIR="$BARE" "$SP" health --json >/dev/null)
[ "$bare_doctor" = "[]" ] || fail "empty doctor JSON compatibility changed"
[ ! -e "$BARE/.state" ] || fail "read-only commands created .state on a bare pad"
[ ! -e "$BARE/stitchpad-git" ] || fail "read-only commands initialized pad git"

MISSING="$TMP/missing/.stitchpad"
mkdir -p "$MISSING"
missing_json="$(cd "$TMP/missing" && STITCHPAD_PAD_DIR="$MISSING" "$SP" health --json)"
python3 - "$missing_json" <<'PY'
import json, sys
snapshot = json.loads(sys.argv[1])
assert "pad_file:missing" in snapshot["pad"]["issues"]
assert snapshot["summary"]["pad_status"] == "error"
assert snapshot["summary"]["overall_status"] == "error"
PY

# Refuse a symlinked runtime-state root rather than traversing it. This keeps a
# malicious pad from using health as an arbitrary local-file reader.
LINKED="$TMP/linked/.stitchpad"
OUTSIDE="$TMP/outside-state"
mkdir -p "$LINKED" "$OUTSIDE"
cat > "$LINKED/stitchpad.md" <<'EOF'
# linked state fixture
```roster
probe | codex | pull | -
```
EOF
printf 'do-not-read' > "$OUTSIDE/alive.probe"
ln -s "$OUTSIDE" "$LINKED/.state"
linked_json="$(cd "$TMP/linked" && STITCHPAD_PAD_DIR="$LINKED" "$SP" health --json)"
linked_status="$(cd "$TMP/linked" && STITCHPAD_PAD_DIR="$LINKED" "$SP" status)"
linked_doctor="$(cd "$TMP/linked" && STITCHPAD_PAD_DIR="$LINKED" "$SP" doctor --json)"
[ "$linked_status" = "stopped" ] || fail "status followed a symlinked state root"
case "$linked_doctor" in *do-not-read*) fail "doctor followed a symlinked state root" ;; esac
python3 - "$linked_json" "$linked_doctor" <<'PY'
import json, sys
snapshot = json.loads(sys.argv[1])
assert isinstance(json.loads(sys.argv[2]), list)
assert snapshot["pad"]["state_access"] == "symlink_refused"
assert "state_dir:symlink_refused" in snapshot["pad"]["issues"]
seat = snapshot["seats"][0]
assert seat["heartbeat"]["parse_error"] == "unavailable:state_symlink_refused"
assert seat["repair"] == []
PY

processes_after="$(process_snapshot)"
[ "$processes_before" = "$processes_after" ] \
  || fail "health fixture changed watcher/heartbeat/health process baseline"

echo "PASS: health is structured, actionable, deep-optional, and zero-mutation"
