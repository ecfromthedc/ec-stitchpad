#!/usr/bin/env bash
# stitchpad auto-rejoin — claude SessionStart hook. Zero-friction reconnect:
# a restarted claude session re-binds its NEW session id to this pad's sticky
# handle (.state/autoname.claude, written by the MCP join tool), restarts the
# heartbeat, and re-pins the herdr wake target to this pane's terminal id.
# Fast no-op when the cwd has no pad or no sticky name.
#
# IDENTITY GUARD — the sticky name is a RECOVERY hint, not a grant. A pad dir
# can host SEVERAL claude sessions at once (fable + helpers); blindly adopting
# the sticky name let a second session steal the handle, hijack the wake
# target, and receive another agent's messages (the 02:53 fable incident).
# Adopt ONLY when one of these holds:
#   (1) true resume  — this session id is already bound to the name
#   (2) same terminal — we're starting in the very herdr terminal the roster
#       says @name lives in (normal restart-in-place)
#   (3) orphan rescue — @name's heartbeat is stale/dead (nobody is the name)
set -uo pipefail

input="$(cat 2>/dev/null || true)"
jqbin="$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)"
cwd=""; sid=""
if [ -x "$jqbin" ] && [ -n "$input" ]; then
  cwd="$(printf '%s' "$input" | "$jqbin" -r '.cwd // empty' 2>/dev/null)"
  sid="$(printf '%s' "$input" | "$jqbin" -r '.session_id // empty' 2>/dev/null)"
fi
[ -n "$cwd" ] || cwd="$PWD"
pad="$cwd/.stitchpad"
[ -d "$pad" ] || exit 0

name=""
[ -f "$pad/.state/autoname.claude" ] && name="$(cat "$pad/.state/autoname.claude" 2>/dev/null | tr -d '[:space:]')"
[ -n "$name" ] || exit 0

# C11 (rc1): the sticky name is written by the MCP join tool WITHOUT a shape
# gate (C7 family) and this hook feeds it straight into `heartbeat start` on
# EVERY session start — a 241-char handle turns every restart into the
# ENAMETOOLONG exec-self spin (fx3 F1), an auto-recurring bomb. Gate the
# handle BEFORE any use. Grammar = kimi2's dm-handle allowlist (rc1 C7 fix
# shape); the shared sp_valid_name_shape consolidation swaps in here later.
# Exit 0, loudly: a session-start hook must never break the session itself.
if ! printf '%s' "$name" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$'; then
  echo "stitchpad: session-start auto-rejoin REFUSED — sticky handle '$(printf '%s' "$name" | cut -c1-40)' fails the handle shape gate; re-join with a valid handle to re-arm" >&2
  exit 0
fi

bin="$HOME/.stitchpad/bin/stitchpad"
[ -x "$bin" ] || bin="$(command -v stitchpad 2>/dev/null || true)"
[ -n "$bin" ] && [ -x "$bin" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# Resolve this pane's herdr terminal id once (used by guard rule 2 + re-pin).
myterm=""
if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  hd="$(command -v herdr 2>/dev/null || echo "$HOME/.local/bin/herdr")"
  if [ -x "$hd" ] && [ -x "$jqbin" ]; then
    myterm="$("$hd" agent get "$HERDR_PANE_ID" 2>/dev/null | "$jqbin" -r '.result.agent.terminal_id // empty' 2>/dev/null)"
  fi
fi

# ── IDENTITY CLAIM (k3 F18) ─────────────────────────────────────────────────
# Every rule below is check-then-act, and rule (3) in particular decides "nobody
# is @name" from a heartbeat file that the winner does not refresh until AFTER
# its ticker forks. Two session starts in the same window therefore both saw a
# stale heartbeat, both adopted, and both bound their session id — two live
# agents answering to one handle, with seen.<name> making mention delivery a
# first-hook-wins race. That is the 02:53 fable incident, re-opened by
# concurrency. Measured before this claim, 5 rounds of paired concurrent starts:
# 5/5 rounds ended with 2 bindings and 2 hooks printing "you are @fable".
#
# mkdir is the atomic primitive used for every other singleton in this codebase.
# Ownership is published with a BUILTIN redirect the instant mkdir returns —
# before anything forks — so a contender never sees an ownerless claim.
#
# A contender WAITS for the claim rather than skipping outright: after the
# winner publishes a live heartbeat, re-running the rules gives the right answer
# for everyone. A genuine resume (rule 1) still adopts; only the orphan rescue,
# whose premise "nobody is the name" has just become false, correctly stands
# down. A claim whose owner is dead is reclaimed, so a crashed hook cannot wedge
# auto-rejoin forever — the failure mode this file exists to avoid.
_claim="$pad/.state/identity-claim.$name.d"
_claim_held=0
_claim_waited=0
_claim_try() { mkdir "$_claim" 2>/dev/null && printf '%s\n' "$$" > "$_claim/owner" 2>/dev/null; }
_claim_owner_dead() {
  local _p
  _p="$(cat "$_claim/owner" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$_p" ] || return 1              # no owner yet: the winner is mid-publish
  kill -0 "$_p" 2>/dev/null && return 1
  return 0
}
mkdir -p "$pad/.state" 2>/dev/null || true
if _claim_try; then
  _claim_held=1
else
  _claim_waited=1
  _w=0
  while [ "$_w" -lt 60 ]; do            # bounded: ~3s of 50ms steps
    sleep 0.05
    if _claim_try; then _claim_held=1; break; fi
    _w=$(( _w + 1 ))
  done
  if [ "$_claim_held" -eq 0 ] && _claim_owner_dead; then
    rmdir "$_claim" 2>/dev/null || rm -rf "$_claim" 2>/dev/null || true
    _claim_try && _claim_held=1
  fi
fi
if [ "$_claim_held" -eq 0 ]; then
  echo "stitchpad: session-start auto-rejoin SKIPPED — another session is claiming @$name right now" >&2
  exit 0
fi
trap 'rm -rf "$_claim" 2>/dev/null || true' EXIT

adopt=0
# (1) true resume: this session id already bound to this name
if [ -n "$sid" ] && [ -f "$pad/.state/sessions/$sid" ]; then
  bound="$(cat "$pad/.state/sessions/$sid" 2>/dev/null | tr -d '[:space:]')"
  [ "$bound" = "$name" ] && adopt=1
fi
# (2) same terminal: restarting in the terminal the roster pins for @name
if [ "$adopt" -eq 0 ] && [ -n "$myterm" ]; then
  rterm="$("$bin" roster 2>/dev/null | awk -F'|' -v n="$name" '$1==n {print $4}' | tr -d '[:space:]')"
  [ -n "$rterm" ] && [ "$rterm" = "$myterm" ] && adopt=1
fi
# (3) orphan rescue: no fresh heartbeat with a live pid → nobody IS the name
if [ "$adopt" -eq 0 ]; then
  hb="$pad/.state/alive.$name"
  orphan=1
  if [ -f "$hb" ]; then
    hts="$(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null || echo 0)"
    hage=$(( $(date +%s) - hts ))
    if [ "$hage" -lt 90 ]; then
      hpid="$(grep -o '"pid":[0-9]*' "$hb" 2>/dev/null | head -1 | cut -d: -f2)"
      if [ -z "$hpid" ] || kill -0 "$hpid" 2>/dev/null; then
        orphan=0   # @name is alive elsewhere — do NOT steal it
      fi
    fi
  fi
  [ "$orphan" -eq 1 ] && adopt=1
fi
if [ "$adopt" -eq 0 ]; then
  # Not adopting is the normal, silent outcome for a helper session sharing a
  # pad. But a session that WAITED on the identity claim and then found the
  # handle taken is the F18 loser — it must not just vanish, or the operator
  # sees one of two panes mysteriously nameless with nothing said about it.
  [ "$_claim_waited" -eq 1 ] && \
    echo "stitchpad: session-start auto-rejoin SKIPPED — @$name was claimed by a session that started at the same moment; this session stays unnamed (run \`stitchpad join\` if you need your own handle)" >&2
  exit 0
fi

# Re-bind THIS session id, restart the heartbeat under the live claude pid.
[ -n "$sid" ] && "$bin" bind-session "$sid" "$name" >/dev/null 2>&1 || true
STITCHPAD_NAME="$name" STITCHPAD_HEARTBEAT_PARENT_PID="$PPID" \
  "$bin" heartbeat start "$name" >/dev/null 2>&1 || true

# k3 F18: the ticker writes alive.<name> from a FORKED child, so `heartbeat
# start` returning proves nothing about the file the next session start will
# read. Hold the claim until the identity is actually published — otherwise the
# contender we serialized against wakes into the same stale-heartbeat window we
# just closed. Bounded (~2s); if the heartbeat never comes up we release anyway
# rather than block a session start on it.
_hbf="$pad/.state/alive.$name"; _now="$(date +%s)"
_hbw=0
while [ "$_hbw" -lt 40 ]; do
  if [ -f "$_hbf" ]; then
    _hbts="$(stat -f %m "$_hbf" 2>/dev/null || stat -c %Y "$_hbf" 2>/dev/null || echo 0)"
    [ "$_hbts" -ge "$_now" ] && break
  fi
  sleep 0.05
  _hbw=$(( _hbw + 1 ))
done

# Re-pin the push wake target to this terminal (stable across pane moves).
[ -n "$myterm" ] && "$bin" set-wake "$name" push "$myterm" herdr >/dev/null 2>&1 || true

# stdout becomes session context: remind the agent who it is on this pad and
# rebuild the same shared coding discipline a brand-new session would get.
printf '%s\n' "stitchpad: you are @$name on this project's pad (auto-rejoined — session re-bound, heartbeat live, wake target re-pinned). Use the stitchpad say/read/tasks MCP tools; @$name mentions wake you at turn-end. Do NOT call join again." \
  | "$bin" prompt-context
exit 0
