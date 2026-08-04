#!/usr/bin/env bash
# tripwire-gate.sh — prove the regression-tripwire correctly classifies every
# blindness class AND that the process exit status matches the verdict.
#
# T1-T5: assert the SHIPPED tripwire exits correctly for every verdict class.
# M0-M3: mutant-proof — each blindness re-introduced, gate detects it.
# M0 is the captain's bounce case: FAILED branch exit 1 → exit 0.
#
# Verdict → expected exit:
#   GREEN         → 0
#   EXIT-CODE     → non-zero
#   INFLATED      → non-zero
#   FORMAT-DRIFT  → non-zero
#   CRASHED       → non-zero
#   REGRESSION    → non-zero
#   MORE-FAILURES → non-zero
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0

ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1 (= $2)"; else bad "$1 (expected $2, got $3)"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then ok "$1 (!= $2, got $3)"; else bad "$1 (expected != $2)"; fi
}
assert_contains() {
  if echo "$1" | grep -qF "$2"; then ok "$3"; else bad "$3 (not found: '$2')"; fi
}
has_verdict() { echo "$1" | grep -qE "^.{41}.*\b${2}\b\s*$"; }
assert_verdict() {
  if has_verdict "$1" "$2"; then ok "$3"; else bad "$3 (verdict '$2' not in STATUS column)"; fi
}
assert_no_verdict() {
  if has_verdict "$1" "$2"; then bad "$3 (forbidden '$2' found)"; else ok "$3"; fi
}

# ── fixture ──────────────────────────────────────────────────────────────

# Helper: create temp files, run tripwire, capture both stdout and exit code.
# Usage: run_tw; echo "$_tw_stdout"; cat $_tw_rcfile
# _tw_stdout, _tw_rcfile are global vars set by run_tw.
_tw_stdout=""

run_tw() {
  _tw_stdout="$(mktemp "${TMPDIR:-/tmp}/sp-tw-out.XXXXXX")"
  _tw_rcfile="$(mktemp "${TMPDIR:-/tmp}/sp-tw-rc.XXXXXX")"
  set +e
  (cd "$FIXTURE" && bash "$FIXTURE/tool/bin/regression-tripwire" >"$_tw_stdout" 2>&1; echo $? > "$_tw_rcfile")
  set -e
}
tw_rc() { cat "${_tw_rcfile:-/dev/null}" 2>/dev/null || echo 255; }
tw_stdout() { cat "${_tw_stdout:-/dev/null}" 2>/dev/null; }
tw_clean() { rm -f "${_tw_stdout:-}" "${_tw_rcfile:-}" 2>/dev/null || true; }

setup_fixture() {
  FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/sp-tripwire-gate.XXXXXX")"
  mkdir -p "$FIXTURE/tool/bin" "$FIXTURE/test"
  cp "$HERE/../tool/bin/regression-tripwire" "$FIXTURE/tool/bin/regression-tripwire"
  chmod +x "$FIXTURE/tool/bin/regression-tripwire"
  sed -i '' 's/kill -9 \$(jobs -p) 2>\/dev\/null/kill -9 \$(jobs -p) 2>\/dev\/null || true/' \
    "$FIXTURE/tool/bin/regression-tripwire"
}

write_bl() {
  # The tripwire gained a suite-level baseline + quarantine + meta-gate (P14/P16)
  # and now exits 2 ("FATAL — baseline not found") without them. This fixture
  # still wrote only pillar-baseline.txt, so EVERY case here failed with rc=2 and
  # all 21 assertions were reporting one stale interface, not 21 defects.
  cat > "$FIXTURE/test/pillar-baseline.txt" <<'BL'
pro5-tier1-mutant-gates.sh 3 0
roster-recovery-guard-regression.sh 3 0
recover-migrated-pad.sh 3 0
recovery-hardening3-regression.sh 3 0
BL
  cp "$FIXTURE/test/pillar-baseline.txt" "$FIXTURE/test/suite-baseline.txt"
  printf '# fixture: nothing quarantined\n' > "$FIXTURE/test/suite-quarantine.txt"
}


# Apply an anchored mutation and PROVE it landed. A mutation that does not apply
# is INCONCLUSIVE and must never be scored as a pass — these three were addressed
# by absolute line number ('175s/...'), so any edit to the tripwire silently
# turned them into no-ops that still "passed".
mutate() { # $1=file $2=needle $3=replacement $4=label
  python3 - "$1" "$2" "$3" <<'PY_MUT'
import sys
p,old,new=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p,encoding='utf-8').read()
if s.count(old)!=1: sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY_MUT
  if [ $? -ne 0 ]; then bad "$4: MUTATION DID NOT APPLY — inconclusive"; return 1; fi
  return 0
}

write_suite() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$FIXTURE/test/$1"
  chmod +x "$FIXTURE/test/$1"
}

echo "=== tripwire-gate ==="
echo ""

# ═════════════════════════════════════════════════════════════════════════
# T1: all GREEN — exit 0
# ═════════════════════════════════════════════════════════════════════════
echo "--- T1: all GREEN, exit 0 ---"
setup_fixture; write_bl
write_suite pro5-tier1-mutant-gates.sh          'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite roster-recovery-guard-regression.sh 'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recover-migrated-pad.sh             'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recovery-hardening3-regression.sh   'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'

run_tw; out="$(tw_stdout)"
_tw_rc="$(tw_rc)"
assert_eq "T1: exit 0" 0 "$_tw_rc"
assert_contains "$out" "TRIPWIRE: PASSED" "T1: PASSED printed"
assert_verdict "$out" "GREEN" "T1: all suites GREEN"
rm -rf "$FIXTURE"; tw_clean
echo ""

# ═════════════════════════════════════════════════════════════════════════
# T2: Mixed failures — exit non-zero
# ═════════════════════════════════════════════════════════════════════════
echo "--- T2: mixed failures, exit non-zero ---"
setup_fixture; write_bl
write_suite pro5-tier1-mutant-gates.sh          'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 1'
write_suite roster-recovery-guard-regression.sh 'echo "=== RESULTS ==="; echo "Passed:  8"; echo "Failed:  0"; exit 0'
write_suite recover-migrated-pad.sh             'echo "noise"; echo "no RESULTS"; exit 0'
write_suite recovery-hardening3-regression.sh   'echo "SIGSEGV"; exit 139'

run_tw; out="$(tw_stdout)"
_tw_rc="$(tw_rc)"
assert_ne "T2: exit non-zero" 0 "$_tw_rc"
assert_contains "$out" "TRIPWIRE: FAILED" "T2: FAILED printed"
assert_verdict "$out" "EXIT-CODE"    "T2a: exit-1 → EXIT-CODE"
assert_verdict "$out" "INFLATED"     "T2b: inflated → INFLATED"
assert_verdict "$out" "FORMAT-DRIFT" "T2c: unparseable+rc0 → FORMAT-DRIFT"
assert_verdict "$out" "CRASHED"      "T2d: unparseable+rc139 → CRASHED"
rm -rf "$FIXTURE"; tw_clean
echo ""

# ═════════════════════════════════════════════════════════════════════════
# T3: REGRESSION — exit non-zero
# ═════════════════════════════════════════════════════════════════════════
echo "--- T3: REGRESSION, exit non-zero ---"
setup_fixture; write_bl
write_suite pro5-tier1-mutant-gates.sh          'echo "=== RESULTS ==="; echo "Passed:  1"; echo "Failed:  0"; exit 0'
write_suite roster-recovery-guard-regression.sh 'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recover-migrated-pad.sh             'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recovery-hardening3-regression.sh   'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'

run_tw; out="$(tw_stdout)"
_tw_rc="$(tw_rc)"
assert_ne "T3: exit non-zero" 0 "$_tw_rc"
assert_contains "$out" "TRIPWIRE: FAILED" "T3: FAILED printed"
assert_verdict "$out" "REGRESSION" "T3: REGRESSION detected"
rm -rf "$FIXTURE"; tw_clean
echo ""

# ═════════════════════════════════════════════════════════════════════════
# T4: MORE-FAILURES — exit non-zero
# ═════════════════════════════════════════════════════════════════════════
echo "--- T4: MORE-FAILURES, exit non-zero ---"
setup_fixture; write_bl
write_suite pro5-tier1-mutant-gates.sh          'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  2"; exit 0'
write_suite roster-recovery-guard-regression.sh 'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recover-migrated-pad.sh             'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recovery-hardening3-regression.sh   'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'

run_tw; out="$(tw_stdout)"
_tw_rc="$(tw_rc)"
assert_ne "T4: exit non-zero" 0 "$_tw_rc"
assert_contains "$out" "TRIPWIRE: FAILED" "T4: FAILED printed"
assert_verdict "$out" "MORE-FAILURES" "T4: MORE-FAILURES detected"
rm -rf "$FIXTURE"; tw_clean
echo ""

# ═════════════════════════════════════════════════════════════════════════
# T5: Single-suite EXIT-CODE only — exit non-zero
# ═════════════════════════════════════════════════════════════════════════
echo "--- T5: EXIT-CODE only, exit non-zero ---"
setup_fixture; write_bl
write_suite pro5-tier1-mutant-gates.sh          'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 1'
write_suite roster-recovery-guard-regression.sh 'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recover-migrated-pad.sh             'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recovery-hardening3-regression.sh   'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'

run_tw; out="$(tw_stdout)"
_tw_rc="$(tw_rc)"
assert_ne "T5: exit non-zero" 0 "$_tw_rc"
assert_contains "$out" "TRIPWIRE: FAILED" "T5: FAILED printed"
assert_verdict "$out" "EXIT-CODE" "T5: EXIT-CODE detected"
rm -rf "$FIXTURE"; tw_clean
echo ""

# ═════════════════════════════════════════════════════════════════════════
# MUTANT PROOF
# ═════════════════════════════════════════════════════════════════════════
echo "=== MUTANT PROOF ==="
echo ""

# ═══ M0: FAILED branch exit 1 → exit 0 (THE BOUNCE CASE) ═══════════════
echo "--- M0: FAILED branch exits 0 (CAPTAIN'S MUTANT) ---"
setup_fixture; write_bl
write_suite pro5-tier1-mutant-gates.sh          'echo "=== RESULTS ==="; echo "Passed:  1"; echo "Failed:  0"; exit 0'
write_suite roster-recovery-guard-regression.sh 'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recover-migrated-pad.sh             'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recovery-hardening3-regression.sh   'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'

sed -i '' 's/^  exit 1$/  exit 0  # MUTATED: was exit 1/' "$FIXTURE/tool/bin/regression-tripwire"

run_tw; out="$(tw_stdout)"
_tw_rc="$(tw_rc)"
if [ "$_tw_rc" -eq 0 ] && echo "$out" | grep -q "TRIPWIRE: FAILED"; then
  ok "M0: gate detects FAILED+exit0 — regression-tripwire is blind (caught)"
elif [ "$_tw_rc" -ne 0 ]; then
  bad "M0: mutation did not take — exit still non-zero ($_tw_rc)"
else
  bad "M0: unexpected: exit=$_tw_rc"
fi
rm -rf "$FIXTURE"; tw_clean
echo ""

# ═══ M1: EXIT-CODE → GREEN (T-1 fix 1 blindness) ═══════════════════════
echo "--- M1: exit-code blindness ---"
setup_fixture; write_bl
write_suite pro5-tier1-mutant-gates.sh          'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 1'
write_suite roster-recovery-guard-regression.sh 'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recover-migrated-pad.sh             'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recovery-hardening3-regression.sh   'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'

mutate "$FIXTURE/tool/bin/regression-tripwire" \
  '_trap_status="EXIT-CODE"; _trap_fail=1' '_trap_status="GREEN"; _trap_fail=0' "M1"

run_tw; out="$(tw_stdout)"
_tw_rc="$(tw_rc)"
if [ "$_tw_rc" -eq 0 ]; then
  ok "M1: blind tripwire exits 0 on exit-1 suite — PROVES BLIND"
else
  bad "M1: blind tripwire exited non-zero ($_tw_rc) — unexpected"
fi
assert_no_verdict "$out" "EXIT-CODE" "M1: EXIT-CODE absent (blind)"
assert_verdict "$out" "GREEN" "M1: pro5-tier1 shows GREEN despite exit 1"
rm -rf "$FIXTURE"; tw_clean
echo ""

# ═══ M2: INFLATED → GREEN (T-1 fix 2 blindness) ════════════════════════
echo "--- M2: inflation blindness ---"
setup_fixture; write_bl
write_suite pro5-tier1-mutant-gates.sh          'echo "=== RESULTS ==="; echo "Passed:  9"; echo "Failed:  0"; exit 0'
write_suite roster-recovery-guard-regression.sh 'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recover-migrated-pad.sh             'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recovery-hardening3-regression.sh   'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'

mutate "$FIXTURE/tool/bin/regression-tripwire" \
  '_trap_status="INFLATED"; _trap_fail=1' '_trap_status="GREEN"; _trap_fail=0' "M2"

run_tw; out="$(tw_stdout)"
_tw_rc="$(tw_rc)"
if [ "$_tw_rc" -eq 0 ]; then
  ok "M2: blind tripwire exits 0 on inflated suite — PROVES BLIND"
else
  bad "M2: blind tripwire exited non-zero ($_tw_rc) — unexpected"
fi
assert_no_verdict "$out" "INFLATED" "M2: INFLATED absent (blind)"
assert_verdict "$out" "GREEN" "M2: pro5-tier1 shows GREEN despite +6 inflation"
rm -rf "$FIXTURE"; tw_clean
echo ""

# ═══ M3: FORMAT-DRIFT → SKIP, no FAILS++ (T-1 fix 3 blindness) ═════════
echo "--- M3: format-drift blindness ---"
setup_fixture; write_bl
write_suite pro5-tier1-mutant-gates.sh          'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite roster-recovery-guard-regression.sh 'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recover-migrated-pad.sh             'echo "=== RESULTS ==="; echo "Passed:  3"; echo "Failed:  0"; exit 0'
write_suite recovery-hardening3-regression.sh   'echo "no RESULTS line"; echo "just junk"; exit 0'

mutate "$FIXTURE/tool/bin/regression-tripwire" \
  '    FAILS=$((FAILS + 1))
    if [ "$obs_rc" != "0" ]; then' '    : # FAILS blinded — FORMAT-DRIFT no longer fails
    if [ "$obs_rc" != "0" ]; then' "M3-a"
mutate "$FIXTURE/tool/bin/regression-tripwire" '"FORMAT-DRIFT"' '"SKIP"' "M3-b"

run_tw; out="$(tw_stdout)"
_tw_rc="$(tw_rc)"
if [ "$_tw_rc" -eq 0 ]; then
  ok "M3: blind tripwire exits 0 despite unparseable suite — PROVES BLIND"
else
  bad "M3: blind tripwire exited non-zero ($_tw_rc) — unexpected"
fi
assert_no_verdict "$out" "FORMAT-DRIFT" "M3: FORMAT-DRIFT absent (blind)"
assert_verdict "$out" "SKIP" "M3: unparseable suite shows SKIP (blind)"
rm -rf "$FIXTURE"; tw_clean
echo ""

# ═════════════════════════════════════════════════════════════════════════
echo "=== RESULTS ==="
echo "Passed:  $pass"
echo "Failed:  $fail"
echo ""

if [ "$fail" -eq 0 ]; then
  echo "tripwire-gate: ALL GATES PASSED"
  exit 0
else
  echo "tripwire-gate: $fail GATE(S) FAILED"
  exit 1
fi
