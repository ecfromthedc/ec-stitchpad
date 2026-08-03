#!/usr/bin/env bash
# recovery-hardening3-regression.sh — TASK-5-follow-on: recovery round-3
# hardening, defending flash's re-attack-2 escalations E1/E2/E3.
#
# Proves:
#   E1: leave-path sid confusion FIXED — journal stamps exact file paths at
#       begin time (.paths), so recovery replays them regardless of the
#       recovering caller's env sid. Operator sid rows never bleed into
#       target sid rows.
#   E2a: base-SHA refusal records an attempt BEFORE continuing — repeated
#        refusals eventually hit the attempt bound (no infinite refusal).
#   E2b: crash-after-commit (own commit landed, live content matches HEAD
#        exactly) is archived instead of refused forever. An UNRELATED
#        commit advancing HEAD by one (R3's shape — live content still
#        diverges from HEAD) is still refused loudly, never silently
#        archived.
#   E3: recover() only consumes the orphan and resets the counter when
#       rollback ACTUALLY SUCCEEDED (rc=0). A rollback that itself refuses
#       (state-root swap) leaves the orphan preserved and the counter intact.
#
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
STITCHPAD="$ROOT/tool/bin/stitchpad"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

make_pad() {
  local dir="$1" name="${2:-test-pad}"
  mkdir -p "$dir/.stitchpad/.state/sessions" "$dir/.stitchpad/.state/claims"
  cat > "$dir/.stitchpad/stitchpad.md" <<'EOPAD'
```roster
alice | claude | pull | -
bob   | ocean  | push | target-123
```
EOPAD
  local gd="$dir/.stitchpad/stitchpad-git"
  mkdir -p "$gd"
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" init -q
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" config user.email "test@test.com"
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" config user.name "Test"
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" add stitchpad.md
  git --git-dir="$gd" --work-tree="$dir/.stitchpad" commit -q -m "initial"
  touch "$dir/.stitchpad/.state/session-registry.jsonl"
}

setup_sources() {
  source "$ROOT/tool/bin/lib.sh"
  source "$ROOT/tool/bin/date-divider.sh"
  source "$ROOT/tool/bin/session-registry.sh"
  source "$ROOT/tool/bin/recovery-policy.sh"
  source "$ROOT/tool/bin/scope-authority.sh"
}

echo "=== recovery-hardening3-regression tests ==="
echo ""

# ============================================================================
# E1: leave-path sid confusion — passed sid (target) != env sid (operator)
# ============================================================================
echo "--- E1: leave-path manifest misalignment (passed sid != env sid) ---"

E1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h3-e1.XXXXXX")"
trap 'rm -rf "$E1_WORK"' RETURN 2>/dev/null || true

make_pad "$E1_WORK/test-pad" "e1-pad"
E1_PAD_DIR="$E1_WORK/test-pad/.stitchpad"
E1_PAD_MD="$E1_PAD_DIR/stitchpad.md"
E1_PAD_STATE="$E1_PAD_DIR/.state"

export STITCHPAD_PAD_DIR="$E1_PAD_DIR"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

setup_sources
PAD_DIR="$E1_PAD_DIR"
PAD_MD="$E1_PAD_MD"
PAD_STATE="$E1_PAD_STATE"

L="alice-sid-L"
O="captain-sid-O"

# L (alice, the leaving target) and O (captain, the operator) both have
# distinct pre-existing markers.
printf 'AAA111' > "$PAD_STATE/session-start.$L"
printf 'AAA333' > "$PAD_STATE/session-activity.$L"
printf 'AAA999' > "$PAD_STATE/session-end.$L"
printf 'OOO111' > "$PAD_STATE/session-start.$O"
printf 'OOO333' > "$PAD_STATE/session-activity.$O"
# O has no session-end (not existed before the op)

# journal_begin with sid=L (the leave path shape: passed sid is the target's
# bound session) while STITCHPAD_SESSION=O (the operator's own env session).
export STITCHPAD_SESSION="$O"
E1_JOURNAL="$(sp_session_registry_journal_begin "$L")"
[ -n "$E1_JOURNAL" ] && [ -d "$E1_JOURNAL" ] || { bad "E1_setup: could not create journal"; }

# Crash mid-leave: mutate L's files (simulating in-progress leave writes that
# never completed).
printf 'CRASHED_START_L' > "$PAD_STATE/session-start.$L"
printf 'CRASHED_ACTIVITY_L' > "$PAD_STATE/session-activity.$L"
rm -f "$PAD_STATE/session-end.$L"

# Third-party recovery with env unset (anonymous recovery).
unset STITCHPAD_SESSION
sp_session_registry_journal_recover >/dev/null 2>&1

# E1a: L's markers restored to L's ORIGINAL bytes (not O's)
[ "$(cat "$PAD_STATE/session-start.$L" 2>/dev/null)" = "AAA111" ] && \
  ok "E1a: session-start.\$L restored to L's own bytes (AAA111)" \
  || bad "E1a: session-start.\$L = $(cat "$PAD_STATE/session-start.$L" 2>/dev/null) (want AAA111)"

[ "$(cat "$PAD_STATE/session-activity.$L" 2>/dev/null)" = "AAA333" ] && \
  ok "E1b: session-activity.\$L restored to L's own bytes (AAA333)" \
  || bad "E1b: session-activity.\$L = $(cat "$PAD_STATE/session-activity.$L" 2>/dev/null) (want AAA333)"

[ -f "$PAD_STATE/session-end.$L" ] && [ "$(cat "$PAD_STATE/session-end.$L" 2>/dev/null)" = "AAA999" ] && \
  ok "E1c: session-end.\$L restored (not deleted)" \
  || bad "E1c: session-end.\$L missing or wrong (deleted by cross-sid manifest bleed?)"

# E1d: O's markers UNTOUCHED (never overwritten by L's row)
[ "$(cat "$PAD_STATE/session-start.$O" 2>/dev/null)" = "OOO111" ] && \
  ok "E1d: session-start.\$O untouched (OOO111)" \
  || bad "E1d: session-start.\$O = $(cat "$PAD_STATE/session-start.$O" 2>/dev/null) (want OOO111, cross-seat bleed!)"

[ "$(cat "$PAD_STATE/session-activity.$O" 2>/dev/null)" = "OOO333" ] && \
  ok "E1e: session-activity.\$O untouched (OOO333)" \
  || bad "E1e: session-activity.\$O = $(cat "$PAD_STATE/session-activity.$O" 2>/dev/null) (want OOO333, cross-seat bleed!)"

# E1f: orphan consumed (recovery succeeded)
[ ! -d "$E1_JOURNAL" ] && ok "E1f: orphan consumed after successful recovery" \
  || bad "E1f: orphan still present"

# ============================================================================
# E2a: base-SHA refusal records an attempt BEFORE continuing
# ============================================================================
echo ""
echo "--- E2a: base-SHA refusal records attempts (no infinite refusal) ---"

E2A_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h3-e2a.XXXXXX")"

make_pad "$E2A_WORK/test-pad" "e2a-pad"
E2A_PAD_DIR="$E2A_WORK/test-pad/.stitchpad"
E2A_PAD_MD="$E2A_PAD_DIR/stitchpad.md"
E2A_PAD_STATE="$E2A_PAD_DIR/.state"
E2A_GIT="$E2A_PAD_DIR/stitchpad-git"

export STITCHPAD_PAD_DIR="$E2A_PAD_DIR"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

E2A_SID="e2a-alice-001"
printf 'alice' > "$E2A_PAD_STATE/sessions/$E2A_SID"

PAD_DIR="$E2A_PAD_DIR"
PAD_MD="$E2A_PAD_MD"
PAD_STATE="$E2A_PAD_STATE"

E2A_ORPHAN="$(STITCHPAD_SESSION="$E2A_SID" sp_session_registry_journal_begin "$E2A_SID")"
[ -n "$E2A_ORPHAN" ] && [ -d "$E2A_ORPHAN" ] || { bad "E2A_setup: could not create orphan"; }

# Unrelated commit advances HEAD (R3 shape — content diverges from HEAD too,
# to force the refusal branch rather than the E2b archive branch).
echo "third party commit" >> "$E2A_PAD_MD"
git --git-dir="$E2A_GIT" --work-tree="$E2A_WORK/test-pad/.stitchpad" add stitchpad.md
git --git-dir="$E2A_GIT" --work-tree="$E2A_WORK/test-pad/.stitchpad" commit -q -m "third party"
echo "uncommitted crash residue" >> "$E2A_PAD_MD"

SP_RECOVERY_MAX_ATTEMPTS=3 SP_RECOVERY_BUDGET_SECONDS=120

# Run recovery 5 times — each pass should hit the refusal branch and record
# an attempt. After 3 attempts the terminal-refusal fires.
for _i in 1 2 3 4 5; do
  sp_session_registry_journal_recover >/dev/null 2>&1
done

E2A_COUNT="$(sp_recovery_attempt_count "$PAD_STATE" "journal:$(basename "$E2A_ORPHAN")")"
[ "$E2A_COUNT" -ge 3 ] 2>/dev/null && \
  ok "E2Aa: attempt counter incremented on base-SHA refusal (count=$E2A_COUNT)" \
  || bad "E2Aa: attempt counter did not increment on refusal (count=$E2A_COUNT, was 0 in the bug)"

[ -d "$E2A_ORPHAN" ] && ok "E2Ab: orphan still preserved (real refusal, not consumed)" \
  || bad "E2Ab: orphan disappeared unexpectedly"

E2A_LAST="$(sp_session_registry_journal_recover 2>&1)"
echo "$E2A_LAST" | grep -qi "RECOVERY EXHAUSTED" && \
  ok "E2Ac: terminal refusal fires after attempts exhausted" \
  || bad "E2Ac: no terminal refusal after exhausting attempts (got: $(printf '%s' "$E2A_LAST" | head -c 150))"

# ============================================================================
# E2b: crash-after-commit archived; unrelated-commit still refused (R3 shape)
# ============================================================================
echo ""
echo "--- E2b: crash-after-commit archived vs unrelated-commit refused ---"

E2B_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h3-e2b.XXXXXX")"

make_pad "$E2B_WORK/test-pad" "e2b-pad"
E2B_PAD_DIR="$E2B_WORK/test-pad/.stitchpad"
E2B_PAD_MD="$E2B_PAD_DIR/stitchpad.md"
E2B_PAD_STATE="$E2B_PAD_DIR/.state"
E2B_GIT="$E2B_PAD_DIR/stitchpad-git"

export STITCHPAD_PAD_DIR="$E2B_PAD_DIR"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

E2B_SID="e2b-alice-001"
printf 'alice' > "$E2B_PAD_STATE/sessions/$E2B_SID"

PAD_DIR="$E2B_PAD_DIR"
PAD_MD="$E2B_PAD_MD"
PAD_STATE="$E2B_PAD_STATE"

# Scenario A: genuine crash-after-commit. The operation's OWN write commits
# (say path: write then commit), THEN crashes before journal_commit removes
# the journal. Live content == HEAD content exactly.
E2B_ORPHAN_A="$(STITCHPAD_SESSION="$E2B_SID" sp_session_registry_journal_begin "$E2B_SID")"
[ -n "$E2B_ORPHAN_A" ] && [ -d "$E2B_ORPHAN_A" ] || { bad "E2Ba_setup: could not create orphan"; }

echo "the operation's own write" >> "$E2B_PAD_MD"
git --git-dir="$E2B_GIT" --work-tree="$E2B_WORK/test-pad/.stitchpad" add stitchpad.md
git --git-dir="$E2B_GIT" --work-tree="$E2B_WORK/test-pad/.stitchpad" commit -q -m "own write committed"
# NOTHING further mutates PAD_MD — live content == HEAD exactly (crash landed
# cleanly right after the commit, before journal_commit could run).

sp_session_registry_journal_recover >/dev/null 2>&1

[ ! -d "$E2B_ORPHAN_A" ] && ok "E2Ba: crash-after-commit orphan archived (not left as permanent refusal)" \
  || bad "E2Ba: crash-after-commit orphan still preserved (should archive)"

[ -d "$PAD_STATE/journal-archive" ] && ls -A "$PAD_STATE/journal-archive" | grep -q . && \
  ok "E2Bb: archived orphan moved to journal-archive/ (evidence retained)" \
  || bad "E2Bb: archived orphan not found in journal-archive/"

grep -q "the operation's own write" "$E2B_PAD_MD" && \
  ok "E2Bc: committed content intact after archive" \
  || bad "E2Bc: committed content missing after archive"

# Scenario B: unrelated commit advances HEAD by exactly one (R3's exact
# shape) — live content DIVERGES from HEAD (uncommitted crash residue still
# sitting in the file). Must NOT be silently archived.
E2B_ORPHAN_B="$(STITCHPAD_SESSION="$E2B_SID" sp_session_registry_journal_begin "$E2B_SID")"
[ -n "$E2B_ORPHAN_B" ] && [ -d "$E2B_ORPHAN_B" ] || { bad "E2Bd_setup: could not create orphan"; }

echo "unrelated third party commit" >> "$E2B_PAD_MD"
git --git-dir="$E2B_GIT" --work-tree="$E2B_WORK/test-pad/.stitchpad" add stitchpad.md
git --git-dir="$E2B_GIT" --work-tree="$E2B_WORK/test-pad/.stitchpad" commit -q -m "unrelated party"
# Ghost content: uncommitted crash residue diverging live from HEAD
echo "GHOST UNCOMMITTED CONTENT" >> "$E2B_PAD_MD"

E2B_RECOVER_OUT="$(sp_session_registry_journal_recover 2>&1)"

[ -d "$E2B_ORPHAN_B" ] && ok "E2Bd: unrelated-commit orphan PRESERVED (not silently archived — R3 must still hold)" \
  || bad "E2Bd: unrelated-commit orphan consumed/archived (R3 regression!)"

echo "$E2B_RECOVER_OUT" | grep -qi "committed work would be reverted\|PRESERVED" && \
  ok "E2Be: unrelated-commit case reports loud refusal (not archived-silently)" \
  || bad "E2Be: no loud refusal for unrelated-commit case"

grep -q "GHOST UNCOMMITTED CONTENT" "$E2B_PAD_MD" && \
  ok "E2Bf: live state untouched by refused recovery (ghost content intact)" \
  || bad "E2Bf: live state tampered by refused recovery"

# ============================================================================
# E3: recover() only consumes orphan + resets counter when rollback SUCCEEDS
# ============================================================================
echo ""
echo "--- E3: rollback rc truthfulness — no false PRESERVED claim, no reset on fail ---"

E3_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h3-e3.XXXXXX")"

make_pad "$E3_WORK/test-pad" "e3-pad"
E3_PAD_DIR="$E3_WORK/test-pad/.stitchpad"
E3_PAD_MD="$E3_PAD_DIR/stitchpad.md"
E3_PAD_STATE="$E3_PAD_DIR/.state"

export STITCHPAD_PAD_DIR="$E3_PAD_DIR"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

E3_SID="e3-alice-001"
printf 'alice' > "$E3_PAD_STATE/sessions/$E3_SID"

PAD_DIR="$E3_PAD_DIR"
PAD_MD="$E3_PAD_MD"
PAD_STATE="$E3_PAD_STATE"

E3_ORPHAN="$(STITCHPAD_SESSION="$E3_SID" sp_session_registry_journal_begin "$E3_SID")"
[ -n "$E3_ORPHAN" ] && [ -d "$E3_ORPHAN" ] || { bad "E3_setup: could not create orphan"; }

# Poison the journal's state-root pin so rollback's C2 check fails and
# rollback returns rc=1 (rollback explicitly refuses / preserves).
printf 'poisoned-not-a-real-stat-pair' > "$E3_ORPHAN/.state-root"

# Direct rollback call: verify it does in fact refuse (rc != 0)
sp_session_registry_journal_rollback "$E3_ORPHAN" "$E3_SID" >/dev/null 2>&1
E3_DIRECT_RC=$?
[ "$E3_DIRECT_RC" -ne 0 ] && ok "E3a: direct rollback call refuses on poisoned state-root (rc=$E3_DIRECT_RC)" \
  || bad "E3a: direct rollback call did not refuse (rc=$E3_DIRECT_RC)"
[ -d "$E3_ORPHAN" ] && ok "E3b: direct rollback preserves the journal on refusal" \
  || bad "E3b: direct rollback deleted the journal despite refusing"

# Now drive it through the recover() path — must not delete the orphan and
# must not reset the counter, because rollback's rc says it failed.
sp_session_registry_journal_recover >/dev/null 2>&1

[ -d "$E3_ORPHAN" ] && ok "E3c: recover() does NOT delete a journal rollback explicitly refused" \
  || bad "E3c: recover() deleted the journal despite rollback refusing (the exact bug — 'preserved' claim was a lie)"

E3_COUNT="$(sp_recovery_attempt_count "$PAD_STATE" "journal:$(basename "$E3_ORPHAN")")"
[ "$E3_COUNT" -ge 1 ] 2>/dev/null && \
  ok "E3d: attempt counter NOT reset after a FAILED recovery (count=$E3_COUNT)" \
  || bad "E3d: attempt counter reset to 0 despite recovery failing (count=$E3_COUNT — terminal refusal unreachable)"

# Run recovery repeatedly — since the counter is never reset on failure, it
# should eventually hit the terminal refusal (the bound becomes reachable).
for _i in 1 2 3 4 5; do
  sp_session_registry_journal_recover >/dev/null 2>&1
done
E3_LAST="$(sp_session_registry_journal_recover 2>&1)"
echo "$E3_LAST" | grep -qi "RECOVERY EXHAUSTED" && \
  ok "E3e: terminal refusal becomes reachable via a persistently-failing rollback" \
  || bad "E3e: terminal refusal never reachable (counter kept resetting on failure)"

# ============================================================================
# Results
# ============================================================================
echo ""
echo "=== RESULTS ==="
printf "Passed:  %d\n" "$pass"
printf "Failed:  %d\n" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '\nAll recovery-hardening3 gates PASSED.\n'
  exit 0
else
  printf '\nSome recovery-hardening3 gates FAILED.\n'
  exit 1
fi
