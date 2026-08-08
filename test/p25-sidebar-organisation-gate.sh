#!/usr/bin/env bash
# p25-sidebar-organisation-gate.sh — P25: the operator can organise the sidebar.
#
# THE PAIN: the channel list rendered in whatever order the server returned. With
# a real fleet that is dozens of pads and no way to keep the two you care about
# at the top. No pinning, no ordering, nothing persisted.
#
# The ordering rules are PURE functions in tool/pwa/sidebar-order.mjs precisely so
# they can be gated here — a sidebar rule that can only be checked by clicking is
# a rule nothing enforces.
#
#   G1  pinned pads come first, in the operator's chosen order
#   G2  unpinned pads keep the server's order
#   G3  preferences persist and are PER USER (no cross-agent bleed)
#   G4  a pinned pad that disappears is ignored but NOT dropped from prefs
#   G5  drag-to-index is clamped (a drop past the end cannot corrupt the list)
#   G6  the sidebar actually RENDERS through sidebarOrder (wiring, not just logic)
#   G7  MUTANT: break the ordering -> G1 goes RED
#   G8  placeInOrder (long-press drag) drops a pad at the EXACT slot released,
#       for a pad with no prior position — not just an already-pinned one
#   G9  the touch long-press reorder is WIRED to placePad (mobile has no HTML5 drag)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$ROOT/tool/pwa/sidebar-order.mjs"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/p25-sidebar.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

command -v node >/dev/null 2>&1 || { echo "node is required for this gate" >&2; exit 1; }

echo "=== P25: sidebar organisation ==="
echo ""

# A tiny in-memory Storage so persistence is exercised for real, not mocked away.
cat > "$TMP/harness.mjs" <<'JS'
const mod = await import(process.argv[2]);
const { sidebarOrder, togglePin, movePinned, reorderPinned, loadPrefs, savePrefs, prefsKey } = mod;
const mem = new Map();
const storage = { getItem: k => (mem.has(k) ? mem.get(k) : null), setItem: (k, v) => mem.set(k, String(v)) };
const pads = [{ name: "alpha" }, { name: "beta" }, { name: "gamma" }, { name: "delta" }];
const names = p => sidebarOrder(pads, p).map(x => x.name).join(",");
const out = {};

let prefs = { pinned: [] };
prefs = togglePin(prefs, "gamma");
prefs = togglePin(prefs, "alpha");
out.pinnedFirst = names(prefs);                       // gamma,alpha,beta,delta
prefs = movePinned(prefs, "alpha", -1);
out.afterNudge = names(prefs);                        // alpha,gamma,beta,delta
out.unpinnedOrder = sidebarOrder(pads, prefs).slice(2).map(x => x.name).join(",");

savePrefs(storage, "ec", prefs);
savePrefs(storage, "other", { pinned: ["delta"] });
out.reloadedEc = (loadPrefs(storage, "ec").pinned || []).join(",");
out.reloadedOther = (loadPrefs(storage, "other").pinned || []).join(",");
out.keysDiffer = String(prefsKey("ec") !== prefsKey("other"));

const shrunk = [{ name: "alpha" }, { name: "beta" }];
out.missingIgnored = sidebarOrder(shrunk, prefs).map(x => x.name).join(",");
out.prefsRetained = (prefs.pinned || []).join(",");

const clamped = reorderPinned(prefs, "gamma", 99);
out.clamped = (clamped.pinned || []).join(",");
out.clampedLen = String((clamped.pinned || []).length);

// placeInOrder: long-press drag. From server order [alpha,beta,gamma,delta]
// with NO prior prefs, dropping "delta" at slot 1 must land it exactly at 1 —
// this is the flaw the live test caught: the old model jumped it to the top.
const { placeInOrder } = mod;
const fresh = { pinned: [] };
const p1 = placeInOrder(pads, fresh, "delta", 1);
out.placedMid = names(p1);                             // alpha,delta,beta,gamma
const p2 = placeInOrder(pads, fresh, "alpha", 99);
out.placedEnd = names(p2);                             // beta,gamma,delta,alpha (clamped)
const p3 = placeInOrder(pads, fresh, "ghost", 0);
out.placedGhost = names(p3);                           // unchanged server order

console.log(JSON.stringify(out));
JS

R="$(node "$TMP/harness.mjs" "$MOD" 2>/dev/null || echo '{}')"
get() { printf '%s' "$R" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || true; }

[ "$(get pinnedFirst)" = "gamma,alpha,beta,delta" ] && [ "$(get afterNudge)" = "alpha,gamma,beta,delta" ] \
  && ok "G1: pinned pads come first, in the operator's order ($(get afterNudge))" \
  || bad "G1: pinned ordering wrong (pinnedFirst=$(get pinnedFirst) afterNudge=$(get afterNudge))"

[ "$(get unpinnedOrder)" = "beta,delta" ] \
  && ok "G2: unpinned pads keep the server's order (beta,delta)" \
  || bad "G2: unpinned order changed ($(get unpinnedOrder))"

if [ "$(get reloadedEc)" = "alpha,gamma" ] && [ "$(get reloadedOther)" = "delta" ] && [ "$(get keysDiffer)" = "true" ]; then
  ok "G3: prefs persist and are per user (ec=alpha,gamma other=delta)"
else
  bad "G3: persistence/per-user bleed (ec=$(get reloadedEc) other=$(get reloadedOther) keysDiffer=$(get keysDiffer))"
fi

if [ "$(get missingIgnored)" = "alpha,beta" ] && [ "$(get prefsRetained)" = "alpha,gamma" ]; then
  ok "G4: a vanished pad is ignored in render but retained in prefs"
else
  bad "G4: vanished-pad handling wrong (render=$(get missingIgnored) prefs=$(get prefsRetained))"
fi

[ "$(get clampedLen)" = "2" ] && ok "G5: drag-to-index is clamped ($(get clamped))" \
  || bad "G5: reorder past the end corrupted the list ($(get clamped) len=$(get clampedLen))"

# G6: wiring — the pure logic is worthless if the sidebar does not call it.
if grep -q 'sidebarOrder(s.pads, s.sidebar)' "$ROOT/tool/pwa/app.js" \
   && grep -q 'from "./sidebar-order.mjs"' "$ROOT/tool/pwa/app.js" \
   && grep -q 'onDrop=' "$ROOT/tool/pwa/app.js"; then
  ok "G6: the sidebar renders through sidebarOrder and accepts drops"
else
  bad "G6: app.js does not render through sidebarOrder — the rules are unused"
fi

# G7: MUTANT — ignore pins entirely.
cp "$MOD" "$TMP/mutant.mjs"
python3 - "$TMP/mutant.mjs" <<'PY_MUT'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = '  return [...pinned.map(n => byName.get(n)), ...list.filter(p => !pinnedSet.has(p.name))];'
if s.count(old) != 1: sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(old, '  return list; // MUTANT: pins ignored'))
PY_MUT
if [ $? -eq 0 ] && grep -q 'MUTANT: pins ignored' "$TMP/mutant.mjs"; then
  RM="$(node "$TMP/harness.mjs" "$TMP/mutant.mjs" 2>/dev/null || echo '{}')"
  MO="$(printf '%s' "$RM" | python3 -c "import json,sys; print(json.load(sys.stdin).get('afterNudge',''))" 2>/dev/null || true)"
  if [ "$MO" != "alpha,gamma,beta,delta" ]; then
    ok "G7: MUTANT — pins ignored, order collapses to server order ($MO), gate bites"
  else
    bad "G7: MUTANT applied but ordering unchanged — this gate cannot see a broken sidebar"
  fi
else
  bad "G7: MUTANT DID NOT APPLY — inconclusive, never treat as a pass"
fi

# G8: placeInOrder drops at the exact released slot, for an unarranged pad.
if [ "$(get placedMid)" = "alpha,delta,beta,gamma" ] \
   && [ "$(get placedEnd)" = "beta,gamma,delta,alpha" ] \
   && [ "$(get placedGhost)" = "alpha,beta,gamma,delta" ]; then
  ok "G8: long-press drag lands a pad exactly where released (mid=$(get placedMid))"
else
  bad "G8: placeInOrder wrong (mid=$(get placedMid) end=$(get placedEnd) ghost=$(get placedGhost))"
fi

# G9: wiring — the gesture is worthless if it is not attached to placePad. On a
# phone there is NO HTML5 drag, so this touch path is the only reorder there.
if grep -q 'placeInOrder' "$ROOT/tool/pwa/app.js" \
   && grep -q 'export function placePad' "$ROOT/tool/pwa/app.js" \
   && grep -q 'addEventListener("touchmove"' "$ROOT/tool/pwa/app.js" \
   && grep -q 'placePad(dragging, target)' "$ROOT/tool/pwa/app.js"; then
  ok "G9: the touch long-press reorder is wired to placePad"
else
  bad "G9: the long-press drag is not wired — mobile reorder does nothing"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
