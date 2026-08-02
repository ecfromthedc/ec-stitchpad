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
cat > "$tmp/tool/bin/test-bin.sh" <<'EOF'
#!/usr/bin/env bash
printf 'bin\n' >> "$RUNNER_LOG"
EOF

runlog="$tmp/run.log"
out="$(env -u STITCHPAD_HOME -u PASTURE_HOME RUNNER_LOG="$runlog" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$tmp/tool/bin/stitchpad" test)"
contains "$out" 'Results: 4 passed, 0 failed, 4 total' || fail "all-pass summary is not truthful"
[ "$(wc -l < "$runlog" | tr -d ' ')" = "4" ] || fail "runner did not discover all four fixtures"
for name in plain wake conditional bin; do
  [ "$(grep -cx "$name" "$runlog")" = "1" ] || fail "$name fixture did not run exactly once"
done

: > "$runlog"
if out="$(env -u STITCHPAD_HOME -u PASTURE_HOME RUNNER_LOG="$runlog" RUNNER_FAIL=1 \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 "$tmp/tool/bin/stitchpad" test 2>&1)"; then
  fail "runner returned success with a failing fixture"
fi
contains "$out" 'Results: 3 passed, 1 failed, 4 total' || fail "failure summary is not truthful"
[ "$(wc -l < "$runlog" | tr -d ' ')" = "4" ] || fail "runner stopped before later fixtures after a failure"

echo "test runner ok"
