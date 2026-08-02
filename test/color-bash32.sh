#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
TMP="$(mktemp -d /tmp/stitchpad-color-bash32.XXXXXX)"
cleanup() {
  STITCHPAD_PAD_DIR="$TMP/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/home"
export HOME="$TMP/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
cd "$TMP"
"$SP" init --name color-bash32 >/dev/null
"$SP" join dale codex pull - >/dev/null
"$SP" join custom-seat codex pull - >/dev/null

[ "$(/bin/bash "$SP" color dale)" = '#00d000' ] \
  || fail "Apple Bash 3.2-compatible override lookup failed"
all="$(/bin/bash "$SP" color --all)"
printf '%s\n' "$all" | grep -qx 'dale #00d000' \
  || fail "--all omitted the fixed override"
custom="$(printf '%s\n' "$all" | awk '$1 == "custom-seat" {print $2}')"
case "$custom" in '#'* ) ;; *) fail "--all omitted the hashed roster color" ;; esac
[ "$(/bin/bash "$SP" color missing-seat)" = '#808080' ] \
  || fail "unknown roster seat did not use the fallback color"

# `color` is a read-only surface query and must remain on the heartbeat
# autostart skip list even when the ambient policy enables autostart.
STITCHPAD_HEARTBEAT_AUTOSTART=1 STITCHPAD_NAME=dale /bin/bash "$SP" color dale >/dev/null
[ ! -d "$TMP/.stitchpad/.state/heartbeat.dale.lock" ] \
  || fail "color query unexpectedly started a heartbeat ticker"

echo "color bash32 ok"
