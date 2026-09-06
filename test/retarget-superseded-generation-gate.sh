#!/usr/bin/env bash
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
# retarget-superseded-generation-gate.sh — a submit from a superseded generation
# is ABANDONED, not unresolved, and must never block a retarget.
#
# Found live: @triage-b was rotated to a new Ocean session, the roster rebind
# failed, and `stitchpad set-wake` refused with "Ocean acceptance/cancellation
# outcome is unresolved" because a generation-27 submit sat with an empty ack
# and no turn file while the pending delivery had already advanced to
# generation 28. Deadlock: the roster went on pointing at the EXHAUSTED session,
# the delivery could not resolve because it was aimed at a dead session, and the
# only action that could fix it was the action the guard forbade.
#
# Proves:
#   G1: a submit from a SUPERSEDED generation does not block (the live shape)
#   G2: a submit at the CURRENT generation with no turn file STILL blocks
#       (the guard's real job is intact — this is not a weakening)
#   G3: an unreadable/non-numeric current generation fails CLOSED (still blocks)
#   G4: a non-numeric submit suffix fails CLOSED (still blocks)
#   G5: a superseded submit alongside a current one still blocks (the current
#       one decides; the skip must not swallow a live submit)
#
set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

source "$ROOT/tool/bin/lib.sh" 2>/dev/null || true
type sp_delivery_ocean_unresolved_after_stop >/dev/null 2>&1 || {
  echo "cannot source sp_delivery_ocean_unresolved_after_stop — aborting"; exit 1; }

echo "=== retarget-superseded-generation-gate ==="
echo ""
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-supers.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export PAD_STATE="$WORK/state"

# Rebuild the exact live shape: state=busy (not in the terminal list), pending
# adapter ocean, a submit with no turn file.
seed() {
  local name="$1" cur_gen="$2"; shift 2
  rm -rf "$PAD_STATE"; mkdir -p "$PAD_STATE"
  printf 'state=busy\ngeneration=%s\nerror_code=busy\n' "$cur_gen" > "$PAD_STATE/delivery.$name.state"
  printf '%s|1110|m1110-1|-|2026-09-06T22:05:06Z|ocean|push|old-sid\n' "$cur_gen" > "$PAD_STATE/delivery.$name.pending"
  [ "$cur_gen" = "SKIP" ] || printf '%s' "$cur_gen" > "$PAD_STATE/delivery.$name.generation"
  for g in "$@"; do printf '2026-09-06T21:54:54Z|m1099-1\n' > "$PAD_STATE/delivery.$name.submit.$g"; done
}

# G1: superseded submit (27) while current generation is 28 → must NOT block
seed tb 28 27
if sp_delivery_ocean_unresolved_after_stop tb; then
  bad "G1: a superseded generation-27 submit still blocks the retarget (the live deadlock)"
else
  ok "G1: a superseded generation-27 submit does not block a retarget"
fi

# G2: submit AT the current generation with no turn file → must STILL block
seed tb 28 28
if sp_delivery_ocean_unresolved_after_stop tb; then
  ok "G2: a current-generation submit with no turn file still blocks"
else
  bad "G2: the guard no longer blocks a live in-flight submit — this is a weakening, not a fix"
fi

# G3: no readable current generation → fail CLOSED
seed tb SKIP 27
if sp_delivery_ocean_unresolved_after_stop tb; then
  ok "G3: an unreadable current generation fails closed (still blocks)"
else
  bad "G3: an unreadable current generation let the retarget through — not fail-closed"
fi

# G4: non-numeric submit suffix → fail CLOSED
seed tb 28 "junk"
if sp_delivery_ocean_unresolved_after_stop tb; then
  ok "G4: a non-numeric submit suffix fails closed (still blocks)"
else
  bad "G4: a non-numeric submit suffix was skipped — not fail-closed"
fi

# G5: superseded AND current together → the current one still decides
seed tb 28 27 28
if sp_delivery_ocean_unresolved_after_stop tb; then
  ok "G5: a live current submit still blocks even beside a superseded one"
else
  bad "G5: the superseded skip swallowed a live current submit"
fi

echo ""
printf "%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
