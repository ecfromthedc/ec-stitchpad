#!/usr/bin/env bash
# Regression test: a dispatch that did not happen must never look like one that did.
#
# The failure it exists for (2026-08-13). `ocean-heartbeat` is a symlink into a
# cargo build directory. A disk cleanup swept that directory, the symlink
# dangled, and every wake died instantly with "no such file or directory".
# Because the orchestrator called it as `... >/dev/null 2>&1 ; echo dispatched`,
# the error vanished and success was announced by a bare echo. THREE dispatches
# were reported sent while the whole crew was unreachable — and every seat then
# read `completed`, not because it had finished but because it was never
# reached. Those two states look identical from outside.
#
# Pinned here:
#   1. a dangling launcher symlink is caught BEFORE a brief is sent, and named
#   2. a launcher missing from PATH is caught
#   3. a wake whose response carries no session id is a FAILURE, not a success
#   4. a wake that does identify a session is reported as delivered
#   5. --verify-artifact fails when the seat produced nothing
#   6. --verify-artifact passes when the branch head actually moved
#
#   bash test/wake-preflight.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../tool/bin/stitchpad-wake"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-wake.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }
[ -x "$TOOL" ] || chmod +x "$TOOL" 2>/dev/null

echo "wake preflight — a dispatch that did not happen must not look like one that did"

mkdir -p "$WORK/bin" "$WORK/state"
echo "do the thing" > "$WORK/brief.txt"
echo "sess-1" > "$WORK/state/ocean-session.kimi"

# ─────────────────────────────────────── 1. the exact outage: dangling symlink
ln -s "$WORK/bin/gone-binary" "$WORK/bin/ocean-heartbeat"
out="$(OCEAN_HEARTBEAT_BIN="$WORK/bin/ocean-heartbeat" "$TOOL" --preflight-only 2>&1)"; rc=$?
if [ $rc -eq 4 ] && printf '%s' "$out" | grep -qi 'DANGLING SYMLINK'; then
  ok "a dangling launcher symlink is caught and named, before any brief is sent"
else
  bad "dangling symlink not caught (rc=$rc): $out"
fi
rm -f "$WORK/bin/ocean-heartbeat"

# ───────────────────────────────────────────────── 2. launcher absent entirely
out="$(OCEAN_HEARTBEAT_BIN="$WORK/bin/not-installed-at-all" "$TOOL" --preflight-only 2>&1)"; rc=$?
if [ $rc -eq 4 ]; then ok "a launcher missing from PATH is caught"
else bad "missing launcher not caught (rc=$rc)"; fi

# ──────────────────────── 3. a response with no session id is a FAILED dispatch
cat > "$WORK/bin/ocean-heartbeat" <<'EOF'
#!/usr/bin/env bash
# The dead-launcher shape: says something, identifies no session.
echo "no such file or directory" >&2
exit 1
EOF
chmod +x "$WORK/bin/ocean-heartbeat"
out="$(OCEAN_HEARTBEAT_BIN="$WORK/bin/ocean-heartbeat" "$TOOL" --seat kimi \
        --session-file "$WORK/state/ocean-session.kimi" --model m --cwd /tmp \
        --brief "$WORK/brief.txt" --state "$WORK/state" 2>&1)"; rc=$?
if [ $rc -eq 5 ] && printf '%s' "$out" | grep -qi 'WAKE NOT DELIVERED'; then
  ok "a wake with no session in its response is reported as NOT delivered"
else
  bad "phantom dispatch reported as success (rc=$rc): $out"
fi
if printf '%s' "$out" | grep -qi 'no such file'; then
  ok "the launcher's own words are surfaced, not swallowed"
else
  bad "launcher output was discarded — the original sin of this outage"
fi

# ───────────────────────────────────────────────── 4. a real wake is delivered
cat > "$WORK/bin/ocean-heartbeat" <<'EOF'
#!/usr/bin/env bash
echo 'wake -> /v1/agent/turns (session 3f2a9c11-4b7d-4e2a-9f10-8c7b6d5e4f30)'
EOF
chmod +x "$WORK/bin/ocean-heartbeat"
OCEAN_HEARTBEAT_BIN="$WORK/bin/ocean-heartbeat" "$TOOL" --seat kimi \
  --session-file "$WORK/state/ocean-session.kimi" --model m --cwd /tmp \
  --brief "$WORK/brief.txt" --state "$WORK/state" >/dev/null 2>&1
[ $? -eq 0 ] && ok "a wake that identifies a session is reported as delivered" \
             || bad "a genuine wake was misreported as failed"

# ──────────────────── 5/6. artifact proof: delivery is not the same as WORK
repo="$WORK/repo"; mkdir -p "$repo"
git -C "$repo" init -q 2>/dev/null
git -C "$repo" config user.email t@t.test; git -C "$repo" config user.name t
echo one > "$repo/f"; git -C "$repo" add f; git -C "$repo" commit -qm one
branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"

OCEAN_HEARTBEAT_BIN="$WORK/bin/ocean-heartbeat" "$TOOL" --seat kimi \
  --session-file "$WORK/state/ocean-session.kimi" --model m --cwd /tmp \
  --brief "$WORK/brief.txt" --state "$WORK/state" \
  --expect-artifact --repo "$repo" --branch "$branch" >/dev/null 2>&1

out="$(OCEAN_HEARTBEAT_BIN="$WORK/bin/ocean-heartbeat" "$TOOL" --seat kimi \
        --verify-artifact --repo "$repo" --branch "$branch" --state "$WORK/state" 2>&1)"; rc=$?
if [ $rc -eq 6 ] && printf '%s' "$out" | grep -qi 'PRODUCED NOTHING'; then
  ok "a seat that produced nothing is called out, however it reported itself"
else
  bad "silent no-work not detected (rc=$rc): $out"
fi

echo two > "$repo/f"; git -C "$repo" add f; git -C "$repo" commit -qm two
out="$(OCEAN_HEARTBEAT_BIN="$WORK/bin/ocean-heartbeat" "$TOOL" --seat kimi \
        --verify-artifact --repo "$repo" --branch "$branch" --state "$WORK/state" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qi 'artifact confirmed'; then
  ok "a seat that moved the branch head is confirmed as having worked"
else
  bad "real work not recognised (rc=$rc): $out"
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
