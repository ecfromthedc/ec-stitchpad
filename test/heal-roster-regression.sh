#!/usr/bin/env bash
# heal-roster-regression.sh — pro8: heal-roster implementation gates
# Covers: (1) heal-roster recovers roster from pad git history end-to-end,
#         (2) unknown commands exit non-zero,
#         (3) heal-roster post-condition verification,
#         (4) heal-roster refuses when no history exists.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  FAIL %s: %s\n' "$1" "${2:-}" >&2; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

cleanup() { rm -rf "$TMP"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-hr.XXXXXX")"
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID

# ===========================================================================
# H1: Unknown command must exit non-zero
# ===========================================================================
echo "=== H1: unknown command exits non-zero ==="
echo ""

H1_OUT="$("$SP" nonexistent-command-zzz 2>&1)" || H1_RC=$?
if [ "${H1_RC:-0}" -ne 0 ]; then ok "H1a: unknown command exits non-zero (rc=$H1_RC)"
else bad "H1a: unknown command exited 0 — false success"; fi

if echo "$H1_OUT" | grep -qi 'unknown command'; then ok "H1b: unknown command diagnostic mentions 'unknown command'"
else bad "H1b: no 'unknown command' diagnostic" "$(printf '%s' "$H1_OUT" | head -c 80)"; fi

# ===========================================================================
# H2: heal-roster end-to-end: clobber → say refuses → heal → say works
# ===========================================================================
echo ""
echo "=== H2: heal-roster end-to-end ==="
echo ""

H2_WORK="$TMP/h2"; mkdir -p "$H2_WORK"
cd "$H2_WORK"

# Set up a pad with members
"$SP" init --name h2 >/dev/null 2>&1 || { bad "H2_init" "init failed"; }
STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1 || { bad "H2_join1" "join failed"; }
STITCHPAD_NAME=bob "$SP" join bob codex pull - >/dev/null 2>&1 || { bad "H2_join2" "join failed"; }

PAD_MD="$H2_WORK/.stitchpad/stitchpad.md"
PAD_GIT="$H2_WORK/.stitchpad/stitchpad-git"
_commit_count="$(git --git-dir="$PAD_GIT" rev-list --count HEAD 2>/dev/null || echo 0)"
check "H2a: commits before clobber" "3" "$_commit_count"

# Clobber the roster (remove the fence block entirely)
python3 - "$PAD_MD" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'```roster\n.*?```\n', '', s, flags=re.S)
open(sys.argv[1], 'w').write(s)
PY

# H2b: say must refuse after clobber
H2B_OUT="$(STITCHPAD_NAME=alice "$SP" say alice "post clobber" 2>&1)" || H2B_RC=$?
if [ "${H2B_RC:-0}" -ne 0 ]; then ok "H2b: say refuses after roster clobber (rc=$H2B_RC)"
else bad "H2b: say succeeded after clobber — false success"; fi

# H2c: refusal names heal-roster
if echo "$H2B_OUT" | grep -q 'heal-roster'; then ok "H2c: say refusal names heal-roster"
else bad "H2c: say refusal does not name heal-roster" "$H2B_OUT"; fi

# H2d: heal-roster recovers the roster
H2D_OUT="$("$SP" heal-roster 2>&1)" || H2D_RC=$?
if [ "${H2D_RC:-0}" -eq 0 ]; then ok "H2d: heal-roster succeeds (rc=0)"
else bad "H2d: heal-roster failed" "$(printf '%s' "$H2D_OUT" | head -c 160)"; fi

# H2e: heal-roster reports what it restored
if echo "$H2D_OUT" | grep -q '✓ roster healed'; then ok "H2e: heal-roster reports success with 'roster healed'"
else bad "H2e: heal-roster output missing 'roster healed'" "$H2D_OUT"; fi

# H2f: roster is actually present after heal
if grep -q '^```roster[[:space:]]*$' "$PAD_MD" 2>/dev/null; then ok "H2f: roster fence present after heal"
else bad "H2f: roster fence still missing after heal"; fi

# H2g: roster has members (both alice and bob recovered)
_member_count="$(grep -c '^alice |\|^bob |' "$PAD_MD" 2>/dev/null || echo 0)"
check "H2g: roster has 2 members after heal" "2" "$_member_count"

# H2h: heal-roster produced a durable commit
_post_commit_count="$(git --git-dir="$PAD_GIT" rev-list --count HEAD 2>/dev/null || echo 0)"
if [ "$_post_commit_count" -gt "$_commit_count" ]; then ok "H2h: heal-roster commit landed (commits: $_commit_count → $_post_commit_count)"
else bad "H2h: heal-roster produced no commit (still $_post_commit_count)"; fi

# H2i: say works after heal
H2I_OUT="$(STITCHPAD_NAME=alice "$SP" say alice "post heal" 2>&1)" || H2I_RC=$?
if [ "${H2I_RC:-0}" -eq 0 ]; then ok "H2i: say works after heal-roster"
else bad "H2i: say still fails after heal" "$H2I_OUT"; fi

if echo "$H2I_OUT" | grep -q 'posted'; then ok "H2j: say prints 'posted' after heal"
else bad "H2j: say did not print 'posted'" "$H2I_OUT"; fi


	# H2k: healed pad has correct STRUCTURE — the --- separator must exist
	# between the roster closing fence and the body (not just membership count).
	# A missing separator means the roster fence runs directly into the header.
	# This gate catches the bash 3.2 printf '---\n\n' bug where --- is parsed
	# as an option and silently dropped.
	_has_sep=0
	if awk '
	  /^```roster/ { in_r=1; next }
	  in_r && /^```/ { in_r=0; after_r=1; next }
	  after_r && /^[[:space:]]*$/ { next }
	  after_r && /^---[[:space:]]*$/ { found=1; exit }
	  after_r && /^# / { exit }
	  END { if (found) exit 0; else exit 1 }
	' "$PAD_MD" 2>/dev/null; then
	  _has_sep=1
	fi
	if [ "$_has_sep" -eq 1 ]; then ok "H2k: healed pad has --- separator between roster and body"
	else bad "H2k: healed pad MISSING --- separator — roster fence runs directly into body (bash 3.2 printf bug)"; fi

	# H2l: healed pad header is present and correct (not missing due to printf failure)
	if head -1 "$PAD_MD" | grep -q '^# 🧵 #'; then ok "H2l: healed pad starts with correct header (# 🧵 #)"
	else bad "H2l: healed pad header missing or malformed" "$(head -1 "$PAD_MD")"; fi
cd "$ROOT"

# ===========================================================================
# H3: heal-roster refuses when no git history exists
# ===========================================================================
echo ""
echo "=== H3: heal-roster with no history ==="
echo ""

H3_WORK="$TMP/h3"; mkdir -p "$H3_WORK"
mkdir -p "$H3_WORK/.stitchpad/.state"
H3_MD="$H3_WORK/.stitchpad/stitchpad.md"

# Create a pad file with NO git history and NO roster
cat > "$H3_MD" <<'EOPAD'
# test pad
no roster here
EOPAD

H3D_OUT="$(HOME="$TMP/home" STITCHPAD_PAD_DIR="$H3_WORK/.stitchpad" \
  STITCHPAD_HOME="$ROOT/tool" "$SP" heal-roster 2>&1)" || H3_RC=$?
if [ "${H3_RC:-0}" -ne 0 ]; then ok "H3a: heal-roster without git exits non-zero"
else bad "H3a: heal-roster without git exited 0 — false success"; fi

if echo "$H3D_OUT" | grep -qi 'no.*history\|cannot heal'; then ok "H3b: heal-roster diagnostic when no git history"
else bad "H3b: no diagnostic for missing git history" "$H3D_OUT"; fi

cd "$ROOT"

# ===========================================================================
# H4: heal-roster idempotent (already healed → no-op)
# ===========================================================================
echo ""
echo "=== H4: heal-roster idempotent ==="
echo ""

H4_WORK="$TMP/h4"; mkdir -p "$H4_WORK"
cd "$H4_WORK"

"$SP" init --name h4 >/dev/null 2>&1
STITCHPAD_NAME=alice "$SP" join alice codex pull - >/dev/null 2>&1

H4_COMMITS_BEFORE="$(git --git-dir="$H4_WORK/.stitchpad/stitchpad-git" rev-list --count HEAD 2>/dev/null || echo 0)"

# Run heal-roster when roster is already healthy
H4_OUT="$("$SP" heal-roster 2>&1)" || H4_RC=$?
if [ "${H4_RC:-0}" -eq 0 ]; then ok "H4a: heal-roster on healthy pad exits 0"
else bad "H4a: heal-roster on healthy pad exited non-zero" "$H4_OUT"; fi

if echo "$H4_OUT" | grep -qi 'already present\|nothing to heal'; then ok "H4b: heal-roster reports 'already present' on healthy pad"
else bad "H4b: unexpected heal-roster output on healthy pad" "$H4_OUT"; fi

# H4c: no extra commit produced (idempotent)
H4_COMMITS_AFTER="$(git --git-dir="$H4_WORK/.stitchpad/stitchpad-git" rev-list --count HEAD 2>/dev/null || echo 0)"
check "H4c: heal-roster on healthy pad produces no extra commit" "$H4_COMMITS_BEFORE" "$H4_COMMITS_AFTER"

cd "$ROOT"

# ===========================================================================
printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll heal-roster gates PASSED.\n'; exit 0; }
printf '\nSome heal-roster gates FAILED.\n'; exit 1
