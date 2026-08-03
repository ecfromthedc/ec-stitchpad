#!/usr/bin/env bash
# date-session-atomicity.sh — STITCHPAD_TEST_COMMIT_FAIL rollback regression
#
# Proves that a failed sp_commit in the `say` and `leave` paths:
#   1. Restores byte-identical pad content (no partial message/roster edit)
#   2. Restores byte-identical session registry (no orphaned entry)
#   3. Restores byte-identical lifecycle markers (no orphaned start/end)
#   4. Restores byte-identical divider epoch (no advance on failed post)
#   5. Exits 1 (fail-closed)
#
# Also proves the happy path works normally WITHOUT the injection (control):
#   6. say without injection posts and commits
#   7. leave without injection removes from roster and commits
#
# Drives the real stitchpad binary via STITCHPAD_PAD_DIR. No mocks beyond the
# STITCHPAD_TEST_COMMIT_FAIL hook (which lives in production lib.sh).
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
STITCHPAD="$ROOT/tool/bin/stitchpad"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

# ── snapshot helpers ──────────────────────────────────────────────────
# Capture a recursive content digest of a directory tree (no-follow).
_snap_dir() {
  python3 - "$1" <<'PYEOF'
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
if not os.path.isdir(root):
    h.update(b"MISSING:" + root.encode())
    print(h.hexdigest()); sys.exit(0)
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames.sort()
    for name in sorted(dirnames):
        p = os.path.join(dirpath, name)
        rel = os.path.relpath(p, root)
        if os.path.islink(p):
            h.update(b"L\0" + rel.encode("utf-8") + b"\0" + os.readlink(p).encode("utf-8") + b"\0")
        else:
            h.update(b"D\0" + rel.encode("utf-8") + b"\0")
    for name in sorted(filenames):
        p = os.path.join(dirpath, name)
        rel = os.path.relpath(p, root)
        if os.path.islink(p):
            h.update(b"L\0" + rel.encode("utf-8") + b"\0" + os.readlink(p).encode("utf-8") + b"\0")
            continue
        with open(p, "rb") as fh:
            data = fh.read()
        h.update(b"F\0" + rel.encode("utf-8") + b"\0" + str(len(data)).encode("ascii") + b"\0" + data + b"\0")
print(h.hexdigest())
PYEOF
}

# Capture full state digest: pad file + state dir (registry, markers, epoch)
state_digest() {
  local pad="$1" state="$2"
  local pad_hash state_hash
  if [ -f "$pad" ]; then
    pad_hash="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$pad")"
  else
    pad_hash="MISSING"
  fi
  state_hash="$(_snap_dir "$state")"
  printf '%s\n%s\n' "$pad_hash" "$state_hash"
}

echo "=== date-session-atomicity tests ==="
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Fixture: full pad with git, roster, session binding
# ══════════════════════════════════════════════════════════════════════════════
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-atom.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PAD_DIR="$WORK/.stitchpad"
PAD_MD="$PAD_DIR/stitchpad.md"
PAD_STATE="$PAD_DIR/.state"
PAD_GIT="$PAD_DIR/stitchpad-git"

export STITCHPAD_PAD_DIR="$PAD_DIR"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export HOME="$WORK/home"

# Hermeticity: clear all session identity env vars so results never depend on
# the runner's ambient environment (Claude Code exports CLAUDE_CODE_SESSION_ID,
# Codex exports CODEX_SESSION_ID). Each test that needs a session sets it
# explicitly via a prefixed env assignment on the command line.
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

mkdir -p "$HOME" "$PAD_STATE/sessions" "$PAD_STATE/claims"

# Minimal pad with roster
cat > "$PAD_MD" <<'EOPAD'
```roster
alice | claude | pull | -
bob   | ocean  | push | target-123
```
EOPAD

# Initialize pad git so sp_commit has something to commit to
mkdir -p "$PAD_GIT"
git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" init -q
git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" config user.email "test@test.com"
git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" config user.name "Test"
git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" add stitchpad.md
git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" commit -q -m "initial"

# Initialize session registry so lifecycle_locked can record events
touch "$PAD_STATE/session-registry.jsonl"

# Bind a session for alice
TEST_SID="test-session-alice-001"
printf 'alice' > "$PAD_STATE/sessions/$TEST_SID"

echo "--- setup complete ---"

# ══════════════════════════════════════════════════════════════════════════════
# 1. SAY with STITCHPAD_TEST_COMMIT_FAIL: rollback + exit 1
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- 1. say with commit failure: rollback + exit 1 ---"

BEFORE="$(state_digest "$PAD_MD" "$PAD_STATE")"
BEFORE_LOG_LINES=$(git --git-dir="$PAD_GIT" log --oneline | wc -l | tr -d ' ')

SAY_RC=0
SAY_OUT="$(STITCHPAD_SESSION="$TEST_SID" STITCHPAD_NAME=alice \
  STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 \
  "$STITCHPAD" say "this message should not survive" 2>&1)" || SAY_RC=$?

[ "$SAY_RC" -eq 1 ] && ok "1a: say with commit fail exits 1" \
  || bad "1a: say with commit fail exits 1 (got rc=$SAY_RC)"

echo "$SAY_OUT" | grep -q "pad commit failed" && ok "1b: say reports pad commit failure" \
  || bad "1b: say reports pad commit failure (output: $(printf '%s' "$SAY_OUT" | head -c 200))"

AFTER="$(state_digest "$PAD_MD" "$PAD_STATE")"
[ "$AFTER" = "$BEFORE" ] && ok "1c: pad + state byte-identical after failed say rollback" \
  || bad "1c: pad + state byte-identical after failed say rollback (state diverged)"

# The message text must NOT appear in the pad
grep -q "this message should not survive" "$PAD_MD" && \
  bad "1d: message text absent from pad after rollback (found it!)" || \
  ok "1d: message text absent from pad after rollback"

# No new git commit
AFTER_LOG_LINES=$(git --git-dir="$PAD_GIT" log --oneline | wc -l | tr -d ' ')
[ "$AFTER_LOG_LINES" = "$BEFORE_LOG_LINES" ] && \
  ok "1e: no new git commit after failed say" || \
  bad "1e: no new git commit after failed say (before=$BEFORE_LOG_LINES after=$AFTER_LOG_LINES)"

# Registry must not have a new entry for the failed say
REG_LINES=$(wc -l < "$PAD_STATE/session-registry.jsonl" 2>/dev/null | tr -d ' ')
[ "$REG_LINES" = "0" ] && ok "1f: registry still empty after failed say" \
  || bad "1f: registry still empty after failed say (lines=$REG_LINES)"

# ══════════════════════════════════════════════════════════════════════════════
# 2. LEAVE with STITCHPAD_TEST_COMMIT_FAIL: rollback + exit 1
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- 2. leave with commit failure: rollback + exit 1 ---"

# Re-snapshot (state may have changed from marker writes during the failed say)
BEFORE2="$(state_digest "$PAD_MD" "$PAD_STATE")"
BEFORE2_LOG_LINES=$(git --git-dir="$PAD_GIT" log --oneline | wc -l | tr -d ' ')
BEFORE2_ROSTER=$(grep -c '^bob' "$PAD_MD" || true)

LEAVE_RC=0
LEAVE_OUT="$(STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 \
  "$STITCHPAD" leave bob 2>&1)" || LEAVE_RC=$?

[ "$LEAVE_RC" -eq 1 ] && ok "2a: leave with commit fail exits 1" \
  || bad "2a: leave with commit fail exits 1 (got rc=$LEAVE_RC)"

echo "$LEAVE_OUT" | grep -q "rolled back\|commit failed" && ok "2b: leave reports rollback/commit failure" \
  || bad "2b: leave reports rollback/commit failure (output: $(printf '%s' "$LEAVE_OUT" | head -c 200))"

AFTER2="$(state_digest "$PAD_MD" "$PAD_STATE")"
[ "$AFTER2" = "$BEFORE2" ] && ok "2c: pad + state byte-identical after failed leave rollback" \
  || bad "2c: pad + state byte-identical after failed leave rollback (state diverged)"

# Bob must still be in the roster
AFTER2_ROSTER=$(grep -c '^bob' "$PAD_MD" || true)
[ "$AFTER2_ROSTER" = "$BEFORE2_ROSTER" ] && ok "2d: roster unchanged after failed leave" \
  || bad "2d: roster unchanged after failed leave (before=$BEFORE2_ROSTER after=$AFTER2_ROSTER)"

# No new git commit
AFTER2_LOG_LINES=$(git --git-dir="$PAD_GIT" log --oneline | wc -l | tr -d ' ')
[ "$AFTER2_LOG_LINES" = "$BEFORE2_LOG_LINES" ] && \
  ok "2e: no new git commit after failed leave" || \
  bad "2e: no new git commit after failed leave (before=$BEFORE2_LOG_LINES after=$AFTER2_LOG_LINES)"

# ══════════════════════════════════════════════════════════════════════════════
# 3. SAY control: without injection, post succeeds
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- 3. say control (no injection): succeeds ---"

CTRL3_LOG_BEFORE=$(git --git-dir="$PAD_GIT" log --oneline | wc -l | tr -d ' ')
CTRL_RC=0
CTRL_OUT="$(STITCHPAD_SESSION="$TEST_SID" STITCHPAD_NAME=alice \
  "$STITCHPAD" say "control message should post" 2>&1)" || CTRL_RC=$?

[ "$CTRL_RC" -eq 0 ] && ok "3a: control say exits 0" \
  || bad "3a: control say exits 0 (got rc=$CTRL_RC, out=$(printf '%s' "$CTRL_OUT" | head -c 200))"

echo "$CTRL_OUT" | grep -q "posted as" && ok "3b: control say reports success" \
  || bad "3b: control say reports success (output: $(printf '%s' "$CTRL_OUT" | head -c 200))"

grep -q "control message should post" "$PAD_MD" && ok "3c: control message in pad" \
  || bad "3c: control message in pad (not found)"

# New git commit exists
CTRL3_LOG_AFTER=$(git --git-dir="$PAD_GIT" log --oneline | wc -l | tr -d ' ')
[ "$CTRL3_LOG_AFTER" -gt "$CTRL3_LOG_BEFORE" ] && ok "3d: new git commit after control say" \
  || bad "3d: new git commit after control say (before=$CTRL3_LOG_BEFORE after=$CTRL3_LOG_AFTER)"

# ══════════════════════════════════════════════════════════════════════════════
# 4. LEAVE control: without injection, succeeds
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- 4. leave control (no injection): succeeds ---"

CTRL2_OUT=""
CTRL2_RC=0
CTRL2_OUT="$("$STITCHPAD" leave bob 2>&1)" || CTRL2_RC=$?

[ "$CTRL2_RC" -eq 0 ] && ok "4a: control leave exits 0" \
  || bad "4a: control leave exits 0 (got rc=$CTRL2_RC, out=$(printf '%s' "$CTRL2_OUT" | head -c 200))"

# Bob gone from roster
CTRL2_ROSTER=$(grep -c '^bob' "$PAD_MD" || true)
[ "$CTRL2_ROSTER" = "0" ] && ok "4b: bob removed from roster after control leave" \
  || bad "4b: bob removed from roster after control leave (still $CTRL2_ROSTER lines)"

# ══════════════════════════════════════════════════════════════════════════════
# 4c. LEAVE with commit failure + AMBIENT CLAUDE_CODE_SESSION_ID: rollback covers env-resolved markers
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- 4c. leave with commit failure + ambient sid: marker rollback ---"

# Restore the pad for this test
cat > "$PAD_MD" <<'EOPAD'
```roster
alice | claude | pull | -
bob   | ocean  | push | target-123
```
EOPAD
git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" add stitchpad.md
git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" commit -q -m "reset for ambient-sid test"

AMBIENT_SID="ambient-claude-code-session-42"

BEFORE_AMB="$(state_digest "$PAD_MD" "$PAD_STATE")"
BEFORE_AMB_LOG=$(git --git-dir="$PAD_GIT" log --oneline | wc -l | tr -d ' ')

AMB_RC=0
AMB_OUT="$(CLAUDE_CODE_SESSION_ID="$AMBIENT_SID" STITCHPAD_NAME=glm \
  STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 \
  "$STITCHPAD" leave bob 2>&1)" || AMB_RC=$?

[ "$AMB_RC" -eq 1 ] && ok "4c1: leave+ambient-sid with commit fail exits 1" \
  || bad "4c1: leave+ambient-sid with commit fail exits 1 (got rc=$AMB_RC)"

AFTER_AMB="$(state_digest "$PAD_MD" "$PAD_STATE")"
[ "$AFTER_AMB" = "$BEFORE_AMB" ] && ok "4c2: pad+state byte-identical after failed leave+ambient rollback" \
  || bad "4c2: pad+state byte-identical after failed leave+ambient rollback (state diverged)"

# Specifically check that no ambient marker files leaked
AMB_END_LEAKED=0
for suffix in session-end session-activity request-id session-start; do
  if [ -f "$PAD_STATE/$suffix.$AMBIENT_SID" ]; then
    AMB_END_LEAKED=1
    bad "4c3: ambient marker $suffix.$AMBIENT_SID leaked after rollback"
  fi
done
[ "$AMB_END_LEAKED" = "0" ] && ok "4c3: no ambient marker files leaked after rollback" || true

# Roster must be unchanged
AMB_ROSTER=$(grep -c '^bob' "$PAD_MD" || true)
[ "$AMB_ROSTER" = "1" ] && ok "4c4: roster unchanged after failed leave+ambient" \
  || bad "4c4: roster unchanged after failed leave+ambient (bob count=$AMB_ROSTER)"

# ══════════════════════════════════════════════════════════════════════════════
# 5. Journal symlink refusal: journal_begin refuses symlinked state files
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- 5. journal refuses symlinked state file ---"

# Restore the pad for this test
cat > "$PAD_MD" <<'EOPAD'
```roster
alice | claude | pull | -
bob   | ocean  | push | target-123
```
EOPAD
git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" add stitchpad.md
git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" commit -q -m "reset for symlink test"

# Source libraries directly to test journal_begin
export PAD_DIR="$PAD_DIR" PAD_MD="$PAD_MD" PAD_STATE="$PAD_STATE" PAD_GIT="$PAD_GIT"
source "$ROOT/tool/bin/lib.sh"
source "$ROOT/tool/bin/date-divider.sh"
source "$ROOT/tool/bin/session-registry.sh"

# Create a symlink in place of a state file that the journal would snapshot
rm -f "$PAD_STATE/last-divider-epoch"
ln -sf /dev/null "$PAD_STATE/last-divider-epoch"

JB_RC=0
JB_DIR="$(sp_session_registry_journal_begin "$TEST_SID" 2>&1)" || JB_RC=$?

[ "$JB_RC" -ne 0 ] && ok "5a: journal_begin refuses symlinked state file" \
  || { bad "5a: journal_begin refuses symlinked state file (got jdir=$JB_DIR)"; rm -rf "$JB_DIR" 2>/dev/null; }

# Symlink must not have been followed
[ -L "$PAD_STATE/last-divider-epoch" ] && ok "5b: symlink not followed by journal_begin" \
  || bad "5b: symlink not followed by journal_begin (was overwritten)"

rm -f "$PAD_STATE/last-divider-epoch"

# ══════════════════════════════════════════════════════════════════════════════
# 6. Journal begin/rollback round-trip: restore creates exact pre-op state
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- 6. journal round-trip: rollback restores exact pre-op state ---"

# Clean state for this test
rm -f "$PAD_STATE/session-registry.jsonl" "$PAD_STATE/session-start."* "$PAD_STATE/session-end."* 2>/dev/null
sp_session_registry_init

# Write some initial registry content
STITCHPAD_SESSION="$TEST_SID" STITCHPAD_NAME=alice STITCHPAD_MODEL=claude-test \
  sp_session_registry_record_event activity 2>/dev/null || true

BEFORE6="$(state_digest "$PAD_MD" "$PAD_STATE")"
BEFORE6_REG_LINES=$(wc -l < "$PAD_STATE/session-registry.jsonl" 2>/dev/null | tr -d ' ')

# Begin journal
J6_DIR="$(sp_session_registry_journal_begin "$TEST_SID")"
[ -d "$J6_DIR" ] && ok "6a: journal_begin succeeds with valid state" \
  || bad "6a: journal_begin succeeds with valid state (got empty jdir)"

# Simulate mutations that an operation would make
echo "MUTATED" >> "$PAD_MD"
echo '{"mutated":true}' >> "$PAD_STATE/session-registry.jsonl"
printf '%s' "999999" > "$PAD_STATE/session-start.$TEST_SID"

# Rollback
sp_session_registry_journal_rollback "$J6_DIR" "$TEST_SID"

AFTER6="$(state_digest "$PAD_MD" "$PAD_STATE")"
[ "$AFTER6" = "$BEFORE6" ] && ok "6b: rollback restores exact pre-op state" \
  || bad "6b: rollback restores exact pre-op state (state diverged)"

# "MUTATED" must be gone
grep -q "MUTATED" "$PAD_MD" && bad "6c: rollback removed appended pad content (still present)" || \
  ok "6c: rollback removed appended pad content"

# The mutated registry line must be gone — line count must match original
AFTER6_REG_LINES=$(wc -l < "$PAD_STATE/session-registry.jsonl" 2>/dev/null | tr -d ' ')
[ "$AFTER6_REG_LINES" = "$BEFORE6_REG_LINES" ] && ok "6d: rollback removed appended registry line (line count matches)" \
  || bad "6d: rollback removed appended registry line (before=$BEFORE6_REG_LINES after=$AFTER6_REG_LINES)"

# Journal dir consumed
[ ! -d "$J6_DIR" ] && ok "6e: journal dir consumed after rollback" \
  || bad "6e: journal dir consumed after rollback (still exists)"

# ══════════════════════════════════════════════════════════════════════════════
# 7. Journal commit: success path drops journal cleanly
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- 7. journal_commit drops journal on success ---"

J7_DIR="$(sp_session_registry_journal_begin "$TEST_SID")"
[ -d "$J7_DIR" ] && ok "7a: journal_begin for commit test" \
  || bad "7a: journal_begin for commit test (got empty)"

sp_session_registry_journal_commit "$J7_DIR"
[ ! -d "$J7_DIR" ] && ok "7b: journal_commit removes journal dir" \
  || bad "7b: journal_commit removes journal dir (still exists)"

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
printf "Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
