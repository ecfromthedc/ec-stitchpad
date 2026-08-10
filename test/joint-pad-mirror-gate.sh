#!/usr/bin/env bash
# Joint-pad mirror gate — pins the two properties that make teammate pad
# mirroring safe to rely on:
#
#   1. bridge.sh reconcile state is keyed PER RELAY. The original single
#      `bridge-pads.prev` was shared by every bridge instance on the machine,
#      so the moment a second (teammate-scoped) bridge ran, each instance read
#      the other's pad list and issued spurious DELETE /pads calls against its
#      own relay every cycle — a mirror that slowly unregisters the owner's
#      pads is worse than no mirror.
#   2. `stitchpad bridge mirror` is scoped and truthful: --print emits a plist
#      whose scan root is exactly the ONE project passed (never $HOME), whose
#      label is derived from the relay, and whose env carries the given relay
#      and token; it refuses a project with no pad, refuses to run tokenless,
#      and --remove on a mirror that does not exist fails loudly instead of
#      reporting success for a teardown that never happened.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
BR="$ROOT/tool/relay/bridge.sh"
FIXTURE_DIR="$(mktemp -d)"
cleanup() { rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT

fail=0
pass() { printf '  PASS %s\n' "$1"; }
flunk() { printf '  FAIL %s\n' "$1"; fail=1; }

# ── 1. per-relay reconcile state ────────────────────────────────────
prev_a="$(STITCHPAD_RELAY=https://alpha.example.org STITCHPAD_TOKEN=x \
  BRIDGE_PRINT_PREV_PATH=1 bash "$BR")"
prev_b="$(STITCHPAD_RELAY=https://beta.example.org STITCHPAD_TOKEN=x \
  BRIDGE_PRINT_PREV_PATH=1 bash "$BR")"
prev_a2="$(STITCHPAD_RELAY=https://alpha.example.org STITCHPAD_TOKEN=x \
  BRIDGE_PRINT_PREV_PATH=1 bash "$BR")"

if [ -n "$prev_a" ] && [ "$prev_a" != "$prev_b" ]; then
  pass "different relays resolve different prev-list files"
else
  flunk "different relays resolve different prev-list files (a='$prev_a' b='$prev_b')"
fi
if [ "$prev_a" = "$prev_a2" ]; then
  pass "same relay resolves a stable prev-list file"
else
  flunk "same relay resolves a stable prev-list file ('$prev_a' vs '$prev_a2')"
fi
case "$prev_a" in
  */bridge-pads.prev) flunk "prev path must not be the legacy shared bridge-pads.prev" ;;
  *) pass "prev path is not the legacy shared bridge-pads.prev" ;;
esac

# ── 2. bridge mirror: scoped, truthful, side-effect-free on --print ─
proj="$FIXTURE_DIR/proj"
mkdir -p "$proj/.stitchpad"
plist="$("$SP" bridge mirror https://gamma.example.org "$proj" --token tok-abc --print)"

echo "$plist" | grep -q "<string>$(cd -P "$proj" && pwd)</string>" \
  && pass "plist scan root is exactly the passed project dir" \
  || flunk "plist scan root is exactly the passed project dir"
echo "$plist" | grep -q "<string>$HOME</string>" \
  && flunk "plist must never scan all of \$HOME" \
  || pass "plist never scans all of \$HOME"
echo "$plist" | grep -q "org.pasture.bridge-mirror-https-gamma-example-org" \
  && pass "label is derived from the relay url" \
  || flunk "label is derived from the relay url"
echo "$plist" | grep -q "<string>https://gamma.example.org</string>" \
  && pass "plist env carries the teammate relay" \
  || flunk "plist env carries the teammate relay"
echo "$plist" | grep -q "<string>tok-abc</string>" \
  && pass "plist env carries the provided token" \
  || flunk "plist env carries the provided token"
[ -f "$HOME/Library/LaunchAgents/org.pasture.bridge-mirror-https-gamma-example-org.plist" ] \
  && flunk "--print must not install anything" \
  || pass "--print installs nothing"

if "$SP" bridge mirror https://gamma.example.org "$FIXTURE_DIR/nopad" --token t --print >/dev/null 2>&1; then
  flunk "refuses a project dir with no .stitchpad"
else
  pass "refuses a project dir with no .stitchpad"
fi
if env -u STITCHPAD_MIRROR_TOKEN "$SP" bridge mirror https://gamma.example.org "$proj" --print >/dev/null 2>&1; then
  flunk "refuses to run without a token or login"
else
  pass "refuses to run without a token or login"
fi
if "$SP" bridge mirror --remove https://never-installed.example.org >/dev/null 2>&1; then
  flunk "--remove of a missing mirror must fail loudly, not report success"
else
  pass "--remove of a missing mirror fails loudly"
fi

exit "$fail"
