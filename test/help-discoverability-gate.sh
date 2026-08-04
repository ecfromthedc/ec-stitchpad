#!/usr/bin/env bash
# help-discoverability-gate.sh — ensure every dispatchable command appears
# in `stitchpad help` output, and every known help doc line has a handler.
#
# This gate FAILS when a user-facing command in the primary dispatch table
# is missing from help — the exact bug that hid the entire `task` family
# and `leave` from new teammates.
#
# Mutant-provable: remove a command from the help header → gate goes RED.
# Remove a handler from the dispatch table → gate goes RED (stale help).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

# ── Dispatch table: every command label from the primary case statement ──
dispatch_labels() {
  sed -n '/^case "\$cmd" in$/,/^esac$/{s/^  \([a-z0-9_.|-]*\)).*/\1/p;}' "$SP"
}

# ── Help doc commands: first word after "stitchpad" in each help header line ──
help_doc_commands() {
  awk 'NR>=2 { if (/^#/) print; else exit }' "$SP" \
    | grep -oE 'stitchpad [a-z][a-z0-9._|-]*' \
    | awk '{print $2}' \
    | tr '|' '\n' \
    | sort -u
}

# ── Internal commands: implementation details, not user-facing ─────────────
is_internal() {
  case "$1" in
    -h|--help|help|instructions|prompt-context|restore-roster|doctor|hook|\
    claim-hook|bind-session|migration-check|ensure-watcher|claims|release|\
    claim|send|test|bridge|clear|color|heartbeat|dm|daemon|authority) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Test 1: every user-facing dispatch command appears in help ──────────────
DISPATCH="$(dispatch_labels)"
HELP_DOC="$(help_doc_commands)"

for entry in $DISPATCH; do
  for cmd in $(echo "$entry" | tr '|' '\n'); do
    is_internal "$cmd" && continue
    if echo "$HELP_DOC" | grep -Fqx "$cmd"; then
      ok "dispatch '$cmd' in help"
    else
      bad "dispatch '$cmd' MISSING from help"
    fi
  done
done

# ── Test 2: every help doc command has a dispatch handler ──────────────────
for cmd in $HELP_DOC; do
  if echo "$DISPATCH" | tr '|' '\n' | grep -Fqx "$cmd"; then
    ok "help '$cmd' has dispatch handler"
  else
    is_internal "$cmd" && { ok "help '$cmd' (internal, doc is reference)"; continue; }
    bad "help '$cmd' has NO dispatch handler (stale doc)"
  fi
done

# ── Test 3: 'stitchpad help' mentions task and leave ────────────────────────
HELP_OUT="$("$SP" help 2>&1 || true)"
echo "$HELP_OUT" | grep -q 'task new|list|show|move|edit|migrate' \
  && ok "help mentions full task family" \
  || bad "help MISSING task family"
echo "$HELP_OUT" | grep -q 'stitchpad leave' \
  && ok "help mentions leave" \
  || bad "help MISSING leave"

# ── Verdict ────────────────────────────────────────────────────────────────
echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
fi
echo "All $pass help-discoverability gates PASSED"
exit 0
