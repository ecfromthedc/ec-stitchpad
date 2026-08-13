#!/usr/bin/env bash
# Regression test: a DELEGATED agent must be able to post as itself.
#
# The failure it exists for: a sub-agent (codex exec, a spawned helper, a CI
# runner) inherits its parent's terminal environment. The terminal is claimed
# by the LEAD, so the helper's `say` was refused — "this terminal is claimed by
# @fable" — and every delegated seat had to hand its findings to the lead to
# re-post by hand. That is a reporting channel with a human in the middle, and
# reports went late or missing.
#
# The guard's real job — one terminal = one PAD — must survive intact.
#
#   bash test/delegate-can-speak.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP="$HERE/../tool/bin/stitchpad"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-deleg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }

export STITCHPAD_HEARTBEAT_AUTOSTART=0
mkdir -p "$WORK/home" "$WORK/padA" "$WORK/padB"
sp() { HOME="$WORK/home" STITCHPAD_PAD_DIR="$2/.stitchpad" STITCHPAD_NAME="$1" \
       ${3:+HERDR_PANE_ID="$3"} "$SP" "${@:4}"; }

( cd "$WORK/padA" && HOME="$WORK/home" "$SP" init >/dev/null 2>&1 )
( cd "$WORK/padA" && HOME="$WORK/home" STITCHPAD_NAME=lead "$SP" join lead cli >/dev/null 2>&1 )
( cd "$WORK/padA" && HOME="$WORK/home" STITCHPAD_NAME=helper "$SP" join helper cli >/dev/null 2>&1 )

# The lead's terminal holds the claim for padA.
TERMDIR="$WORK/home/.stitchpad-terminals"; mkdir -p "$TERMDIR"
printf '%s|lead|%s' "$WORK/padA" "$(date +%s)" > "$TERMDIR/fake-surface"

# The decision that changed lives in sp_term_lock_check. Drive it directly with
# a known roster and a known claim — that is the unit under test; pad-file
# resolution is lib.sh's own business and has its own suites.
check() { # $1=who $2=claim_pad → exit 0 allowed / 1 refused
  HOME="$WORK/home" SP_TERMDIR="$TERMDIR" PAD_DIR="$WORK/padA" \
  WHO="$1" CLAIMPAD="$2" bash -c '
    source "'"$HERE"'/../tool/bin/lib.sh" 2>/dev/null
    PAD_DIR="'"$WORK"'/padA"
    SP_TERMDIR="'"$TERMDIR"'"
    printf "%s|lead|%s" "$CLAIMPAD" "$(date +%s)" > "$SP_TERMDIR/fake-surface"
    sp_term_surface_of() { echo fake-surface; }
    _sp_term_claim_honored() { return 0; }
    sp_roster() { printf "lead|cli|pull|-\nhelper|ocean|push|sid-1\n"; }
    sp_term_lock_check fake-surface "$WHO" >/dev/null
  '
}

check lead "$WORK/padA" && ok "the lead itself still posts" || bad "the lead itself still posts"
check helper "$WORK/padA" && ok "a rostered delegate may speak from the lead's terminal" \
                          || bad "a rostered delegate may speak from the lead's terminal"
check stranger "$WORK/padA" && bad "an unrostered name must still be refused" \
                            || ok "an unrostered name is still refused"

# The actual protection: a claim belonging to a DIFFERENT pad still refuses,
# even for a name that is on this pad's roster.
check helper "$WORK/padB" && bad "a foreign-pad claim must still refuse (ghost post)" \
                          || ok "a foreign-pad claim still refuses — one terminal, one pad"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
