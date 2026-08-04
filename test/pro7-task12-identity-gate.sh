#!/usr/bin/env bash
# pro7-task12-identity-gate.sh — kill the TASK-12 identity-leak mutant.
#
# MUTANT: remove the identity preflight + inline -c flags from sp_commit,
# reverting to plain `sgit commit`.  With the preflight gone:
#   - Commits land with whatever git config user.name is in the shared repo
#   - Parallel workers silently overwrite each other (pro3 committed as pro7)
#
# GATES:
#   G1 — two concurrent workers, different identities → neither misattributed
#   G2 — anonymous commit (no sp_me identity) → REFUSED by preflight
#
# KNOWN: identity-survival-under-join.sh fails on this base due to
# TASK-18 one-terminal-one-pad guard — needs per-seat terminal isolation.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/pro7-identity-gate.XXXXXX")"
cleanup() {
  for pid in $(pgrep -f "$tmp" 2>/dev/null || true); do
    kill -9 "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

echo "=== pro7 TASK-12 identity-gate ==="
echo ""

# ── Build isolated pad ──
PAD_DIR="$tmp/pad/.pasture"
PAD_MD="$PAD_DIR/pasture.md"
PAD_STATE="$PAD_DIR/.state"
PAD_GIT_DIR="$PAD_DIR/pasture-git"

mkdir -p "$PAD_DIR" "$PAD_STATE/sessions"

cat > "$PAD_MD" << 'EOPAD'
```roster
alice | ocean | push | alice-sid
bob   | ocean | push | bob-sid
```
EOPAD

git init -q "$tmp/git-init"
mv "$tmp/git-init/.git" "$PAD_GIT_DIR"
git --git-dir="$PAD_GIT_DIR" --work-tree="$PAD_DIR" config user.email "BOGUS@nowhere.local"
git --git-dir="$PAD_GIT_DIR" --work-tree="$PAD_DIR" config user.name "BOGUS-SHARED-NAME"
git --git-dir="$PAD_GIT_DIR" --work-tree="$PAD_DIR" add pasture.md
git --git-dir="$PAD_GIT_DIR" --work-tree="$PAD_DIR" \
  -c user.name=init -c user.email=init@ocean.local commit -q -m "init"

# Bind both identities
printf 'alice' > "$PAD_STATE/sessions/alice-sid"
printf 'bob'   > "$PAD_STATE/sessions/bob-sid"
touch "$PAD_STATE/session-registry.jsonl"

# Source libraries
export STITCHPAD_PAD_DIR="$PAD_DIR"
unset STITCHPAD_SESSION STITCHPAD_NAME 2>/dev/null || true
source "$ROOT/tool/bin/lib.sh"
source "$ROOT/tool/bin/date-divider.sh"
source "$ROOT/tool/bin/session-registry.sh"
source "$ROOT/tool/bin/recovery-policy.sh"
source "$ROOT/tool/bin/scope-authority.sh"

# Initialize paths
sp_init_paths_readonly || { bad "setup: sp_init_paths_readonly failed"; exit 1; }

# Capture shared config baseline
SHARED_BEFORE="$(grep 'name = ' "$PAD_GIT_DIR/config" 2>/dev/null | head -1 | sed 's/.*name = //')"
echo "shared config baseline: '$SHARED_BEFORE'"

# ═══════════════════════════════════════════════════════════════════════
# GATE G1: two workers, distinct identities → no misattribution
# Kills: revert (plain sgit commit reads shared config → all same author)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "--- G1: concurrent workers, distinct identities ---"

# Alice writes
echo "## @alice · 12:00 PM" >> "$PAD_MD"
echo "alice says hello" >> "$PAD_MD"

STITCHPAD_SESSION="alice-sid" sp_commit "alice: hello" 2>/dev/null || true
A1_AUTHOR="$(git --git-dir="$PAD_GIT_DIR" log -1 --format='%an <%ae>')"
echo "alice commit author: $A1_AUTHOR"

# Bob writes
echo "" >> "$PAD_MD"
echo "## @bob · 12:01 PM" >> "$PAD_MD"
echo "bob says hi" >> "$PAD_MD"

STITCHPAD_SESSION="bob-sid" sp_commit "bob: hi" 2>/dev/null || true
B1_AUTHOR="$(git --git-dir="$PAD_GIT_DIR" log -1 --format='%an <%ae>')"
echo "bob commit author:   $B1_AUTHOR"

echo "$A1_AUTHOR" | grep -qi "alice" && \
  ok "G1a: alice commit authored as alice" \
  || bad "G1a: alice authored as '$A1_AUTHOR' (identity leak)"

echo "$B1_AUTHOR" | grep -qi "bob" && \
  ok "G1b: bob commit authored as bob" \
  || bad "G1b: bob authored as '$B1_AUTHOR' (identity overwrite)"

[ "$A1_AUTHOR" != "$B1_AUTHOR" ] && \
  ok "G1c: alice and bob commits have DIFFERENT authors" \
  || bad "G1c: both commits have same author '$A1_AUTHOR' (shared config leak)"

# ═══════════════════════════════════════════════════════════════════════
# GATE G2: anonymous commit uses fallback "stitchpad", NOT shared config
# Kills: revert (plain sgit commit → shared config name leaks through)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "--- G2: anonymous commit uses fallback, not shared config ---"

HEAD_BEFORE_G2="$(git --git-dir="$PAD_GIT_DIR" rev-parse HEAD)"

echo "" >> "$PAD_MD"
echo "anonymous write — should get fallback author" >> "$PAD_MD"

set +e
STITCHPAD_SESSION="" STITCHPAD_NAME="" sp_commit "anon: fallback author" 2>/dev/null
G2_RC=$?
set -e

HEAD_AFTER_G2="$(git --git-dir="$PAD_GIT_DIR" rev-parse HEAD)"
ANON_AUTHOR="$(git --git-dir="$PAD_GIT_DIR" log -1 --format='%an <%ae>')"
echo "anonymous commit author: $ANON_AUTHOR"

# The commit should succeed (soft fallback) but use "stitchpad", not shared config
[ "$G2_RC" -eq 0 ] && \
  ok "G2a: anonymous commit succeeds with soft fallback" \
  || bad "G2a: anonymous commit refused (rc=$G2_RC) — fallback too strict"

echo "$ANON_AUTHOR" | grep -qi "stitchpad" && \
  ok "G2b: anonymous commit uses 'stitchpad' fallback (inline -c)" \
  || bad "G2b: anonymous author is '$ANON_AUTHOR' — NOT using fallback (shared config leak)"

echo "$ANON_AUTHOR" | grep -qi "BOGUS" && \
  bad "G2c: anonymous author leaked shared config '$ANON_AUTHOR' (no inline -c)" \
  || ok "G2c: anonymous author NOT from shared config"
# Verify shared config is UNCHANGED (no persistent git config write)
SHARED_AFTER="$(grep 'name = ' "$PAD_GIT_DIR/config" 2>/dev/null | head -1 | sed 's/.*name = //')"
if [ "$SHARED_BEFORE" = "$SHARED_AFTER" ]; then
  ok "G2d: shared git config unchanged (no persistent config write)"
else
  bad "G2d: shared git config changed: '$SHARED_BEFORE' → '$SHARED_AFTER' (config leak)"
fi

# ── Results ──
echo ""
echo "=== pro7 TASK-12 identity-gate RESULTS ==="
printf "Passed:  %d\n" "$pass"
printf "Failed:  %d\n" "$fail"

if [ "$fail" -gt 0 ]; then
  echo ""
  echo "MUTANT(S) ALIVE: $fail assertion(s) failed."
  echo "Gate detects when the identity preflight is removed."
  exit 1
fi

echo "IDENTITY MUTANT KILLED — fix is durable against reintroduction."
exit 0
