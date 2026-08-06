#!/usr/bin/env bash
# stitchpad wake adapter for herdr (terminal workspace manager for AI agents).
#
# For agents running in herdr-managed panes (e.g. an interactive pi TUI that has
# no stitchpad extension loaded). Wake = type the nudge into the agent's pane and
# submit it, via `herdr pane run` (writes command text plus Enter).
#
# Called by the watcher as:  herdr.sh mention <name> <stitchpad.md> <taskfile>
# Env: SP_TARGET = herdr agent target (terminal id like term_xxx, unique agent
# name, or pane id) — whatever `herdr agent get <target>` accepts.
#
# Exit contract: 0 delivered · 1 failed · 3 deferred (focus-guard, do not
# consume the gate).
set -uo pipefail

event="${1:-}"; to="${2:-}"; pad_md="${3:-}"; taskfile="${4:-}"
[ "$event" = "mention" ] || exit 0

pad_root="${SP_PAD_DIR:-.}"
if [ -f "$pad_root/stitchpad.md" ]; then
  pad_dir="$pad_root"
elif [ -d "$pad_root/.stitchpad" ]; then
  pad_dir="$pad_root/.stitchpad"
else
  pad_dir=".stitchpad"
fi
mkdir -p "$pad_dir/.state" 2>/dev/null || true
log="$pad_dir/.state/adapter.herdr.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

hd_bin="$(command -v herdr 2>/dev/null || echo "$HOME/.local/bin/herdr")"
[ -x "$hd_bin" ] || { echo "[$(ts)] herdr CLI not found" >>"$log"; exit 1; }

target="${SP_TARGET:-}"
if [ -z "$target" ] || [ "$target" = "-" ]; then
  echo "[$(ts)] no herdr target for @$to (set roster target to the agent's terminal id)" >>"$log"
  exit 1
fi

# ONE TERMINAL = ONE PAD: never inject a wake into a terminal that is live in a
# DIFFERENT pad or under a different name. ~/.stitchpad-terminals/<surface> is
# the machine-global claim registry ("pad_dir|name|epoch", heartbeat-refreshed).
# C12 (rc1): the registry path is built from the ROSTER target — a roster-write
# primitive (C7) with a `../` component and no `@@` traversed the path into an
# arbitrary local file read. The terminal component must be a plain filename;
# anything else is never a legitimate surface id. Fail closed: a wake whose
# target cannot be safety-checked is not delivered.
_tcomp="${target##*@@}"
case "$_tcomp" in
  *[!A-Za-z0-9._-]*|''|..)
    echo "[$(ts)] CROSS-PAD CHECK REFUSED: roster target '$target' has a malformed terminal component — wake NOT delivered (re-pin the roster target)" >>"$log"
    exit 1 ;;
esac
lockf="$HOME/.pasture-terminals/${_tcomp}"; [ -f "$lockf" ] || lockf="$HOME/.stitchpad-terminals/${_tcomp}"
if [ -f "$lockf" ]; then
  IFS='|' read -r _lpad _lname _lts < "$lockf"
  if [ $(( $(date +%s) - ${_lts:-0} )) -lt 300 ] \
     && { [ "$_lpad" != "$pad_dir" ] || [ "$_lname" != "$to" ]; }; then
    echo "[$(ts)] CROSS-PAD BLOCKED: terminal $target is live as @${_lname} in ${_lpad} — refusing wake for @$to from $pad_dir" >>"$log"
    exit 1
  fi
fi

# Resolve the live pane + focus state. `agent get` accepts terminal ids, unique
# agent names, and pane ids; a dead/missing target is a hard fail (the roster
# target must be re-pinned, we never guess a pane).
info="$("$hd_bin" agent get "$target" 2>/dev/null || true)"
pane="$(printf '%s' "$info" | sed -n 's/.*"pane_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
if [ -z "$pane" ]; then
  echo "[$(ts)] no live herdr agent for target '$target' (@$to) — re-pin the roster target" >>"$log"
  exit 1
fi

# FOCUS-GUARD: don't clobber a pane the human is actively typing in.
# Pi is the exception: direct @pi mentions must reach the active agent even
# while its pane is focused. The previous blanket guard left a lone mention
# pending forever because deferred wakes were retried only after another pad
# write. `pane run` safely queues the nudge as steering while Pi is working.
if [ "${STITCHPAD_FORCE_WAKE:-0}" != "1" ] && [ "$to" != "pi" ]; then
  case "$info" in
    *'"focused":true'*)
      echo "[$(ts)] pane $pane focused — deferring wake for @$to" >>"$log"
      exit 3
      ;;
  esac
fi

# Canonical wake message — same text the claude/codex Stop hook delivers.
nudge="$(STITCHPAD_PAD_DIR="$pad_dir" STITCHPAD_NAME="$to" stitchpad wake "$to" --peek 2>/dev/null)"
[ -z "$nudge" ] && nudge="stitchpad: @$to you were pinged — read .stitchpad/stitchpad.md and reply"
# SANITIZE — pane run reaches a raw pty. Strip ALL control bytes (ESC for
# escape-sequence injection, CR/LF for embedded second-command injection), then
# collapse whitespace. Pad body text is untrusted.
#
# k3 F15 was filed UNPROVEN because it needs two things to be true at once. The
# first half is now PROVEN by execution: posting
#     @eve check $(id) and `whoami` ; echo pwned | sh && ls > /tmp/x
# produced a nudge carrying every one of those bytes intact, because the old
# sanitizer removed control characters ONLY. So untrusted pad text with live
# shell metacharacters was being typed into a raw pty and submitted with Enter.
#
# The second half — that the pane is a SHELL rather than an agent TUI — is a
# herdr property this adapter cannot verify (the cross-pad claim check proves
# only that the terminal is not claimed by another pad within 5 minutes, not
# that the agent that owned it is still running). Rather than argue about how
# often that happens, remove the dependency: neutralise the metacharacters, and
# the question stops mattering. A shell handed the sanitised text can only fail
# to find a command named "pasture:".
#
# Mapped to spaces, not deleted, so the words a human reads stay readable. The
# full untouched text is always on the pad; this is a nudge, not the message.
nudge="$(printf '%s' "$nudge" \
  | LC_ALL=C tr -d '\000-\037\177' \
  | LC_ALL=C tr '`$;|&<>()\\' '          ' \
  | tr -s ' ')"
# And a bound: `pane run` TYPES this, one keystroke at a time, into a live TUI.
# The canonical nudge already carries the whole shared-discipline preamble, so
# an un-capped wake types thousands of characters into the operator's terminal.
_n_max="${STITCHPAD_HERDR_NUDGE_MAX:-600}"
if [ "${#nudge}" -gt "$_n_max" ]; then
  # NOTE the wording: this suffix is appended AFTER sanitising, so it must not
  # contain a metacharacter itself. The first version used parentheses and put
  # them straight back into the pty — caught by the gate, which is the only
  # reason it is not still there.
  nudge="${nudge:0:$_n_max} … full message on the pad — stitchpad read -n 30"
fi

if "$hd_bin" pane run "$pane" "$nudge" >>"$log" 2>&1; then
  # SETTLE-RETRY: pane run types text + Enter, but a busy TUI (mid-turn
  # redraw, streaming) can swallow the Enter and park the nudge unsent in the
  # input box. After a short settle, send one bare Enter: if the nudge parked,
  # this submits it (Claude Code queues it as steering); if it already went
  # through, a bare Enter on an empty input is a no-op.
  sleep 2
  "$hd_bin" pane run "$pane" "" >>"$log" 2>&1 || true
  echo "[$(ts)] delivered wake to @$to via pane $pane (+settle-retry enter)" >>"$log"
  # Keep the woken agent's heartbeat alive (cold-wake gap).
  if [ -f "$pad_dir/stitchpad.md" ]; then
    ( cd "$(dirname "$pad_dir")" && STITCHPAD_NAME="$to" stitchpad heartbeat start "$to" >/dev/null 2>&1 )
  fi
  exit 0
fi
echo "[$(ts)] pane run failed for @$to (pane $pane)" >>"$log"
exit 1
