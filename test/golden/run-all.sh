#!/usr/bin/env bash
# run-all.sh — thin runner for the characterization golden harness.
#
# Iterates every .md/.tsv pair under test/golden/ and diffs them via
# harness.sh diff.  One line per corpus, non-zero exit on any mismatch.
#
# Usage:
#   test/golden/run-all.sh
#   STITCHPAD_HOME=./tool ./test/golden/run-all.sh
#   env -i STITCHPAD_HOME=... PATH=... /bin/bash test/golden/run-all.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$SCRIPT_DIR/harness.sh"
STITCHPAD_HOME="${STITCHPAD_HOME:-$SCRIPT_DIR/../../tool}"
export STITCHPAD_HOME

failed=0 total=0

for dir in "$SCRIPT_DIR"/synthetic "$SCRIPT_DIR"/live; do
  [ -d "$dir" ] || continue
  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    tsv="${md%.md}.tsv"
    if [ ! -f "$tsv" ]; then
      echo "SKIP $(basename "$md") — no golden .tsv"
      continue
    fi
    total=$((total + 1))
    label="$(basename "$md")"
    out="$("$HARNESS" diff "$md" "$tsv" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "OK   $label"
    else
      echo "FAIL $label"
      printf '%s\n' "$out" | sed 's/^/  /'
      failed=$((failed + 1))
    fi
  done
done

echo ""
echo "$total checked, $failed failed"
exit "$failed"
