#!/usr/bin/env bash
# journal-quarantine-regression.sh — end-to-end proof that an exhausted
# journal recovery STOPS.
#
# THE BUG, as measured on a live pad on 2026-08-23:
#
#   stitchpad: RECOVERY EXHAUSTED for @system (journal-recovery) — 519/3
#   attempts, budget 120s; key=journal:.registry-journal.sxoQ1b; state
#   preserved for manual inspection
#   ✓ posted as @fable (#m-e8bb79)
#
# Every `stitchpad say` printed that, and the numerator climbed by one per
# post — 517, 518, 519 … 530 — against a stated maximum of 3. Four orphan
# journals were in that state, the oldest for nine days. The post itself
# always succeeded.
#
# Root cause: the orphans' stamped .base-sha had been left behind by an
# advancing pad-git HEAD, which is a PERMANENTLY unrecoverable condition —
# restoring their snapshot would revert every commit since. The refusal was
# correct. What was wrong is that nothing consumed the verdict: recovery
# re-ran on the very next command, recorded another attempt, and re-printed
# the alarm, forever. A bound that is announced but not enforced is not a
# bound.
#
# This test builds an orphan of exactly that shape and asserts the fix:
#   Q1  every say still succeeds (the bug never blocked posting, and the
#       fix must not start blocking it)
#   Q2  the terminal refusal is printed EXACTLY ONCE, not once per command
#   Q3  later commands are completely silent about the journal
#   Q4  the attempt counter stops climbing (this is the 530/3 number)
#   Q5  the orphan's bytes are still on disk — quarantine is not deletion
#   Q6  doctor names it as quarantined
#   Q7  doctor --archive-stale-journals moves it aside without deleting it
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  FAIL %s: %s\n' "$1" "${2:-}" >&2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-jq.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

WORK="$TMP/pad"; mkdir -p "$WORK"; cd "$WORK"
"$SP" init --name jq >/dev/null 2>&1 || { echo "init failed" >&2; exit 1; }
STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1 \
  || { echo "join failed" >&2; exit 1; }

PAD_DIR="$WORK/.stitchpad"
PAD_STATE="$PAD_DIR/.state"
PAD_GIT="$PAD_DIR/stitchpad-git"

say() { STITCHPAD_NAME=alice "$SP" say "$@" 2>&1; }

echo "=== journal-quarantine-regression ==="
echo ""

# Advance pad-git HEAD, then stamp an orphan against a commit that HEAD has
# already left behind — the exact live shape.
say "warm up one" >/dev/null
OLD_SHA="$(git --git-dir="$PAD_GIT" rev-parse HEAD 2>/dev/null)"
say "warm up two" >/dev/null
say "warm up three" >/dev/null
NEW_SHA="$(git --git-dir="$PAD_GIT" rev-parse HEAD 2>/dev/null)"
[ -n "$OLD_SHA" ] && [ "$OLD_SHA" != "$NEW_SHA" ] \
  || { echo "setup: HEAD did not advance" >&2; exit 1; }

ORPHAN="$PAD_STATE/.registry-journal.zzTEST"
mkdir -p "$ORPHAN"
printf '%s' "$OLD_SHA" > "$ORPHAN/.base-sha"
printf '%s' "$(cd -P "$PAD_GIT" && pwd)" > "$ORPHAN/.git-realpath"
: > "$ORPHAN/.sid"                       # live orphans had an empty sid too
printf 'orphan-bytes\n' > "$ORPHAN/0"    # something to preserve
KEY_FILE="$PAD_STATE/recovery-attempts/journal_.registry-journal.zzTEST"

# 8 posts: attempts 1,2 refuse quietly-ish, 3 crosses the bound, 4-8 must be
# silent. The live pad made ~15 posts and got 15 alarms.
NOISY=0; SILENT_TAIL_NOISE=0; POST_FAILURES=0
for i in 1 2 3 4 5 6 7 8; do
  OUT="$(say "post number $i")"; RC=$?
  [ "$RC" -eq 0 ] || POST_FAILURES=$((POST_FAILURES + 1))
  case "$OUT" in *"posted as @alice"*) ;; *) POST_FAILURES=$((POST_FAILURES + 1)) ;; esac
  case "$OUT" in *"RECOVERY EXHAUSTED"*) NOISY=$((NOISY + 1)) ;; esac
  if [ "$i" -ge 4 ]; then
    case "$OUT" in
      *"RECOVERY EXHAUSTED"*|*"stale journal"*|*"QUARANTINED"*)
        SILENT_TAIL_NOISE=$((SILENT_TAIL_NOISE + 1)) ;;
    esac
  fi
done

[ "$POST_FAILURES" -eq 0 ] \
  && ok "Q1: all 8 posts succeeded (quarantine never blocks a say)" \
  || bad "Q1: $POST_FAILURES of 8 posts failed"

[ "$NOISY" -eq 1 ] \
  && ok "Q2: RECOVERY EXHAUSTED printed exactly once across 8 posts" \
  || bad "Q2: RECOVERY EXHAUSTED printed $NOISY times (the live bug printed it every time)"

[ "$SILENT_TAIL_NOISE" -eq 0 ] \
  && ok "Q3: posts after the latch say nothing about the journal at all" \
  || bad "Q3: $SILENT_TAIL_NOISE of the last 5 posts still nagged about the journal"

COUNT="$(cut -d'|' -f1 "$KEY_FILE" 2>/dev/null || echo '?')"
[ "$COUNT" = "3" ] \
  && ok "Q4: attempt counter stopped at the bound (3/3, not 530/3)" \
  || bad "Q4: attempt counter is $COUNT after 8 posts (expected 3)"

[ -d "$ORPHAN" ] && [ -f "$ORPHAN/0" ] \
  && ok "Q5: orphan bytes preserved on disk — quarantine is not deletion" \
  || bad "Q5: the orphan was destroyed"

DOC="$("$SP" doctor 2>&1)"
case "$DOC" in
  *"QUARANTINED"*) ok "Q6: doctor names the orphan as quarantined" ;;
  *) bad "Q6: doctor did not report the quarantine" "$(printf '%s' "$DOC" | grep -A3 'Stale journals' | head -c 300)" ;;
esac

DOC2="$("$SP" doctor --archive-stale-journals 2>&1)"
if [ ! -d "$ORPHAN" ] && [ -f "$PAD_STATE/journal-archive/.registry-journal.zzTEST/0" ]; then
  ok "Q7: --archive-stale-journals moved it aside with its bytes intact"
else
  bad "Q7: archive did not relocate the orphan" "$(printf '%s' "$DOC2" | grep -A4 'Stale journals' | head -c 300)"
fi

# Post-archive: nothing left to nag about.
OUT="$(say "after archive")"
case "$OUT" in
  *"RECOVERY EXHAUSTED"*|*"stale journal"*) bad "Q8: still nagging after archive" "$OUT" ;;
  *) ok "Q8: clean stderr after the orphan is archived" ;;
esac

echo ""
echo "=== RESULTS ==="
echo "Passed:  $PASSED"
echo "Failed:  $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
echo "All journal-quarantine gates PASSED."
