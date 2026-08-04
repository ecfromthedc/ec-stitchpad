#!/usr/bin/env bash
# watcher-ordering-gate.sh — prove the watcher's auto-commit serializes
# against pad writes, preventing interleaving between teammates' posts.
#
# F3 from r3-multi-teammate: watch.sh's periodic auto-commit runs unlocked,
# so it can land between two teammates' simultaneous posts in git history.
# The committed order then doesn't match what the humans saw.
#
# Fix: watcher acquires the pad lock before auto-committing. A subshell
# isolates the lock's trap handlers from the watcher's own EXIT trap.
#
# Gates:
#   G1: watcher commits when lock is free (liveness — no regression)
#   G2: watcher SKIPS commit when a write holds the lock (serialization)
#   G3: mutant — bare sp_commit without lock DOES interleave (RED proof)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tool/bin/lib.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

# ── fixture: pad with two teammates ──────────────────────────────────────
WT="$(mktemp -d "${TMPDIR:-/tmp}/sp-ordering.XXXXXX")"
trap "rm -rf '$WT'" EXIT
PAD="$WT/pad"
mkdir -p "$PAD/.stitchpad/.state/sessions" "$PAD/.stitchpad/.state/claims"
cat > "$PAD/.stitchpad/stitchpad.md" <<'EOPAD'
```roster
alice | cli | pull | -
bob   | cli | pull | -
```
EOPAD
GD="$PAD/.stitchpad/stitchpad-git"
mkdir -p "$GD"
git --git-dir="$GD" --work-tree="$PAD/.stitchpad" init -q
git --git-dir="$GD" --work-tree="$PAD/.stitchpad" config user.email "test@test.com"
git --git-dir="$GD" --work-tree="$PAD/.stitchpad" config user.name "Test"
git --git-dir="$GD" --work-tree="$PAD/.stitchpad" add stitchpad.md
git --git-dir="$GD" --work-tree="$PAD/.stitchpad" commit -q -m "initial"

STITCHPAD_PAD_DIR="$PAD/.stitchpad" sp_init_paths

count_commits() { git --git-dir="$PAD_GIT" log --oneline 2>/dev/null | wc -l | tr -d ' '; }

# ── G1: watcher auto-commits when lock is free (liveness) ─────────────────
echo "" >> "$PAD_MD"
echo "alice: hello from G1" >> "$PAD_MD"
G1_BEFORE=$(count_commits)

( sp_lock 2>/dev/null && sp_commit "update ($(date '+%H:%M:%S'))" ) || true

G1_AFTER=$(count_commits)
if [ "$G1_AFTER" -gt "$G1_BEFORE" ]; then
  ok "G1: watcher auto-commit succeeds when lock is free (${G1_BEFORE}→${G1_AFTER} commits)"
else
  bad "G1: watcher failed to commit when lock is free (${G1_BEFORE}→${G1_AFTER})"
fi

# ── G2: watcher SKIPS auto-commit when a write holds the lock ────────────
echo "" >> "$PAD_MD"
echo "bob: G2 concurrent write data" >> "$PAD_MD"
G2_BEFORE=$(count_commits)

LOCK_DIR="$PAD_STATE/.lock"
# An EMPTY .lock dir is NOT a held lock. This release added empty-lock reclaim, which
# correctly treats an ownerless lock dir as crash residue and takes it — so the old
# `mkdir "$LOCK_DIR"` simulation tested nothing, and the "INTERLEAVING" this gate
# reported was the reclaim path working as designed. Hold the lock honestly instead:
# a background shell acquires it with the REAL sp_lock and keeps it for the assertion.
( sp_lock 2>/dev/null && { : > "$PAD_STATE/.g2-held"; sleep 30; } ) &
_G2_HOLDER=$!
for _ in $(seq 1 200); do [ -e "$PAD_STATE/.g2-held" ] && break; sleep 0.05; done
[ -e "$PAD_STATE/.g2-held" ] || bad "G2: could not acquire a real held lock"

G2_RC=0
export SP_LOCK_TIMEOUT=1
( sp_lock 2>/dev/null && sp_commit "update test G2" ) || G2_RC=$?
G2_AFTER=$(count_commits)
kill -9 "$_G2_HOLDER" 2>/dev/null || true
wait "$_G2_HOLDER" 2>/dev/null || true
rm -f "$PAD_STATE/.g2-held" 2>/dev/null || true
rm -rf "$LOCK_DIR" 2>/dev/null || true

if [ "$G2_AFTER" -eq "$G2_BEFORE" ]; then
  ok "G2: watcher deferred when lock held (no interleaving, still $G2_BEFORE commits)"
else
  bad "G2: watcher committed despite held lock (INTERLEAVING — ${G2_BEFORE}→$G2_AFTER)"
fi

# ── G3 (MUTANT): bare sp_commit DOES interleave ──────────────────────────
echo "" >> "$PAD_MD"
echo "alice: G3 post-write data" >> "$PAD_MD"
G3_BEFORE=$(count_commits)

mkdir "$LOCK_DIR" 2>/dev/null || { bad "G3: could not simulate held lock"; }

# MUTANT: bare sp_commit — the old behavior before the fix
sp_commit "update (mutant: unlocked interleave)" 2>/dev/null || true

G3_AFTER=$(count_commits)
rmdir "$LOCK_DIR" 2>/dev/null || true

if [ "$G3_AFTER" -gt "$G3_BEFORE" ]; then
  ok "G3: mutant (unlocked) interleaves — gate detects the gap (${G3_BEFORE}→${G3_AFTER})"
else
  bad "G3: mutant did NOT interleave (unexpected — sp_commit should have committed)"
fi

# ── Verdict ──────────────────────────────────────────────────────────────
echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
fi
echo "All $pass watcher-ordering gates PASSED"
exit 0
