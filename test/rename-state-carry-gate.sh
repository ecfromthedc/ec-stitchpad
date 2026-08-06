#!/usr/bin/env bash
# rename-state-carry-gate.sh — `stitchpad rename` must carry a seat's name-keyed
# state, or refuse; it may never move the roster row and leave the state behind.
#
# THE BUG THIS EXISTS FOR (evidence/reviews, deepseek F8, LOSES-WORK):
# rename moved seen/count/alive/role/level/runtime/forcewake/dnd/delivered_no_reply
# and stopped there. `.state/ocean-session.<old>` stayed put. seat-keeper iterates
# ocean-session.*, so after a rename it logged "SEAT NOT ON ROSTER" forever for a
# name that no longer existed, while the renamed seat — having no binding file —
# was never considered at all. The anti-starvation watchdog silently stopped
# covering the seat, which is precisely the failure it exists to prevent. And
# rename printed "✓ ... bindings ..." rc=0 the whole time: success reported for
# work not done, the top bug class in this repo.
#
# An allow-list of prefixes WILL rot again. So the contract asserted here is not
# "this specific list is complete" but "an omission is loud": an unrecognised
# name-keyed state file makes rename REFUSE, before it has mutated anything.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
SP="$TOP/tool/bin/stitchpad"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

_RUN_TMP="$(mktemp -d /tmp/sp-gate-rename.XXXXXXXX)"
export TMPDIR="$_RUN_TMP"
export HOME="$_RUN_TMP/home"
mkdir -p "$HOME"
# No pkill anywhere in this suite: a bare pkill kills processes the suite did not
# spawn (ledger P9). Nothing here starts a watcher or a ticker to begin with.
cleanup() { rm -rf "$_RUN_TMP" 2>/dev/null || true; }
trap 'cleanup' EXIT
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export STITCHPAD_WATCH_START_GRACE=0
export STITCHPAD_STEAL=1

# Each case gets its own pad dir — reusing one leaves a terminal-identity lock
# bound to the previous pad and the next `join` fails for an unrelated reason.
new_pad() {
  local dir="$_RUN_TMP/$1"
  mkdir -p "$dir"
  ( cd "$dir" && "$SP" init --name "$1" >/dev/null 2>&1 ) || return 1
  ( cd "$dir" && "$SP" join wkr ocean push sess-abc >/dev/null 2>&1 ) || return 1
  printf '%s' "$dir"
}

echo "=== rename: name-keyed state must follow the seat ==="

# ── A. the reported bug: ocean-session and friends must be carried ───────────
padA="$(new_pad padA)" || { bad "setup A"; echo "=== RESULTS: $pass PASS, $((fail+1)) FAIL ==="; exit 1; }
printf 'sess-abc'        > "$padA/.stitchpad/.state/ocean-session.wkr"
printf 'deepseek-v4-pro' > "$padA/.stitchpad/.state/seat-model.wkr"
printf '2'               > "$padA/.stitchpad/.state/keeper-strike.wkr"
printf 'w'               > "$padA/.stitchpad/.state/scope.wkr"

( cd "$padA" && "$SP" rename wkr wrk2 >/dev/null 2>&1 ) \
  && ok "A1: rename succeeds when every name-keyed file is recognised" \
  || bad "A1: rename failed on a pad it should handle"

for f in ocean-session seat-model keeper-strike scope; do
  if [ -f "$padA/.stitchpad/.state/$f.wrk2" ]; then
    ok "A2/$f: carried to the new name"
  else
    bad "A2/$f: NOT carried — .state/$f.wrk2 is missing"
  fi
  if [ -e "$padA/.stitchpad/.state/$f.wkr" ]; then
    bad "A3/$f: stale file for the OLD name survived the rename"
  else
    ok "A3/$f: no stale file left under the old name"
  fi
done

# The seat-keeper's own view: it iterates ocean-session.* and matches the roster.
_ks="$(cd "$padA" && ls .stitchpad/.state/ocean-session.* 2>/dev/null | head -1)"
_ks="$(basename "${_ks:-none}")"
_roster="$(cd "$padA" && "$SP" roster 2>/dev/null | cut -d'|' -f1 | head -1)"
[ "$_ks" = "ocean-session.$_roster" ] \
  && ok "A4: the keeper's binding file and the roster row name the SAME seat" \
  || bad "A4: keeper binding ($_ks) disagrees with roster row ($_roster)"

# ── B. the anti-rot contract: an unknown name-keyed file must REFUSE ─────────
padB="$(new_pad padB)" || { bad "setup B"; echo "=== RESULTS: $pass PASS, $((fail+1)) FAIL ==="; exit 1; }
printf 'sess-abc' > "$padB/.stitchpad/.state/ocean-session.wkr"
# MUTANT: stands in for the next state file somebody adds without updating the
# rename list. If this does not make rename refuse, the gate is decorative.
printf 'x' > "$padB/.stitchpad/.state/some-future-binding.wkr"

_before_roster="$(cd "$padB" && "$SP" roster 2>/dev/null)"
_rc=0; _out="$( cd "$padB" && "$SP" rename wkr wrk2 2>&1 )" || _rc=$?

[ "$_rc" -ne 0 ] \
  && ok "B1: an unrecognised name-keyed state file makes rename REFUSE" \
  || bad "B1: rename returned 0 while leaving state behind (silent success)"

printf '%s' "$_out" | grep -q "some-future-binding.wkr" \
  && ok "B2: the refusal NAMES the offending file" \
  || bad "B2: the refusal does not say which file blocked it"

# Refusing after the roster rewrite would swap a silent state leak for a working
# pad that disagrees with its own git history. The check must run BEFORE any
# mutation, so nothing may have moved.
[ "$(cd "$padB" && "$SP" roster 2>/dev/null)" = "$_before_roster" ] \
  && ok "B3: the refused rename left the roster untouched" \
  || bad "B3: the roster was rewritten by a rename that then failed"

[ -f "$padB/.stitchpad/.state/ocean-session.wkr" ] \
  && ok "B4: the refused rename left state files untouched" \
  || bad "B4: state was half-moved by a rename that then failed"

_dirty="$(cd "$padB/.stitchpad" && git --git-dir=stitchpad-git --work-tree=. status --short 2>/dev/null | head -1)"
[ -z "$_dirty" ] \
  && ok "B5: the refused rename left no uncommitted pad divergence" \
  || bad "B5: pad file diverges from its git history after a refused rename ($_dirty)"

echo ""
echo "=== RESULTS: $pass PASS, $fail FAIL ==="
[ "$fail" -eq 0 ] || exit 1
