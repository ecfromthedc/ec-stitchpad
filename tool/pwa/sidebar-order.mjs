// sidebar-order.mjs — P25: the operator can organise the sidebar.
//
// Pinning and ordering are PURE functions over (pads, prefs) so the behaviour
// can be gated without a browser. A sidebar rule that can only be checked by
// clicking is a rule nothing enforces.
//
// prefs shape:  { pinned: ["name", ...] }   // order IS the display order
// Preferences are stored PER USER (see prefsKey) — two agents sharing a browser
// profile must not inherit each other's layout.

export const prefsKey = (me) => `sp_sidebar_${me || "default"}`;

export function loadPrefs(storage, me) {
  try {
    const raw = storage?.getItem?.(prefsKey(me));
    if (!raw) return { pinned: [] };
    const p = JSON.parse(raw);
    return { pinned: Array.isArray(p?.pinned) ? p.pinned.filter(n => typeof n === "string") : [] };
  } catch { return { pinned: [] }; }
}

export function savePrefs(storage, me, prefs) {
  try {
    storage?.setItem?.(prefsKey(me), JSON.stringify({ pinned: prefs?.pinned || [] }));
    return true;
  } catch { return false; }
}

// Pinned first, in the operator's chosen order; everything else keeps the
// server's order. A pinned name that no longer exists is ignored, never dropped
// from prefs — a pad can come back (and deleting one must not silently reorder
// the rest of somebody's sidebar).
export function sidebarOrder(pads, prefs) {
  const list = Array.isArray(pads) ? pads : [];
  const byName = new Map(list.map(p => [p.name, p]));
  const pinned = (prefs?.pinned || []).filter(n => byName.has(n));
  const pinnedSet = new Set(pinned);
  return [...pinned.map(n => byName.get(n)), ...list.filter(p => !pinnedSet.has(p.name))];
}

export function isPinned(prefs, name) {
  return (prefs?.pinned || []).includes(name);
}

export function togglePin(prefs, name) {
  const pinned = [...(prefs?.pinned || [])];
  const i = pinned.indexOf(name);
  if (i >= 0) pinned.splice(i, 1); else pinned.push(name);
  return { ...prefs, pinned };
}

// Move a pinned entry to an absolute index (drag-and-drop) — clamped, so a drop
// past either end lands at the end rather than corrupting the list.
export function reorderPinned(prefs, name, toIndex) {
  const pinned = [...(prefs?.pinned || [])];
  const from = pinned.indexOf(name);
  if (from < 0) return { ...prefs, pinned };
  pinned.splice(from, 1);
  const to = Math.max(0, Math.min(toIndex, pinned.length));
  pinned.splice(to, 0, name);
  return { ...prefs, pinned };
}

// Nudge by one (keyboard / arrow buttons — drag is not reachable for everyone).
export function movePinned(prefs, name, delta) {
  const pinned = prefs?.pinned || [];
  const from = pinned.indexOf(name);
  if (from < 0) return { ...prefs, pinned: [...pinned] };
  return reorderPinned(prefs, name, from + delta);
}

// Long-press drag places a pad at an ABSOLUTE visual slot in the full list.
// Reordering by drag means the operator wants an explicit manual order, so this
// snapshots the current visible order, moves `name` to toIndex, and stores that
// whole order. After the first drop every pad has a fixed slot, so a release
// lands exactly where the finger let go — there is no pinned/unpinned split to
// reason about on a touch screen. toIndex is clamped, so a drop past the end
// lands at the end. A name not currently visible is a no-op (never corrupts the
// order). Composes sidebarOrder above, so pins already set are respected as the
// starting order.
export function placeInOrder(pads, prefs, name, toIndex) {
  const order = sidebarOrder(pads, prefs).map(p => p.name);
  const from = order.indexOf(name);
  if (from < 0) return { ...(prefs || {}), pinned: order };
  order.splice(from, 1);
  const to = Math.max(0, Math.min(toIndex, order.length));
  order.splice(to, 0, name);
  return { ...(prefs || {}), pinned: order };
}
