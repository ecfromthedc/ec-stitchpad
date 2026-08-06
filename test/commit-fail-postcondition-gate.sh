#!/usr/bin/env bash
# commit-fail-postcondition-gate.sh
#
# Every command that claims a DURABLE effect must verify its post-condition and
# exit NON-ZERO when the commit does not land. Found by @kimi's cross-family
# audit: seven commands had adopted sp_commit_or_fail while FIVE still printed
# "✓" and exited 0 after an unchecked bare sp_commit — two of them additionally
# stamping every agent's read cursor onto a pre-mutation HEAD.
#
# No suite drove these under commit failure, so the family could rot back with
# all 58 suites green. This gate closes that.
#
# Method: the repo's own sanctioned hook (STITCHPAD_TEST_MODE=1 +
# STITCHPAD_TEST_COMMIT_FAIL=1, lib.sh) forces the commit to fail. Each command
# must then (a) exit non-zero, (b) not advance the commit count.
set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP="$HERE/../tool/bin/stitchpad"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-cfp.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

mkdir -p "$WORK/home"; cd "$WORK" || exit 1
export HOME="$WORK/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID 2>/dev/null || true
"$SP" init --name cfp >/dev/null 2>&1
STITCHPAD_SESSION="cfp-alice-$$" STITCHPAD_NAME=alice "$SP" join alice cli pull - >/dev/null 2>&1
STITCHPAD_SESSION="cfp-bob-$$"   STITCHPAD_NAME=bob   "$SP" join bob   cli pull - >/dev/null 2>&1
for i in $(seq 1 12); do STITCHPAD_NAME=alice "$SP" say "msg $i" >/dev/null 2>&1; done
G="$WORK/.stitchpad/stitchpad-git"
count() { git --git-dir="$G" rev-list --count HEAD 2>/dev/null || echo 0; }

probe() {
  label="$1"; shift
  before="$(count)"
  out="$(STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 STITCHPAD_NAME=alice "$SP" "$@" 2>&1)"; rc=$?
  after="$(count)"
  if printf '%s' "$out" | grep -q 'unknown command'; then
    bad "$label: INVALID PROBE (command not recognised — gate would pass for the wrong reason)"; return
  fi
  # A no-op is not evidence either way: if the command had nothing to do it never
  # reached its commit, so exit 0 proves nothing. Fail loudly rather than silently
  # scoring it — a probe that cannot run is a hole in this gate.
  if printf '%s' "$out" | grep -qiE 'nothing to (compact|archive)|only [0-9]+ messages'; then
    bad "$label: INVALID PROBE (no work to do — probe never reached the commit)"; return
  fi
  if [ "$rc" -eq 0 ]; then
    bad "$label: FALSE SUCCESS — exited 0 with the commit forced to fail"
  elif [ "$before" != "$after" ]; then
    bad "$label: commit count moved (${before}→$after) despite forced failure"
  else
    ok "$label: exits $rc, commits unchanged ($before)"
  fi
}

echo "--- durable commands under forced commit failure ---"
probe "set-wake"     set-wake alice push -
probe "rename"       rename bob bobby
probe "task migrate" task migrate
# amend and react were the two survivors of the family this gate was written for:
# both called a bare sp_commit and then printed "✓" unconditionally, so a failed
# commit left the rewritten body / the reaction line in the WORKING pad, absent
# from history, with rc=0 telling the author it landed. The next successful write
# then commits that state as though it had always been there. Not covered here
# before, which is exactly how they survived the audit that fixed the other five.
_cfp_mid="$(grep -oE '#m-[0-9a-f]+' "$WORK/.stitchpad/stitchpad.md" 2>/dev/null | head -1 | tr -d '#')"
if [ -n "$_cfp_mid" ]; then
  probe "amend" amend "$_cfp_mid" "amended under forced commit failure"
  probe "react" react "$_cfp_mid" "👍"
else
  bad "amend/react: INVALID PROBE (no message id found in the pad to target)"
  bad "react: INVALID PROBE (no message id found in the pad to target)"
fi
# compact and archive both CONSUME messages, so each needs its own fresh supply —
# otherwise whichever runs second is a no-op and proves nothing.
probe "compact"      compact --keep 2
for i in $(seq 13 26); do STITCHPAD_NAME=alice "$SP" say "msg $i" >/dev/null 2>&1; done
probe "archive"      archive --keep 1

# compact/archive additionally stamped EVERY readref onto rev-parse HEAD, which on
# a failed commit is the PRE-mutation commit. Cursors must not move when the
# mutation did not land.
echo "--- cursors must not be stamped onto a stale HEAD ---"
for i in $(seq 27 40); do STITCHPAD_NAME=alice "$SP" say "msg $i" >/dev/null 2>&1; done
STITCHPAD_NAME=alice "$SP" read --new >/dev/null 2>&1
cur_before="$(cat "$WORK/.stitchpad/.state"/readref.* 2>/dev/null | sort | tr -d '\n')"
STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 STITCHPAD_NAME=alice "$SP" compact --keep 2 >/dev/null 2>&1
cur_after="$(cat "$WORK/.stitchpad/.state"/readref.* 2>/dev/null | sort | tr -d '\n')"
if [ "$cur_before" = "$cur_after" ]; then
  ok "compact: read cursors untouched when the commit fails"
else
  bad "compact: read cursors stamped onto a stale HEAD after a failed commit"
fi

# ═══════════════════════════════════════════════════════════════════════════
# deepseek F13 — the failure MESSAGE has to be true as well as the exit code.
#
# compact and archive rewrote the pad in place and deleted every seen.<name>
# cursor BEFORE the commit check, then printed
#     "compact NOT recorded — pad unchanged, cursors untouched"
# with both halves false. Measured before the fix: seen.bob 15 → gone, pad sha
# changed, and because the rewritten pad stayed in the working tree the NEXT
# successful `say` committed it — the failed compact became permanent.
#
#   F13a/e  pad byte-identical after a failed compact / archive
#   F13b/f  every seen.* cursor still present and unchanged
#   F13c/g  the pad's working tree is CLEAN again (nothing for the next `say`
#           to commit — this is the half that made the damage durable)
#   F13d    archive's transcript file is not left half-written
#   F13h    MUTANT: neuter sp_rewrite_rollback → F13b goes RED
# ═══════════════════════════════════════════════════════════════════════════
echo "--- deepseek F13: a failed compact/archive must leave NOTHING behind ---"

f13_pad() {  # $1 = tool root, $2 = pad dir — fresh pad with a real cursor
  local rt="$1" d="$2"
  mkdir -p "$d" "$d/.h"
  ( cd "$d" || exit 1
    export HOME="$d/.h" STITCHPAD_HEARTBEAT_AUTOSTART=0
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID 2>/dev/null || true
    "$rt/bin/stitchpad" init --name f13 >/dev/null 2>&1
    STITCHPAD_NAME=alice "$rt/bin/stitchpad" join alice cli pull - >/dev/null 2>&1
    STITCHPAD_NAME=bob   "$rt/bin/stitchpad" join bob   cli pull - >/dev/null 2>&1
    for i in $(seq 1 14); do STITCHPAD_NAME=alice "$rt/bin/stitchpad" say "msg $i" >/dev/null 2>&1; done
    STITCHPAD_NAME=alice "$rt/bin/stitchpad" say "@bob please look" >/dev/null 2>&1
    STITCHPAD_NAME=bob   "$rt/bin/stitchpad" wake bob >/dev/null 2>&1 ) || true
}
f13_run() {  # $1 = tool root, $2 = pad dir, $3 = compact|archive
  ( cd "$2" || exit 1
    HOME="$2/.h" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 STITCHPAD_NAME=alice \
      "$1/bin/stitchpad" "$3" --keep 2 ) >/dev/null 2>&1
}
f13_dirty() { git --git-dir="$1/.stitchpad/stitchpad-git" --work-tree="$1/.stitchpad" status --porcelain 2>/dev/null | grep -c . || true; }

TOOLROOT="$(cd "$(dirname "$SP")/.." && pwd)"
for _cmd in compact archive; do
  D="$WORK/f13-$_cmd"; f13_pad "$TOOLROOT" "$D"
  P="$D/.stitchpad/stitchpad.md"; ST="$D/.stitchpad/.state"
  _sha0="$(shasum "$P" | cut -c1-40)"; _cur0="$(cat "$ST/seen.bob" 2>/dev/null || echo MISSING)"
  _arch0="$(ls "$D/.stitchpad/archive" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$_cur0" = "MISSING" ]; then
    bad "$_cmd: INVALID PROBE (no seen.bob cursor to lose — fixture never delivered)"
    continue
  fi
  f13_run "$TOOLROOT" "$D" "$_cmd"
  _sha1="$(shasum "$P" | cut -c1-40)"; _cur1="$(cat "$ST/seen.bob" 2>/dev/null || echo MISSING)"
  _arch1="$(ls "$D/.stitchpad/archive" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$_sha0" = "$_sha1" ] \
    && ok "$_cmd: the pad is byte-identical after the failed commit" \
    || bad "$_cmd: the pad was REWRITTEN on disk while the message said it was untouched"
  [ "$_cur0" = "$_cur1" ] \
    && ok "$_cmd: seen.bob survived ($_cur1) — 'cursors untouched' is now true" \
    || bad "$_cmd: seen.bob went $_cur0 → $_cur1 despite the message claiming otherwise"
  _d="$(f13_dirty "$D")"
  [ "${_d:-0}" -eq 0 ] \
    && ok "$_cmd: the pad's working tree is clean — the next \`say\` cannot make the failure durable" \
    || bad "$_cmd: $_d dirty path(s) left behind — the next successful commit will record the failed $_cmd"
  if [ "$_cmd" = archive ]; then
    [ "$_arch0" = "$_arch1" ] \
      && ok "archive: no half-written transcript file left behind" \
      || bad "archive: transcript files went $_arch0 → $_arch1 on a failed archive"
  fi
  # the snapshot machinery must not litter either
  _leak="$(ls -d "$ST"/.rewrite-journal.* 2>/dev/null | wc -l | tr -d ' ')"
  [ "${_leak:-0}" -eq 0 ] \
    && ok "$_cmd: no rollback snapshot left in .state" \
    || bad "$_cmd: $_leak rollback snapshot(s) leaked into .state"
done

# ── F13h MUTANT: take the rollback away and F13b must go red ───────────────
echo "  -- mutant: sp_rewrite_rollback neutered --"
MUT="$WORK/mutant"; mkdir -p "$MUT"; cp -R "$TOOLROOT/." "$MUT/" 2>/dev/null
python3 - "$MUT/bin/lib.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='sp_rewrite_rollback() {   # $1 = snapshot dir'
new='sp_rewrite_rollback() { return 0; } \nsp_rewrite_rollback_disabled() {   # $1 = snapshot dir'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "F13h MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  MD="$WORK/f13-mutant"; f13_pad "$MUT" "$MD"
  _mcur0="$(cat "$MD/.stitchpad/.state/seen.bob" 2>/dev/null || echo MISSING)"
  f13_run "$MUT" "$MD" compact
  _mcur1="$(cat "$MD/.stitchpad/.state/seen.bob" 2>/dev/null || echo MISSING)"
  _mdirty="$(f13_dirty "$MD")"
  if [ "$_mcur0" != "MISSING" ] && [ "$_mcur1" = "MISSING" ] && [ "${_mdirty:-0}" -gt 0 ]; then
    ok "F13h without the rollback the cursor is destroyed again and the pad stays dirty — these gates detect it"
  else
    bad "F13h mutant applied but nothing broke (cursor $_mcur0 → $_mcur1, dirty=$_mdirty) — these gates may be testing nothing"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "All commit-fail post-condition gates PASSED"
