#!/usr/bin/env bash
# stitchpad watcher adapter: claude.
# Fired by watch.sh THE INSTANT a new @name lands in stitchpad.md:
#   claude.sh mention <name> <stitchpad.md> <taskfile>
#
# A running claude TUI has no supported external-injection channel (no socket,
# no stdin into a live session — verified). So the instant-wake we CAN do for an
# interactive claude is: desktop notification now + the message is already on the
# pad, so claude's own Stop hook delivers it at its next turn-end. For an
# autonomous (non-TUI) claude, run it under a host that owns the loop instead.
set -uo pipefail
name="${2:-}"; pad="${3:-}"; taskfile="${4:-}"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$src/bin/lib.sh" 2>/dev/null || true
msg="$(head -c 240 "$taskfile" 2>/dev/null)"
# k3 F14, first line of defence: notify ONCE per mention, not once per retry.
# This adapter can never succeed against a live TUI, so it returns 3 every time
# and the watcher retried it — producing a desktop notification WITH SOUND every
# ~2.5s, forever, from a single @mention to an idle seat. The watcher's retry is
# now bounded and backed off (ds F5 / k3 F14), but the notification is stamped
# per ordinal here as well: a storm this loud must not depend on one guard.
state="${SP_PAD_DIR:-$(dirname "$pad" 2>/dev/null)}/.state"
ord="${SP_ORDINAL:-}"
stamp=""
case "$ord" in ''|*[!0-9]*) ord="" ;; esac
[ -n "$ord" ] && [ -d "$state" ] && stamp="$state/notified.$name.$ord"
if [ -z "$stamp" ] || [ ! -e "$stamp" ]; then
  sp_notify "stitchpad → @$name" "${msg:-new mention}" 2>/dev/null || true
  if [ -n "$stamp" ]; then
    # Ordinals only ever increase, so one stamp per seat is all that is needed —
    # and it keeps .state from collecting a file per mention forever.
    rm -f "$state/notified.$name."* 2>/dev/null || true
    : > "$stamp" 2>/dev/null || true
  fi
fi
# Cannot inject into a live Claude TUI — defer to the Stop hook / host polling.
exit 3
