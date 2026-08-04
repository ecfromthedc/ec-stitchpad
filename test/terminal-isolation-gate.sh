#!/usr/bin/env bash
# terminal-isolation-gate.sh — GAP 2 (FIXTURE-BUG): terminal claims must not
# leak between fixtures. Two consecutive pad fixtures must be able to join
# different names and post without seeing each other's terminal bindings.
#
# Defect: sp_this_surface() falls back to inherited CLAUDE_CODE_SESSION_ID or
# STITCHPAD_SESSION — a REAL session id. Two fixtures sharing the same HOME
# (e.g. the operator's real home, or a shared temp home) collide when the first
# creates a terminal claim and the second join sees it: "REFUSED — terminal
# <id> is live as @alice".
#
# Fix: STITCHPAD_TERMINAL_NAMESPACE env var namespaces the surface id so
# fixtures get distinct terminal claim files even with shared HOME.
#
# Mutant proof (G2): unset STITCHPAD_TERMINAL_NAMESPACE → gate goes RED.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  \033[0;31mFAIL\033[0m %s: %s\n' "$1" "${2:-}" >&2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-term-iso-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true

mkdir -p "$TMP/home" "$TMP/pad-a" "$TMP/pad-b"

# ===========================================================================
# G1: ISOLATED FIXTURES — each with unique namespace, shared HOME
# ===========================================================================
echo ""
echo "=== G1: two fixtures, namespaced, shared HOME ==="
echo ""

# Pad A
(
  export HOME="$TMP/home"
  export STITCHPAD_TERMINAL_NAMESPACE="fixture-a-$$"
  cd "$TMP/pad-a"
  "$SP" init --name gate-a >/dev/null 2>&1
  STITCHPAD_NAME=alpha "$SP" join alpha codex pull - > "$TMP/pad-a-out.txt" 2>&1
  STITCHPAD_NAME=alpha "$SP" say "hello from A" >> "$TMP/pad-a-out.txt" 2>&1
)
_rc_a=$?

# Pad B
(
  export HOME="$TMP/home"
  export STITCHPAD_TERMINAL_NAMESPACE="fixture-b-$$"
  cd "$TMP/pad-b"
  "$SP" init --name gate-b >/dev/null 2>&1
  STITCHPAD_NAME=bravo "$SP" join bravo codex pull - > "$TMP/pad-b-out.txt" 2>&1
  STITCHPAD_NAME=bravo "$SP" say "hello from B" >> "$TMP/pad-b-out.txt" 2>&1
)
_rc_b=$?

if [ "$_rc_a" -eq 0 ]; then
  ok "G1a: fixture A (namespaced) join+say succeeded"
else
  bad "G1a: fixture A failed" "$(grep -i 'REFUSED\|fatal\|error' "$TMP/pad-a-out.txt" 2>/dev/null || echo rc=$_rc_a)"
fi

if [ "$_rc_b" -eq 0 ]; then
  ok "G1b: fixture B (namespaced) join+say succeeded"
else
  bad "G1b: fixture B saw fixture A's claim" "$(grep -i 'REFUSED\|fatal\|error' "$TMP/pad-b-out.txt" 2>/dev/null || echo rc=$_rc_b)"
fi

# Verify terminal claims exist with namespace prefixes
_ns_surfaces="$(find "$TMP/home/.stitchpad-terminals" -type f -not -name '.mutex.*' -not -name '.byname.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${_ns_surfaces:-0}" -eq 2 ]; then
  ok "G1c: 2 namespaced surface claim files (one per fixture)"
else
  bad "G1c: expected 2 surface files, got ${_ns_surfaces:-0}" \
    "$(ls "$TMP/home/.stitchpad-terminals/" 2>/dev/null)"
fi

# ===========================================================================
# G2: MUTANT — no namespace, shared HOME → REFUSED
# ===========================================================================
echo ""
echo "=== G2: mutant — no namespace, shared HOME → REFUSED (RED) ==="
echo ""

# Clean up and create fresh pads
rm -rf "$TMP/pad-c" "$TMP/pad-d" "$TMP/home-cd"
mkdir -p "$TMP/pad-c" "$TMP/pad-d" "$TMP/home-cd"

echo "--- MUTATION: unset STITCHPAD_TERMINAL_NAMESPACE ---"
echo "Both fixtures share HOME=$TMP/home-cd"
echo "Both inherit CLAUDE_CODE_SESSION_ID=$(sp_this_surface 2>/dev/null || echo '<empty>')"
echo "Expected: fixture C creates claim → fixture D REFUSED ---"

# Pad C (no namespace)
(
  export HOME="$TMP/home-cd"
  unset STITCHPAD_TERMINAL_NAMESPACE 2>/dev/null || true
  cd "$TMP/pad-c"
  "$SP" init --name gate-c >/dev/null 2>&1
  STITCHPAD_NAME=charlie "$SP" join charlie codex pull - > "$TMP/pad-c-out.txt" 2>&1
  STITCHPAD_NAME=charlie "$SP" say "claimed" >> "$TMP/pad-c-out.txt" 2>&1
)
_rc_c=$?
echo "Fixture C (charlie): rc=$_rc_c"

# Pad D (no namespace, different pad, same HOME)
(
  export HOME="$TMP/home-cd"
  unset STITCHPAD_TERMINAL_NAMESPACE 2>/dev/null || true
  cd "$TMP/pad-d"
  "$SP" init --name gate-d >/dev/null 2>&1
  STITCHPAD_NAME=delta "$SP" join delta codex pull -
) > "$TMP/pad-d-out.txt" 2>&1
_rc_d=$?
echo "Fixture D (delta):   rc=$_rc_d"
echo "Output: $(cat "$TMP/pad-d-out.txt")"

# G2a: Fixture D must be REFUSED
if [ "$_rc_d" -ne 0 ]; then
  ok "G2a: fixture D (no namespace) REFUSED (rc=$_rc_d)"
else
  bad "G2a: fixture D should have been REFUSED" "rc=$_rc_d output=$(cat "$TMP/pad-d-out.txt")"
fi

# G2b: Diagnostic must name the terminal
if grep -qi 'REFUSED.*terminal.*live' "$TMP/pad-d-out.txt" 2>/dev/null; then
  ok "G2b: REFUSED diagnostic names the live terminal"
else
  bad "G2b: no REFUSED diagnostic" "$(cat "$TMP/pad-d-out.txt")"
fi

# ===========================================================================
# G3: fix applied — namespace lets fixture D succeed
# ===========================================================================
echo ""
echo "=== G3: fix — namespaced fixture D succeeds ==="
echo ""

rm -rf "$TMP/pad-e" "$TMP/home-ce"
mkdir -p "$TMP/pad-e" "$TMP/home-ce"

# Pad C2 (no namespace, creates the claim)
(
  export HOME="$TMP/home-ce"
  unset STITCHPAD_TERMINAL_NAMESPACE 2>/dev/null || true
  cd "$TMP/pad-c"
  # reuse pad-c but with new HOME
)
# Actually need fresh pad-c
(
  export HOME="$TMP/home-ce"
  unset STITCHPAD_TERMINAL_NAMESPACE 2>/dev/null || true
  cd "$TMP/pad-c"
  rm -rf .stitchpad .pasture 2>/dev/null || true
  "$SP" init --name gate-c2 >/dev/null 2>&1
  STITCHPAD_NAME=charlie "$SP" join charlie codex pull - >/dev/null 2>&1
)

# Pad E (WITH namespace, same HOME as C2)
(
  export HOME="$TMP/home-ce"
  export STITCHPAD_TERMINAL_NAMESPACE="fixture-e-$$"
  cd "$TMP/pad-e"
  "$SP" init --name gate-e >/dev/null 2>&1
  STITCHPAD_NAME=echo "$SP" join echo codex pull -
) > "$TMP/pad-e-out.txt" 2>&1
_rc_e=$?
echo "Fixture E (echo, namespaced): rc=$_rc_e"

if [ "$_rc_e" -eq 0 ]; then
  ok "G3a: namespaced fixture E succeeds (override works)"
else
  bad "G3a: namespaced fixture E still refused" "$(cat "$TMP/pad-e-out.txt")"
fi

if ! grep -qi 'REFUSED' "$TMP/pad-e-out.txt" 2>/dev/null; then
  ok "G3b: no REFUSED when namespaced"
else
  bad "G3b: REFUSED despite namespace"
fi

# ===========================================================================
echo ""
cd "$ROOT"

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll terminal-isolation gates PASSED.\n'; exit 0; }
printf '\nSome terminal-isolation gates FAILED.\n'; exit 1
