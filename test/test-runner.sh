#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d /tmp/stitchpad-test-runner.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

mkdir -p "$tmp/tool/bin" "$tmp/test"
cp "$ROOT/tool/bin/stitchpad" "$ROOT/tool/bin/lib.sh" "$tmp/tool/bin/"

cat > "$tmp/test/plain.sh" <<'EOF'
#!/usr/bin/env bash
printf 'plain\n' >> "$RUNNER_LOG"
EOF
cat > "$tmp/test/wake-regression.sh" <<'EOF'
#!/usr/bin/env bash
printf 'wake\n' >> "$RUNNER_LOG"
EOF
cat > "$tmp/test/conditional-fail.sh" <<'EOF'
#!/usr/bin/env bash
printf 'conditional\n' >> "$RUNNER_LOG"
[ "${RUNNER_FAIL:-0}" = "0" ]
EOF
cat > "$tmp/test/leaky.sh" <<'EOF'
#!/usr/bin/env bash
printf 'leak\n' >> "$RUNNER_LOG"
if [ "${RUNNER_LEAK:-0}" = "1" ]; then
  bash "$STITCHPAD_HOME/bin/watch.sh" &
  printf '%s' "$!" > "$RUNNER_LEAK_PID_FILE"
  # Keep the fixture parent alive long enough for the runner's exact descendant
  # registry to observe the child before this shell exits and it reparents.
  sleep 0.2
fi
EOF
cat > "$tmp/tool/bin/test-bin.sh" <<'EOF'
#!/usr/bin/env bash
printf 'bin\n' >> "$RUNNER_LOG"
EOF
cat > "$tmp/tool/bin/watch.sh" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF

runlog="$tmp/run.log"
out="$(env -u STITCHPAD_HOME -u PASTURE_HOME RUNNER_LOG="$runlog" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$tmp/tool/bin/stitchpad" test)"
contains "$out" 'Results: 5 passed, 0 failed, 5 total' || fail "all-pass summary is not truthful"
[ "$(wc -l < "$runlog" | tr -d ' ')" = "5" ] || fail "runner did not discover all five fixtures"
for name in plain wake conditional leak bin; do
  [ "$(grep -cx "$name" "$runlog")" = "1" ] || fail "$name fixture did not run exactly once"
done

: > "$runlog"
if out="$(env -u STITCHPAD_HOME -u PASTURE_HOME RUNNER_LOG="$runlog" RUNNER_FAIL=1 \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$tmp/tool/bin/stitchpad" test 2>&1)"; then
  fail "runner returned success with a failing fixture"
fi
contains "$out" 'Results: 4 passed, 1 failed, 5 total' || fail "failure summary is not truthful"
[ "$(wc -l < "$runlog" | tr -d ' ')" = "5" ] || fail "runner stopped before later fixtures after a failure"

# A passing fixture that leaves a child behind is itself a failure.  The runner
# must identify the exact PID/start/command it observed, terminate only that
# child, continue later fixtures, and report the residue honestly.
: > "$runlog"
leak_pid_file="$tmp/leak.pid"
if out="$(env -u STITCHPAD_HOME -u PASTURE_HOME RUNNER_LOG="$runlog" \
  RUNNER_LEAK=1 RUNNER_LEAK_PID_FILE="$leak_pid_file" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$tmp/tool/bin/stitchpad" test 2>&1)"; then
  fail "runner returned success with fixture process residue"
fi
contains "$out" 'fixture process residue:' || fail "runner did not diagnose fixture process residue"
contains "$out" 'Results: 4 passed, 1 failed, 5 total' || fail "residue summary is not truthful"
[ "$(wc -l < "$runlog" | tr -d ' ')" = "5" ] || fail "runner stopped after process residue"
leak_pid="$(cat "$leak_pid_file")"
kill -0 "$leak_pid" 2>/dev/null && fail "runner left the registered fixture child alive" || true

echo "test runner ok"
