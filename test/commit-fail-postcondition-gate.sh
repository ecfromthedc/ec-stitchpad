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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "All commit-fail post-condition gates PASSED"
