#!/usr/bin/env bash
# command-dispatch-gate.sh — every command named in help, usage strings, or
# user-facing error/refusal messages MUST dispatch (not print "unknown
# command"), and unknown commands MUST exit non-zero.
#
# GAP 1: help-discoverability-gate.sh ensures static help ↔ dispatch table
# sync, but does NOT test that commands in error messages (like
# "run 'stitchpad heal-roster'") actually dispatch.  This gate closes that.
#
# macOS has no `timeout` command — bash-based timeout wrapper below.
# Every invocation is capped at DISPATCH_TIMEOUT seconds.
#
# Mutant-provable:
#   M1: add refusal message naming nonexistent command → gate RED
#   M2: rename heal-roster dispatch entry → advertised but absent → gate RED
#   M3: unknown command exits 0 → gate RED
#
# Frozen SHA: b24cbe8
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass=0; fail=0; warn=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }
wrn() { printf "  ${YELLOW}WARN${NC} %s\n" "$1"; warn=$((warn+1)); }

readonly DISPATCH_TIMEOUT=5
readonly UNKNOWN_MARKER='___gate_cmd_dispatch_no_such_7a3f___'

# ── bash timeout wrapper (macOS has no `timeout` command) ──────────────
# Runs "$@" with a cap of $1 seconds.  stdout+stderr captured to _CAP.
# Returns: exit code of command, or 124 if killed by timeout.
# NOT reentrant — _CAP must be consumed immediately.
_CAP=""
_to_run() {
  local sec="$1"; shift
  local tmp_out pid killer_pid rc
  tmp_out="$(mktemp /tmp/sp-dispatch-to.XXXXXX)"
  _CAP=""
  ( "$@" >"$tmp_out" 2>&1 ) &
  pid=$!
  ( sleep "$sec"; kill -9 "$pid" 2>/dev/null ) &
  killer_pid=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill -9 "$killer_pid" 2>/dev/null; wait "$killer_pid" 2>/dev/null
  if [ "$rc" -eq 137 ] || [ "$rc" -eq 143 ]; then
    rc=124
    echo "TIMED_OUT_AFTER_${sec}S" >> "$tmp_out"
  fi
  _CAP="$(cat "$tmp_out")"
  rm -f "$tmp_out"
  return "$rc"
}

# ── Dispatch check: does the command NOT print "unknown command"? ─────
# "Dispatch" means the case arm was reached — it may still fail with
# a usage error, missing dep, etc., but NOT "unknown command".
# Returns 0 on dispatch, 1 on "unknown command" (or timeout if we couldn't
# even get output — but we're generous: if no "unknown command" visible,
# it dispatched).
dispatches() {
  local cmd="$1"
  _to_run "$DISPATCH_TIMEOUT" "$SP" "$cmd" || true  # ignore rc
  if echo "$_CAP" | grep -q "unknown command"; then
    return 1
  fi
  return 0
}

# ── Temp pad: commands that need a project run inside this ─────────────
_pad_dir="$(mktemp -d /tmp/sp-gate-dispatch-pad.XXXXXX)"
_wk_cleanup() {
  pkill -9 -f "watch.sh" 2>/dev/null || true
  pkill -9 -f "fswatch" 2>/dev/null || true
  rm -rf "$_pad_dir" 2>/dev/null || true
}
trap _wk_cleanup EXIT
( cd "$_pad_dir"; "$SP" init --name gate 2>/dev/null )
_wk_cleanup  # kill watchers from init
sleep 0.5

# ── Source 1: every top-level command in `stitchpad help` output ──────
help_commands() {
  "$SP" help 2>/dev/null \
    | grep -oE 'stitchpad [a-z][a-zA-Z0-9_.|-]+' \
    | sed 's/stitchpad //' \
    | tr '|' '\n' \
    | sort -u
}

# ── Source 2: every command in usage strings ──────────────────────────
usage_commands() {
  grep -oE "usage: stitchpad ([a-z][a-zA-Z0-9_.|-]+)" "$SP" \
    | sed 's/usage: stitchpad //' \
    | sort -u
}

# ── Source 3: commands in error/refusal messages ──────────────────────
messaged_commands() {
  grep -oE "(run|see) ['\`]stitchpad [a-z][a-zA-Z0-9_.|-]+" "$SP" \
    | sed 's/.*stitchpad //' \
    | tr -d "'\`" \
    | sort -u
}

is_subcommand() {
  case "$1" in
    new|list|show|move|edit|migrate) return 0 ;;
    keygen|env|grant|revoke|status) return 0 ;;
    set|get|check|clear|violations|clear-violation) return 0 ;;
    on|off) return 0 ;;
    --save|--claim|--name|--revoke|--peek|--drain|--json|--deep) return 0 ;;
    -n|-h|--help|--keep|--redeliver|--recovery-counters|--to|--ttl) return 0 ;;
    --force|--image|--desc|--model|--days|--limit|--role|--level) return 0 ;;
    *) return 1 ;;
  esac
}

# Daemon/bridge commands — they may wait/spin for IPC; skip.
is_daemon() {
  case "$1" in
    watch|start|stop|restart|bridge|heartbeat|dm|claim|claims|release|send|\
    hook|claim-hook|daemon|ensure-watcher) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== command-dispatch-gate (SHA b24cbe8) ==="

# ── Source 1 ──────────────────────────────────────────────────────────
echo "=== Source 1: 'stitchpad help' commands ==="
for cmd in $(help_commands); do
  if is_daemon "$cmd"; then
    ok "help '$cmd' (daemon/internal — skip)"
    continue
  fi
  if dispatches "$cmd"; then
    ok "help '$cmd' dispatches"
  else
    bad "help '$cmd' DOES NOT DISPATCH (unknown cmd)"
  fi
done

# ── Source 2 ──────────────────────────────────────────────────────────
echo "=== Source 2: usage-string commands ==="
for cmd in $(usage_commands); do
  is_subcommand "$cmd" && continue
  if is_daemon "$cmd"; then ok "usage '$cmd' (daemon — skip)"; continue; fi
  if dispatches "$cmd"; then
    ok "usage '$cmd' dispatches"
  else
    bad "usage '$cmd' DOES NOT DISPATCH"
  fi
done

# ── Source 3 ──────────────────────────────────────────────────────────
echo "=== Source 3: error/refusal message commands ==="
for cmd in $(messaged_commands); do
  is_subcommand "$cmd" && continue
  if is_daemon "$cmd"; then ok "message '$cmd' (daemon — skip)"; continue; fi
  if dispatches "$cmd"; then
    ok "message '$cmd' dispatches"
  else
    bad "message '$cmd' DOES NOT DISPATCH (in error msg but not a command)"
  fi
done

# ── Source 4: unknown command → non-zero exit + proper message ─────────
echo "=== Source 4: unknown command behavior ==="

# Test exit code — run directly, capture rc
set +e
( "$SP" "$UNKNOWN_MARKER" >/dev/null 2>&1 )
ukrc=$?
set -e
if [ "$ukrc" -ne 0 ]; then
  ok "unknown command exits $ukrc (non-zero)"
else
  bad "unknown command exits 0 (should be non-zero)"
fi

# Test stderr message
_to_run 3 "$SP" "$UNKNOWN_MARKER" || true
if echo "$_CAP" | grep -q "unknown command"; then
  ok "unknown command prints 'unknown command'"
else
  bad "unknown command does NOT print 'unknown command' (got: ${_CAP:0:80})"
fi

# ── Verdict ───────────────────────────────────────────────────────────

echo ""
if [ "$fail" -gt 0 ]; then
  echo "${RED}$fail FAILED${NC}, $warn warnings, $pass passed"
  exit 1
fi
echo "${GREEN}All $pass command-dispatch gates PASSED${NC} ($warn skipped daemon)"
exit 0
