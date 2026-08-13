#!/usr/bin/env bash
# say-file-input-gate.sh — a coordination message must arrive as it was written.
#
# THE PAIN (field-reported, 12-hour multi-agent session): `say` took the message
# ONLY as trailing arguments, and every caller is a shell. Backticks in the text
# are command-substituted by that shell before stitchpad is exec'd, so the words
# inside them are replaced by the output of running them — usually nothing at
# all. Two coordination briefs went out that night with a token silently
# deleted: one lost `--ignored`, another lost `simulated`. Nobody noticed until
# the recipients acted on instructions that no longer said what the author
# wrote. A tool whose job is carrying messages between agents cannot quietly
# rewrite them; this is a correctness bug, not an ergonomic one.
#
# `amend` already had the answer — it takes `--file <path>`. `say` gets the same
# door, plus `-` for stdin, so a caller can hand over bytes instead of a shell
# word list.
#
#   G1  --file <path> posts the body verbatim, backticks and all
#   G2  --file - reads the body verbatim from stdin
#   G3  the trailing-args form still posts exactly as before (no caller breaks)
#   G4  --file together with trailing text is a usage error, not a silent
#       precedence rule — and nothing is posted
#   G5  --file composes with --re (the threading flag)
#   G6  --file on an unreadable path fails loudly and posts nothing
#   G7  THE INCIDENT: the same brief through the arg form loses the backticked
#       token; through --file/stdin it survives
#   G8  --file composes with --image (parse-level; images need a live relay)
#   G9  MUTANT: drop the --file branch → G1 goes RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-sayfile.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

build() {  # $1 = tool root, $2 = tag → prints pad dir
  local rt="$1" tag="$2" d="$TMP/pad.$2"
  mkdir -p "$d"
  ( cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="s$tag-a" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$rt/bin/stitchpad" init --name "sf$tag" >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="s$tag-a" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$rt/bin/stitchpad" join larry cli pull - >/dev/null 2>&1 ) || true
  printf '%s' "$d"
}
sp() {  # $1 = tool root, $2 = pad dir, rest = args
  ( cd "$2" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="s$3-a" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$1/bin/stitchpad" "${@:4}" )
}

# The exact shape that corrupted a live brief: a flag name in backticks.
BRIEF='run the suite and pass `--ignored` so the `simulated` cases still report'

echo "=== say must carry a message verbatim ==="
echo ""

P="$(build "$TOP/tool" 1)"
PAD="$P/.stitchpad/stitchpad.md"

# ── G1 --file <path> ──────────────────────────────────────────────────────
printf '%s\n' "$BRIEF" > "$TMP/brief.txt"
_out="$(sp "$TOP/tool" "$P" 1 say --file "$TMP/brief.txt" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && grep -qF -- '`--ignored`' "$PAD" && grep -qF -- '`simulated`' "$PAD"; then
  ok "G1 --file posts the body verbatim, backticks intact"
else
  bad "G1 --file did not land verbatim (rc=$_rc): $(printf '%s' "$_out" | head -2)"
fi

# ── G2 --file - (stdin) ───────────────────────────────────────────────────
_stdin_msg='stdin body with `backticked --token` preserved'
_out="$(printf '%s\n' "$_stdin_msg" | sp "$TOP/tool" "$P" 1 say --file - 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && grep -qF -- '`backticked --token`' "$PAD"; then
  ok "G2 --file - reads the body verbatim from stdin"
else
  bad "G2 --file - did not land verbatim (rc=$_rc): $(printf '%s' "$_out" | head -2)"
fi

# ── G3 the old form still works ───────────────────────────────────────────
_out="$(sp "$TOP/tool" "$P" 1 say plain trailing args still post 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && grep -qF 'plain trailing args still post' "$PAD"; then
  ok "G3 the trailing-args form is untouched — existing callers keep working"
else
  bad "G3 the trailing-args form broke (rc=$_rc): $(printf '%s' "$_out" | head -2)"
fi

# ── G4 --file + trailing text is a usage error ────────────────────────────
_before="$(wc -c < "$PAD")"
_out="$(sp "$TOP/tool" "$P" 1 say --file "$TMP/brief.txt" and also this 2>&1)"; _rc=$?
_after="$(wc -c < "$PAD")"
if [ "$_rc" -ne 0 ] && [ "$_before" = "$_after" ]; then
  ok "G4 --file plus trailing text is refused, and nothing is posted"
elif [ "$_rc" -eq 0 ]; then
  bad "G4 --file plus trailing text was silently accepted — one of the two bodies vanished without a word"
else
  bad "G4 refused but the pad changed anyway ($_before → $_after bytes)"
fi

# ── G5 composes with --re ─────────────────────────────────────────────────
_mid="$(grep -oE '#m-[a-z0-9]+' "$PAD" | head -1)"
if [ -z "$_mid" ]; then
  bad "G5 INVALID PROBE — no message id in the pad to thread against"
else
  printf 'threaded reply body\n' > "$TMP/reply.txt"
  _out="$(sp "$TOP/tool" "$P" 1 say --re "$_mid" --file "$TMP/reply.txt" 2>&1)"; _rc=$?
  if [ "$_rc" -eq 0 ] && grep -qF 'threaded reply body' "$PAD" && grep -qF "re:$_mid" "$PAD"; then
    ok "G5 --file composes with --re (the reply is threaded, the body is the file)"
  else
    bad "G5 --re + --file did not produce a threaded post (rc=$_rc): $(printf '%s' "$_out" | head -2)"
  fi
fi

# ── G6 unreadable path ────────────────────────────────────────────────────
_before="$(wc -c < "$PAD")"
_out="$(sp "$TOP/tool" "$P" 1 say --file "$TMP/does-not-exist.txt" 2>&1)"; _rc=$?
_after="$(wc -c < "$PAD")"
if [ "$_rc" -ne 0 ] && [ "$_before" = "$_after" ]; then
  ok "G6 --file on an unreadable path fails loudly and posts nothing"
else
  bad "G6 a missing --file path did not refuse cleanly (rc=$_rc, $_before → $_after bytes)"
fi

# ── G7 THE INCIDENT ───────────────────────────────────────────────────────
# Reproduce the corruption itself: the caller is a shell, so the arg form is
# evaluated before stitchpad ever runs. This is not a stitchpad bug on its own —
# it is why an arg-only interface cannot be the only interface.
P2="$(build "$TOP/tool" 2)"
PAD2="$P2/.stitchpad/stitchpad.md"
( cd "$P2" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
    STITCHPAD_TERMINAL_NAMESPACE=s2-a STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    bash -c "\"$TOP/tool/bin/stitchpad\" say $BRIEF" ) >/dev/null 2>&1
if grep -qF -- '--ignored' "$PAD2"; then
  bad "G7 INVALID PROBE — the shell did not eat the backticked token, so this gate proves nothing"
else
  ok "G7a the arg form through a shell silently deletes the backticked token (the incident)"
fi
printf '%s\n' "$BRIEF" > "$TMP/brief2.txt"
sp "$TOP/tool" "$P2" 2 say --file "$TMP/brief2.txt" >/dev/null 2>&1
if grep -qF -- '`--ignored`' "$PAD2"; then
  ok "G7b the same brief through --file arrives complete"
else
  bad "G7b --file did not rescue the brief — the corruption is still unavoidable"
fi

# ── G8 composes with --image ──────────────────────────────────────────────
# HONEST LIMIT: `--image` uploads through STITCHPAD_RELAY, so no image can
# actually be posted offline — that is why say-image.sh is baselined 0 0. What
# is checkable here is the part that could regress: the two flags PARSE
# together and the body is read, so the run reaches the relay precondition
# rather than dying as a usage/argument error. If --file ever broke --image
# parsing, this would come back as a usage error instead.
_out="$(sp "$TOP/tool" "$P" 1 say --image "$TMP/nope.png" --file "$TMP/brief.txt" 2>&1)"; _rc=$?
case "$_out" in
  *usage*|*"mutually exclusive"*)
    bad "G8 --image with --file is rejected at argument level: $(printf '%s' "$_out" | head -1)" ;;
  *)
    if [ "$_rc" -ne 0 ]; then
      ok "G8 --image and --file parse together (stopped at the relay/image precondition, not on args)"
    else
      bad "G8 --image + --file unexpectedly succeeded offline — probe is not measuring what it claims"
    fi ;;
esac

# ── G9 MUTANT ─────────────────────────────────────────────────────────────
echo "  -- mutant: say forgets --file --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/bin/stitchpad" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = '      --file)'
if s.count(old) != 1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(old, '      --file-disabled-by-mutant)', 1))
PY
if [ $? -eq 9 ]; then
  bad "G9 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  P3="$(build "$MUT" 3)"
  PAD3="$P3/.stitchpad/stitchpad.md"
  sp "$MUT" "$P3" 3 say --file "$TMP/brief.txt" >/dev/null 2>&1
  if grep -qF -- '`--ignored`' "$PAD3"; then
    bad "G9 mutant applied but the body still landed — G1 may be testing nothing"
  else
    ok "G9 without the --file branch the body never lands — G1 detects it"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "GREEN — say can be handed bytes, so a shell can no longer edit a brief in transit"
