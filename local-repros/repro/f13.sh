#!/bin/bash
# ds F13 reproduction: compact/archive destroy cursors + rewrite the pad BEFORE
# the commit check, then claim "pad unchanged, cursors untouched".
set -u
SP="${1:-/Users/ecfromthedc/dev/rt/rt-stitchpad-prs/wt/tool/bin/stitchpad}"
CMD="${2:-compact}"
W="$(mktemp -d "${TMPDIR:-/tmp}/f13.XXXXXX")"
mkdir -p "$W/home"; cd "$W" || exit 1
export HOME="$W/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID 2>/dev/null || true
"$SP" init --name f13 >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" join alice cli pull - >/dev/null 2>&1
STITCHPAD_NAME=bob   "$SP" join bob   cli pull - >/dev/null 2>&1
for i in $(seq 1 14); do STITCHPAD_NAME=alice "$SP" say "msg $i" >/dev/null 2>&1; done
STITCHPAD_NAME=alice "$SP" say "@bob please look" >/dev/null 2>&1
# bob drains his mailbox so a real cursor exists
STITCHPAD_NAME=bob "$SP" wake bob >/dev/null 2>&1
S="$W/.stitchpad/.state"; PAD="$W/.stitchpad/stitchpad.md"
echo "cursors before : $(ls "$S" | grep '^seen\.' | tr '\n' ' ')"
echo "  seen.bob     = $(cat "$S/seen.bob" 2>/dev/null || echo '<none>')"
before_sum="$(shasum "$PAD" | cut -c1-12)"
echo "pad sha before : $before_sum"
echo "--- $CMD with the commit FORCED to fail (repo's own sanctioned seam) ---"
STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 STITCHPAD_NAME=alice "$SP" "$CMD" --keep 2 2>&1 | sed 's/^/  /'
echo "  rc=${PIPESTATUS[0]}"
echo "cursors after  : $(ls "$S" | grep '^seen\.' | tr '\n' ' ')"
echo "  seen.bob     = $(cat "$S/seen.bob" 2>/dev/null || echo '<none>')"
after_sum="$(shasum "$PAD" | cut -c1-12)"
echo "pad sha after  : $after_sum"
[ "$before_sum" = "$after_sum" ] && echo "PAD: unchanged (as claimed)" || echo "PAD: REWRITTEN despite the claim"
echo "--- and now the next successful say makes it durable ---"
STITCHPAD_NAME=alice "$SP" say "the very next message" >/dev/null 2>&1
git --git-dir="$W/.stitchpad/stitchpad-git" show HEAD:stitchpad.md 2>/dev/null | grep -c 'compacted\|Archived' | sed 's/^/  compaction markers now committed: /'
rm -rf "$W"
