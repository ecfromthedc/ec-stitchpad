#!/usr/bin/env bash
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
# mutant-harness-restores-the-tree-gate.sh — a red-proof harness must never
# leave the working tree mutated, and must never exit 0 if it cannot restore.
#
# Found live: after a suite run, tool/tui-rs/src/widgets/tasks.rs carried
#   for s in [pad_str] { // MUT10: tasks.md IGNORED
# task26-mutant.sh used a FIXED /tmp backup path, `rm -f`'d it in cleanup, and
# restored with `cp ... 2>/dev/null || true`. Two runs sharing that path is all
# it takes: the first run's cleanup deletes the backup, the second's restore
# finds nothing, swallows the failure, and the tree keeps the mutation. Anyone
# running the TUI afterwards silently loses tasks.md, and a blanket `git add -A`
# would commit it. A harness that can strand a mutant is the worst place for
# this bug — every red-proof this project trusts runs through one.
#
# Proves (by reading the harness source; these are properties of the script,
# not of a particular run):
#   H1: the backup path is per-run (mktemp), not a fixed shared filename
#   H2: no restore swallows its own failure with `2>/dev/null || true`
#   H3: the restore VERIFIES the mutant marker is gone afterwards
#   H4: INT and TERM are trapped, not only EXIT — a killed run is exactly when
#       a mutant gets stranded
#   H5: a failed restore exits NONZERO
#   H6: the tree is clean right now (no stranded MUT10 in the checkout)
#
set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
H="$HERE/task26-mutant.sh"
SRC="$ROOT/tool/tui-rs/src/widgets/tasks.rs"
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

echo "=== mutant-harness-restores-the-tree-gate ==="
echo ""
[ -f "$H" ] || { echo "harness not found: $H"; exit 1; }

grep -q 'BACKUP="\$(mktemp' "$H" \
  && ok "H1: backup path is per-run (mktemp)" \
  || bad "H1: backup path is not mktemp — a fixed path is shared between concurrent runs"

if grep -q 'cp "\$BACKUP" "\$SRC" 2>/dev/null || true' "$H"; then
  bad "H2: a restore still swallows its own failure (2>/dev/null || true)"
else
  ok "H2: no restore swallows its own failure"
fi

grep -q 'MUT10: tasks.md IGNORED' "$H" && grep -q 'STILL CARRIES THE MUT10 MUTANT' "$H" \
  && ok "H3: the restore verifies the mutant marker is gone" \
  || bad "H3: the restore does not verify the mutant is actually gone"

grep -q "trap 'exit 130' INT" "$H" && grep -q "trap 'exit 143' TERM" "$H" \
  && ok "H4: INT and TERM are trapped, not only EXIT" \
  || bad "H4: only EXIT is trapped — a killed run strands the mutant"

grep -q 'THE WORKING TREE IS LEFT MUTATED' "$H" && grep -qE '^\s+exit 1$' "$H" \
  && ok "H5: a failed restore exits nonzero and says the tree is mutated" \
  || bad "H5: a failed restore does not fail loudly"

if [ -f "$SRC" ] && grep -q 'MUT10: tasks.md IGNORED' "$SRC"; then
  bad "H6: the checkout RIGHT NOW carries a stranded MUT10 mutant in $SRC"
else
  ok "H6: no stranded mutant in the checkout"
fi

echo ""
printf "%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
