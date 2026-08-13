#!/usr/bin/env bash
# The relay must be opt-in by directory, never an accidental full-home mirror.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HTTP="$ROOT/tool/relay/bridge.sh"
WS="$ROOT/tool/relay/bridge-ws.mjs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HOME_DIR="$WORK/home"
DEFAULT_ROOT="$HOME_DIR/Stitchpad Workspaces"
CUSTOM_ROOT="$WORK/custom workspace"
EXPLICIT_ROOT="$WORK/explicit workspace"
fail=0

check_equal() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  PASS %s\n' "$name"
  else
    printf '  FAIL %s — expected %q, got %q\n' "$name" "$expected" "$actual" >&2
    fail=1
  fi
}

http_roots() { HOME="$HOME_DIR" STITCHPAD_BRIDGE_PRINT_ROOTS=1 bash "$HTTP" "$@"; }
ws_roots() { HOME="$HOME_DIR" STITCHPAD_BRIDGE_PRINT_ROOTS=1 node "$WS" "$@"; }

echo '=== bridge workspace scope ==='
check_equal 'HTTP bridge defaults to the workspace root' "$(http_roots)" "$DEFAULT_ROOT"
check_equal 'WebSocket bridge defaults to the workspace root' "$(ws_roots)" "$DEFAULT_ROOT"
check_equal 'HTTP bridge honors configured workspace root' "$(HOME="$HOME_DIR" STITCHPAD_WORKSPACE_ROOT="$CUSTOM_ROOT" STITCHPAD_BRIDGE_PRINT_ROOTS=1 bash "$HTTP")" "$CUSTOM_ROOT"
check_equal 'WebSocket bridge honors configured workspace root' "$(HOME="$HOME_DIR" STITCHPAD_WORKSPACE_ROOT="$CUSTOM_ROOT" STITCHPAD_BRIDGE_PRINT_ROOTS=1 node "$WS")" "$CUSTOM_ROOT"
check_equal 'HTTP bridge preserves explicit migration root' "$(http_roots "$EXPLICIT_ROOT")" "$EXPLICIT_ROOT"
check_equal 'WebSocket bridge preserves explicit migration root' "$(ws_roots "$EXPLICIT_ROOT")" "$EXPLICIT_ROOT"

if ! grep -Fq '<key>STITCHPAD_WORKSPACE_ROOT</key>' "$ROOT/tool/relay/org.stitchpad.bridge.plist.template"; then
  echo '  FAIL launchd template does not pin a workspace root' >&2
  fail=1
else
  echo '  PASS launchd template pins a workspace root'
fi

[ "$fail" -eq 0 ]
echo 'bridge workspace scope ok'
