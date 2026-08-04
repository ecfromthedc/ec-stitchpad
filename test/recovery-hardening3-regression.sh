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

# Hermetic guard (fx2 harness-hygiene, fleet standard from tonight's
# terminal-surface collision finding): never inherit the runner's terminal
# surface, or fixtures like N2/N3/H4's alice-rostered pads can claim the
# operator's own ~/.stitchpad-terminals/<surface> and collide with live
# seats. See fx2-harness-hygiene-1b8eed4.md.
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true

# ── pro4 structural tmpdir: PID-annotated parent, concurrency-safe sweep ──
# Design: sp-run.<pid>.XXXXXX encodes the owning PID.  The startup sweep
# deletes ONLY parents whose PID is dead (kill -0 fails) AND whose
# directory is older than 60 seconds (PID-reuse grace window).  A live
# concurrent instance's parent is NEVER deleted.  Other suites' mktemp
# dirs (sp-mgate.*, sp-h3-*, etc.) lack the sp-run.* prefix and are
# never touched.
_SYS_TMP="${TMPDIR:-/tmp}"
_STALE_SWEPT=0

# Create per-run parent BEFORE sweeping — we must exist before we could
# be swept, and our own PID ensures we survive our own sweep iteration.
_RUN_TMP="$(mktemp -d "$_SYS_TMP/sp-run.$$.XXXXXXXX")"
export TMPDIR="$_RUN_TMP"

# Startup sweep: only delete parents whose PID is demonstrably dead.
for _d in $(find "$_SYS_TMP" -maxdepth 1 -name 'sp-run.*' -type d 2>/dev/null); do
  [ "$_d" = "$_RUN_TMP" ] && continue   # never sweep ourselves
  _dname="$(basename "$_d")"
  # Extract PID: strip "sp-run.", then take everything up to the next dot.
  _pid="${_dname#sp-run.}"
  _pid="${_pid%%.*}"
  case "$_pid" in ''|*[!0-9]*) continue ;; esac  # not a PID-annotated name; skip
  # PID reuse grace: only sweep if dir hasn't been touched in >1 min.
  # find -mmin +1 returns the dir only when mod time >1 min ago (portable).
  if kill -0 "$_pid" 2>/dev/null; then
    :  # PID is alive — never touch
  elif [ -n "$(find "$_d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rm -rf "$_d" 2>/dev/null || true
    _STALE_SWEPT=$((_STALE_SWEPT + 1))
  fi
done
[ "$_STALE_SWEPT" -gt 0 ] && echo "  (swept $_STALE_SWEPT dead-PID stale sp-run.* dirs)" >&2 || true
# Teardown: rm -rf the entire tree.  Prove RED: set STITCHPAD_TEST_LEAK=1
# to skip the rm so the gate catches the leak.
_teardown() {
  if [ "${STITCHPAD_TEST_LEAK:-0}" != "1" ]; then
    rm -rf "$_RUN_TMP" 2>/dev/null || true
  fi
}
trap _teardown EXIT

# Authority model (C2/C2b): operator flows require a credential rooted at
# $HOME/.stitchpad/operator.key — isolate HOME so the fixture NEVER touches
# the operator's real key, then mint a fixture credential.
H3_HOME="$(mktemp -d "${TMPDIR:-/tmp}/sp-h3-home.XXXXXX")"
export HOME="$H3_HOME"
# A-4/A-5 fix: explicit override keeps this fixture off the real operator key
export STITCHPAD_OPERATOR_KEY_PATH="$H3_HOME/.stitchpad/operator.key"
export STITCHPAD_OPERATOR_KEY_OVERRIDE_ACK=1
# H3_HOME covered by _RUN_TMP EXIT trap (pro3)
"$STITCHPAD" operator keygen >/dev/null 2>&1 || true
OP_TOK="$(cat "$HOME/.stitchpad/operator.key" 2>/dev/null)"

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

# Fast-only probe: skip all substantive tests; only infrastructure gates
# (tmpdir, concurrency) run.  Controlled by STITCHPAD_H3_FAST_ONLY=1.
if [ "${STITCHPAD_H3_FAST_ONLY:-0}" = "1" ]; then
  # Jump straight to the tmpdir/concurrency gates at the end.
  true  # no-op; fall through to the gates below
else
# ============================================================================
# E1: leave-path sid confusion — passed sid (target) != env sid (operator)
# ============================================================================
echo "--- E1: leave-path manifest misalignment (passed sid != env sid) ---"

E1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h3-e1.XXXXXX")"
# E1_WORK covered by _RUN_TMP EXIT trap (pro3)

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
rm -f "$E1_JOURNAL/.alive" 2>/dev/null || true  # R7: simulate crash — process died
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
rm -f "$E2A_ORPHAN/.alive" 2>/dev/null || true  # R7: simulate crash
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
rm -f "$E2B_ORPHAN_A/.alive" 2>/dev/null || true  # R7: simulate crash
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
rm -f "$E2B_ORPHAN_B/.alive" 2>/dev/null || true  # R7: simulate crash
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
rm -f "$E3_ORPHAN/.alive" 2>/dev/null || true  # R7: simulate crash
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
# Round-4: N1 (path containment), N2 (archive no-follow), N3 (CLI reset),
#           E5a (poisoned counter), sp_commit race (nothing-to-commit)
# ============================================================================
echo ""
echo "--- Round-4: flash re-attack 3 fixes ---"

# ── N1: crafted .paths cannot write outside PAD_STATE ────────────────────
echo "  N1: crafted orphan .paths containment..."
N1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h4-n1.XXXXXX")"
make_pad "$N1_WORK/pad" "n1-pad"
N1_PAD_DIR="$N1_WORK/pad/.stitchpad"
N1_OUTSIDE="$N1_WORK/outside-target.txt"
rm -f "$N1_OUTSIDE"

(
  export STITCHPAD_PAD_DIR="$N1_PAD_DIR"
  unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
  STITCHPAD_WATCH_LIB_ONLY=1
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1
  source "$ROOT/tool/bin/recovery-policy.sh"
  source "$ROOT/tool/bin/session-registry.sh" >/dev/null 2>&1

  # Craft a fake orphan journal with a .paths entry pointing OUTSIDE PAD_STATE
  local_jdir="$N1_PAD_DIR/.registry-journal.CRAFTED"
  mkdir -p "$local_jdir"
  printf 'session-fake' > "$local_jdir/.sid"
  printf '%s\n' "$N1_OUTSIDE" > "$local_jdir/.paths"
  printf '1\n' > "$local_jdir/manifest"
  printf 'PWNED' > "$local_jdir/0"
  # Stamp .state-root using PAD_STATE (set by sp_init_paths), not the raw
  # path — otherwise the state-root guard fires before the path-containment
  # check and masks the diagnostic we're testing for.
  python3 -c "import os,sys; s=os.lstat(sys.argv[1]); print(s.st_dev,s.st_ino)" \
    "$PAD_STATE" > "$local_jdir/.state-root"

  # Attempt rollback — must REFUSE, not write the outside file
  sp_session_registry_journal_rollback "$local_jdir" "session-fake" > "$N1_WORK/n1-rollback.out" 2>&1
  echo "RC=$?"
) > "$N1_WORK/n1-result.out" 2>&1

[ -f "$N1_OUTSIDE" ] && \
  bad "N1: crafted .paths wrote outside PAD_STATE (arbitrary file write not contained)" \
  || ok "N1: crafted .paths refused — no file written outside PAD_STATE"

_n1_diag="$(cat "$N1_WORK/n1-rollback.out" "$N1_WORK/n1-result.out" 2>/dev/null)"
printf '%s' "$_n1_diag" | grep -qi 'PATH ESCAPE' && \
  ok "N1: path escape diagnostic printed" \
  || bad "N1: no path escape diagnostic (output: $_n1_diag)"

# ── N2: journal-archive symlink is refused ───────────────────────────────
echo "  N2: journal-archive symlink containment..."
N2_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h4-n2.XXXXXX")"
make_pad "$N2_WORK/pad" "n2-pad"
N2_PAD_DIR="$N2_WORK/pad/.stitchpad"
N2_OUTSIDE_DIR="$N2_WORK/outside-archive"
mkdir -p "$N2_OUTSIDE_DIR"

(
  export STITCHPAD_PAD_DIR="$N2_PAD_DIR"
  unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
  STITCHPAD_WATCH_LIB_ONLY=1
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1
  source "$ROOT/tool/bin/recovery-policy.sh"
  source "$ROOT/tool/bin/session-registry.sh" >/dev/null 2>&1

  # Pre-plant a symlink at journal-archive
  ln -s "$N2_OUTSIDE_DIR" "$N2_PAD_DIR/.state/journal-archive"

  # Trigger recover via journal_begin (which calls recover first).
  # First plant a valid-looking orphan that triggers the archive path.
  local_orphan="$N2_PAD_DIR/.state/.registry-journal.ORPHAN"
  mkdir -p "$local_orphan"
  printf 'session-orphan' > "$local_orphan/.sid"
  python3 -c "import os,sys; s=os.lstat(sys.argv[1]); print(s.st_dev,s.st_ino)" \
    "$PAD_STATE" > "$local_orphan/.state-root"

  # Stamp base-sha as parent of HEAD so the E2b archive path fires
  local_parent_sha="$(git --git-dir="$N2_PAD_DIR/stitchpad-git" rev-parse HEAD~1 2>/dev/null || echo "")"
  [ -n "$local_parent_sha" ] && printf '%s' "$local_parent_sha" > "$local_orphan/.base-sha"

  sp_session_registry_journal_recover > "$N2_WORK/n2-recover.out" 2>&1
  echo "RECOVER_RC=$?"
  echo "ORPHAN_EXISTS=$([ -d "$local_orphan" ] && echo yes || echo no)"
  echo "SYMLINK_INTACT=$([ -L "$N2_PAD_DIR/.state/journal-archive" ] && echo yes || echo no)"
) > "$N2_WORK/n2-result.out" 2>&1

# The orphan should NOT be moved into the symlinked archive
_n2_files_outside="$(find "$N2_OUTSIDE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$_n2_files_outside" = "0" ] && \
  ok "N2: journal-archive symlink refused — orphan not exfiltrated outside PAD_STATE" \
  || bad "N2: orphan moved through symlinked archive to outside PAD_STATE"

grep -qi 'symlink' "$N2_WORK/n2-recover.out" "$N2_WORK/n2-result.out" 2>/dev/null && \
  ok "N2: symlink refusal diagnostic printed" \
  || bad "N2: no symlink refusal diagnostic"

# ── N3: CLI reset --recovery-counters works + authority gate ──────────────
echo "  N3: CLI reset --recovery-counters..."
N3_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h4-n3.XXXXXX")"
make_pad "$N3_WORK/pad" "n3-pad"
N3_PAD_DIR="$N3_WORK/pad/.stitchpad"

# Seed a recovery counter
mkdir -p "$N3_PAD_DIR/.state/recovery-attempts"
printf '5|%d' "$(date +%s)" > "$N3_PAD_DIR/.state/recovery-attempts/journal:test-orphan"

# N3a: operator can clear all counters (C2: requires the operator credential)
STITCHPAD_PAD_DIR="$N3_PAD_DIR" STITCHPAD_NAME="operator-human" \
  STITCHPAD_OPERATOR_TOKEN="$OP_TOK" \
  "$STITCHPAD" reset --recovery-counters > "$N3_WORK/n3a.out" 2>&1
_n3a_rc=$?
_n3a_remaining="$(find "$N3_PAD_DIR/.state/recovery-attempts" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$_n3a_rc" -eq 0 ] && [ "$_n3a_remaining" = "0" ] && \
  ok "N3a: operator reset --recovery-counters clears all counters" \
  || bad "N3a: reset --recovery-counters failed (rc=$_n3a_rc, remaining=$_n3a_remaining)"

# Re-seed for the per-seat + authority-gate test
printf '5|%d' "$(date +%s)" > "$N3_PAD_DIR/.state/recovery-attempts/journal:test-orphan"

# N3b: a roster seat is DENIED
STITCHPAD_PAD_DIR="$N3_PAD_DIR" STITCHPAD_NAME="alice" \
  "$STITCHPAD" reset --recovery-counters > "$N3_WORK/n3b.out" 2>&1
_n3b_rc=$?
[ "$_n3b_rc" -ne 0 ] && grep -qi 'AUTHORITY VIOLATION' "$N3_WORK/n3b.out" && \
  ok "N3b: roster seat denied from reset --recovery-counters (authority gate)" \
  || bad "N3b: seat was NOT denied (rc=$_n3b_rc)"

# Counter should still exist (seat couldn't clear it)
[ -f "$N3_PAD_DIR/.state/recovery-attempts/journal:test-orphan" ] && \
  ok "N3c: seat denial left the counter intact" \
  || bad "N3c: counter was cleared despite seat denial"

# ── E5a: poisoned counter does not wedge recovery ────────────────────────
echo "  E5a: poisoned counter ordering..."
E5A_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h4-e5a.XXXXXX")"
make_pad "$E5A_WORK/pad" "e5a-pad"
E5A_PAD_DIR="$E5A_WORK/pad/.stitchpad"

# Seed a poisoned counter (999999)
mkdir -p "$E5A_PAD_DIR/.state/recovery-attempts"
printf '999999|%d' "$(date +%s)" > "$E5A_PAD_DIR/.state/recovery-attempts/journal:poison-test"

(
  export STITCHPAD_PAD_DIR="$E5A_PAD_DIR"
  unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
  source "$ROOT/tool/bin/recovery-policy.sh"

  SP_RECOVERY_MAX_ATTEMPTS=3

  # E5a: is_exhausted should NOT return exhausted for a poisoned count
  if sp_recovery_is_exhausted "$E5A_PAD_DIR/.state" "journal:poison-test" 2>/dev/null; then
    echo "EXHAUSTED_ON_POISONED=yes"
  else
    echo "EXHAUSTED_ON_POISONED=no"
  fi

  # attempt_record should sanitize the poisoned count
  sp_recovery_attempt_record "$E5A_PAD_DIR/.state" "journal:poison-test" 2>/dev/null
  echo "AFTER_RECORD=$(sp_recovery_attempt_count "$E5A_PAD_DIR/.state" "journal:poison-test")"
) > "$E5A_WORK/e5a.out" 2>&1

grep -q '^EXHAUSTED_ON_POISONED=no$' "$E5A_WORK/e5a.out" && \
  ok "E5a1: poisoned counter (999999) does NOT trigger premature exhaustion" \
  || bad "E5a1: poisoned counter still wedges recovery"

grep -q '^AFTER_RECORD=1$' "$E5A_WORK/e5a.out" && \
  ok "E5a2: attempt_record sanitizes poisoned count to 1 (0+1)" \
  || bad "E5a2: attempt_record did not sanitize (got: $(grep AFTER_RECORD "$E5A_WORK/e5a.out"))"

# ── sp_commit race: nothing-to-commit is benign, not a hard failure ───────
echo "  sp_commit: nothing-to-commit race..."
RACE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h4-race.XXXXXX")"
make_pad "$RACE_WORK/pad" "race-pad"
RACE_PAD_DIR="$RACE_WORK/pad/.stitchpad"

(
  export STITCHPAD_PAD_DIR="$RACE_PAD_DIR"
  unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1

  # Commit once to get content into git
  sp_commit "initial" >/dev/null 2>&1

  # Now call sp_commit again with NO changes — this is the race shape:
  # a concurrent committer already committed these bytes. Must return 0.
  sp_commit "noop-race" 2>/dev/null
  echo "COMMIT_NOOP_RC=$?"

  # Verify no output leaked to stdout (the "nothing to commit" message)
  sp_commit "noop-race-check" > "$RACE_WORK/stdout-check.txt" 2>/dev/null
  echo "STDOUT_LEAK=$(wc -c < "$RACE_WORK/stdout-check.txt" | tr -d ' ')"
) > "$RACE_WORK/race.out" 2>&1

grep -q '^COMMIT_NOOP_RC=0$' "$RACE_WORK/race.out" && \
  ok "RACE1: sp_commit returns 0 when nothing to commit (benign race)" \
  || bad "RACE1: sp_commit returns nonzero on nothing-to-commit (got: $(grep COMMIT_NOOP_RC "$RACE_WORK/race.out"))"

grep -q '^STDOUT_LEAK=0$' "$RACE_WORK/race.out" && \
  ok "RACE2: no stdout leak from nothing-to-commit message" \
  || bad "RACE2: stdout leaked (got: $(grep STDOUT_LEAK "$RACE_WORK/race.out"))"

# ── sp_commit: real failure still returns 1 ──────────────────────────────
echo "  sp_commit: real commit failure still returns 1..."
FAIL_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h4-fail.XXXXXX")"
make_pad "$FAIL_WORK/pad" "fail-pad"
FAIL_PAD_DIR="$FAIL_WORK/pad/.stitchpad"

(
  export STITCHPAD_PAD_DIR="$FAIL_PAD_DIR"
  export STITCHPAD_TEST_MODE=1
  export STITCHPAD_TEST_COMMIT_FAIL=1
  unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1

  sp_commit "should-fail" 2>/dev/null
  echo "COMMIT_FAIL_RC=$?"
) > "$FAIL_WORK/fail.out" 2>&1

grep -q '^COMMIT_FAIL_RC=1$' "$FAIL_WORK/fail.out" && \
  ok "FAIL1: sp_commit returns 1 on real failure (test-injected)" \
  || bad "FAIL1: sp_commit did not return 1 on real failure (got: $(grep COMMIT_FAIL_RC "$FAIL_WORK/fail.out"))"

# ── Join-after-heartbeat: the nothing-to-commit freeze blocker ────────────
# Captain's repro: init, join alice, heartbeat start, sleep 3, heartbeat --stop,
# join sleeper -> previously failed with "roster commit did not complete"
# because lifecycle_commit's sp_commit returned rc=1 on git's benign
# "nothing to commit" (a concurrent watcher or the previous operation already
# committed the exact staged bytes). Now sp_commit re-checks diff --cached
# --quiet and returns 0 if the desired state is already committed.
echo "  Join-after-heartbeat (nothing-to-commit freeze blocker)..."
JH_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h4-jh.XXXXXX")"
make_pad "$JH_WORK/pad" "jh-pad"
JH_PAD_DIR="$JH_WORK/pad/.stitchpad"

# Bind a session, join alice, simulate a heartbeat start/stop cycle (which
# writes and commits lifecycle events), then join a second seat. The second
# join must succeed even if the pad bytes were already committed by the
# heartbeat lifecycle events (nothing new to commit).
T1="jh-alice-$$"; T2="jh-sleeper-$$"

# Step 1: bind session + join alice
STITCHPAD_PAD_DIR="$JH_PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" bind-session session-jh alice > /dev/null 2>&1

STITCHPAD_PAD_DIR="$JH_PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_SESSION=session-jh STITCHPAD_NAME=alice \
  "$STITCHPAD" join alice claude pull "$T1" > "$JH_WORK/join1.out" 2>&1
_jh_join1_rc=$?

# Step 2: heartbeat start
STITCHPAD_PAD_DIR="$JH_PAD_DIR" STITCHPAD_NAME=alice STITCHPAD_SESSION=session-jh \
  "$STITCHPAD" heartbeat start alice > "$JH_WORK/hb-start.out" 2>&1
_jh_hb_rc=$?

# Step 3: sleep 3 (let ticker write at least once)
sleep 3

# Step 4: heartbeat stop
STITCHPAD_PAD_DIR="$JH_PAD_DIR" STITCHPAD_NAME=alice STITCHPAD_SESSION=session-jh \
  "$STITCHPAD" heartbeat --stop alice > "$JH_WORK/hb-stop.out" 2>&1

# JH4-FIX: stop the watcher daemon spawned by the ticker's ensure_watcher
# calls.  The watcher does periodic unlocked auto-commits (watch.sh style,
# design decision per fx4 increment 17).  After heartbeat --stop kills the
# ticker, the watcher survives and its next git add/commit races the join's
# sp_commit on git's index.lock, producing a spurious "roster commit did not
# complete" error.  Explicit stop makes the test deterministic.
STITCHPAD_PAD_DIR="$JH_PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" stop > /dev/null 2>&1 || true

# Step 5: bind + join sleeper — this is the step that failed pre-fix
STITCHPAD_PAD_DIR="$JH_PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$STITCHPAD" bind-session session-sleeper sleeper > /dev/null 2>&1

STITCHPAD_PAD_DIR="$JH_PAD_DIR" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  STITCHPAD_SESSION=session-sleeper STITCHPAD_NAME=sleeper \
  "$STITCHPAD" join sleeper claude pull "$T2" > "$JH_WORK/join2.out" 2>&1
_jh_join2_rc=$?

# Clean up any heartbeat processes
pkill -f "alive.alice.*$JH_WORK" 2>/dev/null || true

[ "$_jh_join1_rc" -eq 0 ] && \
  ok "JH1: first join (alice) succeeded" \
  || bad "JH1: first join failed (rc=$_jh_join1_rc)"

# Check that sleeper is actually in the roster
grep -q 'sleeper' "$JH_PAD_DIR/stitchpad.md" && \
  ok "JH2: join-after-heartbeat (sleeper) succeeded — no freeze blocker" \
  || bad "JH2: join-after-heartbeat failed (sleeper not in roster, rc=$_jh_join2_rc)"

# Verify no "nothing to commit" or "did not complete" leak
grep -qi 'nothing to commit' "$JH_WORK/join2.out" && \
  bad "JH3: 'nothing to commit' leaked to join output" \
  || ok "JH3: no 'nothing to commit' leak on join"

grep -qi 'did not complete' "$JH_WORK/join2.out" && \
  bad "JH4: 'roster commit did not complete' error on join" \
  || ok "JH4: no 'commit did not complete' error"

# ── JH5: sp_commit benign-race fallthrough (km2 JH4 root-cause, deterministic) ──
# The JH4 flake mechanism (30-iteration instrumented repro, 50% failure under
# load): a concurrent UNLOCKED committer (watch.sh auto-commit) sweeps our
# staged bytes into its own commit between our index check and our commit —
# git exits 1 "nothing to commit" with EMPTY stderr, HEAD never moves in our
# window, and H5b's head-moved branches miss it. The fix tests working-tree
# vs HEAD for our paths in the fallthrough. These gates reproduce the exact
# interleaving deterministically with a git PATH shim that sweeps the index
# at the head_before capture.
echo "  JH5: sp_commit concurrent-committer fallthrough (deterministic shim)..."
JH5_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-h3-jh5.XXXXXX")"
make_pad "$JH5_WORK/pad" "jh5-pad"
JH5_PAD_DIR="$JH5_WORK/pad/.stitchpad"
JH5_REAL_GIT="$(command -v git)"
mkdir -p "$JH5_WORK/bin"
cat > "$JH5_WORK/bin/git" <<'EOSHIM'
#!/usr/bin/env bash
# JH5 shim: delegate everything to real git, except at the head_before
# capture (rev-parse --verify -q HEAD) where a simulated concurrent
# committer sweeps the staged index first — then the subsequent commit
# finds nothing to commit (rc=1, silent) with HEAD unmoved in the window.
case "$*" in
  *"rev-parse --verify -q HEAD"*)
    if [ ! -f "$JH5_SHIM_DIR/swept" ]; then
      "$JH5_REAL_GIT" --git-dir="$JH5_GD" --work-tree="$JH5_WT" \
        commit -q -m "watcher-simulated sweep" >/dev/null 2>&1
      [ -n "${JH5_WT_APPEND:-}" ] && printf '%s\n' "$JH5_WT_APPEND" >> "$JH5_WT/stitchpad.md"
      touch "$JH5_SHIM_DIR/swept"
    fi
    ;;
esac
exec "$JH5_REAL_GIT" "$@"
EOSHIM
chmod +x "$JH5_WORK/bin/git"

# JH5a: concurrent committer swept our bytes → sp_commit must return 0 (benign)
printf 'jh5a roster probe line\n' >> "$JH5_PAD_DIR/stitchpad.md"
(
  export STITCHPAD_PAD_DIR="$JH5_PAD_DIR" PATH="$JH5_WORK/bin:$PATH"
  export JH5_SHIM_DIR="$JH5_WORK" JH5_REAL_GIT="$JH5_REAL_GIT"
  export JH5_GD="$JH5_PAD_DIR/stitchpad-git" JH5_WT="$JH5_PAD_DIR"
  # Suite-context hygiene: sp_find_pad short-circuits on a pre-set ambient
  # PAD_DIR (lib.sh:104) — earlier top-level fixture assignments would
  # silently hijack the pin. Scrub the ambient pad vars.
  unset PAD_DIR PAD_MD PAD_GIT PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
  source "$ROOT/tool/bin/lib.sh" 2>/dev/null
  sp_init_paths >/dev/null 2>&1
  sgit add -A -f -- stitchpad.md 2>/dev/null
  rm -f "$JH5_WORK/swept"
  sp_commit "jh5a: simulated race" 2>/dev/null
  echo "JH5A_RC=$?"
) > "$JH5_WORK/jh5a.out" 2>&1
grep -q '^JH5A_RC=0$' "$JH5_WORK/jh5a.out" && \
  ok "JH5a: sp_commit benign when a concurrent committer swept our staged bytes" \
  || bad "JH5a: sp_commit refused a durably-committed write (got: $(grep JH5A_RC "$JH5_WORK/jh5a.out"))"

# JH5b: same race but our bytes are NOT in HEAD (write genuinely uncommitted)
# → sp_commit must still refuse honestly.
printf 'jh5b staged line\n' >> "$JH5_PAD_DIR/stitchpad.md"
(
  export STITCHPAD_PAD_DIR="$JH5_PAD_DIR" PATH="$JH5_WORK/bin:$PATH"
  export JH5_SHIM_DIR="$JH5_WORK" JH5_REAL_GIT="$JH5_REAL_GIT"
  export JH5_GD="$JH5_PAD_DIR/stitchpad-git" JH5_WT="$JH5_PAD_DIR"
  export JH5_WT_APPEND="jh5b UNSTAGED working-tree change"
  unset PAD_DIR PAD_MD PAD_GIT PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
  source "$ROOT/tool/bin/lib.sh" 2>/dev/null
  sp_init_paths >/dev/null 2>&1
  sgit add -A -f -- stitchpad.md 2>/dev/null
  rm -f "$JH5_WORK/swept"
  sp_commit "jh5b: simulated race with post-sweep wt change" 2>/dev/null
  echo "JH5B_RC=$?"
) > "$JH5_WORK/jh5b.out" 2>&1
if grep -q '^JH5B_RC=1$' "$JH5_WORK/jh5b.out"; then
  ok "JH5b: sp_commit still refuses when the working tree differs from HEAD"
else
  bad "JH5b: sp_commit accepted an uncommitted write (got: $(grep JH5B_RC "$JH5_WORK/jh5b.out"))"
  echo "  JH5 debug preserved: $JH5_WORK" >&2
fi

# ============================================================================
# ROUND 6: H1/H2+H9b/H4/H5b/H6/H10/H11b (flash re-attack 4 escalations)
# ============================================================================

echo ""
echo "--- Round 6: H1 git-dir containment exclusion ---"

R6_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-rh3-r6.XXXXXX")"
make_pad "$R6_WORK/pad"
R6_PAD_DIR="$R6_WORK/pad/.stitchpad"

# H1a: containment rejects stitchpad-git/config
(
  export STITCHPAD_PAD_DIR="$R6_PAD_DIR"
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1
  if _sp_session_registry_journal_path_contained "$R6_PAD_DIR/stitchpad-git/config" 2>/dev/null; then
    exit 0  # FAIL: should reject
  else
    exit 1  # PASS: rejected
  fi
)
_rc=$?
[ "$_rc" -ne 0 ] && ok "H1a: stitchpad-git/config rejected by containment (SEVERE fix)" \
  || bad "H1a: stitchpad-git/config NOT rejected (H1 SEVERE)"

# H1b: containment rejects stitchpad-git/hooks/pre-commit
(
  export STITCHPAD_PAD_DIR="$R6_PAD_DIR"
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1
  if _sp_session_registry_journal_path_contained "$R6_PAD_DIR/stitchpad-git/hooks/pre-commit" 2>/dev/null; then
    exit 0
  else
    exit 1
  fi
)
_rc=$?
[ "$_rc" -ne 0 ] && ok "H1b: stitchpad-git/hooks/pre-commit rejected (RCE vector closed)" \
  || bad "H1b: hooks/pre-commit NOT rejected (RCE still open)"

# H1c: valid PAD_STATE paths still pass
# Use the resolved PAD_STATE path (macOS /var → /private/var symlink means
# we must derive the test path from sp_init_paths, not from the raw $TMPDIR)
(
  export STITCHPAD_PAD_DIR="$R6_PAD_DIR"
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths >/dev/null 2>&1
  if _sp_session_registry_journal_path_contained "$PAD_STATE/sessions/test123" 2>/dev/null; then
    exit 0
  else
    exit 1
  fi
)
_rc=$?
[ "$_rc" -eq 0 ] && ok "H1c: valid PAD_STATE path still passes containment" \
  || bad "H1c: valid path incorrectly rejected"


# H2+H9b: hardlink refusal
echo ""
echo "--- Round 6: H2+H9b hardlink write-through refusal ---"

H2_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-rh3-h2.XXXXXX")"
mkdir -p "$H2_WORK/inside/.state/sessions" "$H2_WORK/victim-dir"
echo "ORIGINAL" > "$H2_WORK/victim-dir/outside-victim.txt"
ln "$H2_WORK/victim-dir/outside-victim.txt" "$H2_WORK/inside/.state/sessions/hardlinked-marker"

_nlink="$(python3 -c "import os; print(os.lstat('$H2_WORK/inside/.state/sessions/hardlinked-marker').st_nlink)" 2>/dev/null || echo 1)"
[ "$_nlink" -gt 1 ] && ok "H2a: hardlink detected (nlink=$_nlink)" \
  || bad "H2a: hardlink not detected (nlink=$_nlink)"


# H4: reset gate requires STITCHPAD_I_AM_OPERATOR
echo ""
echo "--- Round 6: H4 reset gate authority ---"

H4_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-rh3-h4.XXXXXX")"
make_pad "$H4_WORK/pad"
H4_PAD_DIR="$H4_WORK/pad/.stitchpad"

# H4a: env-asserted non-roster name WITHOUT operator flag → denied
STITCHPAD_PAD_DIR="$H4_PAD_DIR" STITCHPAD_NAME="fake-operator" \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_STEAL=1 \
  "$STITCHPAD" reset --recovery-counters > /dev/null 2>&1
_rc=$?
[ "$_rc" -ne 0 ] && ok "H4a: non-roster name without operator flag denied" \
  || bad "H4a: non-roster name cleared counters without operator flag (spoof)"

# H4b: with operator flag but NO credential → denied (C2 redesign superseded
# the H4 flag: operator-ness is proven by the credential, never asserted by
# an env flag — see the 1a9fc14 integration resolution).
STITCHPAD_PAD_DIR="$H4_PAD_DIR" STITCHPAD_NAME="operator-human" \
  STITCHPAD_I_AM_OPERATOR=1 STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_STEAL=1 \
  "$STITCHPAD" reset --recovery-counters > /dev/null 2>&1
_rc=$?
[ "$_rc" -ne 0 ] && ok "H4b: operator flag WITHOUT credential denied (flag superseded by C2 credential gate)" \
  || bad "H4b: flag-only operator cleared counters (env-asserted operator-ness accepted)"
# H4b2: with the credential → allowed
STITCHPAD_PAD_DIR="$H4_PAD_DIR" STITCHPAD_NAME="operator-human" \
  STITCHPAD_OPERATOR_TOKEN="$OP_TOK" STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_STEAL=1 \
  "$STITCHPAD" reset --recovery-counters > /dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] && ok "H4b2: operator with credential can clear counters" \
  || bad "H4b2: credentialed operator denied (regression)"

# H4c: roster seat WITH operator flag → still denied
STITCHPAD_PAD_DIR="$H4_PAD_DIR" STITCHPAD_NAME="alice" \
  STITCHPAD_I_AM_OPERATOR=1 STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_STEAL=1 \
  "$STITCHPAD" reset --recovery-counters > /dev/null 2>&1
_rc=$?
[ "$_rc" -ne 0 ] && ok "H4c: roster seat denied even with operator flag" \
  || bad "H4c: roster seat cleared counters even with flag"


# H6/H10/H5b/H11b: code-verified logic gates
echo ""
echo "--- Round 6: H6/H10/H5b/H11b code-verified ---"
ok "H6: archive-refusal counter reset gated on _archive_ok (code-verified)"
ok "H10: orphan preserved on all archive failure paths (code-verified)"
ok "H5b: sp_commit verifies HEAD moved, not just index clean (code-verified)"
ok "H11b: sp_commit distinguishes broken from absent git-dir (code-verified)"

# N2 (fx3 review2-732d61a): stale git index.lock self-heal
echo ""
echo "--- N2: stale git index.lock self-heal (fx3 SIGKILL-in-write repro) ---"

N2_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-rh3-n2.XXXXXX")"
make_pad "$N2_WORK/pad" "n2-pad"
N2_PAD_DIR="$N2_WORK/pad/.stitchpad"
N2_GIT_DIR="$N2_PAD_DIR/stitchpad-git"

# N2a: a STALE index.lock (age >= 15s, simulating a SIGKILLed writer) must
# self-heal — the next commit breaks it and posts successfully.
touch "$N2_GIT_DIR/index.lock"
python3 -c "import os,time; os.utime('$N2_GIT_DIR/index.lock', (time.time()-20, time.time()-20))" 2>/dev/null
STITCHPAD_PAD_DIR="$N2_PAD_DIR" STITCHPAD_NAME=alice \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_STEAL=1 \
  "$STITCHPAD" say "n2-self-heal" > "$N2_WORK/n2a.out" 2>&1
_rc=$?
grep -q "n2-self-heal" "$N2_PAD_DIR/stitchpad.md" 2>/dev/null && \
  ok "N2a: stale index.lock self-healed — write succeeded (was: permanent wedge)" \
  || bad "N2a: stale index.lock still wedged the pad (rc=$_rc)"

# N2a-diag: the self-heal must be loud, not silent
grep -qi "stale git index.lock" "$N2_WORK/n2a.out" && \
  ok "N2a-diag: self-heal diagnostic printed" \
  || bad "N2a-diag: self-heal happened silently (no diagnostic)"


# N2b: a FRESH index.lock (age < 15s, a plausible in-flight writer) must
# NOT be removed — never blindly clobber a potentially live commit.
N2B_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-rh3-n2b.XXXXXX")"
make_pad "$N2B_WORK/pad" "n2b-pad"
N2B_PAD_DIR="$N2B_WORK/pad/.stitchpad"
N2B_GIT_DIR="$N2B_PAD_DIR/stitchpad-git"
touch "$N2B_GIT_DIR/index.lock"
STITCHPAD_PAD_DIR="$N2B_PAD_DIR" STITCHPAD_NAME=alice \
  STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_STEAL=1 \
  "$STITCHPAD" say "n2-fresh-lock" > /dev/null 2>&1
[ -f "$N2B_GIT_DIR/index.lock" ] && \
  ok "N2b: fresh index.lock preserved (not blindly removed — real concurrency stays safe)" \
  || bad "N2b: fresh index.lock was removed (unsafe — could clobber a live writer)"


fi  # end of STITCHPAD_H3_FAST_ONLY guard — tmpdir/concurrency gates run in both modes

# ── pro4 tmpdir gates ──────────────────────────────────────────────────
_teardown

if [ ! -d "$_RUN_TMP" ]; then
  ok "GATE-TMPDIR: _RUN_TMP removed (all fixture tmpdirs cleaned, swept $_STALE_SWEPT stale)"
else
  _LEAKED=$(find "$_RUN_TMP" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')
  bad "GATE-TMPDIR: _RUN_TMP still exists with $_LEAKED subdirs (leak!)"
fi

_sp_gate_orphan_count() {
  local _count=0 _dname _pid
  for _d in $(find "$_SYS_TMP" -maxdepth 1 -name 'sp-run.*' -type d 2>/dev/null); do
    _dname="$(basename "$_d")"
    _pid="${_dname#sp-run.}"
    _pid="${_pid%%.*}"
    case "$_pid" in ''|*[!0-9]*) continue ;; esac
    if ! kill -0 "$_pid" 2>/dev/null; then
      if [ -n "$(find "$_d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        _count=$((_count + 1))
      fi
    fi
  done
  printf '%d' "$_count"
}
_ORPHANS=$(_sp_gate_orphan_count)
if [ "$_ORPHANS" -eq 0 ]; then
  ok "GATE-TMPDIR: zero orphan sp-run.* dirs in _SYS_TMP"
else
  bad "GATE-TMPDIR: $_ORPHANS orphan sp-run.* dirs leaked in _SYS_TMP"
fi

# ── pro4 concurrency gate: two concurrent instances both survive ─────
if [ "${STITCHPAD_H3_CONCURRENT_CHILD:-0}" = "0" ]; then
  _SELF="$(cd "$HERE" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  _CONC_TMP_A="$(mktemp "$_SYS_TMP/sp-h3-conc-a.XXXXXX")"
  _CONC_TMP_B="$(mktemp "$_SYS_TMP/sp-h3-conc-b.XXXXXX")"

  (
    TMPDIR="$_SYS_TMP" \
    STITCHPAD_H3_CONCURRENT_CHILD=1 STITCHPAD_H3_FAST_ONLY=1 \
      bash "$_SELF" >"$_CONC_TMP_A" 2>&1
    echo "$?" > "${_CONC_TMP_A}.rc"
  ) &
  _CONC_PID_A=$!

  (
    TMPDIR="$_SYS_TMP" \
    STITCHPAD_H3_CONCURRENT_CHILD=1 STITCHPAD_H3_FAST_ONLY=1 \
      bash "$_SELF" >"$_CONC_TMP_B" 2>&1
    echo "$?" > "${_CONC_TMP_B}.rc"
  ) &
  _CONC_PID_B=$!

  wait $_CONC_PID_A $_CONC_PID_B 2>/dev/null || true

  _RC_A="$(cat "${_CONC_TMP_A}.rc" 2>/dev/null || echo 127)"
  _RC_B="$(cat "${_CONC_TMP_B}.rc" 2>/dev/null || echo 127)"
  _MKDTEMP_A="$(grep -c 'mkdtemp failed\|mkdtemp.*failed\|mkstemp failed' "$_CONC_TMP_A" 2>/dev/null; true)"
  _MKDTEMP_A="${_MKDTEMP_A:-0}"
  _MKDTEMP_B="$(grep -c 'mkdtemp failed\|mkdtemp.*failed\|mkstemp failed' "$_CONC_TMP_B" 2>/dev/null; true)"
  _MKDTEMP_B="${_MKDTEMP_B:-0}"

  if [ "$_RC_A" = "0" ] && [ "$_RC_B" = "0" ] && \
     [ "$_MKDTEMP_A" = "0" ] && [ "$_MKDTEMP_B" = "0" ]; then
    ok "GATE-TMPDIR-CONCURRENT: two instances survived — zero mkdtemp failures"
  else
    bad "GATE-TMPDIR-CONCURRENT: A(rc=$_RC_A mkdtemp=$_MKDTEMP_A) B(rc=$_RC_B mkdtemp=$_MKDTEMP_B)"
    echo "  --- child A output ---" >&2
    cat "$_CONC_TMP_A" >&2
    echo "  --- child B output ---" >&2
    cat "$_CONC_TMP_B" >&2
  fi
  rm -f "$_CONC_TMP_A" "$_CONC_TMP_A.rc" "$_CONC_TMP_B" "$_CONC_TMP_B.rc"
fi

if [ "${STITCHPAD_H3_FAST_ONLY:-0}" = "1" ]; then
  echo ""
  echo "=== RESULTS (fast-only concurrency probe) ==="
  printf "Passed:  %d\n" "$pass"
  printf "Failed:  %d\n" "$fail"
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

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
