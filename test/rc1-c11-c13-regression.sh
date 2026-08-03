#!/usr/bin/env bash
# rc1-c11-c13-regression.sh — rc1 security lane fixes:
#   C11  session-start-hook feeds the unvalidated sticky autoname into
#        `heartbeat start` — auto-recurring F1-bomb entry. Fixed: handle shape
#        gate, fail closed (exit 0, loud stderr), before any use.
#   C12  herdr.sh builds the terminals-registry path from the roster target —
#        a no-`@@` target with `../` traversed to an arbitrary file read.
#        Fixed: terminal component must be a plain filename, else refuse wake.
#   C13  `search -n` SQL injection at a clean statement boundary dropped the
#        archive `messages` table (irrecoverable — sqlite not in pad git).
#        Fixed: -n must be numeric, validated before both sections.
set -euo pipefail

unset HERDR_PANE_ID HERDR_SESSION HERDR_WINDOW 2>/dev/null || true
export STITCHPAD_HEARTBEAT_AUTOSTART=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_HOME="$ROOT/tool"

passed=0; failed=0
ok()  { passed=$((passed+1)); printf '  PASS %s\n' "$1"; }
bad() { failed=$((failed+1)); printf '  FAIL %s\n' "$1"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rc1-cfix.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"

echo "=== rc1 C11/C12/C13 regression ==="

# ── C13: search -n SQLi ──────────────────────────────────────────────────────
mkdir -p "$tmp/proj"; ( cd "$tmp/proj" && git init -q )
(
  cd "$tmp/proj"
  "$SP" init --name c13 >/dev/null 2>&1
  "$SP" join alice claude >/dev/null 2>&1
  STITCHPAD_NAME=alice "$SP" say "hello archive world" >/dev/null 2>&1
  STITCHPAD_NAME=alice "$SP" say "second hello message" >/dev/null 2>&1
  "$SP" compact >/dev/null 2>&1
)
db="$tmp/proj/.stitchpad/.state/archive.sqlite"
[ -f "$db" ] || { bad "c13-fixture-archive-exists"; db=""; }
rc=0
( cd "$tmp/proj" && "$SP" search hello -n '1;DROP TABLE messages;--' >/dev/null 2>&1 ) || rc=1
if [ "$rc" -eq 1 ] && [ -n "$db" ] \
   && /usr/bin/sqlite3 "$db" '.tables' 2>/dev/null | grep -q messages; then
  ok "c13-sqli-refused-messages-table-intact"
else
  bad "c13-sqli-refused-messages-table-intact"
fi
sout="$(cd "$tmp/proj" && "$SP" search hello -n 5 2>/dev/null)"
if printf '%s' "$sout" | grep -qi 'hello'; then
  ok "c13-legit-search-still-works"
else
  bad "c13-legit-search-still-works"
fi

# ── C11: session-start-hook shape gate ───────────────────────────────────────
LONG=$(printf 'a%.0s' $(seq 1 241))
pad="$tmp/proj/.stitchpad"
printf '%s' "$LONG" > "$pad/.state/autoname.claude"
out="$(printf '{"cwd":"%s","session_id":"s-new"}' "$tmp/proj" \
  | bash "$ROOT/tool/adapters/session-start-hook.sh" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'shape gate'; then
  ok "c11-poisoned-autoname-refused-loudly-rc0"
else
  bad "c11-poisoned-autoname-refused-loudly-rc0 (rc=$rc out=$out)"
fi
if [ ! -e "$pad/.state/alive.$LONG" ] && ! pgrep -f "heartbeat.*$LONG" >/dev/null 2>&1; then
  ok "c11-no-heartbeat-spawned-for-poisoned-name"
else
  bad "c11-no-heartbeat-spawned-for-poisoned-name"
fi
# Control: a valid handle passes the gate (exits later at the bin-resolution
# check under the isolated HOME — crucially, no REFUSED line).
printf 'alice' > "$pad/.state/autoname.claude"
out="$(printf '{"cwd":"%s","session_id":"s-new"}' "$tmp/proj" \
  | bash "$ROOT/tool/adapters/session-start-hook.sh" 2>&1)" || true
if printf '%s' "$out" | grep -q 'shape gate'; then
  bad "c11-valid-handle-not-refused"
else
  ok "c11-valid-handle-not-refused"
fi

# ── C12: herdr.sh lockf traversal ────────────────────────────────────────────
mkdir -p "$HOME/.ssh" "$tmp/bin"
printf 'WRONGPAD|mallory|9999999999\n' > "$HOME/.ssh/config"   # would parse as a live foreign claim IF read
cat > "$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/herdr"
out="$(PATH="$tmp/bin:$PATH" SP_PAD_DIR="$pad" SP_TARGET='../../.ssh/config' \
  bash "$ROOT/tool/adapters/herdr.sh" mention alice "$pad/stitchpad.md" /dev/null 2>&1)" && hrc=0 || hrc=$?
log="$pad/.state/adapter.herdr.log"
if [ "$hrc" -eq 1 ] && grep -q 'CROSS-PAD CHECK REFUSED' "$log" 2>/dev/null \
   && ! grep -q 'CROSS-PAD BLOCKED' "$log" 2>/dev/null; then
  ok "c12-traversal-target-refused-never-read"
else
  bad "c12-traversal-target-refused-never-read (hrc=$hrc)"
fi
# Control: a normal UUID component proceeds past the gate (fails later at
# agent-get against the stub — the absence of REFUSED is the signal).
PATH="$tmp/bin:$PATH" SP_PAD_DIR="$pad" SP_TARGET='1d3f1f1b-7933-45d7-8871-b9a89ff9860a' \
  bash "$ROOT/tool/adapters/herdr.sh" mention alice "$pad/stitchpad.md" /dev/null >/dev/null 2>&1 || true
if grep -q 'CROSS-PAD CHECK REFUSED.*1d3f1f1b' "$log" 2>/dev/null; then
  bad "c12-legit-uuid-target-not-refused"
else
  ok "c12-legit-uuid-target-not-refused"
fi

echo
echo "Passed:  $passed"
echo "Failed:  $failed"
[ "$failed" -eq 0 ] && echo "All gates PASSED."
exit "$failed"
