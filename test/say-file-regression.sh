#!/usr/bin/env bash
# say-file-regression.sh — `stitchpad say --file <path|->`
#
# WHY. An orchestrator driving several seats posts long multi-paragraph status
# updates from a script. Until now the only route was inline text, so every
# body went through the shell first: backticks, $(...), quotes and newlines in
# a report all had to survive a heredoc before they reached the pad. `amend`
# has accepted --file since it existed; `say` — the command an orchestrator
# actually calls — did not.
#
# Gates:
#   F1  --file posts the file's bytes
#   F2  shell metacharacters survive verbatim (nothing is expanded)
#   F3  multi-paragraph structure survives
#   F4  --file - reads stdin
#   F5  --file plus inline text is refused (one body, one source)
#   F6  --file with no argument is refused
#   F7  --file with an unreadable path is refused, and says which path
#   F8  --file with an empty body is refused (a silent empty post is worse)
#   F9  inline `say` is untouched
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  FAIL %s: %s\n' "$1" "${2:-}" >&2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-sf.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

WORK="$TMP/pad"; mkdir -p "$WORK"; cd "$WORK"
"$SP" init --name sf >/dev/null 2>&1 || { echo "init failed" >&2; exit 1; }
STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1 || { echo "join failed" >&2; exit 1; }
PAD_MD="$WORK/.stitchpad/stitchpad.md"

echo "=== say-file-regression ==="
echo ""

BODY="$TMP/body.md"
cat > "$BODY" <<'BODYEOF'
Round 3 closeout: kimi and glm both landed.

Traps found: `$(rm -rf /)` in a heredoc, a bare "quote, and a 'single' one.
Cost line: $1,200 — 100% of budget.

- glm: merged
- kimi: merged
BODYEOF

OUT="$(STITCHPAD_NAME=alice "$SP" say --file "$BODY" 2>&1)"; RC=$?
case "$OUT" in *"posted as @alice"*) ok "F1: --file posts (rc=$RC)" ;;
  *) bad "F1: --file did not post" "$OUT" ;; esac

if grep -qF '`$(rm -rf /)`' "$PAD_MD" && grep -qF "a 'single' one" "$PAD_MD"; then
  ok "F2: shell metacharacters survive verbatim (no expansion)"
else
  bad "F2: body was mangled by the shell" "$(grep -c 'rm -rf' "$PAD_MD" 2>/dev/null)"
fi

if grep -qF 'Round 3 closeout' "$PAD_MD" && grep -qF -- '- kimi: merged' "$PAD_MD"; then
  ok "F3: multi-paragraph structure survives first line to last"
else
  bad "F3: paragraphs lost"
fi

OUT="$(printf 'from stdin: %s\n' 'piped body' | STITCHPAD_NAME=alice "$SP" say --file - 2>&1)"
if grep -qF 'from stdin: piped body' "$PAD_MD"; then ok "F4: --file - reads stdin"
else bad "F4: stdin body not posted" "$OUT"; fi

OUT="$(STITCHPAD_NAME=alice "$SP" say --file "$BODY" and also inline 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && case "$OUT" in *"mutually exclusive"*) true ;; *) false ;; esac; then
  ok "F5: --file plus inline text refused"
else bad "F5: ambiguous body accepted (rc=$RC)" "$OUT"; fi

OUT="$(STITCHPAD_NAME=alice "$SP" say --file 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "F6: bare --file refused (rc=$RC)" || bad "F6: bare --file accepted" "$OUT"

OUT="$(STITCHPAD_NAME=alice "$SP" say --file "$TMP/nope.md" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && case "$OUT" in *"nope.md"*) true ;; *) false ;; esac; then
  ok "F7: unreadable --file refused and names the path"
else bad "F7: missing file not refused clearly (rc=$RC)" "$OUT"; fi

: > "$TMP/empty.md"
OUT="$(STITCHPAD_NAME=alice "$SP" say --file "$TMP/empty.md" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && case "$OUT" in *"empty"*) true ;; *) false ;; esac; then
  ok "F8: empty --file refused"
else bad "F8: empty body posted (rc=$RC)" "$OUT"; fi

OUT="$(STITCHPAD_NAME=alice "$SP" say plain inline message 2>&1)"
case "$OUT" in *"posted as @alice"*) ok "F9: inline say still works" ;;
  *) bad "F9: inline say regressed" "$OUT" ;; esac
grep -qF 'plain inline message' "$PAD_MD" || bad "F9b: inline body missing from pad"

echo ""
echo "=== RESULTS ==="
echo "Passed:  $PASSED"
echo "Failed:  $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
echo "All say --file gates PASSED."
