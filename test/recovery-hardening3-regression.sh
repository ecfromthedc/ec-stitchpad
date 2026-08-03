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
# E4: atomic bind-session + shift-change --save (kill torn/duplicate races)
# ============================================================================
echo ""
echo "--- E4: concurrent bind-session and shift-change --save races ---"

E4_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h3-e4.XXXXXX")"
make_pad "$E4_WORK/test-pad" "e4-pad"
E4_PAD_DIR="$E4_WORK/test-pad/.stitchpad"

# E4a: concurrent bind-session of one fresh sid by two different names —
# must never produce torn garbage. The lock serializes each full
# read-decide-write cycle; the loser's write simply lands after (or the
# collision guard refuses it), but the on-disk value is always a complete,
# valid name — never an interleaved fragment.
E4A_SID="e4a-race-sid"
E4A_ROUNDS=20
E4A_TORN=0
for _r in $(seq 1 "$E4A_ROUNDS"); do
  rm -f "$E4_PAD_DIR/.state/sessions/$E4A_SID"
  (
    STITCHPAD_PAD_DIR="$E4_PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=alice \
      "$STITCHPAD" bind-session "$E4A_SID" alice >/dev/null 2>&1
  ) &
  (
    STITCHPAD_PAD_DIR="$E4_PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=bob \
      "$STITCHPAD" bind-session "$E4A_SID" bob >/dev/null 2>&1
  ) &
  wait
  _e4a_val="$(cat "$E4_PAD_DIR/.state/sessions/$E4A_SID" 2>/dev/null)"
  if [ "$_e4a_val" != "alice" ] && [ "$_e4a_val" != "bob" ]; then
    E4A_TORN=$((E4A_TORN + 1))
    echo "    torn value on round $_r: '$_e4a_val'" >&2
  fi
done
[ "$E4A_TORN" -eq 0 ] && \
  ok "E4a: $E4A_ROUNDS rounds of concurrent bind-session — zero torn writes" \
  || bad "E4a: $E4A_TORN/$E4A_ROUNDS rounds produced torn/invalid binding content"

# E4b: concurrent shift-change --save for the SAME agent — must produce
# exactly one pending row, never a duplicate (SELECT-then-INSERT race).
E4B_HANDOFF="$E4_WORK/handoff.txt"
echo "handoff body for race test" > "$E4B_HANDOFF"
E4B_ROUNDS=15
for _r in $(seq 1 "$E4B_ROUNDS"); do
  (
    STITCHPAD_PAD_DIR="$E4_PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_NAME=alice \
      "$STITCHPAD" shift-change --save alice --file "$E4B_HANDOFF" >/dev/null 2>&1
  ) &
done
wait

E4B_DB="$E4_PAD_DIR/.state/archive.sqlite"
E4B_PENDING="$(/usr/bin/sqlite3 "$E4B_DB" "SELECT COUNT(*) FROM handoffs WHERE agent='alice' AND status='pending';" 2>/dev/null || echo -1)"
[ "$E4B_PENDING" = "1" ] && \
  ok "E4b: $E4B_ROUNDS concurrent shift-change --save calls — exactly 1 pending row" \
  || bad "E4b: $E4B_PENDING pending rows after $E4B_ROUNDS concurrent saves (want 1, duplicate-row race)"

# ============================================================================
# E7: cancel bound extended to all 6 remaining call sites
# ============================================================================
echo ""
echo "--- E7: cancel bound wired at all 6 remaining call sites ---"

# E7a-f: structural verification — each of the six previously-unbounded call
# sites must invoke _sp_delivery_cancel_bound_check within a few lines of its
# delivery_cancel_ocean_turn call. This is the exact defect: before the fix,
# these sites had ZERO calls to the bound helper anywhere near them (grep
# would find nothing); after the fix, each site's failure branch calls it.
_e7_watch="$ROOT/tool/bin/watch.sh"

_e7_site_wired() {
  local anchor="$1" label="$2"
  local line_no window
  line_no="$(grep -n "$anchor" "$_e7_watch" | head -1 | cut -d: -f1)"
  if [ -z "$line_no" ]; then
    bad "E7 $label: anchor pattern not found in watch.sh (site removed/renamed?)"
    return
  fi
  window="$(sed -n "$((line_no)),$((line_no + 10))p" "$_e7_watch")"
  echo "$window" | grep -q '_sp_delivery_cancel_bound_check' && \
    ok "E7 $label: bound check wired at call site" \
    || bad "E7 $label: no _sp_delivery_cancel_bound_check within 10 lines of $anchor"
}

_e7_site_wired 'delivery_cancel_ocean_turn "\$name" "\$turn_id" dnd' "DND"
_e7_site_wired 'delivery_cancel_ocean_turn "\$name" "\$turn_id" "\$DELIVERY_TASK_REASON"; then' "task-invalid (live dispatch)"
_e7_site_wired 'delivery_cancel_ocean_turn "\$name" "\$turn_id" superseded_current' "superseded_current"
_e7_site_wired 'delivery_cancel_ocean_turn "\$name" "\$turn_id" superseded_after_accept' "superseded_after_accept"
_e7_site_wired 'delivery_cancel_ocean_turn "\$name" "\$old_turn" "\$DELIVERY_TASK_REASON"' "task-invalid (reconcile)"
_e7_site_wired 'delivery_cancel_ocean_turn "\$name" "\$old_turn" superseded_by_newer' "superseded_by_newer (reconcile)"

# E7g: the shared helper itself — attempt recording, exhaustion, reset.
E7_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h3-e7.XXXXXX")"
make_pad "$E7_WORK/test-pad" "e7-pad"
E7_PAD_DIR="$E7_WORK/test-pad/.stitchpad"
export STITCHPAD_PAD_DIR="$E7_PAD_DIR"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

(
  STITCHPAD_WATCH_LIB_ONLY=1
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1
  source "$ROOT/tool/bin/recovery-policy.sh"
  source "$ROOT/tool/bin/watch.sh" >/dev/null 2>&1

  SP_RECOVERY_MAX_ATTEMPTS=3

  # Three failed attempts should not yet exhaust (< max)
  _sp_delivery_cancel_bound_check testname testturn testreason >/dev/null 2>&1
  _sp_delivery_cancel_bound_check testname testturn testreason >/dev/null 2>&1
  _rc_before_exhaust=$?
  # Third call crosses the bound (count reaches 3)
  _sp_delivery_cancel_bound_check testname testturn testreason >/dev/null 2>&1
  # Fourth call: exhausted — must return 1 and print terminal refusal
  _e7g_out="$(_sp_delivery_cancel_bound_check testname testturn testreason 2>&1)"
  _e7g_rc=$?
  echo "RC=$_e7g_rc"
  echo "OUT=$_e7g_out"

  # Reset clears it — next check should succeed again (rc 0, not exhausted)
  _sp_delivery_cancel_bound_reset testname testturn testreason
  _sp_delivery_cancel_bound_check testname testturn testreason >/dev/null 2>&1
  echo "RC_AFTER_RESET=$?"
) > "$E7_WORK/e7g.out" 2>&1

grep -q '^RC=1$' "$E7_WORK/e7g.out" && \
  ok "E7g1: bound check returns 1 once exhausted (max attempts reached)" \
  || bad "E7g1: bound check did not exhaust (got: $(grep '^RC=' "$E7_WORK/e7g.out"))"

grep -qi 'RECOVERY EXHAUSTED' "$E7_WORK/e7g.out" && \
  ok "E7g2: terminal refusal diagnostic printed on exhaustion" \
  || bad "E7g2: no terminal refusal diagnostic on exhaustion"

grep -q '^RC_AFTER_RESET=0$' "$E7_WORK/e7g.out" && \
  ok "E7g3: reset clears the counter — bound check succeeds again" \
  || bad "E7g3: reset did not clear the counter (got: $(grep RC_AFTER_RESET "$E7_WORK/e7g.out"))"

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
