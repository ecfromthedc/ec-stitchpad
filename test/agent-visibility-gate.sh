#!/usr/bin/env bash
# agent-visibility-gate.sh — invisible-agent gate (GAP 4)
#
# An agent that produces a durable effect on a pad MUST be visible in that
# pad's membership view. Before this fix: @km2 shipped 14 commits while
# completely invisible to `stitchpad roster` — a live worker doing real
# work that the operator could not see.
#
# Assertions:
#   G1: agent that posts via say → appears in roster
#   G2: agent that posts → commit author in git matches roster
#   G3: captain-side — git authors diffed vs roster → zero unknowns
#   G4: agent with session binding that posts → appears
#   G5: roster omitting a known committer is LOUD (not silent)
#   M1-M3: mutant — manual pad append bypasses say, phantom invisible
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP="$HERE/../tool/bin/stitchpad"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-avg.XXXXXX")"
cleanup() {
  for _h in "$WORK"/home-*; do
    [ -d "$_h" ] && HOME="$_h" STITCHPAD_PAD_DIR="$WORK/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }

export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

# Separate HOME dirs so terminal locks don't collide between identities.
# This is the standard fixture pattern for multi-agent pad tests.
mkdir -p "$WORK/home-op" "$WORK/home-km2" "$WORK/home-fx3"
cd "$WORK"

sp_op() {
  HOME="$WORK/home-op" STITCHPAD_PAD_DIR="$WORK/.stitchpad" \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=operator "$SP" "$@"
}
sp_km2() {
  HOME="$WORK/home-km2" STITCHPAD_PAD_DIR="$WORK/.stitchpad" \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=km2 "$SP" "$@"
}
sp_fx3() {
  HOME="$WORK/home-fx3" STITCHPAD_PAD_DIR="$WORK/.stitchpad" \
    STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=fx3 "$SP" "$@"
}
# daemon-stop between agents: the singleton daemon is per-pad, and a
# leftover fswatch from a prior agent can SIGKILL the next one (rc=137).
sp_stop() {
  for _h in "$WORK"/home-*; do
    [ -d "$_h" ] && HOME="$_h" STITCHPAD_PAD_DIR="$WORK/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  done
  sleep 0.3
}

roster_has() { sp_op roster 2>/dev/null | grep -qi "$1" 2>/dev/null; }
roster_names() { sp_op roster 2>/dev/null | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}' | sort -u; }
roster_count() {
  local _c
  _c="$(sp_op roster 2>/dev/null | grep -c '|' 2>/dev/null)" || _c=0
  _c="${_c##*[!0-9]}"   # strip any non-digit debris
  echo "${_c:-0}"
}

echo "── pad: $WORK/.stitchpad"
sp_op init --name avg >/dev/null 2>&1
sp_op daemon stop >/dev/null 2>&1 || true
sp_op join operator cli pull - >/dev/null 2>&1

pad_md="$WORK/.stitchpad/stitchpad.md"
pad_git="$WORK/.stitchpad/stitchpad-git"

# ── PRE-CONDITION ───────────────────────────────────────────────────────
echo "--- PRE: neither km2 nor fx3 in roster ---"
roster_has km2 && bad "PRE1: km2 should NOT be in roster yet" \
  || ok "PRE1: km2 not in roster (pre-condition)"
roster_has fx3 && bad "PRE2: fx3 should NOT be in roster yet" \
  || ok "PRE2: fx3 not in roster (pre-condition)"

# ── G1: agent posts via say → appears in roster ────────────────────────
echo "--- G1: agent posts via say → appears in roster ---"

sp_km2 say "roster-recovery guard gate v1" >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] && ok "G1a: km2 posted successfully" \
  || bad "G1a: km2 posted successfully (rc=$_rc)"

roster_has km2 && ok "G1b: km2 appears in roster after posting" \
  || bad "G1b: km2 appears in roster — MISSING from: $(roster_names)"

_km2_row="$(sp_op roster 2>/dev/null | grep -i 'km2' || true)"
echo "$_km2_row" | grep -q 'cli' \
  && ok "G1c: km2 adapter defaults to cli" \
  || bad "G1c: km2 adapter defaults to cli (row: $_km2_row)"

# ── G2: commit author matches roster ────────────────────────────────────
echo "--- G2: git commit author matches roster ---"

# km2's commit should carry km2 as author
_author="$(git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" log -1 --format='%an' 2>/dev/null)"
echo "$_author" | grep -qi 'km2' \
  && ok "G2a: km2 commit author is km2 (got: $_author)" \
  || bad "G2a: km2 commit author is km2 (got: $_author)"

# And km2 must be in roster
roster_has km2 && ok "G2b: commit author km2 is in roster" \
  || bad "G2b: commit author km2 is in roster — LOUD: committer km2 NOT IN ROSTER"

# ── G3: captain-side — all git authors in roster ────────────────────────
echo "--- G3: captain-side commit-author audit ---"

sp_stop   # daemon singleton: stop km2's daemon before fx3 runs

# Collect all git authors, excluding the bootstrap "stitchpad" identity.
_git_authors="$(git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" log --format='%an' 2>/dev/null | grep -vx 'stitchpad' | sort -u || true)"
_roster_names="$(roster_names || true)"

_unknown=""
while IFS= read -r _ga; do
  [ -z "$_ga" ] && continue
  if ! echo "$_roster_names" | grep -qixF "$_ga"; then
    _unknown="${_unknown:+$_unknown }$_ga"
  fi
done <<< "$_git_authors"

if [ -z "$_unknown" ]; then
  ok "G3: zero unknown non-bootstrap git committers — all authors in roster"
else
  bad "G3: UNKNOWN COMMITTERS NOT IN ROSTER:$_unknown — LOUD visibility failure"
fi
echo "  git authors (non-bootstrap): [$_git_authors]"
echo "  roster names:                [$_roster_names]"

# ── G4: second agent (fx3) with session binding → appears ───────────────
echo "--- G4: second agent via say → appears ---"

roster_has fx3 && bad "G4a: fx3 not in roster before post" \
  || ok "G4a: fx3 not in roster before post"

sp_stop
sp_fx3 say "operator-key override contract" >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] && ok "G4b: fx3 posted successfully" \
  || bad "G4b: fx3 posted successfully (rc=$_rc)"

roster_has fx3 && ok "G4c: fx3 appears in roster after posting" \
  || bad "G4c: fx3 appears in roster — MISSING from: $(roster_names)"

# ── G5: no duplicate rows after repeated posts ──────────────────────────
echo "--- G5: repeated posts → no duplicate rows ---"

_km2_count_before="$(sp_op roster 2>/dev/null | grep -ci 'km2' 2>/dev/null)" || _km2_count_before=0
_km2_count_before="${_km2_count_before##*[!0-9]}"; _km2_count_before="${_km2_count_before:-0}"
sp_stop
sp_km2 say "authority hardening v2" >/dev/null 2>&1
_fx3_count="$(sp_op roster 2>/dev/null | grep -ci 'fx3' 2>/dev/null)" || _fx3_count=0
_fx3_count="${_fx3_count##*[!0-9]}"; _fx3_count="${_fx3_count:-0}"

[ "$_km2_count_before" -eq 1 ] && ok "G5a: km2 has exactly one roster row" \
  || bad "G5a: km2 has exactly one row (count=$_km2_count_before)"
[ "$_fx3_count" -eq 1 ] && ok "G5b: fx3 has exactly one roster row" \
  || bad "G5b: fx3 has exactly one row (count=$_fx3_count)"

# ── G6: captain-side re-check with both agents ──────────────────────────
echo "--- G6: captain-side re-audit (both agents committed) ---"

_git_authors2="$(git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" log --format='%an' 2>/dev/null | grep -vx 'stitchpad' | sort -u || true)"
_roster_names2="$(roster_names || true)"

_unknown2=""
while IFS= read -r _ga; do
  [ -z "$_ga" ] && continue
  if ! echo "$_roster_names2" | grep -qixF "$_ga"; then
    _unknown2="${_unknown2:+$_unknown2 }$_ga"
  fi
done <<< "$_git_authors2"

if [ -z "$_unknown2" ]; then
  ok "G6: captain-side audit clean after 2 agents — all authors in roster"
else
  bad "G6: UNKNOWN COMMITTERS:$_unknown2 — LOUD visibility failure"
fi
echo "  git authors: [$_git_authors2]"
echo "  roster:      [$_roster_names2]"

# ── MUTANT PROOF ────────────────────────────────────────────────────────
echo "--- MUTANT: manual pad append bypasses say → invisible ---"

# Simulate the pre-fix defect: an agent runtime appends directly to pad.md
# without going through `say` (and thus without auto-registration).
echo "" >> "$pad_md"
echo "## @phantom · 00:00" >> "$pad_md"
echo "" >> "$pad_md"
echo "phantom shipped 14 commits of central work — invisible" >> "$pad_md"

grep -q 'phantom shipped' "$pad_md" 2>/dev/null \
  && ok "M1: phantom message manually injected in pad" \
  || bad "M1: phantom message manually injected"

# Phantom should NOT be in roster (never went through say/join, and
# manual appends don't trigger auto-registration in sp_commit either
# because they aren't committed through sp_commit at all).
roster_has phantom && bad "M2: phantom NOT in roster — exactly the pre-fix @km2 defect (invisible worker)" \
  || ok "M2: phantom NOT in roster — exactly the @km2 invisible-agent defect"

# km2 MUST be in roster (went through say → auto-registered)
roster_has km2 && ok "M3: km2 IS in roster (posted via say)" \
  || bad "M3: km2 NOT in roster — LOUD: registered agent invisible"

# fx3 MUST be in roster (went through say → auto-registered)
roster_has fx3 && ok "M4: fx3 IS in roster (posted via say)" \
  || bad "M4: fx3 NOT in roster — LOUD: registered agent invisible"

# Final roster count: operator + km2 + fx3 = 3 (phantom invisible)
_final_count="$(roster_count)"
[ "$_final_count" -ge 3 ] \
  && ok "M5: roster has at least 3 visible members (op+km2+fx3, count=$_final_count)" \
  || bad "M5: roster has at least 3 visible members (count=$_final_count)"

# ── G7: reconcile backfills already-invisible contributors ────────────
echo "--- G7: reconcile backfills existing invisible git authors ---"

# V1 auto-registers agents on FIRST DURABLE WRITE going forward, but
# agents like @km2 and @fx3 that committed before V1 shipped are still
# invisible.  `stitchpad reconcile` scans pad-git commit authors and
# registers any not yet in the roster.
#
# Simulate this: inject a git commit from @phantom that bypasses
# sp_commit (and thus V1), then reconcile to make phantom visible.

# Inject a phantom commit using git directly with inline author (bypasses V1).
# First, stage stitchpad.md so the commit has actual content to record.
git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" \
  add -A -- stitchpad.md 2>/dev/null || true
git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" \
  -c "user.name=phantom" -c "user.email=phantom@ocean.local" \
  commit -q -m "phantom: pre-V1 commit" >/dev/null 2>&1 \
  && ok "G7a: phantom commit injected (bypassing V1)" \
  || bad "G7a: phantom commit injected (bypassing V1)"

# Confirm phantom commit appears in git log
_git_authors3="$(git --git-dir="$pad_git" --work-tree="$WORK/.stitchpad" log --format='%an' 2>/dev/null | grep -vx 'stitchpad' | sort -u || true)"
echo "$_git_authors3" | grep -qixF 'phantom' \
  && ok "G7b: phantom appears in git log" \
  || bad "G7b: phantom appears in git log (authors: $_git_authors3)"

# Phantom must NOT be in roster (commit bypassed sp_commit/V1)
roster_has phantom && bad "G7c: phantom NOT in roster — injected via bypass" \
  || ok "G7c: phantom NOT in roster (bypassed V1, exactly like pre-fix @km2)"

# Now reconcile — this is the backfill that heals already-invisible agents
_sp_reconcile="$(sp_op reconcile 2>&1)" || true
echo "$_sp_reconcile" | grep -q 'reconciled' \
  && ok "G7d: reconcile reported success" \
  || bad "G7d: reconcile reported success (got: $_sp_reconcile)"

# After reconcile, phantom MUST be visible
sp_stop
roster_has phantom && ok "G7e: phantom IS in roster after reconcile (backfill working)" \
  || bad "G7e: phantom IS in roster after reconcile — LOUD: backfill FAILED for: $(roster_names)"

# Reconcile again — must be idempotent, no error
_sp_reconcile2="$(sp_op reconcile 2>&1)" || true
echo "$_sp_reconcile2" | grep -q 'nothing to reconcile' \
  && ok "G7f: second reconcile is idempotent (no duplicates)" \
  || bad "G7f: second reconcile is idempotent (got: $_sp_reconcile2)"

# ── VERDICT ──────────────────────────────────────────────────────────────
echo ""
if [ "$fail" -gt 0 ]; then
  echo "$fail FAILED, $pass passed"
  exit 1
fi
echo "All $pass agent-visibility gates PASSED"
exit 0
