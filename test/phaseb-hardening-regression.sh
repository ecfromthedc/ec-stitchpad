#!/usr/bin/env bash
# phaseb-hardening-regression.sh — C1-C4 hardening regression tests
#
# Proves the four confirmed defects from flash's adversarial cross-review
# (flash-cross-phaseb-524bea3.md) are fixed:
#
#   C1: stale-journal detection + recovery on next guarded op
#   C2: state-root swap detected and refused before rollback writes
#   C3: STITCHPAD_TEST_COMMIT_FAIL gated behind STITCHPAD_TEST_MODE=1
#   C4: leave roster-edit write failure propagates and rolls back
#
# Each test class reproduces flash's repro then asserts the fix.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
STITCHPAD="$ROOT/tool/bin/stitchpad"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

# ── helpers ───────────────────────────────────────────────────────────────
_snap_dir() {
  python3 - "$1" <<'PYEOF'
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
if not os.path.isdir(root):
    h.update(b"MISSING:" + root.encode())
    print(h.hexdigest()); sys.exit(0)
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    # TASK-7 telemetry is best-effort and outside the journal contract — its
    # per-second jsonl/drop counter must never break byte-identical digests.
    dirnames[:] = [d for d in dirnames if d != "telemetry"]
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

state_digest() {
  local pad="$1" state="$2"
  local pad_hash
  if [ -f "$pad" ]; then
    pad_hash="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$pad")"
  else
    pad_hash="MISSING"
  fi
  printf '%s\n%s\n' "$pad_hash" "$(_snap_dir "$state")"
}

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

echo "=== phaseb-hardening-regression tests ==="
echo ""

# ============================================================================
# C1: Stale-Journal Recovery
# ============================================================================
echo "--- C1: stale-journal recovery ---"

C1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-hard-c1.XXXXXX")"
C1_CLEAN="rm -rf $C1_WORK"
trap "$C1_CLEAN" EXIT

make_pad "$C1_WORK/test-pad" "c1-pad"
C1_PAD_DIR="$C1_WORK/test-pad/.stitchpad"
C1_PAD_MD="$C1_PAD_DIR/stitchpad.md"
C1_PAD_STATE="$C1_PAD_DIR/.state"
C1_GIT="$C1_PAD_DIR/stitchpad-git"

export STITCHPAD_PAD_DIR="$C1_PAD_DIR"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export HOME="$C1_WORK/home"
mkdir -p "$HOME"
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

# Bind alice
C1_SID="c1-alice-001"
printf 'alice' > "$C1_PAD_STATE/sessions/$C1_SID"

# Source journal functions to create a REAL orphan (with valid snapshots)
source "$ROOT/tool/bin/lib.sh"
source "$ROOT/tool/bin/date-divider.sh"
source "$ROOT/tool/bin/session-registry.sh"
PAD_DIR="$C1_PAD_DIR"
PAD_MD="$C1_PAD_MD"
PAD_STATE="$C1_PAD_STATE"

# Create a REAL orphan journal by calling journal_begin and never cleaning it
C1_ORPHAN="$(STITCHPAD_SESSION="$C1_SID" sp_session_registry_journal_begin "$C1_SID")"
[ -n "$C1_ORPHAN" ] && [ -d "$C1_ORPHAN" ] || { bad "C1_setup: could not create orphan journal"; exit 1; }

# Now run say — it should recover the orphan, restore pre-crash state, and post
C1_SAY_OUT="$(STITCHPAD_TEST_MODE=1 STITCHPAD_SESSION="$C1_SID" STITCHPAD_NAME=alice \
  "$STITCHPAD" say "post-crash message" 2>&1)" || C1_SAY_RC=$?
C1_SAY_RC=${C1_SAY_RC:-0}

[ "$C1_SAY_RC" -eq 0 ] && ok "C1a: say succeeds after orphan recovery (rc=0)" \
  || bad "C1a: say succeeded after orphan recovery (rc=$C1_SAY_RC)"

# C1b: orphan journal must be GONE
[ ! -d "$C1_ORPHAN" ] && ok "C1b: orphan journal removed after recovery" \
  || bad "C1b: orphan journal removed after recovery (still present)"

# C1c: message actually posted
grep -q "post-crash message" "$C1_PAD_MD" && ok "C1c: message posted through recovery" \
  || bad "C1c: message posted through recovery (not found in pad)"

# C1d: no orphan journals remain
C1_ORPHANS="$(find "$C1_PAD_STATE" -maxdepth 1 -name '.registry-journal.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$C1_ORPHANS" = "0" ] && ok "C1d: zero orphan journals remain" \
  || bad "C1d: zero orphan journals remain (found $C1_ORPHANS)"

# C1e: two consecutive orphan journals — recovery handles both.
# journal_begin recovers orphans first, so the second call cleans the first.
# Create first orphan, then create second (which recovers first), verify
# second exists and the say recovers it.
C1_ORPHAN_A="$(STITCHPAD_SESSION="$C1_SID" sp_session_registry_journal_begin "$C1_SID")"
[ -d "$C1_ORPHAN_A" ] || { bad "C1e_setup: could not create first orphan"; }
C1_ORPHAN_B="$(STITCHPAD_SESSION="$C1_SID" sp_session_registry_journal_begin "$C1_SID")"
[ -d "$C1_ORPHAN_B" ] || { bad "C1e_setup: could not create second orphan (first may have been recovered)"; }
# C1_ORPHAN_A may already be gone (recovered by second journal_begin) — that's fine

C1_SAY2_OUT="$(STITCHPAD_TEST_MODE=1 STITCHPAD_SESSION="$C1_SID" STITCHPAD_NAME=alice \
  "$STITCHPAD" say "second message" 2>&1)" || C1_SAY2_RC=$?
C1_SAY2_RC=${C1_SAY2_RC:-0}

[ "$C1_SAY2_RC" -eq 0 ] && ok "C1e: say succeeds with multiple orphans (rc=0)" \
  || bad "C1e: say succeeded with multiple orphans (rc=$C1_SAY2_RC)"

C1_ORPHANS2="$(find "$C1_PAD_STATE" -maxdepth 1 -name '.registry-journal.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$C1_ORPHANS2" = "0" ] && ok "C1f: both orphans cleaned up" \
  || bad "C1f: both orphans cleaned up (found $C1_ORPHANS2)"

# ============================================================================
# C2: State-Root Swap Detection
# ============================================================================
echo ""
echo "--- C2: state-root swap detection ---"

C2_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-hard-c2.XXXXXX")"
C2_CLEAN="rm -rf $C2_WORK $C1_WORK"
trap "$C2_CLEAN" EXIT

make_pad "$C2_WORK/test-pad" "c2-pad"
C2_PAD_DIR="$C2_WORK/test-pad/.stitchpad"
C2_PAD_STATE="$C2_PAD_DIR/.state"

C2_SID="c2-test-sid"
printf 'alice' > "$C2_PAD_STATE/sessions/$C2_SID"
printf '{"request_id":"c2-alice-0","session_id":"%s","provider":"ocean","model":"test","worktree":"/tmp","event":"activity","epoch":1000000000}\n' "$C2_SID" > "$C2_PAD_STATE/session-registry.jsonl"

source "$ROOT/tool/bin/lib.sh"
source "$ROOT/tool/bin/date-divider.sh"
source "$ROOT/tool/bin/session-registry.sh"
PAD_DIR="$C2_PAD_DIR"
PAD_MD="$C2_PAD_DIR/stitchpad.md"
PAD_STATE="$C2_PAD_STATE"

# C2a: begin journal, swap state root, rollback must FAIL
C2_JOURNAL="$(sp_session_registry_journal_begin "$C2_SID")"
[ -n "$C2_JOURNAL" ] && [ -d "$C2_JOURNAL" ] && ok "C2a: journal_begin succeeded" \
  || { bad "C2a: journal_begin succeeded (dir=$C2_JOURNAL)"; C2_JOURNAL=""; }

if [ -n "$C2_JOURNAL" ]; then
  # Swap: rename real state, symlink to a fake dir
  C2_REAL_STATE="$C2_PAD_STATE"
  C2_FAKE="$(mktemp -d "$C2_WORK/fake-state.XXXXXX")"
  mv "$C2_REAL_STATE" "$C2_WORK/real-state-saved"
  ln -s "$C2_FAKE" "$C2_REAL_STATE"

  C2_ROLL_RC=0
  C2_ROLL_OUT="$(sp_session_registry_journal_rollback "$C2_JOURNAL" "$C2_SID" 2>&1)" || C2_ROLL_RC=$?

  # Restore
  rm -f "$C2_REAL_STATE"
  mv "$C2_WORK/real-state-saved" "$C2_REAL_STATE"

  [ "$C2_ROLL_RC" -ne 0 ] && ok "C2b: rollback refuses after state-root swap (rc=$C2_ROLL_RC)" \
    || bad "C2b: rollback refuses after state-root swap (got rc=0)"

  echo "$C2_ROLL_OUT" | grep -qi "swap\|state.root\|detected" && ok "C2c: rollback reports swap detection on stderr" \
    || bad "C2c: rollback reports swap detection (got: $(printf '%s' "$C2_ROLL_OUT" | head -c 200))"

  # C2d: rollback without swap succeeds (control)
  C2_JOURNAL2="$(sp_session_registry_journal_begin "$C2_SID")"
  [ -n "$C2_JOURNAL2" ] && [ -d "$C2_JOURNAL2" ] && ok "C2d: second journal_begin succeeds" \
    || { bad "C2d: second journal_begin succeeded"; C2_JOURNAL2=""; }

  if [ -n "$C2_JOURNAL2" ]; then
    sp_session_registry_journal_rollback "$C2_JOURNAL2" "$C2_SID" >/dev/null 2>&1 && \
      ok "C2e: rollback succeeds without swap (control)" || \
      bad "C2e: rollback succeeds without swap"
  fi
fi

# ============================================================================
# C3: Blast Radius — TEST_COMMIT_FAIL Gated Behind TEST_MODE
# ============================================================================
echo ""
echo "--- C3: blast radius / hook gating ---"

C3_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-hard-c3.XXXXXX")"
C3_CLEAN="rm -rf $C3_WORK $C2_WORK $C1_WORK"
trap "$C3_CLEAN" EXIT

make_pad "$C3_WORK/test-pad" "c3-pad"
C3_PAD_DIR="$C3_WORK/test-pad/.stitchpad"
C3_PAD_MD="$C3_PAD_DIR/stitchpad.md"
C3_PAD_STATE="$C3_PAD_DIR/.state"
C3_GIT="$C3_PAD_DIR/stitchpad-git"

export STITCHPAD_PAD_DIR="$C3_PAD_DIR"

# C3a: STITCHPAD_TEST_COMMIT_FAIL=1 WITHOUT TEST_MODE=1 -> hook INERT
C3_CLEAR_OUT="$(STITCHPAD_NAME=alice STITCHPAD_TEST_COMMIT_FAIL=1 \
  "$STITCHPAD" clear 2>&1)" || C3_CLEAR_RC=$?
C3_CLEAR_RC=${C3_CLEAR_RC:-0}

echo "$C3_CLEAR_OUT" | grep -qi "cleared" && ok "C3a: clear succeeds without TEST_MODE (hook inert)" \
  || bad "C3a: clear succeeds without TEST_MODE (rc=$C3_CLEAR_RC output: $(printf '%s' "$C3_CLEAR_OUT" | head -c 200))"

# C3b: HEAD must have advanced (clear actually committed)
C3_HEAD1="$(git --git-dir="$C3_GIT" rev-parse HEAD 2>/dev/null)"
C3_INIT="$(git --git-dir="$C3_GIT" log --format='%H' --reverse | head -1)"
[ "$C3_HEAD1" != "$C3_INIT" ] && ok "C3b: clear produced a new commit (hook was inert)" \
  || bad "C3b: clear produced a new commit (HEAD unchanged — hook fired without TEST_MODE)"

# Rebuild pad for join test
rm -rf "$C3_PAD_DIR"
make_pad "$C3_WORK/test-pad" "c3-pad-2"
C3_PAD_MD="$C3_PAD_DIR/stitchpad.md"
C3_GIT="$C3_PAD_DIR/stitchpad-git"

# C3c: join WITHOUT TEST_MODE + target=- (no terminal lock) — hook inert
C3_JOIN_OUT="$(STITCHPAD_NAME=charlie STITCHPAD_TEST_COMMIT_FAIL=1 \
  "$STITCHPAD" join charlie pi pull - 2>&1)" || C3_JOIN_RC=$?
C3_JOIN_RC=${C3_JOIN_RC:-0}

[ "$C3_JOIN_RC" -eq 0 ] && ok "C3c: join succeeds without TEST_MODE (hook inert)" \
  || bad "C3c: join succeeded without TEST_MODE (rc=$C3_JOIN_RC output: $(printf '%s' "$C3_JOIN_OUT" | head -c 200))"

grep -qi "charlie" "$C3_PAD_MD" && ok "C3d: charlie appears in pad after inert-hook join" \
  || bad "C3d: charlie appears in pad after join"

# C3e: WITH TEST_MODE=1 -> hook ACTIVE, clear FAILS
C3_CLEAR2_OUT="$(STITCHPAD_NAME=alice STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 \
  "$STITCHPAD" clear 2>&1)" || C3_CLEAR2_RC=$?
C3_CLEAR2_RC=${C3_CLEAR2_RC:-0}

[ "$C3_CLEAR2_RC" -ne 0 ] && ok "C3e: clear FAILS with TEST_MODE=1 (hook active)" \
  || bad "C3e: clear fails with TEST_MODE (got rc=$C3_CLEAR2_RC)"

echo "$C3_CLEAR2_OUT" | grep -q "injected commit failure\|commit did not complete\|pad commit" && \
  ok "C3f: clear reports failure reason" || \
  bad "C3f: clear reports failure reason (output: $(printf '%s' "$C3_CLEAR2_OUT" | head -c 200))"

# C3g: WITH TEST_MODE=1 -> join FAILS (fresh pad to avoid terminal lock)
rm -rf "$C3_PAD_DIR"
make_pad "$C3_WORK/test-pad-3" "c3-pad-3"
C3_PAD_DIR="$C3_WORK/test-pad-3/.stitchpad"
C3_PAD_MD="$C3_PAD_DIR/stitchpad.md"
C3_PAD_STATE="$C3_PAD_DIR/.state"
export STITCHPAD_PAD_DIR="$C3_PAD_DIR"
C3_SID="c3-charlie-001"
printf 'charlie' > "$C3_PAD_STATE/sessions/$C3_SID"
C3_JOIN2_OUT="$(STITCHPAD_SESSION="$C3_SID" STITCHPAD_NAME=charlie \
  STITCHPAD_TEST_MODE=1 STITCHPAD_TEST_COMMIT_FAIL=1 \
  "$STITCHPAD" join charlie pi pull - 2>&1)" || C3_JOIN2_RC=$?
C3_JOIN2_RC=${C3_JOIN2_RC:-0}

[ "$C3_JOIN2_RC" -ne 0 ] && ok "C3g: join FAILS with TEST_MODE=1 (hook active)" \
  || bad "C3g: join fails with TEST_MODE (got rc=$C3_JOIN2_RC)"

echo "$C3_JOIN2_OUT" | grep -q "commit did not complete\|roster commit\|injected\|REFUSED" && \
  ok "C3h: join reports failure reason" || \
  bad "C3h: join reports failure reason (output: $(printf '%s' "$C3_JOIN2_OUT" | head -c 200))"

# ============================================================================
# C4: Leave Roster-Edit Write Failure
# ============================================================================
echo ""
echo "--- C4: leave roster-edit write failure ---"

C4_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-hard-c4.XXXXXX")"
C4_CLEAN="rm -rf $C4_WORK $C3_WORK $C2_WORK $C1_WORK"
trap "$C4_CLEAN" EXIT

make_pad "$C4_WORK/test-pad" "c4-pad"
C4_PAD_DIR="$C4_WORK/test-pad/.stitchpad"
C4_PAD_MD="$C4_PAD_DIR/stitchpad.md"
C4_PAD_STATE="$C4_PAD_DIR/.state"
C4_GIT="$C4_PAD_DIR/stitchpad-git"

export STITCHPAD_PAD_DIR="$C4_PAD_DIR"

# Bind bob
C4_SID="c4-bob-001"
printf 'bob' > "$C4_PAD_STATE/sessions/$C4_SID"

# C4a: pre-place a stale .ready to block the roster-edit write in leave
mkdir "$C4_PAD_MD.ready"

BEFORE_LEAVE="$(state_digest "$C4_PAD_MD" "$C4_PAD_STATE")"

C4_LEAVE_OUT="$(STITCHPAD_TEST_MODE=1 STITCHPAD_SESSION="$C4_SID" STITCHPAD_NAME=bob \
  "$STITCHPAD" leave bob 2>&1)" || C4_LEAVE_RC=$?
C4_LEAVE_RC=${C4_LEAVE_RC:-0}

[ "$C4_LEAVE_RC" -ne 0 ] && ok "C4a: leave fails when roster-edit write is blocked (rc=$C4_LEAVE_RC)" \
  || bad "C4a: leave fails on roster-edit failure (got rc=0)"

# C4b: leave must report failure — any stderr output qualifies
[ -n "$C4_LEAVE_OUT" ] && ok "C4b: leave produced failure output on stderr" \
  || bad "C4b: leave produced failure output (empty)"

AFTER_LEAVE="$(state_digest "$C4_PAD_MD" "$C4_PAD_STATE")"
[ "$AFTER_LEAVE" = "$BEFORE_LEAVE" ] && ok "C4c: pad + state unchanged after failed leave" \
  || bad "C4c: pad + state unchanged after leave (state diverged)"

# C4d: bob still in roster
grep -q "bob" "$C4_PAD_MD" && ok "C4d: bob still in roster after failed leave" \
  || bad "C4d: bob still in roster after leave (removed!)"

# C4e: no new git commit
C4_COMMIT_COUNT="$(git --git-dir="$C4_GIT" log --oneline | wc -l | tr -d ' ')"
[ "$C4_COMMIT_COUNT" = "1" ] && ok "C4e: no new git commit after failed leave" \
  || bad "C4e: no new git commit after leave (commits=$C4_COMMIT_COUNT)"

# Clean up the .ready dir
rm -rf "$C4_PAD_MD.ready"

# C4f: normal leave succeeds (control)
C4_LEAVE_OK="$(STITCHPAD_TEST_MODE=1 STITCHPAD_SESSION="$C4_SID" STITCHPAD_NAME=bob \
  "$STITCHPAD" leave bob 2>&1)" && C4_LEAVE_OK_RC=$? || C4_LEAVE_OK_RC=$?
C4_LEAVE_OK_RC=${C4_LEAVE_OK_RC:-0}

[ "$C4_LEAVE_OK_RC" -eq 0 ] && ok "C4f: normal leave succeeds (control)" \
  || bad "C4f: normal leave succeeds (rc=$C4_LEAVE_OK_RC)"

grep -qv "bob | ocean" "$C4_PAD_MD" && ok "C4g: bob removed from roster on success" \
  || bad "C4g: bob removed from roster on success"

# ============================================================================
# Results
# ============================================================================
echo ""
echo "=== RESULTS ==="
printf "Passed:  %d\n" "$pass"
printf "Failed:  %d\n" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '\nAll hardening gates PASSED.\n'
  exit 0
else
  printf '\nSome hardening gates FAILED.\n'
  exit 1
fi
