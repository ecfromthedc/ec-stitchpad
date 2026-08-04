#!/usr/bin/env bash
# pro5-tier1-mutant-kill-demo.sh — OUTCOME-BASED v3
# 7 mutants: M1-M6 from original plan + M7 (stitchpad-git hardcode on line 856)
# Each: apply mutant → RED (gate fails) → revert → GREEN (gate passes)
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SRC="$ROOT/tool/bin/session-registry.sh"
GATE="$HERE/pro5-tier1-mutant-gates.sh"
CLEAN="/tmp/pro5-src-clean-v3.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

restore() { cp "$CLEAN" "$SRC"; }
run_gate() { MUTANT="$1" bash "$GATE" 2>&1 || true; }

killed=0; survived=0
red_results=(); green_results=()

demo() {
  local label="$1" mutant="$2" red_out green_out
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  $label"
  echo "═══════════════════════════════════════════════════════════════"

  echo "  ── RED (mutant applied) ──"
  red_out="$(run_gate "$mutant")"
  echo "$red_out"
  if echo "$red_out" | grep -q "FAIL"; then
    echo "  ${RED}>>> KILLED (gate caught the mutant)${NC}"
    killed=$((killed + 1)); red_results+=("$label: KILLED ✓")
  else
    echo "  ${YELLOW}>>> SURVIVED (gate did NOT catch)${NC}"
    survived=$((survived + 1)); red_results+=("$label: SURVIVED ✗")
  fi

  restore

  echo "  ── GREEN (clean source) ──"
  green_out="$(run_gate "$mutant")"
  echo "$green_out"
  if echo "$green_out" | grep -q "FAIL"; then
    echo "  ${RED}>>> STILL FAILS (gate broken)${NC}"
    green_results+=("$label: BROKEN ✗")
  else
    echo "  ${GREEN}>>> PASSES (gate validates fix)${NC}"
    green_results+=("$label: PASSES ✓")
  fi
}

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║   PRO5 TIER-1: 7 MUTANT KILL DEMONSTRATION (outcome-based)   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

# ── M1 ──
echo ">>> M1: Swap pasture-git ↔ stitchpad-git order"
python3 "$HERE/_m1_swap_order.py" "$SRC"
demo "M1 resolution-order" "m1"

# ── M2 ──
echo ">>> M2: Replace one git --git-dir with bare git rev-parse"
python3 "$HERE/_m2_bare_git.py" "$SRC"
demo "M2 bare-git-call" "m2"

# ── M3 (special: current code IS the mutant) ──
echo ">>> M3: PAD_DIR empty — current code is the mutant"
echo "  ── RED (current code: silent-skip) ──"
m3_red="$(run_gate "m3")"
echo "$m3_red"
if echo "$m3_red" | grep -q "FAIL"; then
  echo "  ${RED}>>> KILLED${NC}"; killed=$((killed+1)); red_results+=("M3: KILLED ✓")
else
  echo "  ${YELLOW}>>> SURVIVED${NC}"; survived=$((survived+1)); red_results+=("M3: SURVIVED ✗")
fi
python3 "$HERE/_m3_add_guard.py" "$SRC"
echo "  ── GREEN (fix applied) ──"
m3_green="$(run_gate "m3")"
echo "$m3_green"
if echo "$m3_green" | grep -q "FAIL"; then
  echo "  ${RED}>>> STILL FAILS${NC}"; green_results+=("M3: BROKEN ✗")
else
  echo "  ${GREEN}>>> PASSES${NC}"; green_results+=("M3: PASSES ✓")
fi
restore

# ── M4 ──
echo ">>> M4: journal_begin uses PAD_GIT (empty on pasture)"
python3 "$HERE/_m4_padgit_stamp.py" "$SRC"
demo "M4 empty-base-sha" "m4"

# ── M5 ──
echo ">>> M5: recover uses cached PAD_GIT"
python3 "$HERE/_m5_cached_padgit.py" "$SRC"
demo "M5 cached-PAD_GIT" "m5"

# ── M6 ──
echo ">>> M6: recover has no _git resolution"
python3 "$HERE/_m6_no_local_git.py" "$SRC"
demo "M6 standalone-recover" "m6"

# ── M7 (NEW) ──
echo ">>> M7: recover uses PAD_DIR/stitchpad-git hardcoded (line 856)"
python3 "$HERE/_m7_stitchpad_hardcode.py" "$SRC"
demo "M7 stitchpad-git-hardcode" "m7"

# ═══════ SUMMARY ═══════
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║   SUMMARY                                                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo "RED (mutant active → gate detected):"
for s in "${red_results[@]}"; do echo "  $s"; done
echo ""
echo "GREEN (fix in place → gate passed):"
for s in "${green_results[@]}"; do echo "  $s"; done
echo ""
echo "KILLED: $killed / 7    SURVIVED: $survived / 7"

restore
echo "Final: session-registry.sh restored to clean e2bcdf4"
