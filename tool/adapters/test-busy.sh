#!/usr/bin/env bash
# test-busy.sh — stitchpad adapter for P22 operator-conduct gate.
# Simulates a busy agent: on first delivery returns rc=3 (BUSY),
# then after a control file signals it's free, returns rc=0 and
# writes an answer to a marker file.
#
# Control protocol:
#   $PAD_STATE/.test-busy.control  — "busy" (default) | "free" | "answer:<text>"
#   $PAD_STATE/.test-busy.last     — last message delivered
#   $PAD_STATE/.test-busy.mid-lane — written when returning busy (lane context)
set -uo pipefail

name="${2:-}"; pad="${3:-}"; taskfile="${4:-}"
[ -n "$name" ] || exit 1

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$src/bin/lib.sh" 2>/dev/null || true

# PAD_STATE is set by sp_init_paths, which an adapter never calls — sourcing
# lib.sh only defines functions. So every marker below was being written to
# "/.test-busy.*" (an empty prefix), which silently failed and left the P22 gate
# reporting "agent log missing" as if the capability were unbuilt. The adapter
# contract is `adapter.sh <event> <to> <stitchpad.md> <task-text-file>`, so the
# state dir is derivable from $3.
if [ -z "${PAD_STATE:-}" ] && [ -n "$pad" ]; then
  PAD_STATE="$(cd "$(dirname "$pad")" 2>/dev/null && pwd)/.state"
fi
[ -n "${PAD_STATE:-}" ] || { echo "[test-busy.sh] cannot resolve PAD_STATE" >&2; exit 1; }

# Read control
control="${PAD_STATE:-}/.test-busy.control"
if [ -f "$control" ]; then
  _ctrl="$(cat "$control" 2>/dev/null || echo "busy")"
else
  _ctrl="busy"
fi

# Record the message
msg="$(head -c 500 "$taskfile" 2>/dev/null | tr '\n' ' ')"
echo "$(date '+%H:%M:%S') | $msg" >> "${PAD_STATE:-}/.test-busy.last"

case "$_ctrl" in
  busy)
    # Write lane context for the ack
    echo "working on a lane fix; ETA ~2 min" > "${PAD_STATE:-}/.test-busy.mid-lane"
    echo "[test-busy.sh] @$name is mid-lane — deferring" >&2
    exit 3
    ;;
  free:*)
    _answer="${_ctrl#free:}"
    echo "answered: $_answer" >> "${PAD_STATE:-}/.test-busy.last"
    # Signal completion so the gate can detect it
    touch "${PAD_STATE:-}/.test-busy.done"
    echo "[test-busy.sh] @$name is free — delivering" >&2
    exit 0
    ;;
  free)
    echo "answered: done" >> "${PAD_STATE:-}/.test-busy.last"
    touch "${PAD_STATE:-}/.test-busy.done"
    echo "[test-busy.sh] @$name is free — delivering" >&2
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
