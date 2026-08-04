#!/usr/bin/env bash
# evidence-verify-gate.sh — P7: "is it sealed?" must have ONE answer, and
# `stitchpad evidence verify` must be a VERDICT, not a printer.
#
# Defects in the pre-fix verb (@kimi, reading tool/bin/stitchpad evidence):
#   (a) verify's counters lived in a `find | while` PIPELINE subshell and were
#       never even incremented — verify printed OK/STALE/MISS but ALWAYS
#       exited 0, so scripts and CI could never trust it;
#   (b) an unsealed artifact (no .sha256 sidecar) did not affect the verdict;
#   (c) an orphan sidecar (artifact deleted) was silently ignored.
#
# G1: no evidence dir -> rc=0 with the seal hint (fresh pads are not failures)
# G2: seal -> artifact + sidecar exist; verify rc=0, summary "1 OK, 0 STALE, 0 MISSING"
# G3: tamper one byte -> verify prints STALE and exits NON-ZERO (the P7 core)
# G4: re-seal -> verify rc=0 again (the recovery path works)
# G5: delete the sidecar -> verify prints MISS and exits NON-ZERO
# G6: orphan sidecar (artifact removed) -> verify names it and exits NON-ZERO
# G7 MUTANT: neuter the failure exit in a COPY of the tool -> a tampered
#     artifact verifies rc=0 again. A mutant patch that does not apply is
#     INCONCLUSIVE and fails the gate — never a pass.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-evg.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s: %s\n' "$1" "$2"; fail=$((fail+1)); }

mkdir -p "$WORK/home"
export HOME="$WORK/home" STITCHPAD_HEARTBEAT_AUTOSTART=0 HERDR_URL="" HERDR_SECRET=""
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID 2>/dev/null || true

PAD="$WORK/pad"
mkdir -p "$PAD"
( cd "$PAD" && "$SP" init --name evg >/dev/null 2>&1 )
EV="$PAD/.stitchpad/evidence"

echo "=== G1: no evidence dir ==="
G1_OUT="$(cd "$PAD" && "$SP" evidence verify 2>&1)"; G1_RC=$?
{ [ "$G1_RC" -eq 0 ] && printf '%s' "$G1_OUT" | grep -q 'evidence seal'; } \
  && ok "G1: absent dir rc=0 with seal hint" \
  || bad "G1: absent dir rc=0 with seal hint" "rc=$G1_RC out=$G1_OUT"

echo "=== G2: seal + clean verify ==="
printf 'kimi evidence probe\n' > "$WORK/report.md"
G2_OUT="$(cd "$PAD" && "$SP" evidence seal "$WORK/report.md" 2>&1)"
{ [ -f "$EV/report.md" ] && [ -f "$EV/report.md.sha256" ]; } \
  && ok "G2a: seal creates artifact + sidecar in the canonical pad dir" \
  || bad "G2a: seal creates artifact + sidecar in the canonical pad dir" "$G2_OUT"
G2V_OUT="$(cd "$PAD" && "$SP" evidence verify 2>&1)"; G2V_RC=$?
{ [ "$G2V_RC" -eq 0 ] && printf '%s' "$G2V_OUT" | grep -q 'verify: 1 OK, 0 STALE, 0 MISSING'; } \
  && ok "G2b: clean verify rc=0 with 1-OK summary" \
  || bad "G2b: clean verify rc=0 with 1-OK summary" "rc=$G2V_RC out=$G2V_OUT"

echo "=== G3: tamper -> STALE + non-zero ==="
printf 'tampered\n' >> "$EV/report.md"
G3_OUT="$(cd "$PAD" && "$SP" evidence verify 2>&1)"; G3_RC=$?
{ [ "$G3_RC" -ne 0 ] && printf '%s' "$G3_OUT" | grep -q 'STALE'; } \
  && ok "G3: tampered artifact -> STALE, verify exits non-zero" \
  || bad "G3: tampered artifact -> STALE, verify exits non-zero" "rc=$G3_RC out=$G3_OUT"

echo "=== G4: re-seal recovers ==="
( cd "$PAD" && "$SP" evidence seal "$EV/report.md" >/dev/null 2>&1 )
# seal copies basename onto itself — seal from the tampered artifact path is a
# self-copy; instead re-seal from a fresh source to exercise the real path.
printf 'kimi evidence probe v2\n' > "$WORK/report2.md"
( cd "$PAD" && "$SP" evidence seal "$WORK/report2.md" >/dev/null 2>&1 )
rm -f "$EV/report.md" "$EV/report.md.sha256"
G4_OUT="$(cd "$PAD" && "$SP" evidence verify 2>&1)"; G4_RC=$?
{ [ "$G4_RC" -eq 0 ] && printf '%s' "$G4_OUT" | grep -q 'verify: 1 OK, 0 STALE, 0 MISSING'; } \
  && ok "G4: re-sealed set verifies rc=0" \
  || bad "G4: re-sealed set verifies rc=0" "rc=$G4_RC out=$G4_OUT"

echo "=== G5: missing sidecar -> MISS + non-zero ==="
rm -f "$EV/report2.md.sha256"
G5_OUT="$(cd "$PAD" && "$SP" evidence verify 2>&1)"; G5_RC=$?
{ [ "$G5_RC" -ne 0 ] && printf '%s' "$G5_OUT" | grep -qi 'MISS'; } \
  && ok "G5: unsealed artifact -> MISS, verify exits non-zero" \
  || bad "G5: unsealed artifact -> MISS, verify exits non-zero" "rc=$G5_RC out=$G5_OUT"

echo "=== G6: orphan sidecar -> named + non-zero ==="
printf 'deadbeef\n' > "$EV/ghost.md.sha256"
G6_OUT="$(cd "$PAD" && "$SP" evidence verify 2>&1)"; G6_RC=$?
{ [ "$G6_RC" -ne 0 ] && printf '%s' "$G6_OUT" | grep -q 'ghost.md.sha256'; } \
  && ok "G6: orphan sidecar named, verify exits non-zero" \
  || bad "G6: orphan sidecar named, verify exits non-zero" "rc=$G6_RC out=$G6_OUT"

echo "=== G7: MUTANT — neutered failure exit verifies anything rc=0 ==="
MUT="$WORK/mutant-bin"
cp -R "$ROOT/tool/bin" "$MUT"
MUT_APPLIED="$(python3 - "$MUT/stitchpad" <<'PYEOF'
import io, sys
path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()
anchor = 'if [ "$_v_stale" -gt 0 ] || [ "$_v_miss" -gt 0 ]; then'
if src.count(anchor) != 1:
    sys.stdout.write("MISSING\n")
    sys.exit(0)
src = src.replace(anchor, 'if false; then', 1)
io.open(path, "w", encoding="utf-8").write(src)
sys.stdout.write("APPLIED\n")
PYEOF
)"
if [ "$MUT_APPLIED" != "APPLIED" ]; then
  bad "G7: mutant patch applied" "anchor missing — INCONCLUSIVE, gate cannot self-prove"
else
  MPAD="$WORK/mpad"
  mkdir -p "$MPAD"
  ( cd "$MPAD" && "$MUT/stitchpad" init --name evgm >/dev/null 2>&1 )
  printf 'mutant probe\n' > "$WORK/mreport.md"
  ( cd "$MPAD" && "$MUT/stitchpad" evidence seal "$WORK/mreport.md" >/dev/null 2>&1 )
  printf 'tampered\n' >> "$MPAD/.stitchpad/evidence/mreport.md"
  G7_OUT="$(cd "$MPAD" && "$MUT/stitchpad" evidence verify 2>&1)"; G7_RC=$?
  if [ "$G7_RC" -eq 0 ]; then
    ok "G7: mutant verify exits 0 on a tampered artifact — defect visible, gate bites"
  else
    bad "G7: mutant verify exits 0 on a tampered artifact — defect visible, gate bites" \
        "rc=$G7_RC out=$G7_OUT (mutant still refuses — gate may be blind)"
  fi
fi

echo ""
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
