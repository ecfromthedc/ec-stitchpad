#!/usr/bin/env bash
# pad-visibility-gate.sh — prove P5+P7 pad visibility tier
#
# P5: a pad with missing/broken pad git must FAIL LOUD
# P7: evidence has one canonical home + list/verify/seal against .sha256 sidecars
#
# Gates:
#   G1:  roster on deleted-stitchpad-git exits non-zero, prints cause
#   G2:  whoami on deleted-stitchpad-git exits non-zero
#   G3:  doctor on deleted-stitchpad-git exits non-zero, reports MISSING
#   G4:  corrupt pad git (empty dir, not a repo) exits non-zero
#   G5:  healthy pad git — all commands work normally (no regression)
#   G6:  evidence list shows sealed artifact with OK status
#   G7:  evidence verify detects STALE (tampered) evidence
#   G8:  evidence seal creates non-empty .sha256 sidecar
#   M1:  mutant — old blind code: roster exits 0 on deleted git (PROVES BLIND)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

assert_ne() {
  if [ "$2" != "$3" ]; then ok "$1 (exit=$3)"; else bad "$1 (expected != $2)"; fi
}
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2, got $3)"; fi
}
assert_contains() {
  if echo "$1" | grep -qF "$2"; then ok "$3"; else bad "$3 (not found: '$2')"; fi
}

SP="$ROOT/tool/bin/stitchpad"

# ── helpers ──────────────────────────────────────────────────────────────
fresh_pad() {
  local label="$1"
  WT="$(mktemp -d "${TMPDIR:-/tmp}/sp-vis.${label}.XXXXXX")"
  mkdir -p "$WT/$label"
  ( cd "$WT/$label" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_WATCH_START_GRACE=0 \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" init --name "$label" 2>/dev/null )
  sleep 0.5
}

kill_pad() {
  # Kill only the watcher we spawned for this pad
  local wp
  wp="$(cat "$WT/.watcher-pid" 2>/dev/null || true)"
  [ -n "$wp" ] && kill "$wp" 2>/dev/null || true
  sleep 0.2
  # Force-unlock any leftover lock
  rm -f "$PAD_DIR/.state/.lock/owner" 2>/dev/null || true
  rmdir "$PAD_DIR/.state/.lock" 2>/dev/null || true
}

run_sp() {
  local pad="$1" cmd="$2" arg1="${3:-}" arg2="${4:-}"
  ( cd "$pad" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_WATCH_START_GRACE=0 \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" "$cmd" ${arg1:+"$arg1"} ${arg2:+"$arg2"} 2>&1; echo "EXIT=$?" )
}

echo "=== pad-visibility-gate ==="
echo ""

# ═════════════════════════════════════════════════════════════════════════
# G1: roster on deleted pad git exits non-zero
# ═════════════════════════════════════════════════════════════════════════
echo "--- G1: roster on deleted pad git ---"
fresh_pad g1
rm -rf "$WT/g1/.stitchpad/stitchpad-git"
out="$(run_sp "$WT/g1" roster)"
assert_ne "G1: roster exit non-zero" 0 "$(echo "$out" | grep EXIT= | sed 's/EXIT=//')"
assert_contains "$out" "missing" "G1: names missing pad git"
rm -rf "$WT"
echo ""

# ═════════════════════════════════════════════════════════════════════════
# G2: whoami on deleted pad git exits non-zero
# ═════════════════════════════════════════════════════════════════════════
echo "--- G2: whoami on deleted pad git ---"
fresh_pad g2
rm -rf "$WT/g2/.stitchpad/stitchpad-git"
out="$(run_sp "$WT/g2" whoami)"
assert_ne "G2: whoami exit non-zero" 0 "$(echo "$out" | grep EXIT= | sed 's/EXIT=//')"
assert_contains "$out" "missing" "G2: names missing pad git"
rm -rf "$WT"
echo ""

# ═════════════════════════════════════════════════════════════════════════
# G3: doctor on deleted pad git exits non-zero, reports MISSING
# ═════════════════════════════════════════════════════════════════════════
echo "--- G3: doctor on deleted pad git ---"
fresh_pad g3
rm -rf "$WT/g3/.stitchpad/stitchpad-git"
out="$(run_sp "$WT/g3" doctor)"
assert_ne "G3: doctor exit non-zero" 0 "$(echo "$out" | grep EXIT= | sed 's/EXIT=//')"
assert_contains "$out" "missing" "G3: reports missing pad git"
rm -rf "$WT"
echo ""

# ═════════════════════════════════════════════════════════════════════════
# G4: corrupt pad git (empty dir) exits non-zero
# ═════════════════════════════════════════════════════════════════════════
echo "--- G4: corrupt pad git (empty dir) ---"
fresh_pad g4
rm -rf "$WT/g4/.stitchpad/stitchpad-git"
mkdir "$WT/g4/.stitchpad/stitchpad-git"
out="$(run_sp "$WT/g4" roster)"
assert_ne "G4: roster on corrupt git exit non-zero" 0 "$(echo "$out" | grep EXIT= | sed 's/EXIT=//')"
assert_contains "$out" "corrupt" "G4: names corrupt pad git"
rm -rf "$WT"
echo ""

# ═════════════════════════════════════════════════════════════════════════
# G5: healthy pad — normal operation (no regression)
# ═════════════════════════════════════════════════════════════════════════
echo "--- G5: healthy pad, normal operation ---"
fresh_pad g5
out="$(run_sp "$WT/g5" roster)"
assert_eq "G5: roster exit 0" 0 "$(echo "$out" | grep EXIT= | sed 's/EXIT=//')"
out2="$(run_sp "$WT/g5" doctor)"
assert_contains "$out2" "pad git healthy" "G5: doctor shows healthy pad git"
rm -rf "$WT"
echo ""

# ═════════════════════════════════════════════════════════════════════════
# G6: evidence list shows sealed artifact with OK status
# ═════════════════════════════════════════════════════════════════════════
echo "--- G6: evidence list with sealed artifact ---"
fresh_pad g6
echo "test evidence content" > "$WT/g6/test-evid.md"
out="$(run_sp "$WT/g6" evidence seal "$WT/g6/test-evid.md")"
assert_contains "$out" "sealed" "G6a: seal reports success"
out2="$(run_sp "$WT/g6" evidence list)"
assert_contains "$out2" "test-evid.md" "G6b: lists sealed evidence"
assert_contains "$out2" "OK" "G6c: evidence verifies OK"
rm -rf "$WT"
echo ""

# ═════════════════════════════════════════════════════════════════════════
# G7: evidence verify detects STALE (tampered)
# ═════════════════════════════════════════════════════════════════════════
echo "--- G7: tampered evidence detected ---"
fresh_pad g7
echo "original content" > "$WT/g7/tamper.md"
run_sp "$WT/g7" evidence seal "$WT/g7/tamper.md" >/dev/null
echo "TAMPERED" >> "$WT/g7/.stitchpad/evidence/tamper.md"
out="$(run_sp "$WT/g7" evidence verify)"
assert_contains "$out" "STALE" "G7: tampered evidence shows STALE"
rm -rf "$WT"
echo ""

# ═════════════════════════════════════════════════════════════════════════
# G8: evidence seal creates non-empty .sha256 sidecar
# ═════════════════════════════════════════════════════════════════════════
echo "--- G8: evidence seal creates sidecar ---"
fresh_pad g8
echo "sidecar test" > "$WT/g8/sidecar.md"
run_sp "$WT/g8" evidence seal "$WT/g8/sidecar.md" >/dev/null
sidecar="$WT/g8/.stitchpad/evidence/sidecar.md.sha256"
if [ -f "$sidecar" ] && [ -s "$sidecar" ]; then
  ok "G8: .sha256 sidecar exists and non-empty"
else
  bad "G8: .sha256 sidecar missing or empty"
fi
rm -rf "$WT"
echo ""

# ═════════════════════════════════════════════════════════════════════════
# MUTANT PROOF
# ═════════════════════════════════════════════════════════════════════════
echo "=== MUTANT PROOF ==="

# M1: remove the P5 git checks from sp_init_paths_readonly, proving the
# old code was blind: roster on a deleted-stitchpad-git exits 0 silently.
echo "--- M1: old blind code — roster silent on deleted git ---"

fresh_pad m1
rm -rf "$WT/m1/.stitchpad/stitchpad-git"

# Create mutated lib: strip the P5 block from sp_init_paths_readonly
MUT_LIB="$WT/m1-mut-lib.sh"
python3 - "$ROOT/tool/bin/lib.sh" "$MUT_LIB" <<'PY'
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
# Remove the two P5 if-blocks: the missing-git check and the corrupt-git check.
# They are back-to-back after the symlink check, each a multi-line if/fi block.
# Use a regex that matches from "# P5:" comment through both closing "fi"s.
content = re.sub(
    r'\n  # P5:.*?\n  fi\n  # P5:.*?\n  fi\n',
    '\n',
    content,
    flags=re.DOTALL
)
with open(sys.argv[2], 'w') as f:
    f.write(content)
PY

# Run roster using the mutated lib
MUT_OUT="$(cd "$WT/m1" && STITCHPAD_HOME="$ROOT/tool" STITCHPAD_WATCH_START_GRACE=0 \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 \
    bash -c "source '$MUT_LIB'; STITCHPAD_PAD_DIR='$WT/m1/.stitchpad' sp_init_paths_readonly && sp_roster; echo EXIT=\$?" 2>&1)"

MUT_EXIT="$(echo "$MUT_OUT" | grep EXIT= | sed 's/EXIT=//')"
if [ "$MUT_EXIT" = "0" ]; then
  ok "M1: mutant (blind) roster exits 0 on deleted git — PROVES BLIND"
else
  bad "M1: mutant roster still exits non-zero ($MUT_EXIT) — mutation may not have applied"
fi
rm -rf "$WT" "$MUT_LIB"
echo ""

# ═════════════════════════════════════════════════════════════════════════
echo "=== RESULTS ==="
echo "Passed:  $pass"
echo "Failed:  $fail"
echo ""
if [ "$fail" -eq 0 ]; then
  echo "pad-visibility-gate: ALL GATES PASSED"
  exit 0
else
  echo "pad-visibility-gate: $fail GATE(S) FAILED"
  exit 1
fi
