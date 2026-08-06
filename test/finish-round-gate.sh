#!/usr/bin/env bash
# finish-round-gate.sh — the closing round of review findings, each reproduced
# before it was fixed. One suite rather than five, because these share a fixture.
#
#   R1  deepseek F11 — `task new --to` posted the assignment notice TWICE, the
#       second copy appended after sp_unlock with an unchecked sp_commit
#   R2  k3 F19      — join accepted a 241-char handle; state files are
#       "<prefix>.<name>" and a path component caps at 255 bytes
#   R3  k3 F12      — `pads` used a bare -maxdepth 4, so a pad deeper than four
#       levels was invisible, including the one you were standing in
#   R4  deepseek F2 — `lanes` rendered a board and exited 0 on a pad whose git
#       dir was gone, while roster/whoami correctly refused
#   R5  FOUND LIVE  — a seat whose ocean turn ERRORED could never be removed:
#       the guard demanded a cancel-result file that only a CANCEL creates, so
#       `leave` and `rename` refused that seat forever
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
SP="$TOP/tool/bin/stitchpad"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-finish.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
export TMPDIR="$TMP" HOME="$TMP/home"; mkdir -p "$HOME"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }   # no pkill: nothing here spawns (P9)
trap cleanup EXIT
export STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_WATCH_START_GRACE=0 STITCHPAD_STEAL=1

newpad() {  # $1 = dir name, $2 = terminal namespace
  local d="$TMP/$1"; mkdir -p "$d"
  ( cd "$d" && STITCHPAD_TERMINAL_NAMESPACE="$2" "$SP" init >/dev/null 2>&1 ) || return 1
  printf '%s' "$d"
}

echo "=== closing round: five findings ==="

# ── R1: exactly ONE assignment notice, and it carries a message id ───────────
P1="$(newpad p1 r1)" || { bad "R1 setup"; }
( cd "$P1" && STITCHPAD_TERMINAL_NAMESPACE=r1 "$SP" join dale cli pull - >/dev/null 2>&1 )
( cd "$P1" && STITCHPAD_TERMINAL_NAMESPACE=r1b "$SP" join larry cli pull - >/dev/null 2>&1 )
( cd "$P1" && STITCHPAD_TERMINAL_NAMESPACE=r1 STITCHPAD_NAME=dale "$SP" task new "assigned card" --to larry >/dev/null 2>&1 )
_n="$(grep -c 'assigned:' "$P1/.stitchpad/stitchpad.md" 2>/dev/null || echo 0)"
if [ "$_n" = "1" ]; then
  ok "R1: the assignment notice is posted exactly once"
else
  bad "R1: assignment notice appears $_n times (want 1) — the post-unlock duplicate is back"
fi
if grep -B2 'assigned:' "$P1/.stitchpad/stitchpad.md" 2>/dev/null | grep -q '#m-'; then
  ok "R1b: the surviving notice carries a message id (threadable/reactable)"
else
  bad "R1b: notice has no message id — the wrong copy survived"
fi

# ── R2: handle length is capped at the PRODUCER ─────────────────────────────
P2="$(newpad p2 r2)" || bad "R2 setup"
_long="$(printf 'a%.0s' $(seq 1 241))"
if ( cd "$P2" && STITCHPAD_TERMINAL_NAMESPACE=r2 "$SP" join "$_long" cli pull - >/dev/null 2>&1 ); then
  bad "R2: join accepted a 241-char handle"
else
  ok "R2: join refuses a 241-char handle"
fi
_ok64="$(printf 'b%.0s' $(seq 1 64))"
if ( cd "$P2" && STITCHPAD_TERMINAL_NAMESPACE=r2c "$SP" join "$_ok64" cli pull - >/dev/null 2>&1 ); then
  ok "R2b: a 64-char handle is still accepted (the cap is not over-tight)"
else
  bad "R2b: a 64-char handle was refused — the cap is too aggressive"
fi

# ── R3: pads finds a pad deeper than four levels ────────────────────────────
mkdir -p "$HOME/a/b/c/d/e/deep"
( cd "$HOME/a/b/c/d/e/deep" && STITCHPAD_TERMINAL_NAMESPACE=r3 "$SP" init >/dev/null 2>&1 )
if "$SP" pads 2>/dev/null | grep -q 'a/b/c/d/e/deep'; then
  ok "R3: a pad six levels down is listed"
else
  bad "R3: a pad six levels down is invisible — the depth limit is back"
fi

# ── R4: lanes refuses on a pad whose git is gone ────────────────────────────
P4="$(newpad p4 r4)" || bad "R4 setup"
( cd "$P4" && STITCHPAD_TERMINAL_NAMESPACE=r4 "$SP" join dale cli pull - >/dev/null 2>&1 )
if ( cd "$P4" && "$SP" lanes >/dev/null 2>&1 ); then
  ok "R4a: lanes works on a healthy pad"
else
  bad "R4a: lanes fails on a HEALTHY pad — the new assertion is too aggressive"
fi
rm -rf "$P4/.stitchpad/stitchpad-git"
if ( cd "$P4" && "$SP" lanes >/dev/null 2>&1 ); then
  bad "R4: lanes exited 0 on a pad with no git — the board still lies about a broken pad"
else
  ok "R4: lanes refuses on a pad whose durability layer is gone"
fi

# ── R5: a seat whose delivery ERRORED can be removed ────────────────────────
# The guard read only delivery.<name>.cancel.<turn>/result, which exists solely
# after a CANCEL. An errored turn produced none, so leave/rename refused forever.
P5="$(newpad p5 r5)" || bad "R5 setup"
( cd "$P5" && STITCHPAD_TERMINAL_NAMESPACE=r5 "$SP" join dale cli pull - >/dev/null 2>&1 )
( cd "$P5" && STITCHPAD_TERMINAL_NAMESPACE=r5b "$SP" join stuck ocean push sess-xyz >/dev/null 2>&1 )
_st="$P5/.stitchpad/.state"
printf 'ordinal|x|x|x|x|ocean\n' > "$_st/delivery.stuck.pending"
printf 'turn-abc' > "$_st/delivery.stuck.turn.1"
printf 'x' > "$_st/delivery.stuck.submit.1"
{ printf 'state=errored\n'; printf 'turn_status=errored\n'; } > "$_st/delivery.stuck.state"
if ( cd "$P5" && STITCHPAD_TERMINAL_NAMESPACE=r5 "$SP" leave stuck >/dev/null 2>&1 ); then
  ok "R5: a seat whose ocean turn ERRORED can be removed"
else
  bad "R5: cannot remove a seat with an errored turn — the broken seat is the one you cannot delete"
fi
# And the guard must still HOLD for a genuinely in-flight delivery.
( cd "$P5" && STITCHPAD_TERMINAL_NAMESPACE=r5c "$SP" join inflight ocean push sess-abc >/dev/null 2>&1 )
printf 'ordinal|x|x|x|x|ocean\n' > "$_st/delivery.inflight.pending"
printf 'x' > "$_st/delivery.inflight.submit.1"
: > "$_st/delivery.inflight.turn.1"        # submitted, no turn id yet = in flight
printf 'state=submitted\n' > "$_st/delivery.inflight.state"
if ( cd "$P5" && STITCHPAD_TERMINAL_NAMESPACE=r5 "$SP" leave inflight >/dev/null 2>&1 ); then
  bad "R5b: removed a seat with a delivery still in flight — the guard was widened too far"
else
  ok "R5b: a genuinely in-flight delivery still blocks removal"
fi

echo ""
echo "=== RESULTS: $pass PASS, $fail FAIL ==="
[ "$fail" -eq 0 ] || exit 1
