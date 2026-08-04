#!/usr/bin/env bash
# rp2-directory-pathspec-gate.sh — P19: RP-2 post-commit byte verification must
# compare per-FILE blob hashes, never a pathspec against a directory tree hash.
#
# Defect (found dogfooding as a fresh operator, @kimi): sp_commit's RP-2
# capture recorded ONE hash per pathspec (`ls-files --stage -- archive` → the
# blob hash of the file inside) and verified it against `ls-tree HEAD --
# archive` — which returns the directory's TREE hash. Blob != tree, so EVERY
# real `archive` printed "write NOT committed" and skipped the readref
# re-stamp even though the commit landed cleanly (pad rewritten, ordinals
# shrunk, cursors frozen — the compact/archive cursor wound via false
# positive). Suites stayed green because rc varied (0 on first archive, 1 on
# later) and no suite asserted the absence of the failure text or the cursor
# stamp.
#
# G1: archive on a fresh pad is honest: rc==0, "✓ archived", no "NOT
#     recorded", the commit is in HEAD, and existing readref cursors are
#     re-stamped onto the post-archive HEAD.
# G2: compact (single-file pathspec) stays honest.
# G3 MUTANT: restore the per-pathspec capture in a COPY of the tool -> the
#     defect is VISIBLE again ("NOT recorded" resurfaces). A mutant patch that
#     does not apply is INCONCLUSIVE and fails the gate — never a pass.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-rp2.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s: %s\n' "$1" "$2"; fail=$((fail+1)); }

mkdir -p "$WORK/home"
export HOME="$WORK/home" STITCHPAD_HEARTBEAT_AUTOSTART=0 HERDR_URL="" HERDR_SECRET=""
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID 2>/dev/null || true

padgit() { git --git-dir="$1/.stitchpad/stitchpad-git" --work-tree="$1/.stitchpad" "${@:2}"; }

# E-17: the read cursor file is readref.<sha256(identity)[:16]>, not readref.<name>.
RR_ALICE="$(printf '%s' alice | shasum -a 256 | cut -d' ' -f1 | cut -c1-16)"

# make_pad DIR — fresh pad with alice joined, a read cursor, and 6 messages.
make_pad() {
  local d="$1"
  mkdir -p "$d"
  ( cd "$d" && "$SP" init --name rp2 >/dev/null 2>&1 )
  ( cd "$d" && STITCHPAD_NAME=alice "$SP" join alice cli pull - >/dev/null 2>&1 )
  ( cd "$d" && STITCHPAD_NAME=alice "$SP" read --new >/dev/null 2>&1 )
  local i
  for i in 1 2 3 4 5 6; do
    ( cd "$d" && STITCHPAD_NAME=alice "$SP" say "rp2 message $i" >/dev/null 2>&1 )
  done
}

echo "=== G1: archive honest on a fresh pad (directory pathspec) ==="
P1="$WORK/pad1"
make_pad "$P1"
[ -f "$P1/.stitchpad/.state/readref.$RR_ALICE" ] \
  && ok "G1a: fixture readref.$RR_ALICE exists" \
  || bad "G1a: fixture readref.$RR_ALICE exists" "read --new left no cursor"
G1_OUT="$(cd "$P1" && "$SP" archive --keep 2 2>&1)"; G1_RC=$?
[ "$G1_RC" -eq 0 ] \
  && ok "G1b: archive exits 0" \
  || bad "G1b: archive exits 0" "rc=$G1_RC out=$G1_OUT"
printf '%s' "$G1_OUT" | grep -q '✓ archived' \
  && ok "G1c: archive prints success" \
  || bad "G1c: archive prints success" "out=$G1_OUT"
printf '%s' "$G1_OUT" | grep -q 'NOT recorded' \
  && bad "G1d: no false failure text" "out=$G1_OUT" \
  || ok "G1d: no false failure text"
G1_HEAD="$(padgit "$P1" log -1 --format=%s)"
case "$G1_HEAD" in
  archive:*) ok "G1e: archive commit is HEAD" ;;
  *) bad "G1e: archive commit is HEAD" "HEAD=$G1_HEAD" ;;
esac
padgit "$P1" ls-tree -r --name-only HEAD | grep -q '^archive/.*conversation\.md$' \
  && ok "G1f: archive file committed in HEAD" \
  || bad "G1f: archive file committed in HEAD" "$(padgit "$P1" ls-tree -r --name-only HEAD)"
G1_SHA="$(padgit "$P1" rev-parse HEAD)"
if [ -f "$P1/.stitchpad/.state/readref.$RR_ALICE" ]; then
  [ "$(cat "$P1/.stitchpad/.state/readref.$RR_ALICE")" = "$G1_SHA" ] \
    && ok "G1g: readref re-stamped onto post-archive HEAD" \
    || bad "G1g: readref re-stamped onto post-archive HEAD" \
         "readref=$(cat "$P1/.stitchpad/.state/readref.$RR_ALICE") HEAD=$G1_SHA"
else
  bad "G1g: readref re-stamped onto post-archive HEAD" "readref.$RR_ALICE missing after archive"
fi

echo "=== G2: compact honest (single-file pathspec regression cover) ==="
P2="$WORK/pad2"
make_pad "$P2"
G2_OUT="$(cd "$P2" && "$SP" compact --keep 2 2>&1)"; G2_RC=$?
{ [ "$G2_RC" -eq 0 ] && printf '%s' "$G2_OUT" | grep -q '✓ compact' \
    && ! printf '%s' "$G2_OUT" | grep -q 'NOT recorded'; } \
  && ok "G2: compact rc=0, success text, no false failure" \
  || bad "G2: compact rc=0, success text, no false failure" "rc=$G2_RC out=$G2_OUT"

echo "=== G3: MUTANT — per-pathspec capture resurfaces the defect ==="
MUT="$WORK/mutant-bin"
cp -R "$ROOT/tool/bin" "$MUT"
MUT_APPLIED="$(python3 - "$MUT/lib.sh" <<'PYEOF'
import io, sys
path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()
anchor1 = "| awk -F'\\t' '{ split($1, m, \" \"); print $2 \":\" m[2] }')"
anchor2 = '_rp2_hashes="${_rp2_hashes}${_rp2_entries}"'
if src.count(anchor1) != 1 or src.count(anchor2) != 1:
    sys.stdout.write("MISSING\n")
    sys.exit(0)
src = src.replace(anchor1, "| awk '{print $2}')", 1)
src = src.replace(anchor2, '_rp2_hashes="${_rp2_hashes}${_p}:${_rp2_entries}"', 1)
io.open(path, "w", encoding="utf-8").write(src)
sys.stdout.write("APPLIED\n")
PYEOF
)"
if [ "$MUT_APPLIED" != "APPLIED" ]; then
  bad "G3: mutant patch applied" "anchor missing — INCONCLUSIVE, gate cannot self-prove"
else
  ok "G3a: mutant patch applied (per-pathspec capture restored)"
  P3="$WORK/pad3"
  make_pad "$P3"
  G3_OUT="$(cd "$P3" && "$MUT/stitchpad" archive --keep 2 2>&1)"; G3_RC=$?
  if printf '%s' "$G3_OUT" | grep -q 'NOT recorded'; then
    ok "G3b: mutant archive falsely reports failure — defect visible, gate bites"
  else
    bad "G3b: mutant archive falsely reports failure — defect visible, gate bites" \
        "rc=$G3_RC out=$G3_OUT (mutant did NOT resurface the defect — gate is blind)"
  fi
fi

echo ""
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
