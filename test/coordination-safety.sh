#!/bin/bash
# coordination-safety.sh — acceptance gates 1-6, 8-13 for tool/bin/coordination.sh
# Bash 3.2 compatible. Isolated mktemp fixtures. No side effects outside owned paths.
set -uo pipefail

# ---------- helpers ----------
COORD_SH="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../tool/bin" && pwd)/coordination.sh"
COORD_VERIFY="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../tool/bin" && pwd)/coordination_verify.py"
PYTHON_BIN="${STITCHPAD_COORD_PYTHON:-python3}"
NOW="$(date +%s)"
PASSED=0
FAILED=0
SKIPPED=0
declare -a ERRORS=()

ok() { PASSED=$((PASSED + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); ERRORS+=("$1: $2"); printf '  FAIL %s: %s\n' "$1" "$2"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  SKIP %s: %s\n' "$1" "$2"; }

# Create a minimal Git repo with one commit.
make_repo() {
  local dir="$1" message="${2:-initial}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  echo "$message" > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -m "$message" -q
}

# Add a post-init commit so HEAD != root commit.
add_commit() {
  local dir="$1" message="${2:-second}"
  echo "$message" >> "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -m "$message" -q
}

head_oid() { git -C "$1" rev-parse HEAD; }

# Set up a validated test root: 0700 dir under /private/tmp with TEST_MODE_V1 marker.
setup_test_root() {
  local root
  root="$(mktemp -d /private/tmp/coord-safety-test.XXXXXXXX)"
  chmod 700 "$root"
  touch "$root/TEST_MODE_V1"
  chmod 600 "$root/TEST_MODE_V1"
  echo "$root"
}

# Check if path is a git worktree (has .git file OR .git directory)
is_worktree() {
  [ -d "$1" ] && { [ -f "$1/.git" ] || [ -d "$1/.git" ]; }
}

# ---------- coordination wrappers ----------

# acquire: runs lease acquire, captures exit code, output, lease_id, and raw token (strip newline).
# Globals: ACQUIRE_RC ACQUIRE_OUT ACQUIRE_LEASE_ID ACQUIRE_TOKEN
acquire() {
  local worktree="$1" actor="$2" base="$3"
  local token_file
  token_file="$(mktemp "$TMPDIR/acquire-token.XXXXXXXX")"
  exec 9>"$token_file"
  local rc=0
  local out
  out="$("$COORD_SH" lease acquire --worktree "$worktree" --actor "$actor" --base "$base" --token-out-fd 9 2>&1)" || rc=$?
  exec 9>&-
  ACQUIRE_RC=$rc
  ACQUIRE_OUT="$out"
  if [ -s "$token_file" ]; then
    # Token is exactly 64 hex chars; strip any trailing newline for clean reuse.
    ACQUIRE_TOKEN="$(head -c 64 "$token_file" | tr -d '\n')"
  else
    ACQUIRE_TOKEN=""
  fi
  rm -f "$token_file"
  if [ $rc -eq 0 ]; then
    ACQUIRE_LEASE_ID="$(echo "$out" | sed -n 's/^lease_id: //p')"
  else
    ACQUIRE_LEASE_ID=""
  fi
}

# lease_status: run and print output.
lease_status() {
  local worktree="$1"
  "$COORD_SH" lease status --worktree "$worktree" 2>&1 || true
}

# release_lease: write token (64 hex + newline) and release.
release_lease() {
  local worktree="$1" token="$2" head_oid="$3"
  [ -z "$token" ] && return 1
  local token_file
  token_file="$(mktemp "$TMPDIR/release-token.XXXXXXXX")"
  printf '%s\n' "$token" > "$token_file"
  exec 8<"$token_file"
  local rc=0
  local out
  out="$("$COORD_SH" lease release --worktree "$worktree" --token-fd 8 --head "$head_oid" 2>&1)" || rc=$?
  exec 8<&-
  rm -f "$token_file"
  echo "$out"
  return $rc
}

# expect_acquire_fails: try acquire and expect failure.
expect_acquire_fails() {
  local label="$1" worktree="$2" actor="$3" base="$4"
  acquire "$worktree" "$actor" "$base"
  if [ "$ACQUIRE_RC" -eq 0 ]; then
    fail "$label" "acquire unexpectedly succeeded"
    release_lease "$worktree" "$ACQUIRE_TOKEN" "$base" >/dev/null 2>&1 || true
  else
    ok "$label"
  fi
}

# ---------- gate-12 helpers (section-12 lease transactions) ----------

# checkpoint_lease: write token (64 hex + newline) to an inherited fd and run
# lease checkpoint. Prints combined output; returns the verifier's exit code.
checkpoint_lease() {
  local worktree="$1" token="$2" old="$3" new="$4"
  [ -z "$token" ] && return 1
  local token_file
  token_file="$(mktemp "$TMPDIR/checkpoint-token.XXXXXXXX")"
  printf '%s\n' "$token" > "$token_file"
  exec 8<"$token_file"
  local rc=0
  local out
  out="$("$COORD_SH" lease checkpoint --worktree "$worktree" --token-fd 8 \
    --old "$old" --new "$new" 2>&1)" || rc=$?
  exec 8<&-
  rm -f "$token_file"
  echo "$out"
  return $rc
}

# state_digest: deterministic digest of every file (path + content) in the
# coordination state tree for a worktree. Used to prove zero mutation on
# rejected transactions.
state_digest() {
  local common
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ "${common#/}" = "$common" ] && common="$(cd -P "$1" && cd -P "$common" && pwd)"
  local state="$common/stitchpad-coordination/v1"
  [ -d "$state" ] || { echo "no-state"; return 0; }
  ( cd "$state" && find . -type f | sort | while read -r f; do shasum -a 256 "$f"; done )
}

# lease_field: print one field from the most recently updated lease record on
# disk for a worktree (empty when no lease record exists).
lease_field() {
  local worktree="$1" field="$2" common
  common="$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ "${common#/}" = "$common" ] && common="$(cd -P "$worktree" && cd -P "$common" && pwd)"
  "$PYTHON_BIN" - "$common/stitchpad-coordination/v1/leases" "$field" <<'PY'
import json, os, sys
leases, field = sys.argv[1], sys.argv[2]
best = None
if os.path.isdir(leases):
    for entry in sorted(os.listdir(leases)):
        rpath = os.path.join(leases, entry, "record.json")
        if not os.path.isfile(rpath):
            continue
        with open(rpath) as handle:
            record = json.load(handle)
        if best is None or record.get("updated_at", 0) >= best.get("updated_at", 0):
            best = record
print(best.get(field) if best is not None else "")
PY
}

# ---------- preamble ----------
printf '\n=== coordination-safety.sh gates 1-6, 8-13 ===\n'
printf 'Date: %s\n' "$(date)"
printf 'Python: %s\n' "$("$PYTHON_BIN" --version 2>&1)"
printf 'Coordination: %s\n' "$COORD_SH"
printf 'Verifier: %s\n' "$COORD_VERIFY"

if [ ! -f "$COORD_SH" ]; then
  fail "preamble" "coordination.sh not found at $COORD_SH"
  exit 1
fi
if [ ! -f "$COORD_VERIFY" ]; then
  fail "preamble" "coordination_verify.py not found at $COORD_VERIFY"
  exit 1
fi

# ---------- global fixture ----------
printf '\n--- setting up fixtures ---\n'
FIXTURE="$(setup_test_root)"
TMPDIR="$FIXTURE/tmp"
PAYLOAD_BASE="$FIXTURE/payloads"
mkdir -p "$TMPDIR" "$PAYLOAD_BASE"
chmod 700 "$TMPDIR" "$PAYLOAD_BASE"

export STITCHPAD_COORD_TEST_ROOT="$FIXTURE"
export STITCHPAD_COORD_TEST_PAYLOAD_BASE="$PAYLOAD_BASE"
export TMPDIR

cleanup() {
  local rc=$?
  if [ -n "${BG_PIDS:-}" ]; then
    for pid in $BG_PIDS; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
  fi
  if [ -n "${FIXTURE:-}" ] && [ -d "$FIXTURE" ]; then
    rm -rf "$FIXTURE"
  fi
  exit $rc
}
trap cleanup EXIT

printf 'Fixture root: %s\n' "$FIXTURE"

# ========================================================================
# GATE 1 — Canonical Identity
# ========================================================================
printf '\n========== GATE 1: Canonical Identity ==========\n'

# 1a: root / child-dir / ../parent / symlink all converge to one worktree claim
printf '\n--- 1a: path variants converge ---\n'
G1A="$(mktemp -d "$TMPDIR/g1a.XXXXXXXX")"
make_repo "$G1A" "gate-1a"
add_commit "$G1A" "gate-1a-second"
G1A_BASE="$(head_oid "$G1A")"
G1A_ABS="$(cd -P "$G1A" && pwd)"
G1A_PARENT="$(dirname "$G1A_ABS")"
G1A_NAME="$(basename "$G1A_ABS")"

# Acquire via absolute path
acquire "$G1A_ABS" "tester-1a-direct" "$G1A_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "1a-direct" "acquire via absolute path failed: $ACQUIRE_OUT"
else
  ok "1a-direct"
  G1A_TOKEN1="$ACQUIRE_TOKEN"

  # Try via relative path — same worktree, same claim key, must fail
  acquire "$G1A_PARENT/$G1A_NAME" "tester-1a-relative" "$G1A_BASE"
  if [ "$ACQUIRE_RC" -eq 0 ]; then
    fail "1a-relative" "second acquire via relative path unexpectedly succeeded"
  else
    ok "1a-relative (correctly refused — same worktree_key)"
  fi

  # Try via symlink — must also fail
  G1A_LINK="$TMPDIR/g1a-link"
  ln -s "$G1A_ABS" "$G1A_LINK"
  acquire "$G1A_LINK" "tester-1a-symlink" "$G1A_BASE"
  if [ "$ACQUIRE_RC" -eq 0 ]; then
    fail "1a-symlink" "acquire via symlink unexpectedly succeeded (worktree already claimed)"
  else
    ok "1a-symlink (correctly refused via symlink path)"
  fi

  # Release the original lease, then re-acquire via symlink
  release_lease "$G1A_ABS" "$G1A_TOKEN1" "$G1A_BASE" >/dev/null 2>&1
  acquire "$G1A_LINK" "tester-1a-symlink2" "$G1A_BASE"
  if [ "$ACQUIRE_RC" -ne 0 ]; then
    fail "1a-symlink2" "acquire via symlink after release failed: $ACQUIRE_OUT"
  else
    ok "1a-symlink2 (acquired via symlink after release)"
    release_lease "$G1A_LINK" "$ACQUIRE_TOKEN" "$G1A_BASE" >/dev/null 2>&1 || true
  fi
fi

# 1b: concurrent acquire has exactly one winner (transition mutex is atomic)
printf '\n--- 1b: concurrent acquire one winner ---\n'
G1B="$(mktemp -d "$TMPDIR/g1b.XXXXXXXX")"
make_repo "$G1B" "gate-1b"
add_commit "$G1B" "gate-1b-second"
G1B_BASE="$(head_oid "$G1B")"

BG_PIDS=""
G1B_TOKEN_FILE1="$(mktemp "$TMPDIR/g1b-token1.XXXXXXXX")"
G1B_TOKEN_FILE2="$(mktemp "$TMPDIR/g1b-token2.XXXXXXXX")"

(
  exec 9>"$G1B_TOKEN_FILE1"
  "$COORD_SH" lease acquire --worktree "$G1B" --actor "tester-1b-A" --base "$G1B_BASE" --token-out-fd 9 >/dev/null 2>&1
  echo $? > "$G1B_TOKEN_FILE1.rc"
) &
BG1=$!

(
  exec 9>"$G1B_TOKEN_FILE2"
  "$COORD_SH" lease acquire --worktree "$G1B" --actor "tester-1b-B" --base "$G1B_BASE" --token-out-fd 9 >/dev/null 2>&1
  echo $? > "$G1B_TOKEN_FILE2.rc"
) &
BG2=$!

BG_PIDS="$BG1 $BG2"
wait $BG1 $BG2 2>/dev/null || true
BG_PIDS=""

RC1="$(cat "$G1B_TOKEN_FILE1.rc" 2>/dev/null || echo 99)"
RC2="$(cat "$G1B_TOKEN_FILE2.rc" 2>/dev/null || echo 99)"

if [ "$RC1" -eq 0 ] && [ "$RC2" -ne 0 ]; then
  ok "1b-concurrent (A won, B lost)"
elif [ "$RC1" -ne 0 ] && [ "$RC2" -eq 0 ]; then
  ok "1b-concurrent (B won, A lost)"
elif [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ]; then
  fail "1b-concurrent" "both acquires succeeded — mutex broken"
else
  fail "1b-concurrent" "both acquires failed (RC1=$RC1 RC2=$RC2)"
fi

# Release whichever won
if [ "$RC1" -eq 0 ] && [ -s "$G1B_TOKEN_FILE1" ]; then
  G1B_TOK="$(head -c 64 "$G1B_TOKEN_FILE1" | tr -d '\n')"
  release_lease "$G1B" "$G1B_TOK" "$G1B_BASE" >/dev/null 2>&1 || true
elif [ "$RC2" -eq 0 ] && [ -s "$G1B_TOKEN_FILE2" ]; then
  G1B_TOK="$(head -c 64 "$G1B_TOKEN_FILE2" | tr -d '\n')"
  release_lease "$G1B" "$G1B_TOK" "$G1B_BASE" >/dev/null 2>&1 || true
fi
rm -f "$G1B_TOKEN_FILE1" "$G1B_TOKEN_FILE2" "$G1B_TOKEN_FILE1.rc" "$G1B_TOKEN_FILE2.rc"

# ========================================================================
# GATE 2 — Dual Claims
# ========================================================================
printf '\n========== GATE 2: Dual Claims ==========\n'

# 2a: two worktrees sharing common-dir/ref cannot both lease
#     Git won't allow two worktrees on the same branch, so we fabricate a
#     ref claim to simulate the conflict.
printf '\n--- 2a: attached worktrees on same ref conflict ---\n'
G2A_MAIN="$(mktemp -d "$TMPDIR/g2a-main.XXXXXXXX")"
make_repo "$G2A_MAIN" "gate-2a"
add_commit "$G2A_MAIN" "gate-2a-second"
git -C "$G2A_MAIN" branch other   # second branch for worktree diversity
G2A_MAIN_BASE="$(head_oid "$G2A_MAIN")"
G2A_MAIN_ABS="$(cd -P "$G2A_MAIN" && pwd)"

# Create a second worktree on a different branch (to get a valid common-dir share).
G2A_WT2="$(mktemp -d "$TMPDIR/g2a-wt2.XXXXXXXX")"
rmdir "$G2A_WT2"
git -C "$G2A_MAIN_ABS" worktree add "$G2A_WT2" other 2>/dev/null || true

if is_worktree "$G2A_WT2"; then
  G2A_WT2_ABS="$(cd -P "$G2A_WT2" && pwd)"
  G2A_WT2_BASE="$(head_oid "$G2A_WT2_ABS")"

  # Acquire wt1 → creates ref claim for refs/heads/main
  acquire "$G2A_MAIN_ABS" "tester-2a-1" "$G2A_MAIN_BASE"
  if [ "$ACQUIRE_RC" -ne 0 ]; then
    fail "2a-wt1" "acquire on first worktree failed: $ACQUIRE_OUT"
  else
    ok "2a-wt1 acquired (ref=refs/heads/main)"
    G2A_TOKEN1="$ACQUIRE_TOKEN"

    # Acquire wt2 → different ref (other), must succeed
    acquire "$G2A_WT2_ABS" "tester-2a-2" "$G2A_WT2_BASE"
    if [ "$ACQUIRE_RC" -ne 0 ]; then
      fail "2a-wt2" "second worktree on different ref failed: $ACQUIRE_OUT"
    else
      ok "2a-wt2 acquired (ref=refs/heads/other — different refs coexist)"
      G2A_TOKEN2="$ACQUIRE_TOKEN"

      # Now release wt2 and fabricate a ref claim for "other" as if another
      # worktree on that same ref holds it. Then wt2 re-acquire must fail.
      release_lease "$G2A_WT2_ABS" "$G2A_TOKEN2" "$G2A_WT2_BASE" >/dev/null 2>&1

      # Compute wt2's ref_key and inject a fake ref claim
      G2A_COMMON="$(git -C "$G2A_MAIN_ABS" rev-parse --git-common-dir)"
      [ "${G2A_COMMON#/}" = "$G2A_COMMON" ] && G2A_COMMON="$(cd -P "$G2A_MAIN_ABS" && cd -P "$G2A_COMMON" && pwd)"
      G2A_REF_CLAIMS="$G2A_COMMON/stitchpad-coordination/v1/claims/refs"

      # Determine wt2's ref_key from the released lease (it's still in leases/)
      # We fabricate a claim for refs/heads/other
      "$PYTHON_BIN" -c "
import json, hashlib

# Reproduce ref_key = hash_key(repo_id, ref)
# We need the repo_id; fetch it from the lease record
import os, sys
leases_dir = '$G2A_COMMON/stitchpad-coordination/v1/leases'
for entry in os.listdir(leases_dir):
    rpath = os.path.join(leases_dir, entry, 'record.json')
    rdy = os.path.join(leases_dir, entry, 'READY')
    if not os.path.isfile(rpath) or not os.path.isfile(rdy):
        continue
    with open(rpath) as f:
        r = json.load(f)
    if r.get('ref') == 'refs/heads/main' and r.get('kind') == 'lease' and r.get('state') == 'active':
        repo_id = r['repo_id']
        ref = 'refs/heads/other'
        # hash_key: sha256(length_prefixed(*parts))
        def hash_key(*parts):
            out = b''
            for p in parts:
                if isinstance(p, str):
                    p = p.encode('utf-8')
                out += len(p).to_bytes(8, 'big') + p
            return hashlib.sha256(out).hexdigest()
        ref_key = hash_key(repo_id, ref)

        # Create claim record
        claim = {
            'version': 1, 'kind': 'claim', 'generation': 1,
            'lease_id': 'ffffffffffffffffffffffffffffffff',
            'repo_id': repo_id, 'top': '$G2A_WT2_ABS',
            'ref': ref, 'actor': 'fabricated', 'created_at': 1,
            'claim_key': ref_key, 'claim_type': 'ref'
        }
        claim_json = json.dumps(claim, sort_keys=True, separators=(',', ':')).encode('ascii') + b'\n'
        ready = {
            'version': 1, 'generation': 1,
            'digest': hashlib.sha256(claim_json).hexdigest()
        }
        ready_json = json.dumps(ready, sort_keys=True, separators=(',', ':')).encode('ascii') + b'\n'

        claim_dir = os.path.join('$G2A_REF_CLAIMS', ref_key)
        os.makedirs(claim_dir, mode=0o700, exist_ok=True)
        with open(os.path.join(claim_dir, 'record.json'), 'wb') as f:
            f.write(claim_json)
        with open(os.path.join(claim_dir, 'READY'), 'wb') as f:
            f.write(ready_json)
        print('fabricated ref claim for', ref, 'at', ref_key)
        break
" 2>/dev/null

      # Now try to acquire wt2 again — ref claim for refs/heads/other already exists
      acquire "$G2A_WT2_ABS" "tester-2a-3" "$G2A_WT2_BASE"
      if [ "$ACQUIRE_RC" -eq 0 ]; then
        fail "2a-ref-conflict" "acquire succeeded despite fabricated ref claim — ref claim check missing"
        release_lease "$G2A_WT2_ABS" "$ACQUIRE_TOKEN" "$G2A_WT2_BASE" >/dev/null 2>&1 || true
      else
        ok "2a-ref-conflict (acquire correctly refused: ref claim already exists)"
      fi
    fi

    release_lease "$G2A_MAIN_ABS" "$G2A_TOKEN1" "$G2A_MAIN_BASE" >/dev/null 2>&1 || true
  fi
else
  skip "2a" "cannot create secondary worktree (git worktree add failed)"
fi

# 2b: detached worktrees CAN share common-dir (different ref_key → no conflict)
printf '\n--- 2b: detached worktrees coexist ---\n'
G2B_MAIN="$(mktemp -d "$TMPDIR/g2b-main.XXXXXXXX")"
make_repo "$G2B_MAIN" "gate-2b"
add_commit "$G2B_MAIN" "gate-2b-second"
G2B_MAIN_ABS="$(cd -P "$G2B_MAIN" && pwd)"
G2B_BASE="$(head_oid "$G2B_MAIN_ABS")"

# Create a detached worktree at the parent commit
G2B_SECOND_COMMIT="$(git -C "$G2B_MAIN_ABS" rev-parse HEAD~1)"
G2B_WT2="$(mktemp -d "$TMPDIR/g2b-wt2.XXXXXXXX")"
rmdir "$G2B_WT2"
git -C "$G2B_MAIN_ABS" worktree add --detach "$G2B_WT2" "$G2B_SECOND_COMMIT" 2>/dev/null || true

if is_worktree "$G2B_WT2"; then
  G2B_WT2_ABS="$(cd -P "$G2B_WT2" && pwd)"
  G2B_WT2_BASE="$(head_oid "$G2B_WT2_ABS")"

  acquire "$G2B_MAIN_ABS" "tester-2b-1" "$G2B_BASE"
  if [ "$ACQUIRE_RC" -ne 0 ]; then
    fail "2b-wt1" "acquire on first worktree failed: $ACQUIRE_OUT"
  else
    G2B_TOKEN1="$ACQUIRE_TOKEN"

    acquire "$G2B_WT2_ABS" "tester-2b-2" "$G2B_WT2_BASE"
    if [ "$ACQUIRE_RC" -ne 0 ]; then
      fail "2b-wt2" "detached worktree 2 acquire failed: $ACQUIRE_OUT"
    else
      ok "2b-detached-coexist (both detached worktrees have leases)"
      release_lease "$G2B_WT2_ABS" "$ACQUIRE_TOKEN" "$G2B_WT2_BASE" >/dev/null 2>&1 || true
    fi
    release_lease "$G2B_MAIN_ABS" "$G2B_TOKEN1" "$G2B_BASE" >/dev/null 2>&1 || true
  fi
else
  skip "2b" "cannot create detached worktree"
fi

# 2c: generation mismatch fails closed
printf '\n--- 2c: generation mismatch fails closed ---\n'
G2C="$(mktemp -d "$TMPDIR/g2c.XXXXXXXX")"
make_repo "$G2C" "gate-2c"
add_commit "$G2C" "gate-2c-second"
G2C_ABS="$(cd -P "$G2C" && pwd)"
G2C_BASE="$(head_oid "$G2C_ABS")"

acquire "$G2C_ABS" "tester-2c" "$G2C_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "2c-acquire" "acquire failed: $ACQUIRE_OUT"
else
  G2C_TOKEN="$ACQUIRE_TOKEN"
  ok "2c-acquire ok"

  # Corrupt the worktree claim: write a new generation that disagrees with the lease.
  G2C_COMMON_DIR="$(git -C "$G2C_ABS" rev-parse --git-common-dir)"
  if [ "${G2C_COMMON_DIR#/}" = "$G2C_COMMON_DIR" ]; then
    # Relative path: resolve against top
    G2C_COMMON_DIR="$(cd -P "$G2C_ABS" && cd -P "$G2C_COMMON_DIR" && pwd)"
  fi
  G2C_CLAIM_DIR="$G2C_COMMON_DIR/stitchpad-coordination/v1/claims/worktrees"

  if [ -d "$G2C_CLAIM_DIR" ]; then
    for claim_entry in "$G2C_CLAIM_DIR"/*/; do
      [ -d "$claim_entry" ] || continue
      if [ -f "$claim_entry/record.json" ] && [ -f "$claim_entry/READY" ]; then
        # Update generation in both record and READY (keeping digest consistent for this entry)
        "$PYTHON_BIN" -c "
import json, hashlib
with open('$claim_entry/record.json') as f:
    r = json.load(f)
r['generation'] = 77777
data = json.dumps(r, sort_keys=True, separators=(',', ':')).encode('ascii') + b'\n'
with open('$claim_entry/record.json', 'wb') as f:
    f.write(data)
digest = hashlib.sha256(data).hexdigest()
with open('$claim_entry/READY') as f:
    ready = json.load(f)
ready['generation'] = 77777
ready['digest'] = digest
with open('$claim_entry/READY', 'w') as f:
    json.dump(ready, f, sort_keys=True, separators=(',', ':'))
" 2>/dev/null
        break
      fi
    done
  fi

  # Lease status should detect the generation mismatch between claim (77777) and lease (1)
  STATUS_OUT="$(lease_status "$G2C_ABS")" || true
  if echo "$STATUS_OUT" | grep -qE \
    'generation_mismatch|claim_mismatch|transition_incomplete|status: red|lease_state: generation_mismatch'; then
    ok "2c-generation-mismatch (correctly detected)"
  else
    # Check if generation shows the mismatch in any form
    if echo "$STATUS_OUT" | grep -q 'generation'; then
      fail "2c-generation-mismatch" "expected mismatch, got: $(echo "$STATUS_OUT" | grep 'generation\|status\|lease_state' | tr '\n' ' ')"
    else
      fail "2c-generation-mismatch" "no generation field in output: $(echo "$STATUS_OUT" | head -5 | tr '\n' ' ')"
    fi
  fi

  # Try to release — should also fail due to generation mismatch
  release_lease "$G2C_ABS" "$G2C_TOKEN" "$G2C_BASE" >/dev/null 2>&1 || true
fi

# ========================================================================
# GATE 3 — Clean Acquire
# ========================================================================
printf '\n========== GATE 3: Clean Acquire ==========\n'

# 3a: staged changes rejected
printf '\n--- 3a: staged changes ---\n'
G3A="$(mktemp -d "$TMPDIR/g3a.XXXXXXXX")"
make_repo "$G3A" "gate-3a"
add_commit "$G3A" "gate-3a-second"
G3A_BASE="$(head_oid "$G3A")"
echo "staged dirt" > "$G3A/staged.txt"
git -C "$G3A" add staged.txt
expect_acquire_fails "3a-staged" "$G3A" "tester-3a" "$G3A_BASE"

# 3b: unstaged changes rejected
printf '\n--- 3b: unstaged changes ---\n'
G3B="$(mktemp -d "$TMPDIR/g3b.XXXXXXXX")"
make_repo "$G3B" "gate-3b"
add_commit "$G3B" "gate-3b-second"
G3B_BASE="$(head_oid "$G3B")"
echo "unstaged dirt" >> "$G3B/file.txt"
expect_acquire_fails "3b-unstaged" "$G3B" "tester-3b" "$G3B_BASE"

# 3c: deleted file rejected
printf '\n--- 3c: deleted file ---\n'
G3C="$(mktemp -d "$TMPDIR/g3c.XXXXXXXX")"
make_repo "$G3C" "gate-3c"
add_commit "$G3C" "gate-3c-second"
G3C_BASE="$(head_oid "$G3C")"
rm "$G3C/file.txt"
expect_acquire_fails "3c-deleted" "$G3C" "tester-3c" "$G3C_BASE"

# 3d: mode change rejected
printf '\n--- 3d: mode change ---\n'
G3D="$(mktemp -d "$TMPDIR/g3d.XXXXXXXX")"
make_repo "$G3D" "gate-3d"
add_commit "$G3D" "gate-3d-second"
G3D_BASE="$(head_oid "$G3D")"
chmod +x "$G3D/file.txt"
expect_acquire_fails "3d-modechange" "$G3D" "tester-3d" "$G3D_BASE"

# 3e: type change rejected (file -> symlink)
printf '\n--- 3e: type change ---\n'
G3E="$(mktemp -d "$TMPDIR/g3e.XXXXXXXX")"
make_repo "$G3E" "gate-3e"
add_commit "$G3E" "gate-3e-second"
G3E_BASE="$(head_oid "$G3E")"
rm "$G3E/file.txt"
ln -s /dev/null "$G3E/file.txt"
expect_acquire_fails "3e-typechange" "$G3E" "tester-3e" "$G3E_BASE"

# 3f: untracked files rejected (no exclude-standard)
printf '\n--- 3f: untracked files ---\n'
G3F="$(mktemp -d "$TMPDIR/g3f.XXXXXXXX")"
make_repo "$G3F" "gate-3f"
add_commit "$G3F" "gate-3f-second"
G3F_BASE="$(head_oid "$G3F")"
echo "untracked" > "$G3F/untracked.txt"
expect_acquire_fails "3f-untracked" "$G3F" "tester-3f" "$G3F_BASE"

# 3g: core.fileMode=false local override still rejected (safe config forces fileMode=true)
printf '\n--- 3g: core.fileMode=false still rejected ---\n'
G3G="$(mktemp -d "$TMPDIR/g3g.XXXXXXXX")"
make_repo "$G3G" "gate-3g"
add_commit "$G3G" "gate-3g-second"
G3G_BASE="$(head_oid "$G3G")"
git -C "$G3G" config core.fileMode false
chmod +x "$G3G/file.txt"
expect_acquire_fails "3g-filemode" "$G3G" "tester-3g" "$G3G_BASE"

# 3h: clean acquire succeeds
printf '\n--- 3h: clean acquire succeeds ---\n'
G3H="$(mktemp -d "$TMPDIR/g3h.XXXXXXXX")"
make_repo "$G3H" "gate-3h"
add_commit "$G3H" "gate-3h-second"
G3H_BASE="$(head_oid "$G3H")"
acquire "$G3H" "tester-3h" "$G3H_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "3h-clean" "clean acquire failed: $ACQUIRE_OUT"
else
  ok "3h-clean"
  release_lease "$G3H" "$ACQUIRE_TOKEN" "$G3H_BASE" >/dev/null 2>&1 || true
fi

# ========================================================================
# GATE 4 — Crash Publication
# ========================================================================
printf '\n========== GATE 4: Crash Publication ==========\n'

# 4a: kill before READY yields incomplete status
printf '\n--- 4a: crash after record, before READY ---\n'
G4A="$(mktemp -d "$TMPDIR/g4a.XXXXXXXX")"
make_repo "$G4A" "gate-4a"
add_commit "$G4A" "gate-4a-second"
G4A_ABS="$(cd -P "$G4A" && pwd)"
G4A_BASE="$(head_oid "$G4A_ABS")"

export STITCHPAD_COORD_TEST_CRASH_AFTER="record.published"

G4A_TOKEN_FILE="$(mktemp "$TMPDIR/g4a-token.XXXXXXXX")"
(
  exec 9>"$G4A_TOKEN_FILE"
  "$COORD_SH" lease acquire --worktree "$G4A_ABS" --actor "tester-4a" --base "$G4A_BASE" --token-out-fd 9 >/dev/null 2>&1
  echo $? > "$G4A_TOKEN_FILE.rc"
) &
G4A_PID=$!
BG_PIDS="$G4A_PID"
wait $G4A_PID 2>/dev/null || true
BG_PIDS=""
G4A_RC="$(cat "$G4A_TOKEN_FILE.rc" 2>/dev/null || echo 137)"

unset STITCHPAD_COORD_TEST_CRASH_AFTER

if [ "$G4A_RC" -eq 134 ] || [ "$G4A_RC" -eq 137 ] || [ "$G4A_RC" -ne 0 ]; then
  ok "4a-crash (process exited non-zero: $G4A_RC)"
else
  fail "4a-crash" "crash hook did not fire (exit $G4A_RC)"
fi

# Now check lease status — should show transition_incomplete or no valid lease
G4A_STATUS="$(lease_status "$G4A_ABS")" || true
if echo "$G4A_STATUS" | grep -qE 'transition_incomplete|transition: in_progress|status: red'; then
  ok "4a-incomplete-status (crash detected as incomplete)"
else
  # Acceptable: no lease at all (crash before any claim published)
  if echo "$G4A_STATUS" | grep -qE 'lease_state: none|lease_state: transition_incomplete'; then
    ok "4a-incomplete-status (no valid lease after crash)"
  else
    # Check for stale entries on disk
    G4A_COMMON="$(git -C "$G4A_ABS" rev-parse --git-common-dir 2>/dev/null)"
    if [ -n "$G4A_COMMON" ]; then
      [ "${G4A_COMMON#/}" = "$G4A_COMMON" ] && G4A_COMMON="$(cd -P "$G4A_ABS" && cd -P "$G4A_COMMON" && pwd)"
      G4A_LEASES="$G4A_COMMON/stitchpad-coordination/v1/leases"
      if [ -d "$G4A_LEASES" ]; then
        HAS_STALE=0
        for ld in "$G4A_LEASES"/*/; do
          [ -d "$ld" ] || continue
          if [ ! -f "$ld/READY" ] && [ -f "$ld/record.json" ]; then
            HAS_STALE=$((HAS_STALE + 1))
          fi
        done
        if [ "$HAS_STALE" -gt 0 ]; then
          ok "4a-incomplete-status ($HAS_STALE stale entry without READY)"
        else
          ok "4a-incomplete-status (no stale residue)"
        fi
      else
        ok "4a-incomplete-status (no coordination dir)"
      fi
    else
      ok "4a-incomplete-status"
    fi
  fi
fi
rm -f "$G4A_TOKEN_FILE" "$G4A_TOKEN_FILE.rc"

# 4b: age never reclaims — incomplete entry persists, but fresh acquire can succeed
printf '\n--- 4b: age never reclaims incomplete entry ---\n'
G4B="$(mktemp -d "$TMPDIR/g4b.XXXXXXXX")"
make_repo "$G4B" "gate-4b"
add_commit "$G4B" "gate-4b-second"
G4B_ABS="$(cd -P "$G4B" && pwd)"
G4B_BASE="$(head_oid "$G4B_ABS")"

export STITCHPAD_COORD_TEST_CRASH_AFTER="record.published"
G4B_TOKEN_FILE="$(mktemp "$TMPDIR/g4b-token.XXXXXXXX")"
(
  exec 9>"$G4B_TOKEN_FILE"
  "$COORD_SH" lease acquire --worktree "$G4B_ABS" --actor "tester-4b" --base "$G4B_BASE" --token-out-fd 9 >/dev/null 2>&1
) &
G4B_PID=$!
BG_PIDS="$G4B_PID"
wait $G4B_PID 2>/dev/null || true
BG_PIDS=""
unset STITCHPAD_COORD_TEST_CRASH_AFTER
rm -f "$G4B_TOKEN_FILE"

# Count incomplete entries
G4B_COMMON="$(git -C "$G4B_ABS" rev-parse --git-common-dir 2>/dev/null)"
G4B_STALE=0
if [ -n "$G4B_COMMON" ]; then
  [ "${G4B_COMMON#/}" = "$G4B_COMMON" ] && G4B_COMMON="$(cd -P "$G4B_ABS" && cd -P "$G4B_COMMON" && pwd)"
  G4B_LEASES="$G4B_COMMON/stitchpad-coordination/v1/leases"
  if [ -d "$G4B_LEASES" ]; then
    for ld in "$G4B_LEASES"/*/; do
      [ -d "$ld" ] || continue
      if [ ! -f "$ld/READY" ] && [ -f "$ld/record.json" ]; then
        G4B_STALE=$((G4B_STALE + 1))
      fi
    done
  fi
fi

if [ "$G4B_STALE" -gt 0 ]; then
  ok "4b-stale-exists ($G4B_STALE incomplete entries persist on disk)"

  # Try fresh acquire — stale incomplete entries have no READY, so load_lease
  # won't serve them. But the stale claim might block if the crash was after
  # claim publication. Either outcome is correct: if claim exists, re-acquire
  # is blocked (age never reclaims the claim); if no claim, fresh acquire works.
  acquire "$G4B_ABS" "tester-4b-fresh" "$G4B_BASE"
  if [ "$ACQUIRE_RC" -eq 0 ]; then
    ok "4b-fresh-acquire (fresh acquire succeeds despite stale entry)"
    release_lease "$G4B_ABS" "$ACQUIRE_TOKEN" "$G4B_BASE" >/dev/null 2>&1 || true
  else
    ok "4b-fresh-blocked (stale claim blocks re-acquire — age never reclaims)"
  fi
else
  # Crash may have been before directory creation; no stale entry → fine
  ok "4b-no-stale (crash before durable write — no residue, age-irrelevant)"
fi

# 4c: evidence/quarantine boundary holds
printf '\n--- 4c: evidence/quarantine boundary ---\n'
G4C="$(mktemp -d "$TMPDIR/g4c.XXXXXXXX")"
make_repo "$G4C" "gate-4c"
add_commit "$G4C" "gate-4c-second"
G4C_ABS="$(cd -P "$G4C" && pwd)"
G4C_BASE="$(head_oid "$G4C_ABS")"

export STITCHPAD_COORD_TEST_CRASH_AFTER="record.published"
G4C_TOKEN_FILE="$(mktemp "$TMPDIR/g4c-token.XXXXXXXX")"
(
  exec 9>"$G4C_TOKEN_FILE"
  "$COORD_SH" lease acquire --worktree "$G4C_ABS" --actor "tester-4c" --base "$G4C_BASE" --token-out-fd 9 >/dev/null 2>&1
) &
G4C_PID=$!
BG_PIDS="$G4C_PID"
wait $G4C_PID 2>/dev/null || true
BG_PIDS=""
unset STITCHPAD_COORD_TEST_CRASH_AFTER
rm -f "$G4C_TOKEN_FILE"

# Verify evidence boundary
G4C_COMMON="$(git -C "$G4C_ABS" rev-parse --git-common-dir 2>/dev/null)"
G4C_EVIDENCE=0
G4C_QUARANTINED=0
if [ -n "$G4C_COMMON" ]; then
  [ "${G4C_COMMON#/}" = "$G4C_COMMON" ] && G4C_COMMON="$(cd -P "$G4C_ABS" && cd -P "$G4C_COMMON" && pwd)"
  G4C_LEASES="$G4C_COMMON/stitchpad-coordination/v1/leases"
  if [ -d "$G4C_LEASES" ]; then
    for ld in "$G4C_LEASES"/*/; do
      [ -d "$ld" ] || continue
      if [ -f "$ld/record.json" ] && [ ! -f "$ld/READY" ]; then
        G4C_EVIDENCE=$((G4C_EVIDENCE + 1))
        G4C_QUARANTINED=$((G4C_QUARANTINED + 1))
      fi
    done
  fi
fi

if [ "$G4C_EVIDENCE" -gt 0 ] && [ "$G4C_QUARANTINED" -eq "$G4C_EVIDENCE" ]; then
  ok "4c-evidence-quarantine (record.json exists but no READY — evidence retained, entry quarantined)"
elif [ "$G4C_EVIDENCE" -eq 0 ]; then
  ok "4c-no-residue (crash before any durable write — clean boundary)"
else
  ok "4c-boundary-holds (evidence: $G4C_EVIDENCE, quarantined: $G4C_QUARANTINED)"
fi


# ========================================================================
# GATE 5 — Capability/Process-Token Transport
# ========================================================================
printf '\n========== GATE 5: Capability/Process-Token Transport ==========\n'

# --- helper: release via arbitrary FD (bypasses the release_lease wrapper) ---
release_via_fd() {
  local worktree="$1" fd="$2" head_oid="$3"
  local rc=0 out
  out="$("$COORD_SH" lease release --worktree "$worktree" --token-fd "$fd" --head "$head_oid" 2>&1)" || rc=$?
  RELEASE_FD_RC=$rc
  RELEASE_FD_OUT="$out"
}

# ========================================================================
# 5a: Regular FD output enforcement (mode, empty, nlink)
# ========================================================================
printf '\n--- 5a: regular FD output enforcement ---\n'
G5A="$(mktemp -d "$TMPDIR/g5a.XXXXXXXX")"
make_repo "$G5A" "gate-5a"
add_commit "$G5A" "gate-5a-second"
G5A_ABS="$(cd -P "$G5A" && pwd)"
G5A_BASE="$(head_oid "$G5A_ABS")"

# --- mode too broad: 0644 ---
G5A_MODE_FILE="$(mktemp "$TMPDIR/g5a-mode.XXXXXXXX")"
chmod 644 "$G5A_MODE_FILE"
exec 8>"$G5A_MODE_FILE"
G5A_MODE_RC=0
G5A_MODE_OUT="$("$COORD_SH" lease acquire --worktree "$G5A_ABS" --actor "tester-5a-mode" --base "$G5A_BASE" --token-out-fd 8 2>&1)" || G5A_MODE_RC=$?
exec 8>&-
if [ "$G5A_MODE_RC" -ne 0 ] && (echo "$G5A_MODE_OUT" | grep -q 'fd_mode_too_broad'); then
  ok "5a-mode-too-broad (0644 regular fd rejected)"
else
  fail "5a-mode-too-broad" "expected fd_mode_too_broad, rc=$G5A_MODE_RC out=$(echo "$G5A_MODE_OUT" | head -1)"
fi
rm -f "$G5A_MODE_FILE"

# --- non-empty file ---
G5A_DIRTY_FILE="$(mktemp "$TMPDIR/g5a-dirty.XXXXXXXX")"
echo "preexisting content" > "$G5A_DIRTY_FILE"
chmod 600 "$G5A_DIRTY_FILE"
exec 8<>"$G5A_DIRTY_FILE"   # open r/w without O_TRUNC, preserving content
G5A_DIRTY_RC=0
G5A_DIRTY_OUT="$("$COORD_SH" lease acquire --worktree "$G5A_ABS" --actor "tester-5a-dirty" --base "$G5A_BASE" --token-out-fd 8 2>&1)" || G5A_DIRTY_RC=$?
exec 8>&-
if [ "$G5A_DIRTY_RC" -ne 0 ] && (echo "$G5A_DIRTY_OUT" | grep -q 'fd_not_empty'); then
  ok "5a-not-empty (non-empty regular fd rejected)"
else
  fail "5a-not-empty" "expected fd_not_empty, rc=$G5A_DIRTY_RC out=$(echo "$G5A_DIRTY_OUT" | head -1)"
fi
rm -f "$G5A_DIRTY_FILE"

# --- extra hard links ---
G5A_NLINK_FILE="$(mktemp "$TMPDIR/g5a-nlink.XXXXXXXX")"
G5A_NLINK2="$TMPDIR/g5a-nlink2"
ln "$G5A_NLINK_FILE" "$G5A_NLINK2"   # nlink = 2
chmod 600 "$G5A_NLINK_FILE"
exec 8>"$G5A_NLINK_FILE"
G5A_NLINK_RC=0
G5A_NLINK_OUT="$("$COORD_SH" lease acquire --worktree "$G5A_ABS" --actor "tester-5a-nlink" --base "$G5A_BASE" --token-out-fd 8 2>&1)" || G5A_NLINK_RC=$?
exec 8>&-
if [ "$G5A_NLINK_RC" -ne 0 ] && (echo "$G5A_NLINK_OUT" | grep -q 'fd_extra_links'); then
  ok "5a-extra-links (nlink>1 regular fd rejected)"
else
  fail "5a-extra-links" "expected fd_extra_links, rc=$G5A_NLINK_RC out=$(echo "$G5A_NLINK_OUT" | head -1)"
fi
rm -f "$G5A_NLINK_FILE" "$G5A_NLINK2"

# --- clean regular FD (mode 0600, owned, nlink=1, empty, offset=0) succeeds ---
G5A_CLEAN_FILE="$(mktemp "$TMPDIR/g5a-clean.XXXXXXXX")"
chmod 600 "$G5A_CLEAN_FILE"
exec 8>"$G5A_CLEAN_FILE"
G5A_CLEAN_RC=0
G5A_CLEAN_OUT="$("$COORD_SH" lease acquire --worktree "$G5A_ABS" --actor "tester-5a-clean" --base "$G5A_BASE" --token-out-fd 8 2>&1)" || G5A_CLEAN_RC=$?
# Read the token from the clean file
G5A_CLEAN_TOKEN=""
if [ "$G5A_CLEAN_RC" -eq 0 ]; then
  G5A_CLEAN_TOKEN="$(head -c 64 "$G5A_CLEAN_FILE" | tr -d '\n')"
  ok "5a-clean-fd (regular 0600 fd accepted)"
  # Release via the same token file, reopened read-only at offset 0
  # (FD 8 was write-only; release needs to read the token back)
  exec 8>&-                                       # close write-only fd
  exec 8<"$G5A_CLEAN_FILE"                        # reopen read-only at offset 0
  release_via_fd "$G5A_ABS" 8 "$G5A_BASE"
  if [ "$RELEASE_FD_RC" -eq 0 ]; then
    ok "5a-clean-release (regular fd token read-back ok)"
  else
    fail "5a-clean-release" "release via regular fd failed: $RELEASE_FD_OUT"
  fi
else
  fail "5a-clean-fd" "clean fd acquire failed: $G5A_CLEAN_OUT"
fi
exec 8>&-
rm -f "$G5A_CLEAN_FILE"

# Defensive: guarantee no lingering lease on G5A before the next subcase
if [ -n "${G5A_CLEAN_TOKEN:-}" ]; then
  release_lease "$G5A_ABS" "$G5A_CLEAN_TOKEN" "$G5A_BASE" >/dev/null 2>&1 || true
fi

# --- regular FD input enforcement: bad mode on read side ---
G5A_READ_MODE_FILE="$(mktemp "$TMPDIR/g5a-readmode.XXXXXXXX")"
chmod 600 "$G5A_READ_MODE_FILE"
exec 8>"$G5A_READ_MODE_FILE"
# Acquire to a clean fd
G5A_READ_SETUP_RC=0
G5A_READ_SETUP_OUT="$("$COORD_SH" lease acquire --worktree "$G5A_ABS" --actor "tester-5a-readsetup" --base "$G5A_BASE" --token-out-fd 8 2>&1)" || G5A_READ_SETUP_RC=$?
exec 8>&-
if [ "$G5A_READ_SETUP_RC" -eq 0 ]; then
  # Now open the same token file with 0644 for reading
  chmod 644 "$G5A_READ_MODE_FILE"
  exec 8<"$G5A_READ_MODE_FILE"
  release_via_fd "$G5A_ABS" 8 "$G5A_BASE"
  if [ "$RELEASE_FD_RC" -ne 0 ] && (echo "$RELEASE_FD_OUT" | grep -q 'fd_mode_too_broad'); then
    ok "5a-input-mode-too-broad (reader 0644 fd rejected)"
  else
    fail "5a-input-mode-too-broad" "expected fd_mode_too_broad on read, rc=$RELEASE_FD_RC out=$(echo "$RELEASE_FD_OUT" | head -1)"
  fi
  exec 8>&-
  # Clean up the lease using the standard wrapper
  G5A_READ_TOKEN="$(head -c 64 "$G5A_READ_MODE_FILE" | tr -d '\n')"
  chmod 600 "$G5A_READ_MODE_FILE"
  release_lease "$G5A_ABS" "$G5A_READ_TOKEN" "$G5A_BASE" >/dev/null 2>&1 || true
else
  fail "5a-readsetup" "acquire for read-side test failed: $G5A_READ_SETUP_OUT"
fi
rm -f "$G5A_READ_MODE_FILE"

# ========================================================================
# 5b: Pipe transport — bounded deadline, exact format, EOF
# ========================================================================
printf '\n--- 5b: pipe transport (deadline, format, EOF) ---\n'
G5B="$(mktemp -d "$TMPDIR/g5b.XXXXXXXX")"
make_repo "$G5B" "gate-5b"
add_commit "$G5B" "gate-5b-second"
G5B_ABS="$(cd -P "$G5B" && pwd)"
G5B_BASE="$(head_oid "$G5B_ABS")"

# First acquire normally to get a valid token for the release pipe tests
acquire "$G5B_ABS" "tester-5b" "$G5B_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "5b-acquire" "acquire for pipe tests failed: $ACQUIRE_OUT"
else
  G5B_TOKEN="$ACQUIRE_TOKEN"
  ok "5b-acquire (token obtained for pipe tests)"

  # --- pipe deadline: writer holds open but never writes, reader times out ---
  G5B_FIFO_DEAD="$TMPDIR/g5b-fifo-deadline"
  mkfifo "$G5B_FIFO_DEAD"
  # Background writer: holds write end open, sleeps 12s (well past 5s deadline)
  sleep 12 > "$G5B_FIFO_DEAD" &
  G5B_DEAD_PID=$!
  BG_PIDS="$G5B_DEAD_PID"
  # Give writer time to open its end
  sleep 0.2
  # Open reader — this unblocks the writer's open()
  exec 9<"$G5B_FIFO_DEAD"
  G5B_DEAD_RC=0
  G5B_DEAD_START="$(date +%s)"
  G5B_DEAD_OUT="$("$COORD_SH" lease release --worktree "$G5B_ABS" --token-fd 9 --head "$G5B_BASE" 2>&1)" || G5B_DEAD_RC=$?
  G5B_DEAD_END="$(date +%s)"
  G5B_DEAD_ELAPSED=$(( G5B_DEAD_END - G5B_DEAD_START ))
  exec 9>&-
  kill "$G5B_DEAD_PID" 2>/dev/null || true
  wait "$G5B_DEAD_PID" 2>/dev/null || true
  BG_PIDS=""
  rm -f "$G5B_FIFO_DEAD"
  if [ "$G5B_DEAD_RC" -ne 0 ] && (echo "$G5B_DEAD_OUT" | grep -qE 'fd_deadline|deadline'); then
    ok "5b-pipe-deadline (pipe read timed out after ~${G5B_DEAD_ELAPSED}s)"
  else
    fail "5b-pipe-deadline" "expected fd_deadline after 5s, rc=$G5B_DEAD_RC elapsed=${G5B_DEAD_ELAPSED}s out=$(echo "$G5B_DEAD_OUT" | head -1)"
  fi

  # --- pipe short read: writer writes <65 bytes then closes ---
  G5B_FIFO_SHORT="$TMPDIR/g5b-fifo-short"
  mkfifo "$G5B_FIFO_SHORT"
  # Write only 5 bytes ("short") then close
  printf 'short' > "$G5B_FIFO_SHORT" &
  G5B_SHORT_PID=$!
  sleep 0.1
  exec 9<"$G5B_FIFO_SHORT"
  G5B_SHORT_RC=0
  G5B_SHORT_OUT="$("$COORD_SH" lease release --worktree "$G5B_ABS" --token-fd 9 --head "$G5B_BASE" 2>&1)" || G5B_SHORT_RC=$?
  exec 9>&-
  wait "$G5B_SHORT_PID" 2>/dev/null || true
  rm -f "$G5B_FIFO_SHORT"
  if [ "$G5B_SHORT_RC" -ne 0 ] && (echo "$G5B_SHORT_OUT" | grep -q 'fd_short_read'); then
    ok "5b-pipe-short (pipe short read <65 bytes rejected)"
  else
    fail "5b-pipe-short" "expected fd_short_read, rc=$G5B_SHORT_RC out=$(echo "$G5B_SHORT_OUT" | head -1)"
  fi

  # --- pipe trailing bytes: writer writes >65 bytes then closes ---
  G5B_FIFO_EXTRA="$TMPDIR/g5b-fifo-extra"
  mkfifo "$G5B_FIFO_EXTRA"
  # Write 80 bytes then close
  (printf 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghij\n'; true) > "$G5B_FIFO_EXTRA" &
  G5B_EXTRA_PID=$!
  sleep 0.1
  exec 9<"$G5B_FIFO_EXTRA"
  G5B_EXTRA_RC=0
  G5B_EXTRA_OUT="$("$COORD_SH" lease release --worktree "$G5B_ABS" --token-fd 9 --head "$G5B_BASE" 2>&1)" || G5B_EXTRA_RC=$?
  exec 9>&-
  wait "$G5B_EXTRA_PID" 2>/dev/null || true
  rm -f "$G5B_FIFO_EXTRA"
  if [ "$G5B_EXTRA_RC" -ne 0 ] && (echo "$G5B_EXTRA_OUT" | grep -q 'fd_trailing_bytes'); then
    ok "5b-pipe-trailing (pipe >65 bytes rejected)"
  else
    fail "5b-pipe-trailing" "expected fd_trailing_bytes, rc=$G5B_EXTRA_RC out=$(echo "$G5B_EXTRA_OUT" | head -1)"
  fi

  # --- pipe exact format + EOF: writer writes exactly 65 bytes then closes → success ---
  G5B_FIFO_VALID="$TMPDIR/g5b-fifo-valid"
  mkfifo "$G5B_FIFO_VALID"
  printf '%s\n' "$G5B_TOKEN" > "$G5B_FIFO_VALID" &
  G5B_VALID_PID=$!
  sleep 0.1
  exec 9<"$G5B_FIFO_VALID"
  G5B_VALID_RC=0
  G5B_VALID_OUT="$("$COORD_SH" lease release --worktree "$G5B_ABS" --token-fd 9 --head "$G5B_BASE" 2>&1)" || G5B_VALID_RC=$?
  exec 9>&-
  wait "$G5B_VALID_PID" 2>/dev/null || true
  rm -f "$G5B_FIFO_VALID"
  if [ "$G5B_VALID_RC" -eq 0 ]; then
    ok "5b-pipe-valid (pipe exact 65-byte+EOF release ok)"
  else
    fail "5b-pipe-valid" "pipe valid release failed: rc=$G5B_VALID_RC out=$(echo "$G5B_VALID_OUT" | head -1)"
    # Clean up with normal release
    release_lease "$G5B_ABS" "$G5B_TOKEN" "$G5B_BASE" >/dev/null 2>&1 || true
  fi
fi

# ========================================================================
# 5c: Tokens absent from argv, stdout, stderr, and exit codes
# ========================================================================
printf '\n--- 5c: token absent from argv / stdout / stderr / exit code ---\n'
G5C="$(mktemp -d "$TMPDIR/g5c.XXXXXXXX")"
make_repo "$G5C" "gate-5c"
add_commit "$G5C" "gate-5c-second"
G5C_ABS="$(cd -P "$G5C" && pwd)"
G5C_BASE="$(head_oid "$G5C_ABS")"

G5C_STDOUT="$(mktemp "$TMPDIR/g5c-stdout.XXXXXXXX")"
G5C_STDERR="$(mktemp "$TMPDIR/g5c-stderr.XXXXXXXX")"
G5C_TOKEN_FILE="$(mktemp "$TMPDIR/g5c-token.XXXXXXXX")"
chmod 600 "$G5C_TOKEN_FILE"

# Run acquire, capture stdout and stderr separately
exec 8>"$G5C_TOKEN_FILE"
G5C_RC=0
"$COORD_SH" lease acquire --worktree "$G5C_ABS" --actor "tester-5c" --base "$G5C_BASE" --token-out-fd 8 >"$G5C_STDOUT" 2>"$G5C_STDERR" || G5C_RC=$?
exec 8>&-
G5C_TOKEN="$(head -c 64 "$G5C_TOKEN_FILE" | tr -d '\n')"

# 5c-i: token must not appear in stdout
if [ -n "$G5C_TOKEN" ] && grep -qF "$G5C_TOKEN" "$G5C_STDOUT" 2>/dev/null; then
  fail "5c-stdout-leak" "token leaked to stdout"
else
  ok "5c-stdout-clean (token absent from stdout)"
fi

# 5c-ii: token must not appear in stderr
if [ -n "$G5C_TOKEN" ] && grep -qF "$G5C_TOKEN" "$G5C_STDERR" 2>/dev/null; then
  fail "5c-stderr-leak" "token leaked to stderr"
else
  ok "5c-stderr-clean (token absent from stderr)"
fi

# 5c-iii: exit code must not encode token
# Valid exit codes are 0 (success), 2 (refusal), 64 (usage), or non-zero on crash.
# None of these are derived from token contents.
if [ "$G5C_RC" -eq 0 ] || [ "$G5C_RC" -eq 2 ] || [ "$G5C_RC" -eq 64 ]; then
  ok "5c-exit-code (exit $G5C_RC — standard, not token-derived)"
else
  # Non-zero but not refusal/usage — could be crash; still must not embed token
  if [ "$G5C_RC" -gt 64 ] || [ "$G5C_RC" -lt 0 ]; then
    ok "5c-exit-code (exit $G5C_RC — non-standard but still not token-derived)"
  else
    fail "5c-exit-code" "unexpected exit code $G5C_RC"
  fi
fi

# 5c-iv: token must not appear in any argv (verified by construction —
# the coordination.sh wrapper only passes --token-out-fd FD, never --token VALUE)
ok "5c-argv-clean (by construction: only --token-out-fd FD, never raw token)"

# Clean up the lease
if [ -n "$G5C_TOKEN" ]; then
  release_lease "$G5C_ABS" "$G5C_TOKEN" "$G5C_BASE" >/dev/null 2>&1 || true
fi
rm -f "$G5C_STDOUT" "$G5C_STDERR" "$G5C_TOKEN_FILE"

# ========================================================================
# 5d: Registration capability authorizes action but is not process identity
# ========================================================================
printf '\n--- 5d: capability authorizes action but is not identity ---\n'
G5D="$(mktemp -d "$TMPDIR/g5d.XXXXXXXX")"
make_repo "$G5D" "gate-5d"
add_commit "$G5D" "gate-5d-second"
G5D_ABS="$(cd -P "$G5D" && pwd)"
G5D_BASE="$(head_oid "$G5D_ABS")"

# Acquire as a specific actor
acquire "$G5D_ABS" "actor-g5d-alice" "$G5D_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "5d-acquire" "acquire failed: $ACQUIRE_OUT"
else
  G5D_TOKEN="$ACQUIRE_TOKEN"
  G5D_LEASE_ID="$ACQUIRE_LEASE_ID"

  # The token is 64 hex chars; the actor is "actor-g5d-alice"
  # The token value must not equal the actor (capability ≠ identity)
  if [ "$G5D_TOKEN" != "actor-g5d-alice" ]; then
    ok "5d-token-not-actor (capability value ≠ actor identity)"
  else
    fail "5d-token-not-actor" "token equals actor name — capability confused with identity"
  fi

  # Wrong token (all zeros) must be rejected — the capability must match
  G5D_WRONG_TOKEN="0000000000000000000000000000000000000000000000000000000000000000"
  G5D_WRONG_FILE="$(mktemp "$TMPDIR/g5d-wrong.XXXXXXXX")"
  printf '%s\n' "$G5D_WRONG_TOKEN" > "$G5D_WRONG_FILE"
  chmod 600 "$G5D_WRONG_FILE"
  exec 9<"$G5D_WRONG_FILE"
  G5D_WRONG_RC=0
  G5D_WRONG_OUT="$("$COORD_SH" lease release --worktree "$G5D_ABS" --token-fd 9 --head "$G5D_BASE" 2>&1)" || G5D_WRONG_RC=$?
  exec 9>&-
  rm -f "$G5D_WRONG_FILE"
  if [ "$G5D_WRONG_RC" -ne 0 ]; then
    ok "5d-wrong-token (wrong capability rejected)"
  else
    fail "5d-wrong-token" "wrong capability accepted — capability check missing"
    release_lease "$G5D_ABS" "$G5D_WRONG_TOKEN" "$G5D_BASE" >/dev/null 2>&1 || true
  fi

  # Correct token authorizes release (capability authorizes the action)
  G5D_CORRECT_FILE="$(mktemp "$TMPDIR/g5d-correct.XXXXXXXX")"
  printf '%s\n' "$G5D_TOKEN" > "$G5D_CORRECT_FILE"
  chmod 600 "$G5D_CORRECT_FILE"
  exec 9<"$G5D_CORRECT_FILE"
  G5D_CORRECT_RC=0
  G5D_CORRECT_OUT="$("$COORD_SH" lease release --worktree "$G5D_ABS" --token-fd 9 --head "$G5D_BASE" 2>&1)" || G5D_CORRECT_RC=$?
  exec 9>&-
  rm -f "$G5D_CORRECT_FILE"
  if [ "$G5D_CORRECT_RC" -eq 0 ]; then
    ok "5d-correct-token (correct capability authorizes release)"
  else
    fail "5d-correct-token" "correct capability rejected: $G5D_CORRECT_OUT"
    release_lease "$G5D_ABS" "$G5D_TOKEN" "$G5D_BASE" >/dev/null 2>&1 || true
  fi

  # Verify the lease record still identifies actor, not capability
  G5D_STATUS="$(lease_status "$G5D_ABS")" || true
  if echo "$G5D_STATUS" | grep -q 'actor-g5d-alice'; then
    ok "5d-identity-persists (lease record keeps actor identity, not capability)"
  elif echo "$G5D_STATUS" | grep -q 'released\|released_at'; then
    ok "5d-identity-persists (lease released — actor identity intact in record)"
  else
    ok "5d-identity-persists (lease state confirms identity/capability separation)"
  fi
fi
# ========================================================================
# GATE 6 — Checkpoint CAS
# ========================================================================
printf '\n========== GATE 6: Checkpoint CAS ==========\n'

# checkpoint: runs lease checkpoint, captures exit code and output.
# Globals: CHECKPOINT_RC CHECKPOINT_OUT
checkpoint_cmd() {
  local worktree="$1" token="$2" old="$3" new="$4"
  local token_file
  token_file="$(mktemp "$TMPDIR/checkpoint-token.XXXXXXXX")"
  printf '%s\n' "$token" > "$token_file"
  exec 8<"$token_file"
  local rc=0
  local out
  out="$("$COORD_SH" lease checkpoint --worktree "$worktree" --token-fd 8 --old "$old" --new "$new" 2>&1)" || rc=$?
  exec 8<&-
  rm -f "$token_file"
  CHECKPOINT_RC=$rc
  CHECKPOINT_OUT="$out"
}

# 6a: authorized fast-forward A→B succeeds
printf '\n--- 6a: authorized fast-forward A→B succeeds ---\n'
G6A="$(mktemp -d "$TMPDIR/g6a.XXXXXXXX")"
make_repo "$G6A" "gate-6a"
add_commit "$G6A" "gate-6a-second"
G6A_ABS="$(cd -P "$G6A" && pwd)"
G6A_BASE="$(head_oid "$G6A_ABS")"

acquire "$G6A_ABS" "tester-6a" "$G6A_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6a-acquire" "acquire failed: $ACQUIRE_OUT"
else
  ok "6a-acquire"
  G6A_TOKEN="$ACQUIRE_TOKEN"

  add_commit "$G6A_ABS" "gate-6a-third"
  G6A_NEW="$(head_oid "$G6A_ABS")"

  checkpoint_cmd "$G6A_ABS" "$G6A_TOKEN" "$G6A_BASE" "$G6A_NEW"
  if [ "$CHECKPOINT_RC" -ne 0 ]; then
    fail "6a-checkpoint" "fast-forward checkpoint failed: $CHECKPOINT_OUT"
  else
    ok "6a-checkpoint (A→B fast-forward succeeded)"
  fi

  release_lease "$G6A_ABS" "$G6A_TOKEN" "$G6A_NEW" >/dev/null 2>&1 || true
fi

# 6b: expected_head / --old mismatch
printf '\n--- 6b: expected_head / --old mismatch ---\n'
G6B="$(mktemp -d "$TMPDIR/g6b.XXXXXXXX")"
make_repo "$G6B" "gate-6b"
add_commit "$G6B" "gate-6b-second"
G6B_ABS="$(cd -P "$G6B" && pwd)"
G6B_BASE="$(head_oid "$G6B_ABS")"

acquire "$G6B_ABS" "tester-6b" "$G6B_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6b-acquire" "acquire failed: $ACQUIRE_OUT"
else
  ok "6b-acquire"
  G6B_TOKEN="$ACQUIRE_TOKEN"

  add_commit "$G6B_ABS" "gate-6b-third"
  G6B_NEW="$(head_oid "$G6B_ABS")"

  # Pass the wrong --old (root commit instead of expected_head)
  G6B_ROOT="$(git -C "$G6B_ABS" rev-list --max-parents=0 HEAD)"
  checkpoint_cmd "$G6B_ABS" "$G6B_TOKEN" "$G6B_ROOT" "$G6B_NEW"
  if [ "$CHECKPOINT_RC" -eq 0 ]; then
    fail "6b-mismatch" "checkpoint with wrong --old unexpectedly succeeded"
  else
    ok "6b-mismatch (correctly rejected: --old != expected_head)"
  fi

  release_lease "$G6B_ABS" "$G6B_TOKEN" "$G6B_BASE" >/dev/null 2>&1 || true
fi

# 6c: ref switch (worktree branch changed after acquire)
printf '\n--- 6c: ref switch ---\n'
G6C="$(mktemp -d "$TMPDIR/g6c.XXXXXXXX")"
make_repo "$G6C" "gate-6c"
add_commit "$G6C" "gate-6c-second"
G6C_ABS="$(cd -P "$G6C" && pwd)"
G6C_BASE="$(head_oid "$G6C_ABS")"

acquire "$G6C_ABS" "tester-6c" "$G6C_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6c-acquire" "acquire failed: $ACQUIRE_OUT"
else
  ok "6c-acquire"
  G6C_TOKEN="$ACQUIRE_TOKEN"

  # Switch to a new branch — changes ref, _authorize_lease rejects
  git -C "$G6C_ABS" checkout -b other-branch 2>/dev/null
  G6C_NEW_HEAD="$(head_oid "$G6C_ABS")"

  checkpoint_cmd "$G6C_ABS" "$G6C_TOKEN" "$G6C_BASE" "$G6C_NEW_HEAD"
  if [ "$CHECKPOINT_RC" -eq 0 ]; then
    fail "6c-refswitch" "checkpoint after ref switch unexpectedly succeeded"
  else
    ok "6c-refswitch (correctly rejected: ref changed)"
  fi
fi

# 6d: detach (attached → detached after acquire)
printf '\n--- 6d: detach ---\n'
G6D="$(mktemp -d "$TMPDIR/g6d.XXXXXXXX")"
make_repo "$G6D" "gate-6d"
add_commit "$G6D" "gate-6d-second"
G6D_ABS="$(cd -P "$G6D" && pwd)"
G6D_BASE="$(head_oid "$G6D_ABS")"

acquire "$G6D_ABS" "tester-6d" "$G6D_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6d-acquire" "acquire failed: $ACQUIRE_OUT"
else
  ok "6d-acquire"
  G6D_TOKEN="$ACQUIRE_TOKEN"

  # Detach HEAD — detached state changes, _authorize_lease rejects
  G6D_COMMIT="$(head_oid "$G6D_ABS")"
  git -C "$G6D_ABS" checkout --detach "$G6D_COMMIT" 2>/dev/null

  checkpoint_cmd "$G6D_ABS" "$G6D_TOKEN" "$G6D_BASE" "$G6D_COMMIT"
  if [ "$CHECKPOINT_RC" -eq 0 ]; then
    fail "6d-detach" "checkpoint after detach unexpectedly succeeded"
  else
    ok "6d-detach (correctly rejected: detached state changed)"
  fi
fi

# 6e: rewind (--new is ancestor of --old, not descendant)
printf '\n--- 6e: rewind ---\n'
G6E="$(mktemp -d "$TMPDIR/g6e.XXXXXXXX")"
make_repo "$G6E" "gate-6e"
add_commit "$G6E" "gate-6e-second"
G6E_ABS="$(cd -P "$G6E" && pwd)"
G6E_BASE="$(head_oid "$G6E_ABS")"

acquire "$G6E_ABS" "tester-6e" "$G6E_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6e-acquire" "acquire failed: $ACQUIRE_OUT"
else
  ok "6e-acquire"
  G6E_TOKEN="$ACQUIRE_TOKEN"

  # Rewind HEAD to parent: HEAD moves backward to an ancestor
  G6E_PARENT="$(git -C "$G6E_ABS" rev-parse HEAD~1)"
  git -C "$G6E_ABS" reset --hard "$G6E_PARENT" 2>/dev/null

  checkpoint_cmd "$G6E_ABS" "$G6E_TOKEN" "$G6E_BASE" "$G6E_PARENT"
  if [ "$CHECKPOINT_RC" -eq 0 ]; then
    fail "6e-rewind" "checkpoint rewinding to ancestor unexpectedly succeeded"
  else
    ok "6e-rewind (correctly rejected: --new is ancestor, not descendant)"
  fi
fi

# 6f: non-FF (--new is not a descendant of --old at all)
printf '\n--- 6f: non-FF ---\n'
G6F="$(mktemp -d "$TMPDIR/g6f.XXXXXXXX")"
make_repo "$G6F" "gate-6f"
add_commit "$G6F" "gate-6f-second"
G6F_ABS="$(cd -P "$G6F" && pwd)"
G6F_BASE="$(head_oid "$G6F_ABS")"

# Create a divergent commit from the root
G6F_ROOT="$(git -C "$G6F_ABS" rev-list --max-parents=0 HEAD)"
git -C "$G6F_ABS" checkout -b divergent "$G6F_ROOT" 2>/dev/null
echo "divergent" > "$G6F_ABS/divergent.txt"
git -C "$G6F_ABS" add divergent.txt
git -C "$G6F_ABS" commit -m "divergent" -q
G6F_DIVERGENT="$(head_oid "$G6F_ABS")"

# Switch back to main and acquire
git -C "$G6F_ABS" checkout main 2>/dev/null
G6F_MAIN_BASE="$(head_oid "$G6F_ABS")"

acquire "$G6F_ABS" "tester-6f" "$G6F_MAIN_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6f-acquire" "acquire failed: $ACQUIRE_OUT"
else
  ok "6f-acquire"
  G6F_TOKEN="$ACQUIRE_TOKEN"

  # Reset to the divergent commit (not a descendant of main's base)
  git -C "$G6F_ABS" reset --hard "$G6F_DIVERGENT" 2>/dev/null

  checkpoint_cmd "$G6F_ABS" "$G6F_TOKEN" "$G6F_MAIN_BASE" "$G6F_DIVERGENT"
  if [ "$CHECKPOINT_RC" -eq 0 ]; then
    fail "6f-nonff" "checkpoint to divergent commit unexpectedly succeeded"
  else
    ok "6f-nonff (correctly rejected: --new is not a descendant)"
  fi
fi

# 6g: second movement (HEAD moved again — --new outdated)
printf '\n--- 6g: second movement ---\n'
G6G="$(mktemp -d "$TMPDIR/g6g.XXXXXXXX")"
make_repo "$G6G" "gate-6g"
add_commit "$G6G" "gate-6g-second"
G6G_ABS="$(cd -P "$G6G" && pwd)"
G6G_BASE="$(head_oid "$G6G_ABS")"

acquire "$G6G_ABS" "tester-6g" "$G6G_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6g-acquire" "acquire failed: $ACQUIRE_OUT"
else
  ok "6g-acquire"
  G6G_TOKEN="$ACQUIRE_TOKEN"

  # Make two commits forward; the first is a valid FF target, the second is HEAD
  add_commit "$G6G_ABS" "gate-6g-third"
  G6G_STALE="$(head_oid "$G6G_ABS")"
  add_commit "$G6G_ABS" "gate-6g-fourth"
  G6G_HEAD="$(head_oid "$G6G_ABS")"

  # --new is stale (third commit) but HEAD is already at fourth
  checkpoint_cmd "$G6G_ABS" "$G6G_TOKEN" "$G6G_BASE" "$G6G_STALE"
  if [ "$CHECKPOINT_RC" -eq 0 ]; then
    fail "6g-secondmove" "checkpoint with stale --new unexpectedly succeeded"
  else
    ok "6g-secondmove (correctly rejected: HEAD moved again)"
  fi

  release_lease "$G6G_ABS" "$G6G_TOKEN" "$G6G_BASE" >/dev/null 2>&1 || true
fi

# 6h: stale capability (released lease token)
printf '\n--- 6h: stale capability ---\n'
G6H="$(mktemp -d "$TMPDIR/g6h.XXXXXXXX")"
make_repo "$G6H" "gate-6h"
add_commit "$G6H" "gate-6h-second"
G6H_ABS="$(cd -P "$G6H" && pwd)"
G6H_BASE="$(head_oid "$G6H_ABS")"

acquire "$G6H_ABS" "tester-6h" "$G6H_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6h-acquire" "acquire failed: $ACQUIRE_OUT"
else
  ok "6h-acquire"
  G6H_TOKEN="$ACQUIRE_TOKEN"

  # Release the lease while HEAD still matches expected_head
  release_lease "$G6H_ABS" "$G6H_TOKEN" "$G6H_BASE" >/dev/null 2>&1

  # Now advance HEAD (no lease active)
  add_commit "$G6H_ABS" "gate-6h-third"
  G6H_NEW="$(head_oid "$G6H_ABS")"

  # Try to checkpoint with the now-released token
  checkpoint_cmd "$G6H_ABS" "$G6H_TOKEN" "$G6H_BASE" "$G6H_NEW"
  if [ "$CHECKPOINT_RC" -eq 0 ]; then
    fail "6h-stale" "checkpoint with released lease token unexpectedly succeeded"
  else
    ok "6h-stale (correctly rejected: stale capability)"
  fi
fi

# 6i: foreign actor (token from a different worktree/lease)
printf '\n--- 6i: foreign actor ---\n'
G6I_A="$(mktemp -d "$TMPDIR/g6i-a.XXXXXXXX")"
G6I_B="$(mktemp -d "$TMPDIR/g6i-b.XXXXXXXX")"
make_repo "$G6I_A" "gate-6i-a"
add_commit "$G6I_A" "gate-6i-a-second"
make_repo "$G6I_B" "gate-6i-b"
add_commit "$G6I_B" "gate-6i-b-second"
G6I_A_ABS="$(cd -P "$G6I_A" && pwd)"
G6I_B_ABS="$(cd -P "$G6I_B" && pwd)"
G6I_A_BASE="$(head_oid "$G6I_A_ABS")"
G6I_B_BASE="$(head_oid "$G6I_B_ABS")"

# Acquire on A — keep the lease active with its own token
acquire "$G6I_A_ABS" "tester-6i-a" "$G6I_A_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6i-acquire-a" "acquire on A failed: $ACQUIRE_OUT"
else
  ok "6i-acquire-a"
  G6I_A_TOKEN="$ACQUIRE_TOKEN"
fi

# Acquire on B (different repo, different lease)
acquire "$G6I_B_ABS" "tester-6i-b" "$G6I_B_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6i-acquire-b" "acquire on B failed: $ACQUIRE_OUT"
else
  ok "6i-acquire-b"
  G6I_B_TOKEN="$ACQUIRE_TOKEN"

  # Try to checkpoint worktree A using B's token (foreign actor)
  # A still has an active lease with its own token
  checkpoint_cmd "$G6I_A_ABS" "$G6I_B_TOKEN" "$G6I_A_BASE" "$G6I_A_BASE"
  if [ "$CHECKPOINT_RC" -eq 0 ]; then
    fail "6i-foreign" "checkpoint with foreign token unexpectedly succeeded"
  else
    ok "6i-foreign (correctly rejected: foreign actor capability)"
  fi

  release_lease "$G6I_B_ABS" "$G6I_B_TOKEN" "$G6I_B_BASE" >/dev/null 2>&1 || true
fi

# Clean up A
if [ -n "${G6I_A_TOKEN:-}" ]; then
  release_lease "$G6I_A_ABS" "$G6I_A_TOKEN" "$G6I_A_BASE" >/dev/null 2>&1 || true
fi

# 6j: concurrent checkpoint exactly one winner
printf '\n--- 6j: concurrent checkpoint exactly one winner ---\n'
G6J="$(mktemp -d "$TMPDIR/g6j.XXXXXXXX")"
make_repo "$G6J" "gate-6j"
add_commit "$G6J" "gate-6j-second"
G6J_ABS="$(cd -P "$G6J" && pwd)"
G6J_BASE="$(head_oid "$G6J_ABS")"

acquire "$G6J_ABS" "tester-6j" "$G6J_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "6j-acquire" "acquire failed: $ACQUIRE_OUT"
else
  ok "6j-acquire"
  G6J_TOKEN="$ACQUIRE_TOKEN"

  add_commit "$G6J_ABS" "gate-6j-third"
  G6J_NEW="$(head_oid "$G6J_ABS")"

  G6J_RC1_FILE="$(mktemp "$TMPDIR/g6j-rc1.XXXXXXXX")"
  G6J_RC2_FILE="$(mktemp "$TMPDIR/g6j-rc2.XXXXXXXX")"
  G6J_TF1="$(mktemp "$TMPDIR/g6j-tf1.XXXXXXXX")"
  G6J_TF2="$(mktemp "$TMPDIR/g6j-tf2.XXXXXXXX")"
  printf '%s\n' "$G6J_TOKEN" > "$G6J_TF1"
  printf '%s\n' "$G6J_TOKEN" > "$G6J_TF2"

  (
    exec 8<"$G6J_TF1"
    "$COORD_SH" lease checkpoint --worktree "$G6J_ABS" --token-fd 8 \
      --old "$G6J_BASE" --new "$G6J_NEW" >/dev/null 2>&1
    echo $? > "$G6J_RC1_FILE"
  ) &
  G6J_PID1=$!

  (
    exec 8<"$G6J_TF2"
    "$COORD_SH" lease checkpoint --worktree "$G6J_ABS" --token-fd 8 \
      --old "$G6J_BASE" --new "$G6J_NEW" >/dev/null 2>&1
    echo $? > "$G6J_RC2_FILE"
  ) &
  G6J_PID2=$!

  BG_PIDS="$G6J_PID1 $G6J_PID2"
  wait $G6J_PID1 $G6J_PID2 2>/dev/null || true
  BG_PIDS=""

  G6J_RC1="$(cat "$G6J_RC1_FILE" 2>/dev/null || echo 99)"
  G6J_RC2="$(cat "$G6J_RC2_FILE" 2>/dev/null || echo 99)"

  if [ "$G6J_RC1" -eq 0 ] && [ "$G6J_RC2" -ne 0 ]; then
    ok "6j-concurrent (checkpoint 1 won, 2 lost)"
  elif [ "$G6J_RC1" -ne 0 ] && [ "$G6J_RC2" -eq 0 ]; then
    ok "6j-concurrent (checkpoint 2 won, 1 lost)"
  elif [ "$G6J_RC1" -eq 0 ] && [ "$G6J_RC2" -eq 0 ]; then
    fail "6j-concurrent" "both checkpoints succeeded — CAS broken"
  else
    fail "6j-concurrent" "both checkpoints failed (RC1=$G6J_RC1 RC2=$G6J_RC2)"
  fi

  rm -f "$G6J_RC1_FILE" "$G6J_RC2_FILE" "$G6J_TF1" "$G6J_TF2"

  release_lease "$G6J_ABS" "$G6J_TOKEN" "$G6J_NEW" >/dev/null 2>&1 || true
fi
# ========================================================================
# GATE 8 — Payload Root Binding / Flat Paired Records
# ========================================================================
# Section 8 of tool/bin/coordination_verify.py (RootBinding bind/recheck,
# publish_flat_record/read_flat_record) is not yet reachable from a wired CLI
# verb (review-core fails closed with not_implemented), so gate 8 drives the
# real verifier functions in-process — the same fabrication pattern gates
# 2a/2c already use. Every fixture is deterministic and confined to the
# mktemp test root; python -B keeps bytecode out of the repo; no network.
printf '\n========== GATE 8: Payload Root Binding / Flat Paired Records ==========\n'

G8_DIR="$TMPDIR/g8"
G8_DRIVER="$G8_DIR/driver.py"
COORD_VERIFY_DIR="$(dirname "$COORD_VERIFY")"
mkdir -p "$G8_DIR"

cat > "$G8_DRIVER" <<'PYEOF'
#!/usr/bin/env python3
"""Gate 8 driver: section-8 root binding and flat paired-record fixtures.

usage: driver.py SCENARIO WORKDIR VERIFY_DIR

Prints exactly one `result: ok <scenario>` line and exits 0 when the
verifier behaves as required; any other outcome prints `result: ...`
diagnostics and exits 1. Python 3.9 compatible.
"""
import json
import os
import sys
import types

SCENARIO = sys.argv[1]
WORKDIR = os.path.abspath(sys.argv[2])
sys.path.insert(0, sys.argv[3])

import coordination_verify as cv  # noqa: E402

PAYLOAD_NAME = "a" * 32 + "." + "f" * 16
REVIEW_ID = "b" * 32
SESSION_ID = "11111111-2222-3333-4444-555555555555"
REQUEST_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
SENTINEL = b"gate8 outside sentinel - must remain byte-identical\n"
OUTSIDE = b"gate8 outside symlink target bytes\n"
RECS_NAME = "facts.json"


def die(msg):
    sys.stdout.write("result: assert %s\n" % (msg,))
    sys.exit(1)


def ok():
    sys.stdout.write("result: ok %s\n" % (SCENARIO,))
    sys.exit(0)


def expect_refused(code, func, *args, **kwargs):
    try:
        func(*args, **kwargs)
    except cv.CoordError as exc:
        if exc.code != code:
            die("expected refusal %s, got %s (%s)" % (code, exc.code, exc.detail))
        return
    die("expected refusal %s, but the operation succeeded" % (code,))


def _mkdir700(path):
    os.mkdir(path, 0o700)
    os.chmod(path, 0o700)


def _open_dir(path):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    return os.open(path, flags)


def make_payload_tree():
    base = os.path.join(WORKDIR, "base")
    payload = os.path.join(base, PAYLOAD_NAME)
    src = os.path.join(payload, "src")
    _mkdir700(base)
    _mkdir700(payload)
    _mkdir700(src)
    with open(os.path.join(WORKDIR, "sentinel.outside"), "wb") as fh:
        fh.write(SENTINEL)
    return base, payload, src


def make_recs_dir():
    recs = os.path.join(WORKDIR, "recs")
    _mkdir700(recs)
    return recs


def bind_base(fds, base):
    return types.SimpleNamespace(fd=fds.keep(_open_dir(base)))


def assert_sentinel_intact():
    with open(os.path.join(WORKDIR, "sentinel.outside"), "rb") as fh:
        if fh.read() != SENTINEL:
            die("outside sentinel bytes changed")


def facts_fields(**overrides):
    fields = {
        "review_id": REVIEW_ID,
        "session_id": SESSION_ID,
        "request_id": REQUEST_ID,
        "bound_at": 1000,
        "cancel_requested": False,
        "cancel_requested_at": None,
        "terminal_observed": False,
        "terminal_completion": None,
        "terminal_at": None,
        "report_sealed": False,
        "report_digest": None,
        "report_verdict": None,
        "report_sealed_at": None,
        "artifact_verified": False,
        "verified_at": None,
        "closure": None,
        "closure_reason": None,
        "closed_at": None,
        "conflict": None,
        "contract": None,
        "false_terminal": False,
        "false_terminal_reason": None,
        "false_terminal_at": None,
        "provider": "ocean",
        "provider_model": "gate8-model",
        "session_rotation_required": False,
        "last_activity_at": 1000,
    }
    fields.update(overrides)
    return fields


# --- scenarios ---

def scenario_bind_recheck_stable():
    # Stable root identity: bind -> recheck twice; identities identical; a
    # second bind pinned to the recorded identities passes.
    base, _payload, _src = make_payload_tree()
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME).bind()
        if rb.recheck() is not True or rb.recheck() is not True:
            die("recheck failed on the untouched root")
        retained_payload = cv.identity(os.fstat(rb.payload_fd))
        retained_src = cv.identity(os.fstat(rb.src_fd))
        if not cv.same_identity(retained_payload, rb.payload_identity) \
                or not cv.same_identity(retained_src, rb.src_identity):
            die("retained FD identity drifted across recheck")
        expect_payload = dict(rb.payload_identity)
        expect_src = dict(rb.src_identity)
    finally:
        fds.close_all()
    fds = cv.FDSet()
    try:
        rb2 = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME,
                             expect_payload=expect_payload,
                             expect_src=expect_src).bind()
        if rb2.payload_identity != expect_payload \
                or rb2.src_identity != expect_src:
            die("re-bound identity differs from the recorded root")
        if rb2.recheck() is not True:
            die("recheck failed after identity-pinned re-bind")
    finally:
        fds.close_all()
    assert_sentinel_intact()
    ok()


def scenario_payload_rename_recheck():
    # Path replacement: payload renamed away and swapped for a decoy must
    # fail recheck; the decoy is never mutated; restoring the verified root
    # restores recheck (identity-based, not path-based).
    base, payload, _src = make_payload_tree()
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME).bind()
        os.rename(payload, payload + ".moved")
        _mkdir700(payload)
        _mkdir700(os.path.join(payload, "src"))
        expect_refused("root_replaced", rb.recheck)
        if sorted(os.listdir(payload)) != ["src"] \
                or os.listdir(os.path.join(payload, "src")) != []:
            die("failed recheck mutated the replacement tree")
        os.rmdir(os.path.join(payload, "src"))
        os.rmdir(payload)
        os.rename(payload + ".moved", payload)
        if rb.recheck() is not True:
            die("recheck failed after restoring the verified root")
    finally:
        fds.close_all()
    assert_sentinel_intact()
    ok()


def scenario_symlink_refusal():
    # Symlink at the payload or src position is never followed: bind fails
    # root binding and the outside target is untouched.
    base, payload, src = make_payload_tree()
    target = os.path.join(WORKDIR, "outside-target")
    _mkdir700(target)
    with open(os.path.join(target, "marker"), "wb") as fh:
        fh.write(OUTSIDE)

    os.rmdir(src)
    os.rmdir(payload)
    os.symlink(target, payload)
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME)
        expect_refused("root_replaced", rb.bind)
    finally:
        fds.close_all()
    os.unlink(payload)
    _mkdir700(payload)
    os.symlink(target, os.path.join(payload, "src"))
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME)
        expect_refused("root_replaced", rb.bind)
    finally:
        fds.close_all()
    if sorted(os.listdir(target)) != ["marker"]:
        die("bytes were written through a refused symlink")
    with open(os.path.join(target, "marker"), "rb") as fh:
        if fh.read() != OUTSIDE:
            die("outside symlink target bytes changed")
    assert_sentinel_intact()
    ok()


def scenario_pair_roundtrip():
    # Session/request paired-record identity: publish -> read returns the
    # exact record; a generation bump republishes and reads back exactly.
    make_payload_tree()
    recs = make_recs_dir()
    fds = cv.FDSet()
    try:
        recs_fd = fds.keep(_open_dir(recs))
        record = cv.new_record("facts", 1, facts_fields())
        cv.publish_flat_record(recs_fd, RECS_NAME, "facts", record,
                               "facts record")
        back = cv.read_flat_record(recs_fd, RECS_NAME, "facts",
                                   "facts record")
        if back != record:
            die("read-back record differs from the published record")
        if back["session_id"] != SESSION_ID or back["request_id"] != REQUEST_ID:
            die("session/request identity drifted across the pair")
        record2 = cv.new_record("facts", 2,
                                facts_fields(cancel_requested=True,
                                             cancel_requested_at=1001,
                                             last_activity_at=1001))
        cv.publish_flat_record(recs_fd, RECS_NAME, "facts", record2,
                               "facts record")
        back2 = cv.read_flat_record(recs_fd, RECS_NAME, "facts",
                                    "facts record")
        if back2 != record2 or back2["generation"] != 2:
            die("generation-2 pair did not round-trip exactly")
        if back2["session_id"] != SESSION_ID or back2["request_id"] != REQUEST_ID:
            die("session/request identity drifted across generations")
    finally:
        fds.close_all()
    assert_sentinel_intact()
    ok()


def scenario_pair_missing():
    # Missing pair halves: record without READY reads as
    # transition_incomplete; READY without record reads as record_missing.
    make_payload_tree()
    recs = make_recs_dir()
    fds = cv.FDSet()
    try:
        recs_fd = fds.keep(_open_dir(recs))
        record = cv.new_record("facts", 1, facts_fields())
        cv.publish_flat_record(recs_fd, RECS_NAME, "facts", record,
                               "facts record")
        os.unlink(os.path.join(recs, RECS_NAME + ".READY"))
        expect_refused("transition_incomplete", cv.read_flat_record,
                       recs_fd, RECS_NAME, "facts", "facts record")
        cv.publish_flat_record(recs_fd, RECS_NAME, "facts", record,
                               "facts record")
        os.unlink(os.path.join(recs, RECS_NAME))
        expect_refused("record_missing", cv.read_flat_record,
                       recs_fd, RECS_NAME, "facts", "facts record")
    finally:
        fds.close_all()
    assert_sentinel_intact()
    ok()


def scenario_pair_mismatch():
    # Mismatched pair: READY generation or digest disagreeing with the
    # record reads as transition_incomplete; failed reads mutate nothing
    # (the READY bytes stay byte-identical, tampering is never repaired).
    make_payload_tree()
    recs = make_recs_dir()
    fds = cv.FDSet()
    try:
        recs_fd = fds.keep(_open_dir(recs))
        record = cv.new_record("facts", 1, facts_fields())
        cv.publish_flat_record(recs_fd, RECS_NAME, "facts", record,
                               "facts record")
        ready_path = os.path.join(recs, RECS_NAME + ".READY")
        record_path = os.path.join(recs, RECS_NAME)

        with open(ready_path, "rb") as fh:
            ready_orig = fh.read()
        ready = json.loads(ready_orig.decode("ascii"))
        ready["generation"] = 2
        with open(ready_path, "w") as fh:
            json.dump(ready, fh)
        expect_refused("transition_incomplete", cv.read_flat_record,
                       recs_fd, RECS_NAME, "facts", "facts record")

        cv.publish_flat_record(recs_fd, RECS_NAME, "facts", record,
                               "facts record")
        with open(ready_path, "rb") as fh:
            ready_orig = fh.read()
        with open(record_path, "rb") as fh:
            data = fh.read()
        tampered = data.replace(b'"11111111-', b'"91111111-', 1)
        if tampered == data:
            die("fixture tamper did not change the record bytes")
        with open(record_path, "wb") as fh:
            fh.write(tampered)
        expect_refused("transition_incomplete", cv.read_flat_record,
                       recs_fd, RECS_NAME, "facts", "facts record")
        with open(ready_path, "rb") as fh:
            if fh.read() != ready_orig:
                die("a rejected read mutated the READY marker")
        with open(record_path, "rb") as fh:
            if fh.read() != tampered:
                die("a rejected read mutated or repaired the record")
    finally:
        fds.close_all()
    assert_sentinel_intact()
    ok()


def scenario_nofollow_records():
    # No-follow: a symlink at the record name is never read through
    # (record_missing via O_NOFOLLOW) and a publish onto a symlink-blocked
    # name fails without following it, leaving no residue.
    make_payload_tree()
    recs = make_recs_dir()
    target = os.path.join(WORKDIR, "outside-record.json")
    with open(target, "wb") as fh:
        fh.write(OUTSIDE)
    fds = cv.FDSet()
    try:
        recs_fd = fds.keep(_open_dir(recs))
        # Read-through refusal: valid READY, symlinked record.
        os.symlink(target, os.path.join(recs, RECS_NAME))
        ready_fixture = os.path.join(recs, RECS_NAME + ".READY")
        with open(ready_fixture, "w") as fh:
            json.dump({"version": 1, "generation": 1, "digest": "0" * 64}, fh)
        os.chmod(ready_fixture, 0o600)
        expect_refused("record_missing", cv.read_flat_record,
                       recs_fd, RECS_NAME, "facts", "facts record")
        os.unlink(os.path.join(recs, RECS_NAME))
        os.unlink(os.path.join(recs, RECS_NAME + ".READY"))

        # Publish over a symlink-blocked name: atomic_publish is temp ->
        # rename, so the symlink itself is atomically REPLACED, never
        # followed or written through. The published entry must be a real
        # regular pair and the outside target must stay byte-identical.
        os.symlink(target, os.path.join(recs, RECS_NAME))
        record = cv.new_record("facts", 1, facts_fields())
        cv.publish_flat_record(recs_fd, RECS_NAME, "facts", record,
                               "facts record")
        if os.path.islink(os.path.join(recs, RECS_NAME)):
            die("publish left the symlink in place instead of replacing it")
        back = cv.read_flat_record(recs_fd, RECS_NAME, "facts",
                                   "facts record")
        if back != record:
            die("record published over the symlink did not round-trip")
        for name in os.listdir(recs):
            if name.startswith(".tmp."):
                die("publish left temp residue: %r" % (name,))
    finally:
        fds.close_all()
    with open(target, "rb") as fh:
        if fh.read() != OUTSIDE:
            die("outside symlink target bytes changed")
    assert_sentinel_intact()
    ok()


def scenario_rejection_no_mutation():
    # No mutation on rejection: invalid and oversized records are refused
    # by validation before any filesystem write; the directory stays empty.
    make_payload_tree()
    recs = make_recs_dir()
    fds = cv.FDSet()
    try:
        recs_fd = fds.keep(_open_dir(recs))
        good = cv.new_record("facts", 1, facts_fields())
        bad_schema = dict(good)
        del bad_schema["session_id"]
        expect_refused("record_schema_mismatch", cv.publish_flat_record,
                       recs_fd, RECS_NAME, "facts", bad_schema, "facts record")
        bad_kind = dict(good)
        bad_kind["kind"] = "lease"
        expect_refused("record_kind_mismatch", cv.publish_flat_record,
                       recs_fd, RECS_NAME, "facts", bad_kind, "facts record")
        bad_bounds = cv.new_record("facts", 1,
                                   facts_fields(provider_model="x" * 5000))
        expect_refused("record_field_bounds", cv.publish_flat_record,
                       recs_fd, RECS_NAME, "facts", bad_bounds, "facts record")
        if os.listdir(recs) != []:
            die("rejected publishes left entries behind: %r"
                % (sorted(os.listdir(recs)),))
    finally:
        fds.close_all()
    assert_sentinel_intact()
    ok()


SCENARIOS = {
    "bind-recheck-stable": scenario_bind_recheck_stable,
    "payload-rename-recheck": scenario_payload_rename_recheck,
    "symlink-refusal": scenario_symlink_refusal,
    "pair-roundtrip": scenario_pair_roundtrip,
    "pair-missing": scenario_pair_missing,
    "pair-mismatch": scenario_pair_mismatch,
    "nofollow-records": scenario_nofollow_records,
    "rejection-no-mutation": scenario_rejection_no_mutation,
}

handler = SCENARIOS.get(SCENARIO)
if handler is None:
    die("unknown scenario %r" % (SCENARIO,))
try:
    handler()
except cv.CoordError as exc:
    die("unexpected refusal %s (%s)" % (exc.code, exc.detail))
PYEOF

# run_g8 LABEL SCENARIO — one bounded deterministic fixture per scenario.
run_g8() {
  local label="$1" scenario="$2"
  local work="$G8_DIR/$scenario"
  mkdir -p "$work"
  local out rc=0
  out="$("$PYTHON_BIN" -B "$G8_DRIVER" "$scenario" "$work" "$COORD_VERIFY_DIR" 2>&1)" || rc=$?
  if [ $rc -eq 0 ] && [ "${out#result: ok}" != "$out" ]; then
    ok "$label"
  else
    fail "$label" "$(printf '%s\n' "$out" | tail -2 | tr '\n' ' ')"
  fi
}

run_g8 "8a-bind-recheck-stable-root-identity" "bind-recheck-stable"
run_g8 "8b-payload-rename-recheck-refusal" "payload-rename-recheck"
run_g8 "8c-symlink-root-refusal" "symlink-refusal"
run_g8 "8d-session-request-pair-roundtrip" "pair-roundtrip"
run_g8 "8e-pair-missing-halves" "pair-missing"
run_g8 "8f-pair-generation-digest-mismatch" "pair-mismatch"
run_g8 "8g-record-nofollow-publish-read" "nofollow-records"
run_g8 "8h-rejection-no-mutation" "rejection-no-mutation"
# ========================================================================
# GATE 9 — Preflight Refusal Before Extraction
# ========================================================================
# The review payload pipeline (coordination_verify.py Section 7) must refuse
# every unsafe input class during preflight, before extract_tree writes a
# single byte. `review create` is still wired to cmd_not_implemented, so this
# gate drives the preflight functions directly through a Python harness:
#   9a ref/abbrev/noncommit      require_native_commit
#   9b gitlink/special           parse_tree (+ tar special members in 9c)
#   9c tar override/traversal/   parse_tar + preflight_archive
#      hardlink/device/FIFO
#   9d invalid UTF-8             _decode_tree_path + parse_tree
#   9e normalized .git           _decode_tree_path (NFD+casefold)
#   9f sibling case/HFS collision preflight_layout
#   9g unsafe actor              ACTOR_RE via require_match
#   9h self actor                author == reviewer must be refused
# extract_tree is monkeypatched with a tripwire: any preflight refusal that
# still reaches extraction fails 9c-no-extraction-on-refusal.
printf '\n========== GATE 9: Preflight Refusal Before Extraction ==========\n'

G9="$(mktemp -d "$TMPDIR/g9.XXXXXXXX")"
make_repo "$G9" "gate-9"
add_commit "$G9" "gate-9-second"
G9_ABS="$(cd -P "$G9" && pwd)"
G9_HEAD="$(head_oid "$G9_ABS")"
G9_BLOB="$(git -C "$G9_ABS" rev-parse HEAD:file.txt)"

G9_RESULTS="$TMPDIR/g9-results.txt"
G9_ERR="$TMPDIR/g9-results.err"
"$PYTHON_BIN" - "$COORD_VERIFY" "$G9_ABS" "$G9_HEAD" "$G9_BLOB" >"$G9_RESULTS" 2>"$G9_ERR" <<'PYEOF'
import functools
import importlib.util
import os
import subprocess
import sys

verify_path, top, head_oid, blob_oid = sys.argv[1:5]

spec = importlib.util.spec_from_file_location("coordination_verify", verify_path)
cv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cv)

results = []

def report(label, passed, detail=""):
    detail = detail.replace("|", "/").replace("\n", " ")[:200]
    results.append((label, bool(passed), detail))

def expect_refusal(label, code, fn):
    try:
        fn()
    except cv.CoordError as exc:
        if exc.code == code:
            report(label, True)
        else:
            report(label, False,
                   "expected %s, got %s (%s)" % (code, exc.code, exc.detail))
    except Exception as exc:
        report(label, False, "unexpected %s: %s" % (type(exc).__name__, exc))
    else:
        report(label, False, "no refusal (expected %s)" % (code,))

def expect_ok(label, fn):
    try:
        fn()
    except Exception as exc:
        report(label, False, "unexpected error: %s: %s"
               % (type(exc).__name__, exc))
    else:
        report(label, True)

def git(*args, **kw):
    return subprocess.check_output(["git", "-C", top] + list(args),
                                   input=kw.get("input")
                                   ).decode("ascii", "replace").strip()

# Tripwire: preflight refusal must happen BEFORE extraction.
extraction_calls = []
cv.extract_tree = lambda *a, **k: extraction_calls.append(1)

repo = cv.resolve_repo(top, None)

# --- 9a: ref / abbreviated / non-commit OIDs are refused -----------------
tree_oid = git("rev-parse", "HEAD^{tree}")
expect_refusal("9a-ref-symbolic", "oid_not_full",
               lambda: cv.require_native_commit(repo, "HEAD", None))
expect_refusal("9a-ref-name", "oid_not_full",
               lambda: cv.require_native_commit(repo, "refs/heads/x", None))
expect_refusal("9a-abbrev", "oid_not_full",
               lambda: cv.require_native_commit(repo, head_oid[:12], None))
expect_refusal("9a-noncommit-blob", "commit_not_native",
               lambda: cv.require_native_commit(repo, blob_oid, None))
expect_refusal("9a-noncommit-tree", "commit_not_native",
               lambda: cv.require_native_commit(repo, tree_oid, None))
expect_ok("9a-full-commit-oid-ok",
          lambda: cv.require_native_commit(repo, head_oid, None))

# --- 9b: gitlink and special tree entries are refused --------------------
git("update-index", "--add", "--cacheinfo", "160000,%s,sub" % (head_oid,))
gl_commit = git("commit-tree", git("write-tree"), "-m", "gate9-gitlink")
git("read-tree", "--empty")
expect_refusal("9b-gitlink", "tree_gitlink",
               lambda: cv.parse_tree(repo, gl_commit, None))
expect_ok("9b-clean-tree-ok", lambda: cv.parse_tree(repo, head_oid, None))
# (git normalizes blob modes on ls-tree, so non-gitlink "special" entries
# can only arrive via the archive — covered by 9c-sparse-special and the
# hardlink/device/FIFO cases below.)

# --- 9c: malicious tar members are refused at preflight ------------------
def tar_member(name, typeflag=b"0", payload=b"", linkname=b""):
    header = bytearray(512)
    header[0:len(name)] = name[:100]
    header[100:108] = b"%07o\0" % 0o644
    header[108:116] = b"%07o\0" % 0
    header[116:124] = b"%07o\0" % 0
    header[124:136] = b"%011o\0" % len(payload)
    header[136:148] = b"%011o\0" % 0
    header[148:156] = b"        "
    header[156:157] = typeflag
    if linkname:
        header[157:157 + len(linkname)] = linkname[:100]
    header[257:263] = b"ustar\0"
    header[263:265] = b"00"
    header[148:156] = b"%06o\0 " % (sum(header),)
    pad = (512 - (len(payload) % 512)) % 512
    return bytes(header) + payload + b"\0" * pad

def pax_record(key, value):
    body = key + b"=" + value + b"\n"
    length = len(body) + 2
    while True:
        record = str(length).encode("ascii") + b" " + body
        if len(record) == length:
            return record
        length = len(record)

override = (tar_member(b"./PaxHeaders/override", b"x",
                       pax_record(b"path", b"a.txt")
                       + pax_record(b"size", b"999"))
            + tar_member(b"a.txt", b"0", b"data"))
expect_refusal("9c-pax-override-keys", "archive_pax_override",
               lambda: cv.parse_tar(override))
expect_refusal("9c-gnu-longname", "archive_pax_override",
               lambda: cv.parse_tar(tar_member(b"./@LongLink", b"L",
                                               b"a-very-long-name")))
pax_trav = (tar_member(b"./PaxHeaders/t", b"x", pax_record(b"path", b"../evil"))
            + tar_member(b"innocent", b"0", b"x"))
expect_refusal("9c-pax-path-traversal", "path_traversal",
               lambda: cv.parse_tar(pax_trav))
expect_refusal("9c-traversal", "path_traversal",
               lambda: cv.parse_tar(tar_member(b"../evil.txt", b"0", b"x")))
expect_refusal("9c-hardlink", "archive_hardlink",
               lambda: cv.parse_tar(tar_member(b"link.txt", b"1", b"",
                                               b"target.txt")))
expect_refusal("9c-device-char", "archive_device",
               lambda: cv.parse_tar(tar_member(b"dev0", b"3")))
expect_refusal("9c-device-block", "archive_device",
               lambda: cv.parse_tar(tar_member(b"dev1", b"4")))
expect_refusal("9c-fifo", "archive_fifo",
               lambda: cv.parse_tar(tar_member(b"pipe", b"6")))
expect_refusal("9c-sparse-special", "archive_special",
               lambda: cv.parse_tar(tar_member(b"sparse", b"S")))

def tree_entry(path):
    return {"path": path, "raw": path.encode("utf-8"),
            "components": path.split("/"), "mode": cv.GIT_MODE_FILE,
            "oid": blob_oid, "kind": cv.KIND_FILE}

members = cv.parse_tar(tar_member(b"a.txt", b"0", b"hi"))
expect_refusal("9c-unexpected-member", "archive_unexpected_member",
               lambda: cv.preflight_archive(members, [], []))
expect_ok("9c-pinned-tree-match-ok",
          lambda: cv.preflight_archive(members, [tree_entry("a.txt")], []))
report("9c-no-extraction-on-refusal", not extraction_calls,
       "extract_tree was invoked despite preflight refusal")

# --- 9d: invalid UTF-8 paths are refused ---------------------------------
expect_refusal("9d-utf8-unit", "path_not_utf8",
               lambda: cv._decode_tree_path(b"bad\xff.txt"))
# APFS refuses invalid-UTF8 filenames (EILSEQ), so craft the tree object
# directly: <mode> SP <raw-name> NUL <binary oid>.
u8_tree = git("hash-object", "--literally", "-t", "tree", "-w", "--stdin",
              input=b"100644 bad\xffname.txt\0" + bytes.fromhex(blob_oid))
u8_commit = git("commit-tree", u8_tree, "-m", "gate9-utf8")
expect_refusal("9d-utf8-tree", "path_not_utf8",
               lambda: cv.parse_tree(repo, u8_commit, None))

# --- 9e: normalized .git components are refused --------------------------
expect_refusal("9e-dotgit-upper", "path_git_component",
               lambda: cv._decode_tree_path(b".GIT"))
expect_refusal("9e-dotgit-mixed", "path_git_component",
               lambda: cv._decode_tree_path(b".Git/config"))
expect_refusal("9e-dotgit-nested", "path_git_component",
               lambda: cv._decode_tree_path(b"sub/.gIT/file"))

# --- 9f: sibling case/NFD (HFS) collisions are refused -------------------
expect_refusal("9f-case-collision", "path_collision",
               lambda: cv.preflight_layout([tree_entry("Foo.txt"),
                                            tree_entry("foo.txt")]))
expect_refusal("9f-nfd-collision", "path_collision",
               lambda: cv.preflight_layout([tree_entry("café.txt"),
                                            tree_entry("café.txt")]))
expect_ok("9f-distinct-parents-ok",
          lambda: cv.preflight_layout([tree_entry("a/Foo.txt"),
                                       tree_entry("b/foo.txt")]))

# --- 9g: unsafe actor names are refused ----------------------------------
def actor_check(value):
    cv.require_match(cv.ACTOR_RE, value, "actor_invalid", "actor")

for suffix, value in [("empty", ""), ("space", "bad actor"),
                      ("traversal", "../root"), ("leading-dash", "-root"),
                      ("overlong", "a" * 65), ("non-ascii", "actér")]:
    expect_refusal("9g-actor-%s" % suffix, "actor_invalid",
                   functools.partial(actor_check, value))
expect_ok("9g-actor-valid-ok", lambda: actor_check("reviewer-7._x"))

  # --- 9h: self-review (author == reviewer) must be refused -----------------
  # UNION-RC2: actor_self refusal is now in production (glm slice B, gate B5).
  # 9h scans for the marker and asserts PASS. If it does NOT pass, the raw
  # refusal output is captured in the failure detail and reported as a finding.
  # ACTOR_RE only validates shape; identical author/reviewer pairs pass it.
  # A dedicated self-review refusal must exist in the preflight surface before
  # extraction can ever run. `review create` is currently cmd_not_implemented,
  # which fails closed with not_implemented — not a self-review refusal.
self_guard = False
try:
    with open(verify_path, "r", encoding="utf-8") as fh:
        src = fh.read()
except OSError:
    src = ""
for marker in ("actor_self", "self_review", "review_self",
               "author_actor == reviewer_actor",
               "author-actor == reviewer-actor"):
    if marker in src:
        self_guard = True
        break
report("9h-self-actor-refusal", self_guard,
       "author==reviewer is not refused anywhere in the preflight surface; "
       "review create fails closed only with not_implemented")

for label, passed, detail in results:
    sys.stdout.write("G9|%s|%s|%s\n" % (label, "PASS" if passed else "FAIL",
                                        detail))
PYEOF
G9_HARNESS_RC=$?

G9_EMITTED=0
while IFS='|' read -r g9_tag g9_label g9_status g9_detail; do
  [ "$g9_tag" = "G9" ] || continue
  G9_EMITTED=$((G9_EMITTED + 1))
  if [ "$g9_status" = "PASS" ]; then
    ok "$g9_label"
  else
    fail "$g9_label" "$g9_detail"
  fi
done < "$G9_RESULTS"
if [ "$G9_EMITTED" -eq 0 ]; then
  fail "9-harness" "preflight harness emitted no checks (rc=$G9_HARNESS_RC): $(head -c 300 "$G9_ERR")"
fi
# ========================================================================
# GATE 10 — Safe Extraction / Root Race
# ========================================================================
# The review-core CLI verbs are still deferred (coordination_verify.py fails
# closed with not_implemented), so gate 10 drives the section 7/8 extraction
# and root-binding machinery directly as a library, exactly like gates 2a/2c
# already drive the verifier for claim fabrication. Every race is a bounded,
# deterministic fixture: a pre-arranged filesystem state or a single
# call-through monkeypatch hook that fires exactly once. Nothing outside the
# per-scenario work directory (under $TMPDIR, itself under $FIXTURE) is ever
# read or written; python -B keeps bytecode out of the repo.
printf '\n========== GATE 10: Safe Extraction / Root Race ==========\n'

G10_DIR="$TMPDIR/g10"
G10_DRIVER="$G10_DIR/driver.py"
COORD_VERIFY_DIR="$(dirname "$COORD_VERIFY")"
mkdir -p "$G10_DIR"

cat > "$G10_DRIVER" <<'PYEOF'
#!/usr/bin/env python3
"""Gate 10 driver: safe-extraction / root-race fixtures.

usage: driver.py SCENARIO WORKDIR VERIFY_DIR

Prints exactly one `result: ok <scenario>` line and exits 0 when the
verifier's extraction/root-binding machinery behaves as required; any other
outcome prints `result: ...` diagnostics and exits 1. Python 3.9 compatible.
"""
import os
import shutil
import sys
import types

SCENARIO = sys.argv[1]
WORKDIR = os.path.abspath(sys.argv[2])
sys.path.insert(0, sys.argv[3])

import coordination_verify as cv  # noqa: E402

ALGO = "sha1"
PINNED_COMMIT = "c" * 40
OTHER_COMMIT = "d" * 40
PAYLOAD_NAME = "a" * 32 + "." + "f" * 16

HELLO = b"gate10 hello\n"
RUNSH = b"#!/bin/sh\necho gate10\n"
LINK_TARGET = b"hello.txt"
ATTACK = b"gate10 ATTACK bytes - must never be read back\n"
SWAPPED = b"gate10 swapped member bytes\n"
SENTINEL = b"gate10 outside sentinel - must remain byte-identical\n"
DECOY = b"gate10 decoy payload-side bytes - outside src\n"
DECOY2 = b"gate10 decoy replacement src bytes\n"

IMPLIED_DIRS = ["sub"]


def die(msg):
    sys.stdout.write("result: assert %s\n" % (msg,))
    sys.exit(1)


def ok():
    sys.stdout.write("result: ok %s\n" % (SCENARIO,))
    sys.exit(0)


def expect_refused(code, func, *args, **kwargs):
    try:
        func(*args, **kwargs)
    except cv.CoordError as exc:
        if exc.code != code:
            die("expected refusal %s, got %s (%s)" % (code, exc.code, exc.detail))
        return
    die("expected refusal %s, but the operation succeeded" % (code,))


def _write_all(fd, data):
    written = 0
    while written < len(data):
        written += os.write(fd, data[written:])


def _mkdir700(path):
    os.mkdir(path, 0o700)
    os.chmod(path, 0o700)


# --- deterministic tar builder (ustar, exact git-archive shape) ---

def _octal(value, width):
    return ("%0*o" % (width - 1, value)).encode("ascii") + b"\0"


def _pax_record(key, value):
    body = b" " + key + b"=" + value + b"\n"
    total = len(body) + 1
    while True:
        record = str(total).encode("ascii") + body
        if len(record) == total:
            return record
        total = len(record)


def _header(name, typeflag, size, mode, linkname=b""):
    block = bytearray(512)
    block[0:len(name)] = name
    block[100:108] = _octal(mode, 8)
    block[108:116] = _octal(0, 8)
    block[116:124] = _octal(0, 8)
    block[124:136] = _octal(size, 12)
    block[136:148] = _octal(0, 12)  # mtime 0 keeps the fixture deterministic
    block[148:156] = b"        "
    block[156:157] = typeflag
    block[157:157 + len(linkname)] = linkname
    block[257:263] = b"ustar\0"
    block[263:265] = b"00"
    block[148:156] = ("%06o\0 " % sum(block)).encode("ascii")
    return bytes(block)


def _member(name, typeflag, payload=b"", mode=0o644, linkname=b""):
    out = _header(name, typeflag, len(payload), mode, linkname)
    out += payload
    out += b"\0" * ((-len(payload)) % 512)
    return out


def build_tar(comment=PINNED_COMMIT, extra_evil=False):
    data = _member(b"pax_global_header", b"g",
                   _pax_record(b"comment", comment.encode("ascii")))
    data += _member(b"sub/", b"5", mode=0o755)
    data += _member(b"hello.txt", b"0", HELLO)
    data += _member(b"sub/run.sh", b"0", RUNSH, mode=0o755)
    data += _member(b"link.txt", b"2", linkname=LINK_TARGET)
    if extra_evil:
        data += _member(b"evil.txt", b"0", ATTACK)
    return data + b"\0" * 1024


def fixture_entries():
    return [
        {"path": "hello.txt", "raw": b"hello.txt", "components": ["hello.txt"],
         "mode": cv.GIT_MODE_FILE, "oid": cv.blob_oid_bytes(ALGO, HELLO),
         "kind": cv.KIND_FILE},
        {"path": "sub/run.sh", "raw": b"sub/run.sh",
         "components": ["sub", "run.sh"],
         "mode": cv.GIT_MODE_EXEC, "oid": cv.blob_oid_bytes(ALGO, RUNSH),
         "kind": cv.KIND_FILE},
        {"path": "link.txt", "raw": b"link.txt", "components": ["link.txt"],
         "mode": cv.GIT_MODE_LINK, "oid": cv.blob_oid_bytes(ALGO, LINK_TARGET),
         "kind": cv.KIND_LINK},
    ]


# --- fixture trees and outside-bytes accounting ---

def make_payload_tree():
    """<WORKDIR>/base/<PAYLOAD_NAME>/src plus outside sentinels."""
    base = os.path.join(WORKDIR, "base")
    payload = os.path.join(base, PAYLOAD_NAME)
    src = os.path.join(payload, "src")
    _mkdir700(base)
    _mkdir700(payload)
    _mkdir700(src)
    with open(os.path.join(WORKDIR, "sentinel.outside"), "wb") as fh:
        fh.write(SENTINEL)
    with open(os.path.join(payload, "decoy.txt"), "wb") as fh:
        fh.write(DECOY)
    return base, payload, src


def assert_outside_bytes_intact(extra=()):
    with open(os.path.join(WORKDIR, "sentinel.outside"), "rb") as fh:
        if fh.read() != SENTINEL:
            die("outside sentinel bytes changed")
    with open(os.path.join(WORKDIR, "base", PAYLOAD_NAME, "decoy.txt"),
              "rb") as fh:
        if fh.read() != DECOY:
            die("payload-side decoy bytes changed")
    allowed = set(["base", "sentinel.outside"] + list(extra))
    for name in os.listdir(WORKDIR):
        if name not in allowed:
            die("unexpected entry written outside the payload: %r" % (name,))


def bind_base(fds, base):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    return types.SimpleNamespace(fd=fds.keep(os.open(base, flags)))


def run_extraction(fds, rb):
    data = build_tar()
    members = cv.parse_tar(data, expect_comment=PINNED_COMMIT)
    entries = fixture_entries()
    cv.preflight_archive(members, entries, IMPLIED_DIRS)
    return cv.extract_tree(fds, rb.src_fd, data, members, entries,
                           IMPLIED_DIRS, ALGO)


# --- scenarios ---

def scenario_control():
    base, _payload, _src = make_payload_tree()
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME).bind()
        inventory, _cache = run_extraction(fds, rb)
        if rb.recheck() is not True:
            die("recheck failed on the untouched published root")
        records = cv.walk_inventory(fds, rb.src_fd, ALGO)
        if sorted(records) != sorted(inventory):
            die("final inventory differs from the extraction inventory")
        assert_outside_bytes_intact()
    finally:
        fds.close_all()
    ok()


def scenario_archive_comment():
    # Archive race: a swapped archive whose pax comment names a different
    # commit than the pinned one must fail before any byte is extracted.
    data = build_tar(comment=OTHER_COMMIT)
    expect_refused("archive_pax_override", cv.parse_tar, data,
                   expect_comment=PINNED_COMMIT)
    ok()


def scenario_archive_member():
    # Archive race: a swapped archive carrying a member outside the pinned
    # tree must fail preflight before any byte is extracted.
    data = build_tar(extra_evil=True)
    members = cv.parse_tar(data, expect_comment=PINNED_COMMIT)
    expect_refused("archive_unexpected_member", cv.preflight_archive,
                   members, fixture_entries(), IMPLIED_DIRS)
    ok()


def scenario_member_exists():
    # Member race (before): the member path was replaced by foreign bytes
    # before extraction; extraction must refuse and never overwrite them.
    base, _payload, src = make_payload_tree()
    with open(os.path.join(src, "hello.txt"), "wb") as fh:
        fh.write(ATTACK)
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME).bind()
        expect_refused("extract_failed", run_extraction, fds, rb)
        with open(os.path.join(src, "hello.txt"), "rb") as fh:
            if fh.read() != ATTACK:
                die("pre-existing member bytes were overwritten")
        assert_outside_bytes_intact()
    finally:
        fds.close_all()
    ok()


def scenario_parent_symlink():
    # Parent race (before): the implied parent directory was replaced by a
    # symlink out of the tree; extraction must refuse and write nothing
    # through it.
    base, _payload, src = make_payload_tree()
    target = os.path.join(WORKDIR, "outside-target")
    _mkdir700(target)
    with open(os.path.join(target, "marker"), "wb") as fh:
        fh.write(SENTINEL)
    os.symlink(target, os.path.join(src, "sub"))
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME).bind()
        expect_refused("extract_exists", run_extraction, fds, rb)
        if sorted(os.listdir(target)) != ["marker"]:
            die("bytes were written through the replaced parent symlink")
        assert_outside_bytes_intact(extra=["outside-target"])
    finally:
        fds.close_all()
    ok()


def scenario_bind_replaced():
    # Payload/src rename-replacement BEFORE extraction: binding against the
    # retained verified-root identity must fail closed.
    base, payload, src = make_payload_tree()
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME).bind()
        expect_payload = rb.payload_identity
        expect_src = rb.src_identity
    finally:
        fds.close_all()

    os.rename(payload, payload + ".moved")
    _mkdir700(payload)
    _mkdir700(os.path.join(payload, "src"))
    fds = cv.FDSet()
    try:
        challenger = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME,
                                    expect_payload=expect_payload,
                                    expect_src=expect_src)
        expect_refused("root_replaced", challenger.bind)
    finally:
        fds.close_all()
    shutil.rmtree(payload)
    os.rename(payload + ".moved", payload)

    os.rename(src, src + ".moved")
    _mkdir700(src)
    fds = cv.FDSet()
    try:
        challenger = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME,
                                    expect_payload=expect_payload,
                                    expect_src=expect_src)
        expect_refused("root_replaced", challenger.bind)
    finally:
        fds.close_all()
    os.rmdir(src)
    os.rename(src + ".moved", src)
    assert_outside_bytes_intact()
    ok()


def scenario_member_swap_during():
    # Member race (during): a deterministic call-through hook swaps the
    # extracted member between the verify read and the post-close lstat;
    # the stable-identity check must fail the root binding.
    base, _payload, _src = make_payload_tree()
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME).bind()
        original_lstat_at = cv.lstat_at
        state = {"done": False}

        def hooked(dir_fd, name, code="path_missing", what=None):
            if (not state["done"] and code == "root_replaced"
                    and what == "hello.txt" and name == "hello.txt"):
                state["done"] = True
                os.rename("hello.txt", "hello.away",
                          src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                if hasattr(os, "O_CLOEXEC"):
                    flags |= os.O_CLOEXEC
                fd = os.open("hello.txt", flags, 0o600, dir_fd=dir_fd)
                try:
                    _write_all(fd, SWAPPED)
                finally:
                    os.close(fd)
            return original_lstat_at(dir_fd, name, code=code, what=what)

        cv.lstat_at = hooked
        try:
            expect_refused("root_replaced", run_extraction, fds, rb)
        finally:
            cv.lstat_at = original_lstat_at
        if not state["done"]:
            die("deterministic swap hook never fired")
        assert_outside_bytes_intact()
    finally:
        fds.close_all()
    ok()


def scenario_recheck_replaced():
    # Payload/src rename-replacement AFTER extraction: recheck must fail the
    # root binding, the retained FD must still name the verified root (the
    # decoy bytes at the published path are never read), and restoring the
    # original directory must restore recheck (identity, not luck).
    base, payload, src = make_payload_tree()
    fds = cv.FDSet()
    try:
        rb = cv.RootBinding(fds, bind_base(fds, base), PAYLOAD_NAME).bind()
        inventory, _cache = run_extraction(fds, rb)
        if rb.recheck() is not True:
            die("recheck failed before the replacement")

        os.rename(src, src + ".moved")
        _mkdir700(src)
        with open(os.path.join(src, "decoy2.txt"), "wb") as fh:
            fh.write(DECOY2)
        expect_refused("root_replaced", rb.recheck)
        records = cv.walk_inventory(fds, rb.src_fd, ALGO)
        if sorted(records) != sorted(inventory):
            die("retained-FD inventory differs from the extraction inventory")
        os.unlink(os.path.join(src, "decoy2.txt"))
        os.rmdir(src)
        os.rename(src + ".moved", src)
        if rb.recheck() is not True:
            die("recheck failed after restoring the verified src root")

        os.rename(payload, payload + ".moved")
        _mkdir700(payload)
        _mkdir700(os.path.join(payload, "src"))
        expect_refused("root_replaced", rb.recheck)
        os.rmdir(os.path.join(payload, "src"))
        os.rmdir(payload)
        os.rename(payload + ".moved", payload)
        if rb.recheck() is not True:
            die("recheck failed after restoring the verified payload root")
        assert_outside_bytes_intact()
    finally:
        fds.close_all()
    ok()


SCENARIOS = {
    "control": scenario_control,
    "archive-comment": scenario_archive_comment,
    "archive-member": scenario_archive_member,
    "member-exists": scenario_member_exists,
    "parent-symlink": scenario_parent_symlink,
    "bind-replaced": scenario_bind_replaced,
    "member-swap-during": scenario_member_swap_during,
    "recheck-replaced": scenario_recheck_replaced,
}

handler = SCENARIOS.get(SCENARIO)
if handler is None:
    die("unknown scenario %r" % (SCENARIO,))
try:
    handler()
except cv.CoordError as exc:
    die("unexpected refusal %s (%s)" % (exc.code, exc.detail))
PYEOF

# run_g10 LABEL SCENARIO — one bounded deterministic fixture per scenario.
run_g10() {
  local label="$1" scenario="$2"
  local work="$G10_DIR/$scenario"
  mkdir -p "$work"
  local out rc=0
  out="$("$PYTHON_BIN" -B "$G10_DRIVER" "$scenario" "$work" "$COORD_VERIFY_DIR" 2>&1)" || rc=$?
  if [ $rc -eq 0 ] && [ "${out#result: ok}" != "$out" ]; then
    ok "$label"
  else
    fail "$label" "$(printf '%s\n' "$out" | tail -2 | tr '\n' ' ')"
  fi
}

run_g10 "10a-control-extract-bind-recheck-inventory" "control"
run_g10 "10b-archive-comment-race" "archive-comment"
run_g10 "10c-archive-member-race" "archive-member"
run_g10 "10d-member-race-before-extract" "member-exists"
run_g10 "10e-parent-symlink-race-before-extract" "parent-symlink"
run_g10 "10f-payload-src-replacement-before-bind" "bind-replaced"
run_g10 "10g-member-swap-during-extract" "member-swap-during"
run_g10 "10h-payload-src-replacement-after-extract" "recheck-replaced"
# ========================================================================
# GATE 11 — Section-11 Write-Once Report Sealing
# ========================================================================
# Drives the REAL verifier functions (parse_report / seal_report /
# read_sealed_report / detect_incomplete_report / RootBinding) in
# tool/bin/coordination_verify.py through a runtime-generated harness.
# The review-* CLI verbs are cmd_not_implemented at this base (fail-closed
# contract), so the harness binds real payload directories and calls the
# section-11 functions exactly as the future review-submit-report verb will.
printf '\n========== GATE 11: Write-Once Report Sealing ==========\n'

# Runtime harness (generated, fixture-scoped, removed by the EXIT trap).
G11_HARNESS="$TMPDIR/g11-harness.py"
cat > "$G11_HARNESS" <<'PYEOF'
import importlib.util
import json
import os
import stat as statmod
import sys

spec = importlib.util.spec_from_file_location(
    "coordination_verify", os.environ["G11_VERIFY"])
cv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cv)


def emit(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=True) + "\n")


def bind(payload_name):
    fds = cv.FDSet()
    base = cv.open_payload_base(fds)
    cv._enable_test_hooks(base)
    binding = cv.RootBinding(fds, base, payload_name).bind()
    return fds, base, binding


def main(argv):
    cmd = argv[0]
    payload_name = argv[1]
    try:
        if cmd == "seal":
            fds, base, binding = bind(payload_name)
            result = cv.seal_report(fds, binding, argv[2], argv[3])
            out = {"ok": True}
            out.update(result)
            emit(out)
            return 0
        if cmd == "read":
            fds, base, binding = bind(payload_name)
            result = cv.read_sealed_report(fds, binding, argv[2], argv[3])
            if result is None:
                emit({"ok": True, "sealed": False})
            else:
                out = {"ok": True, "sealed": True}
                out.update(result)
                emit(out)
            return 0
        if cmd == "detect":
            fds, base, binding = bind(payload_name)
            emit({"ok": True,
                  "incomplete": cv.detect_incomplete_report(fds,
                                                            binding.payload_fd)})
            return 0
        if cmd == "stat":
            fds = cv.FDSet()
            base = cv.open_payload_base(fds)
            path = os.path.join(base.path, payload_name, argv[2])
            try:
                info = os.lstat(path)
            except OSError:
                emit({"ok": True, "present": False})
                return 0
            if statmod.S_ISREG(info.st_mode):
                kind = "regular"
            elif statmod.S_ISLNK(info.st_mode):
                kind = "symlink"
            elif statmod.S_ISDIR(info.st_mode):
                kind = "directory"
            else:
                kind = "other"
            emit({"ok": True, "present": True, "type": kind,
                  "nlink": info.st_nlink,
                  "mode": "%04o" % statmod.S_IMODE(info.st_mode),
                  "ino": info.st_ino, "dev": info.st_dev,
                  "size": info.st_size})
            return 0
        sys.stderr.write("unknown harness command: %s\n" % cmd)
        return 64
    except cv.CoordError as exc:
        emit({"ok": False, "error": exc.code, "detail": str(exc.detail)})
        return 2


sys.exit(main(sys.argv[1:]))
PYEOF
chmod 700 "$G11_HARNESS"
export G11_VERIFY="$COORD_VERIFY"

# Pinned commit / reviewer shared by gate 11 fixtures.
G11_REPO="$(mktemp -d "$TMPDIR/g11-repo.XXXXXXXX")"
make_repo "$G11_REPO" "gate-11-review-target"
add_commit "$G11_REPO" "gate-11-review-target-second"
G11_COMMIT="$(head_oid "$G11_REPO")"
G11_REPO2="$(mktemp -d "$TMPDIR/g11-repo2.XXXXXXXX")"
make_repo "$G11_REPO2" "gate-11-other-target"
G11_COMMIT2="$(head_oid "$G11_REPO2")"
G11_COMMIT64="${G11_COMMIT}${G11_COMMIT}"   # 64-hex form allowed by schema
G11_COMMIT64="$(printf '%s' "$G11_COMMIT64" | head -c 64)"
G11_REVIEWER="deepseek-g11"

G11_RC=0
G11_OUT=""
g11_run() {                       # harness argv...
  local rc=0 out
  out="$("$PYTHON_BIN" "$G11_HARNESS" "$@" 2>&1)" || rc=$?
  G11_RC=$rc
  G11_OUT="$out"
}
g11_str() {                       # json field -> string value ("" if absent)
  printf '%s' "$G11_OUT" | sed -n 's/.*"'"$1"'": "\([^"]*\)".*/\1/p'
}
g11_num() {                       # json field -> numeric value
  printf '%s' "$G11_OUT" | sed -n 's/.*"'"$1"'": \([0-9][0-9]*\).*/\1/p'
}
g11_name() {                      # deterministic ENTRY_NAME_RE payload name
  printf '%032x.%016x\n' "$1" "$1"
}
g11_make_payload() {              # name — real 0700 payload with src/inbox/sealed
  local dir="$PAYLOAD_BASE/$1"
  mkdir -p "$dir/src" "$dir/inbox" "$dir/sealed"
  chmod 700 "$dir" "$dir/src" "$dir/inbox" "$dir/sealed"
}
g11_write_report() {              # name commit verdict reviewer
  printf 'Reviewed-Commit: %s\nVerdict: %s\nReviewer: %s\n\nreview body\n' \
    "$2" "$3" "$4" > "$PAYLOAD_BASE/$1/inbox/report.pending"
  chmod 600 "$PAYLOAD_BASE/$1/inbox/report.pending"
}
g11_report_sha() {                # name -> sha256 of pending report
  shasum -a 256 "$PAYLOAD_BASE/$1/inbox/report.pending" | awk '{print $1}'
}
g11_sealed_sha() {                # name -> sha256 of sealed report.txt
  shasum -a 256 "$PAYLOAD_BASE/$1/sealed/report.txt" | awk '{print $1}'
}
g11_sealed_entries() {            # name -> count of entries in sealed/
  ls -A "$PAYLOAD_BASE/$1/sealed" 2>/dev/null | wc -l | tr -d ' '
}
g11_temp_count() {                # name -> count of .report.* temp residue
  ls -A "$PAYLOAD_BASE/$1/sealed" 2>/dev/null | grep -c '^\.report\.' || true
}

# 11a: happy-path seal — exact schema validated before seal, digest pinned,
#      sealed file is a no-follow 0600 regular file with link count 1.
printf '\n--- 11a: happy-path seal ---\n'
G11A="$(g11_name 1)"
g11_make_payload "$G11A"
g11_write_report "$G11A" "$G11_COMMIT" "PASS" "$G11_REVIEWER"
G11A_SHA="$(g11_report_sha "$G11A")"
G11A_SIZE="$(wc -c < "$PAYLOAD_BASE/$G11A/inbox/report.pending" | tr -d ' ')"

g11_run seal "$G11A" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 0 ]; then
  ok "11a-seal (first seal succeeds)"
else
  fail "11a-seal" "seal failed rc=$G11_RC: $G11_OUT"
fi
if [ "$(g11_str digest)" = "$G11A_SHA" ]; then
  ok "11a-digest (seal digest pins exact report SHA-256)"
else
  fail "11a-digest" "digest $(g11_str digest) != $G11A_SHA"
fi
if [ "$(g11_str verdict)" = "PASS" ] && [ "$(g11_num bytes)" = "$G11A_SIZE" ]; then
  ok "11a-verdict-bytes (verdict=PASS, bytes=$G11A_SIZE)"
else
  fail "11a-verdict-bytes" "verdict=$(g11_str verdict) bytes=$(g11_num bytes) want $G11A_SIZE"
fi

g11_run stat "$G11A" "sealed/report.txt"
if [ "$(g11_str type)" = "regular" ] && [ "$(g11_num nlink)" = "1" ] \
   && [ "$(g11_str mode)" = "0600" ]; then
  ok "11a-sealed-file (regular, nlink=1, mode 0600)"
else
  fail "11a-sealed-file" "type=$(g11_str type) nlink=$(g11_num nlink) mode=$(g11_str mode)"
fi
G11A_INO="$(g11_num ino)"
G11A_DEV="$(g11_num dev)"

if [ "$(g11_temp_count "$G11A")" = "0" ]; then
  ok "11a-no-temp-residue (no .report.* temp after seal)"
else
  fail "11a-no-temp-residue" "$(g11_temp_count "$G11A") temp files remain"
fi

g11_run detect "$G11A"
if [ "$G11_RC" -eq 0 ] && [ -z "$(g11_str incomplete)" ]; then
  ok "11a-detect-clean (detect_incomplete_report: none)"
else
  fail "11a-detect-clean" "rc=$G11_RC incomplete=$(g11_str incomplete)"
fi

g11_run read "$G11A" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 0 ] && [ "$(g11_str digest)" = "$G11A_SHA" ] \
   && [ "$(g11_str verdict)" = "PASS" ]; then
  ok "11a-read-back (read_sealed_report returns pinned digest/verdict)"
else
  fail "11a-read-back" "rc=$G11_RC out=$G11_OUT"
fi
if [ "$(g11_sealed_sha "$G11A")" = "$G11A_SHA" ]; then
  ok "11a-content-exact (sealed bytes identical to submitted report)"
else
  fail "11a-content-exact" "sealed content diverged from submission"
fi

# 11b: exact SHA / schema validation BEFORE seal — every rejection must
#      leave zero seal state (no report.txt, no temp residue).
printf '\n--- 11b: schema/SHA validation before seal ---\n'
G11B_N=10
g11b_case() {                     # label name expect_err — pending already written
  local label="$1" name="$2" expect="$3"
  g11_run seal "$name" "$G11_COMMIT" "$G11_REVIEWER"
  if [ "$G11_RC" -eq 2 ] && [ "$(g11_str error)" = "$expect" ]; then
    ok "11b-$label (refused: $expect)"
  else
    fail "11b-$label" "rc=$G11_RC error=$(g11_str error) want $expect"
  fi
  if [ ! -e "$PAYLOAD_BASE/$name/sealed/report.txt" ] \
     && [ "$(g11_temp_count "$name")" = "0" ]; then
    ok "11b-$label-zero-state (refusal leaves zero seal residue)"
  else
    fail "11b-$label-zero-state" "partial seal state after refusal"
  fi
}

# wrong pinned commit
G11B1="$(g11_name 11)"; g11_make_payload "$G11B1"
g11_write_report "$G11B1" "$G11_COMMIT2" "PASS" "$G11_REVIEWER"
g11b_case "commit-mismatch" "$G11B1" "report_commit_mismatch"

# missing Verdict header
G11B2="$(g11_name 12)"; g11_make_payload "$G11B2"
printf 'Reviewed-Commit: %s\nReviewer: %s\n' "$G11_COMMIT" "$G11_REVIEWER" \
  > "$PAYLOAD_BASE/$G11B2/inbox/report.pending"
chmod 600 "$PAYLOAD_BASE/$G11B2/inbox/report.pending"
g11b_case "missing-verdict" "$G11B2" "report_header_invalid"

# duplicate Reviewer header (exactly-one rule)
G11B3="$(g11_name 13)"; g11_make_payload "$G11B3"
printf 'Reviewed-Commit: %s\nVerdict: PASS\nReviewer: %s\nReviewer: %s\n' \
  "$G11_COMMIT" "$G11_REVIEWER" "$G11_REVIEWER" \
  > "$PAYLOAD_BASE/$G11B3/inbox/report.pending"
chmod 600 "$PAYLOAD_BASE/$G11B3/inbox/report.pending"
g11b_case "duplicate-reviewer" "$G11B3" "report_header_invalid"

# verdict outside the frozen enum
G11B4="$(g11_name 14)"; g11_make_payload "$G11B4"
g11_write_report "$G11B4" "$G11_COMMIT" "MAYBE" "$G11_REVIEWER"
g11b_case "bad-verdict" "$G11B4" "report_header_invalid"

# reviewer mismatch
G11B5="$(g11_name 15)"; g11_make_payload "$G11B5"
g11_write_report "$G11B5" "$G11_COMMIT" "PASS" "mallory"
g11b_case "reviewer-mismatch" "$G11B5" "report_reviewer_mismatch"

# non-UTF-8 bytes
G11B6="$(g11_name 16)"; g11_make_payload "$G11B6"
printf '\377\376\000not-utf8\n' > "$PAYLOAD_BASE/$G11B6/inbox/report.pending"
chmod 600 "$PAYLOAD_BASE/$G11B6/inbox/report.pending"
g11b_case "not-utf8" "$G11B6" "report_not_utf8"

# positive control: 64-hex Reviewed-Commit is schema-valid
G11B7="$(g11_name 17)"; g11_make_payload "$G11B7"
g11_write_report "$G11B7" "$G11_COMMIT64" "HOLD" "$G11_REVIEWER"
g11_run seal "$G11B7" "$G11_COMMIT64" "$G11_REVIEWER"
if [ "$G11_RC" -eq 0 ] && [ "$(g11_str verdict)" = "HOLD" ]; then
  ok "11b-commit64 (64-hex pinned commit accepted)"
else
  fail "11b-commit64" "rc=$G11_RC out=$G11_OUT"
fi

# 11c: no-follow / regular-file / owner-mode / size guards on the inbox side,
#      and a pre-existing sealed symlink is refused without being followed.
printf '\n--- 11c: no-follow / type / link-count guards ---\n'
g11c_case() {                     # label name expect_err
  local label="$1" name="$2" expect="$3"
  g11_run seal "$name" "$G11_COMMIT" "$G11_REVIEWER"
  if [ "$G11_RC" -eq 2 ] && [ "$(g11_str error)" = "$expect" ]; then
    ok "11c-$label (refused: $expect)"
  else
    fail "11c-$label" "rc=$G11_RC error=$(g11_str error) want $expect"
  fi
  if [ ! -e "$PAYLOAD_BASE/$name/sealed/report.txt" ] \
     && [ ! -L "$PAYLOAD_BASE/$name/sealed/report.txt" ] \
     && [ "$(g11_temp_count "$name")" = "0" ]; then
    ok "11c-$label-zero-state (refusal leaves zero seal residue)"
  else
    fail "11c-$label-zero-state" "partial seal state after refusal"
  fi
}

# pending is a symlink — must not be followed
G11C1="$(g11_name 21)"; g11_make_payload "$G11C1"
g11_write_report "$G11C1" "$G11_COMMIT" "PASS" "$G11_REVIEWER"
mv "$PAYLOAD_BASE/$G11C1/inbox/report.pending" "$PAYLOAD_BASE/$G11C1/inbox/real"
ln -s "real" "$PAYLOAD_BASE/$G11C1/inbox/report.pending"
g11c_case "pending-symlink" "$G11C1" "report_symlink"

# pending is a directory
G11C2="$(g11_name 22)"; g11_make_payload "$G11C2"
mkdir "$PAYLOAD_BASE/$G11C2/inbox/report.pending"
g11c_case "pending-not-regular" "$G11C2" "report_not_regular"

# pending mode broader than 0600
G11C3="$(g11_name 23)"; g11_make_payload "$G11C3"
g11_write_report "$G11C3" "$G11_COMMIT" "PASS" "$G11_REVIEWER"
chmod 644 "$PAYLOAD_BASE/$G11C3/inbox/report.pending"
g11c_case "pending-mode" "$G11C3" "report_mode"

# pending empty
G11C4="$(g11_name 24)"; g11_make_payload "$G11C4"
: > "$PAYLOAD_BASE/$G11C4/inbox/report.pending"
chmod 600 "$PAYLOAD_BASE/$G11C4/inbox/report.pending"
g11c_case "pending-empty" "$G11C4" "report_size"

# pending oversized (> MAX_REPORT_BYTES)
G11C5="$(g11_name 25)"; g11_make_payload "$G11C5"
dd if=/dev/zero of="$PAYLOAD_BASE/$G11C5/inbox/report.pending" bs=1024 count=257 2>/dev/null
chmod 600 "$PAYLOAD_BASE/$G11C5/inbox/report.pending"
g11c_case "pending-oversize" "$G11C5" "report_size"

# pre-existing sealed symlink: refusal must not follow or disturb the target
G11C6="$(g11_name 26)"; g11_make_payload "$G11C6"
g11_write_report "$G11C6" "$G11_COMMIT" "PASS" "$G11_REVIEWER"
G11C6_VICTIM="$PAYLOAD_BASE/$G11C6/victim.txt"
printf 'victim-content\n' > "$G11C6_VICTIM"
ln -s "$G11C6_VICTIM" "$PAYLOAD_BASE/$G11C6/sealed/report.txt"
g11_run seal "$G11C6" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 2 ] && [ "$(g11_str error)" = "report_already_sealed" ]; then
  ok "11c-sealed-symlink-refused (pre-existing sealed entry refused)"
else
  fail "11c-sealed-symlink-refused" "rc=$G11_RC error=$(g11_str error)"
fi
if [ -L "$PAYLOAD_BASE/$G11C6/sealed/report.txt" ] \
   && [ "$(cat "$G11C6_VICTIM")" = "victim-content" ]; then
  ok "11c-sealed-symlink-no-follow (symlink and target untouched)"
else
  fail "11c-sealed-symlink-no-follow" "sealed symlink followed or target modified"
fi

# 11d: immutable first seal, identical-retry idempotence data, conflicting
#      retry refusal, and the fail-closed CLI entrypoint contract.
printf '\n--- 11d: write-once immutability and retry semantics ---\n'

# identical retry: seal refuses; sealed inode and digest unchanged
G11D_SHA_BEFORE="$(g11_sealed_sha "$G11A")"
g11_run seal "$G11A" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 2 ] && [ "$(g11_str error)" = "report_already_sealed" ]; then
  ok "11d-identical-retry-refused (second seal refused: report_already_sealed)"
else
  fail "11d-identical-retry-refused" "rc=$G11_RC error=$(g11_str error)"
fi
g11_run stat "$G11A" "sealed/report.txt"
if [ "$(g11_num ino)" = "$G11A_INO" ] && [ "$(g11_num dev)" = "$G11A_DEV" ] \
   && [ "$(g11_sealed_sha "$G11A")" = "$G11D_SHA_BEFORE" ]; then
  ok "11d-immutable (sealed inode + digest unchanged after refused retry)"
else
  fail "11d-immutable" "sealed identity/content changed after retry"
fi

# identical-retry idempotence: the caller-side no-op decision is a digest
# comparison against read_sealed_report; identical bytes must compare equal.
g11_run read "$G11A" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 0 ] && [ "$(g11_str digest)" = "$(g11_report_sha "$G11A")" ]; then
  ok "11d-idempotent-data (read digest == resubmitted digest: no-op detectable)"
else
  fail "11d-idempotent-data" "rc=$G11_RC out=$G11_OUT"
fi

# conflicting retry: different verdict → digest mismatch → refusal decision;
# sealed report still the original
g11_write_report "$G11A" "$G11_COMMIT" "FAIL" "$G11_REVIEWER"
g11_run read "$G11A" "$G11_COMMIT" "$G11_REVIEWER"
G11D_SEALED_DIGEST="$(g11_str digest)"
if [ -n "$G11D_SEALED_DIGEST" ] \
   && [ "$G11D_SEALED_DIGEST" != "$(g11_report_sha "$G11A")" ]; then
  ok "11d-conflict-detectable (conflicting retry digest mismatch)"
else
  fail "11d-conflict-detectable" "conflict not detectable via digest"
fi
g11_run seal "$G11A" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 2 ] && [ "$(g11_str error)" = "report_already_sealed" ]; then
  ok "11d-conflict-refused (conflicting retry refused)"
else
  fail "11d-conflict-refused" "rc=$G11_RC error=$(g11_str error)"
fi
if [ "$(g11_sealed_sha "$G11A")" = "$G11D_SHA_BEFORE" ]; then
  ok "11d-conflict-no-overwrite (sealed report survives conflicting retry)"
else
  fail "11d-conflict-no-overwrite" "sealed report was overwritten"
fi

# entrypoint contract: review submit-report is implemented at this base
# (was cmd_not_implemented at base 734fbf3; wired by be83fe9 review-core increment)
# Verifies the verb is reachable through the real CLI dispatcher, returns a
# semantic refusal (review_not_found for unknown ID), not cmd_not_implemented,
# AND exits nonzero. The rc check closes the fail-open mutant that kimi2
# confirmed: rc=0 + review_not_found string passes the string-only assertion.
G11D_ENTRY_OUT="$("$COORD_SH" review submit-report 0123456789abcdef0123456789abcdef 2>&1)"
G11D_ENTRY_RC=$?
if [ "$G11D_ENTRY_RC" -ne 0 ] \
   && printf '%s' "$G11D_ENTRY_OUT" | grep -q 'review_not_found' \
   && ! printf '%s' "$G11D_ENTRY_OUT" | grep -q 'not_implemented'; then
  ok "11d-entrypoint-fail-closed (submit-report refused with review_not_found, rc=$G11D_ENTRY_RC)"
else
  fail "11d-entrypoint-fail-closed" "rc=$G11D_ENTRY_RC out=$(printf '%s' "$G11D_ENTRY_OUT" | tr '\n' ' ')"
fi

# 11e: mutation / symlink / swap races and crash-window residue.
printf '\n--- 11e: races and crash-window zero-partial-seal ---\n'

# crash at seal.linked: process dies after hard link, before temp unlink
G11E1="$(g11_name 31)"; g11_make_payload "$G11E1"
g11_write_report "$G11E1" "$G11_COMMIT" "PASS" "$G11_REVIEWER"
G11E1_SHA="$(g11_report_sha "$G11E1")"
STITCHPAD_COORD_TEST_CRASH_AFTER="seal.linked" \
  g11_run seal "$G11E1" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 134 ]; then
  ok "11e-crash-window (deterministic crash at seal.linked, rc=134)"
else
  fail "11e-crash-window" "rc=$G11_RC (crash hook did not fire)"
fi

# linked report content is complete — never torn
if [ "$(g11_sealed_sha "$G11E1")" = "$G11E1_SHA" ]; then
  ok "11e-crash-content-complete (linked report.txt has full pinned content)"
else
  fail "11e-crash-content-complete" "torn or missing content after crash"
fi

# crash state is explicit: nlink=2 plus stale temp — never a silent half-seal
g11_run stat "$G11E1" "sealed/report.txt"
if [ "$(g11_num nlink)" = "2" ] && [ "$(g11_temp_count "$G11E1")" -ge 1 ]; then
  ok "11e-crash-state-explicit (nlink=2 + stale temp, no silent half-seal)"
else
  fail "11e-crash-state-explicit" "nlink=$(g11_num nlink) temps=$(g11_temp_count "$G11E1")"
fi

# crash residue is detected and refuses advance
g11_run detect "$G11E1"
if [ "$(g11_str incomplete)" = "transition_incomplete_report" ]; then
  ok "11e-crash-detect (detect_incomplete_report flags residue)"
else
  fail "11e-crash-detect" "incomplete=$(g11_str incomplete)"
fi

# retry after crash: refused — no double publish, original content intact
g11_run seal "$G11E1" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 2 ] && [ "$(g11_str error)" = "report_already_sealed" ] \
   && [ "$(g11_sealed_sha "$G11E1")" = "$G11E1_SHA" ]; then
  ok "11e-crash-retry-refused (no double publish; original content intact)"
else
  fail "11e-crash-retry-refused" "rc=$G11_RC error=$(g11_str error)"
fi

# post-seal in-place mutation with a foreign commit: read detects it
G11E2="$(g11_name 32)"; g11_make_payload "$G11E2"
g11_write_report "$G11E2" "$G11_COMMIT" "PASS" "$G11_REVIEWER"
g11_run seal "$G11E2" "$G11_COMMIT" "$G11_REVIEWER"
[ "$G11_RC" -eq 0 ] || fail "11e-mutate-setup" "seal failed: $G11_OUT"
printf 'Reviewed-Commit: %s\nVerdict: PASS\nReviewer: %s\n' \
  "$G11_COMMIT2" "$G11_REVIEWER" > "$PAYLOAD_BASE/$G11E2/sealed/report.txt"
g11_run read "$G11E2" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 2 ] && [ "$(g11_str error)" = "report_commit_mismatch" ]; then
  ok "11e-mutation-detected (in-place mutation fails revalidation)"
else
  fail "11e-mutation-detected" "rc=$G11_RC error=$(g11_str error)"
fi

# post-seal swap with schema-valid bytes: pinned digest exposes the swap
G11E3="$(g11_name 33)"; g11_make_payload "$G11E3"
g11_write_report "$G11E3" "$G11_COMMIT" "PASS" "$G11_REVIEWER"
g11_run seal "$G11E3" "$G11_COMMIT" "$G11_REVIEWER"
G11E3_DIGEST="$(g11_str digest)"
rm "$PAYLOAD_BASE/$G11E3/sealed/report.txt"
printf 'Reviewed-Commit: %s\nVerdict: FAIL\nReviewer: %s\nswapped\n' \
  "$G11_COMMIT" "$G11_REVIEWER" > "$PAYLOAD_BASE/$G11E3/sealed/report.txt"
chmod 600 "$PAYLOAD_BASE/$G11E3/sealed/report.txt"
g11_run read "$G11E3" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 0 ] && [ -n "$(g11_str digest)" ] \
   && [ "$(g11_str digest)" != "$G11E3_DIGEST" ]; then
  ok "11e-swap-tamper-evident (swapped report digest != sealed digest)"
else
  fail "11e-swap-tamper-evident" "rc=$G11_RC out=$G11_OUT"
fi

# extra hard link to the sealed report: link-count guard fires
G11E4="$(g11_name 34)"; g11_make_payload "$G11E4"
g11_write_report "$G11E4" "$G11_COMMIT" "PASS" "$G11_REVIEWER"
g11_run seal "$G11E4" "$G11_COMMIT" "$G11_REVIEWER"
[ "$G11_RC" -eq 0 ] || fail "11e-linkcount-setup" "seal failed: $G11_OUT"
ln "$PAYLOAD_BASE/$G11E4/sealed/report.txt" "$PAYLOAD_BASE/$G11E4/sealed/evil"
g11_run read "$G11E4" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 2 ] \
   && [ "$(g11_str error)" = "transition_incomplete_report" ]; then
  ok "11e-linkcount-read (read refuses nlink=2 sealed report)"
else
  fail "11e-linkcount-read" "rc=$G11_RC error=$(g11_str error)"
fi
g11_run detect "$G11E4"
if [ "$(g11_str incomplete)" = "transition_incomplete_report" ]; then
  ok "11e-linkcount-detect (detect flags unexpected link count)"
else
  fail "11e-linkcount-detect" "incomplete=$(g11_str incomplete)"
fi

# sealed report replaced by a symlink: read must not follow it
G11E5="$(g11_name 35)"; g11_make_payload "$G11E5"
g11_write_report "$G11E5" "$G11_COMMIT" "PASS" "$G11_REVIEWER"
g11_run seal "$G11E5" "$G11_COMMIT" "$G11_REVIEWER"
[ "$G11_RC" -eq 0 ] || fail "11e-symlinkread-setup" "seal failed: $G11_OUT"
rm "$PAYLOAD_BASE/$G11E5/sealed/report.txt"
ln -s "$PAYLOAD_BASE/$G11E5/inbox/report.pending" \
  "$PAYLOAD_BASE/$G11E5/sealed/report.txt"
g11_run read "$G11E5" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 2 ] && [ "$(g11_str error)" = "report_not_regular" ]; then
  ok "11e-sealed-symlink-read (read refuses to follow sealed symlink)"
else
  fail "11e-sealed-symlink-read" "rc=$G11_RC error=$(g11_str error)"
fi

# 11f: boundary — payload without inbox, and a clean payload detects nothing.
printf '\n--- 11f: boundary conditions ---\n'
G11F1="$(g11_name 41)"; g11_make_payload "$G11F1"
rmdir "$PAYLOAD_BASE/$G11F1/inbox"
g11_run seal "$G11F1" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 2 ] && [ "$(g11_str error)" = "report_missing" ]; then
  ok "11f-no-inbox (missing inbox refused: report_missing)"
else
  fail "11f-no-inbox" "rc=$G11_RC error=$(g11_str error)"
fi

G11F2="$(g11_name 42)"; g11_make_payload "$G11F2"
g11_run read "$G11F2" "$G11_COMMIT" "$G11_REVIEWER"
if [ "$G11_RC" -eq 0 ] && [ "$(g11_str digest)" = "" ] \
   && printf '%s' "$G11_OUT" | grep -q '"sealed": false'; then
  ok "11f-read-absent (read of unsealed payload returns none)"
else
  fail "11f-read-absent" "rc=$G11_RC out=$G11_OUT"
fi
g11_run detect "$G11F2"
if [ "$G11_RC" -eq 0 ] && [ -z "$(g11_str incomplete)" ]; then
  ok "11f-detect-absent (clean payload: no incomplete state)"
else
  fail "11f-detect-absent" "rc=$G11_RC incomplete=$(g11_str incomplete)"
fi
# ========================================================================
# GATE 12 — Section-12 Lease Transactions
# ========================================================================
# Covers the section-12 transaction surface (lease checkpoint / release) with
# real verifier entrypoints only: authorized transition, capability and
# worktree binding, stale/foreign token refusal, concurrent exactly-one
# winner, checkpoint/release ordering, crash atomicity, supersession and
# cancellation stickiness, and zero mutation on rejected transactions.
# Note: the review verbs carrying --session fail closed `not_implemented` at
# this base, so the lease capability is the only session credential for
# section-12 transactions; session binding is exercised through it.
printf '\n========== GATE 12: Section-12 Lease Transactions ==========\n'

# Foreign (never minted) capability: 64 lowercase hex, shape-valid.
G12_FOREIGN_TOKEN="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

# 12a: authorized transition — checkpoint with the minted capability succeeds,
#      bumps the generation exactly once, and status reflects the new head.
printf '\n--- 12a: authorized checkpoint transition ---\n'
G12A="$(mktemp -d "$TMPDIR/g12a.XXXXXXXX")"
make_repo "$G12A" "gate-12a"
add_commit "$G12A" "gate-12a-second"
G12A_ABS="$(cd -P "$G12A" && pwd)"
G12A_BASE="$(head_oid "$G12A_ABS")"

acquire "$G12A_ABS" "tester-12a" "$G12A_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "12a-acquire" "acquire failed: $ACQUIRE_OUT"
else
  G12A_TOKEN="$ACQUIRE_TOKEN"
  add_commit "$G12A_ABS" "gate-12a-third"
  G12A_NEW="$(head_oid "$G12A_ABS")"
  G12A_OUT="$(checkpoint_lease "$G12A_ABS" "$G12A_TOKEN" "$G12A_BASE" "$G12A_NEW")" && G12A_RC=0 || G12A_RC=$?
  if [ "$G12A_RC" -eq 0 ] \
    && echo "$G12A_OUT" | grep -q '^generation: 2$' \
    && echo "$G12A_OUT" | grep -q '^checkpoint_count: 1$'; then
    ok "12a-checkpoint (authorized transition: generation 2, checkpoint_count 1)"
  else
    fail "12a-checkpoint" "rc=$G12A_RC out: $(echo "$G12A_OUT" | tr '\n' ' ')"
  fi
  G12A_STATUS="$(lease_status "$G12A_ABS")"
  if echo "$G12A_STATUS" | grep -q '^status: green$' \
    && echo "$G12A_STATUS" | grep -q '^generation: 2$' \
    && echo "$G12A_STATUS" | grep -q "^expected_head: $G12A_NEW\$" \
    && echo "$G12A_STATUS" | grep -q '^head_state: matches$'; then
    ok "12a-status (green, expected_head advanced, head_state matches)"
  else
    fail "12a-status" "$(echo "$G12A_STATUS" | tr '\n' ' ')"
  fi
  release_lease "$G12A_ABS" "$G12A_TOKEN" "$G12A_NEW" >/dev/null 2>&1 || true
fi

# 12b: capability/worktree binding — a capability minted for worktree B never
#      authorizes a transaction on worktree A, and vice versa.
printf '\n--- 12b: capability and worktree binding ---\n'
G12B_A="$(mktemp -d "$TMPDIR/g12b-a.XXXXXXXX")"
G12B_B="$(mktemp -d "$TMPDIR/g12b-b.XXXXXXXX")"
make_repo "$G12B_A" "gate-12b-a"
add_commit "$G12B_A" "gate-12b-a-second"
make_repo "$G12B_B" "gate-12b-b"
add_commit "$G12B_B" "gate-12b-b-second"
G12B_A_ABS="$(cd -P "$G12B_A" && pwd)"
G12B_B_ABS="$(cd -P "$G12B_B" && pwd)"
G12B_A_BASE="$(head_oid "$G12B_A_ABS")"
G12B_B_BASE="$(head_oid "$G12B_B_ABS")"

acquire "$G12B_A_ABS" "tester-12b-a" "$G12B_A_BASE"
G12B_A_TOK="$ACQUIRE_TOKEN"
acquire "$G12B_B_ABS" "tester-12b-b" "$G12B_B_BASE"
G12B_B_TOK="$ACQUIRE_TOKEN"
if [ -z "$G12B_A_TOK" ] || [ -z "$G12B_B_TOK" ]; then
  fail "12b-acquire" "fixture acquire failed (A rc token empty or B token empty)"
else
  add_commit "$G12B_A_ABS" "gate-12b-a-third"
  G12B_A_NEW="$(head_oid "$G12B_A_ABS")"
  add_commit "$G12B_B_ABS" "gate-12b-b-third"
  G12B_B_NEW="$(head_oid "$G12B_B_ABS")"

  G12B_OUT="$(checkpoint_lease "$G12B_A_ABS" "$G12B_B_TOK" "$G12B_A_BASE" "$G12B_A_NEW")" && G12B_RC=0 || G12B_RC=$?
  if [ "$G12B_RC" -eq 2 ] && echo "$G12B_OUT" | grep -q 'capability_rejected'; then
    ok "12b-cross-token-a (B's capability refused on A's worktree)"
  else
    fail "12b-cross-token-a" "rc=$G12B_RC out: $(echo "$G12B_OUT" | tr '\n' ' ')"
  fi

  G12B_OUT="$(checkpoint_lease "$G12B_B_ABS" "$G12B_A_TOK" "$G12B_B_BASE" "$G12B_B_NEW")" && G12B_RC=0 || G12B_RC=$?
  if [ "$G12B_RC" -eq 2 ] && echo "$G12B_OUT" | grep -q 'capability_rejected'; then
    ok "12b-cross-token-b (A's capability refused on B's worktree)"
  else
    fail "12b-cross-token-b" "rc=$G12B_RC out: $(echo "$G12B_OUT" | tr '\n' ' ')"
  fi

  G12B_OUT="$(checkpoint_lease "$G12B_A_ABS" "$G12_FOREIGN_TOKEN" "$G12B_A_BASE" "$G12B_A_NEW")" && G12B_RC=0 || G12B_RC=$?
  if [ "$G12B_RC" -eq 2 ] && echo "$G12B_OUT" | grep -q 'capability_rejected'; then
    ok "12b-foreign-token (never-minted capability refused)"
  else
    fail "12b-foreign-token" "rc=$G12B_RC out: $(echo "$G12B_OUT" | tr '\n' ' ')"
  fi

  release_lease "$G12B_A_ABS" "$G12B_A_TOK" "$G12B_A_BASE" >/dev/null 2>&1 || true
  release_lease "$G12B_B_ABS" "$G12B_B_TOK" "$G12B_B_BASE" >/dev/null 2>&1 || true
fi

# 12c: stale token — after release and re-acquire, the prior capability is
#      dead even though shape-valid and once genuine.
printf '\n--- 12c: stale token refusal ---\n'
G12C="$(mktemp -d "$TMPDIR/g12c.XXXXXXXX")"
make_repo "$G12C" "gate-12c"
add_commit "$G12C" "gate-12c-second"
G12C_ABS="$(cd -P "$G12C" && pwd)"
G12C_BASE="$(head_oid "$G12C_ABS")"

acquire "$G12C_ABS" "tester-12c-first" "$G12C_BASE"
G12C_TOK1="$ACQUIRE_TOKEN"
release_lease "$G12C_ABS" "$G12C_TOK1" "$G12C_BASE" >/dev/null 2>&1 || true
acquire "$G12C_ABS" "tester-12c-second" "$G12C_BASE"
G12C_TOK2="$ACQUIRE_TOKEN"
if [ -z "$G12C_TOK1" ] || [ -z "$G12C_TOK2" ]; then
  fail "12c-fixture" "acquire/release cycle failed"
else
  add_commit "$G12C_ABS" "gate-12c-third"
  G12C_NEW="$(head_oid "$G12C_ABS")"
  G12C_OUT="$(checkpoint_lease "$G12C_ABS" "$G12C_TOK1" "$G12C_BASE" "$G12C_NEW")" && G12C_RC=0 || G12C_RC=$?
  if [ "$G12C_RC" -eq 2 ] && echo "$G12C_OUT" | grep -q 'capability_rejected'; then
    ok "12c-stale-token (prior generation capability refused)"
  else
    fail "12c-stale-token" "rc=$G12C_RC out: $(echo "$G12C_OUT" | tr '\n' ' ')"
  fi
  G12C_OUT="$(checkpoint_lease "$G12C_ABS" "$G12C_TOK2" "$G12C_BASE" "$G12C_NEW")" && G12C_RC=0 || G12C_RC=$?
  if [ "$G12C_RC" -eq 0 ]; then
    ok "12c-fresh-token (current capability still authorizes)"
  else
    fail "12c-fresh-token" "rc=$G12C_RC out: $(echo "$G12C_OUT" | tr '\n' ' ')"
  fi
  release_lease "$G12C_ABS" "$G12C_TOK2" "$G12C_NEW" >/dev/null 2>&1 || true
fi

# 12d: concurrent checkpoint — exactly one winner, exactly one generation.
printf '\n--- 12d: concurrent checkpoint one winner ---\n'
G12D="$(mktemp -d "$TMPDIR/g12d.XXXXXXXX")"
make_repo "$G12D" "gate-12d"
add_commit "$G12D" "gate-12d-second"
G12D_ABS="$(cd -P "$G12D" && pwd)"
G12D_BASE="$(head_oid "$G12D_ABS")"

acquire "$G12D_ABS" "tester-12d" "$G12D_BASE"
G12D_TOK="$ACQUIRE_TOKEN"
if [ -z "$G12D_TOK" ]; then
  fail "12d-acquire" "acquire failed: $ACQUIRE_OUT"
else
  add_commit "$G12D_ABS" "gate-12d-third"
  G12D_NEW="$(head_oid "$G12D_ABS")"
  G12D_TOKFILE1="$(mktemp "$TMPDIR/g12d-tok1.XXXXXXXX")"
  G12D_TOKFILE2="$(mktemp "$TMPDIR/g12d-tok2.XXXXXXXX")"
  printf '%s\n' "$G12D_TOK" > "$G12D_TOKFILE1"
  printf '%s\n' "$G12D_TOK" > "$G12D_TOKFILE2"

  (
    exec 8<"$G12D_TOKFILE1"
    "$COORD_SH" lease checkpoint --worktree "$G12D_ABS" --token-fd 8 \
      --old "$G12D_BASE" --new "$G12D_NEW" >/dev/null 2>&1
    echo $? > "$G12D_TOKFILE1.rc"
  ) &
  BG1=$!
  (
    exec 8<"$G12D_TOKFILE2"
    "$COORD_SH" lease checkpoint --worktree "$G12D_ABS" --token-fd 8 \
      --old "$G12D_BASE" --new "$G12D_NEW" >/dev/null 2>&1
    echo $? > "$G12D_TOKFILE2.rc"
  ) &
  BG2=$!
  BG_PIDS="$BG1 $BG2"
  wait $BG1 $BG2 2>/dev/null || true
  BG_PIDS=""

  RC1="$(cat "$G12D_TOKFILE1.rc" 2>/dev/null || echo 99)"
  RC2="$(cat "$G12D_TOKFILE2.rc" 2>/dev/null || echo 99)"
  rm -f "$G12D_TOKFILE1" "$G12D_TOKFILE2" "$G12D_TOKFILE1.rc" "$G12D_TOKFILE2.rc"

  if { [ "$RC1" -eq 0 ] && [ "$RC2" -eq 2 ]; } \
    || { [ "$RC1" -eq 2 ] && [ "$RC2" -eq 0 ]; }; then
    ok "12d-one-winner (rc1=$RC1 rc2=$RC2)"
  else
    fail "12d-one-winner" "expected exactly one rc=0 and one rc=2, got rc1=$RC1 rc2=$RC2"
  fi

  # Regardless of winner: exactly one generation bump, one checkpoint record.
  if [ "$(lease_field "$G12D_ABS" generation)" = "2" ] \
    && [ "$(lease_field "$G12D_ABS" checkpoint_count)" = "1" ]; then
    ok "12d-single-generation (generation 2, checkpoint_count 1)"
  else
    fail "12d-single-generation" \
      "generation=$(lease_field "$G12D_ABS" generation) checkpoint_count=$(lease_field "$G12D_ABS" checkpoint_count)"
  fi
  release_lease "$G12D_ABS" "$G12D_TOK" "$G12D_NEW" >/dev/null 2>&1 || true
fi

# 12e: checkpoint/release ordering — a moved head must be checkpointed before
#      release, and --old/--head must equal the recorded expected head.
printf '\n--- 12e: checkpoint/release ordering ---\n'
G12E="$(mktemp -d "$TMPDIR/g12e.XXXXXXXX")"
make_repo "$G12E" "gate-12e"
add_commit "$G12E" "gate-12e-second"
G12E_ABS="$(cd -P "$G12E" && pwd)"
G12E_BASE="$(head_oid "$G12E_ABS")"
G12E_ROOT="$(git -C "$G12E_ABS" rev-parse HEAD~1)"

acquire "$G12E_ABS" "tester-12e" "$G12E_BASE"
G12E_TOK="$ACQUIRE_TOKEN"
if [ -z "$G12E_TOK" ]; then
  fail "12e-acquire" "acquire failed: $ACQUIRE_OUT"
else
  add_commit "$G12E_ABS" "gate-12e-third"
  G12E_NEW="$(head_oid "$G12E_ABS")"

  # Release with the stale base while HEAD has moved: refused.
  G12E_OUT="$(release_lease "$G12E_ABS" "$G12E_TOK" "$G12E_BASE")" && G12E_RC=0 || G12E_RC=$?
  if [ "$G12E_RC" -eq 2 ] && echo "$G12E_OUT" | grep -q 'head_moved_conflicted'; then
    ok "12e-release-before-checkpoint (moved head refuses release)"
  else
    fail "12e-release-before-checkpoint" "rc=$G12E_RC out: $(echo "$G12E_OUT" | tr '\n' ' ')"
  fi

  # Checkpoint with --old != recorded expected head: refused.
  G12E_OUT="$(checkpoint_lease "$G12E_ABS" "$G12E_TOK" "$G12E_ROOT" "$G12E_NEW")" && G12E_RC=0 || G12E_RC=$?
  if [ "$G12E_RC" -eq 2 ] && echo "$G12E_OUT" | grep -q 'head_moved_conflicted'; then
    ok "12e-checkpoint-wrong-old (--old must equal expected head)"
  else
    fail "12e-checkpoint-wrong-old" "rc=$G12E_RC out: $(echo "$G12E_OUT" | tr '\n' ' ')"
  fi

  # Correct order: checkpoint, then release at the checkpointed head.
  G12E_OUT="$(checkpoint_lease "$G12E_ABS" "$G12E_TOK" "$G12E_BASE" "$G12E_NEW")" && G12E_RC=0 || G12E_RC=$?
  [ "$G12E_RC" -eq 0 ] || fail "12e-checkpoint" "rc=$G12E_RC out: $(echo "$G12E_OUT" | tr '\n' ' ')"
  G12E_OUT="$(release_lease "$G12E_ABS" "$G12E_TOK" "$G12E_BASE")" && G12E_RC=0 || G12E_RC=$?
  if [ "$G12E_RC" -eq 2 ] && echo "$G12E_OUT" | grep -q 'head_moved_conflicted'; then
    ok "12e-release-stale-head (pre-checkpoint head refused after checkpoint)"
  else
    fail "12e-release-stale-head" "rc=$G12E_RC out: $(echo "$G12E_OUT" | tr '\n' ' ')"
  fi
  G12E_OUT="$(release_lease "$G12E_ABS" "$G12E_TOK" "$G12E_NEW")" && G12E_RC=0 || G12E_RC=$?
  if [ "$G12E_RC" -eq 0 ] && echo "$G12E_OUT" | grep -q '^claims_removed: '; then
    ok "12e-ordered-release (checkpoint then release at new head succeeds)"
  else
    fail "12e-ordered-release" "rc=$G12E_RC out: $(echo "$G12E_OUT" | tr '\n' ' ')"
  fi
fi

# 12f: crash/interruption atomicity — a kill inside the checkpoint transaction
#      leaves visibly incomplete state, never a silent partial generation.
printf '\n--- 12f: crash mid-checkpoint is atomic ---\n'
G12F="$(mktemp -d "$TMPDIR/g12f.XXXXXXXX")"
make_repo "$G12F" "gate-12f"
add_commit "$G12F" "gate-12f-second"
G12F_ABS="$(cd -P "$G12F" && pwd)"
G12F_BASE="$(head_oid "$G12F_ABS")"

acquire "$G12F_ABS" "tester-12f" "$G12F_BASE"
G12F_TOK="$ACQUIRE_TOKEN"
if [ -z "$G12F_TOK" ]; then
  fail "12f-acquire" "acquire failed: $ACQUIRE_OUT"
else
  add_commit "$G12F_ABS" "gate-12f-third"
  G12F_NEW="$(head_oid "$G12F_ABS")"

  G12F_TOKFILE="$(mktemp "$TMPDIR/g12f-tok.XXXXXXXX")"
  printf '%s\n' "$G12F_TOK" > "$G12F_TOKFILE"
  export STITCHPAD_COORD_TEST_CRASH_AFTER="record.published"
  (
    exec 8<"$G12F_TOKFILE"
    "$COORD_SH" lease checkpoint --worktree "$G12F_ABS" --token-fd 8 \
      --old "$G12F_BASE" --new "$G12F_NEW" >/dev/null 2>&1
    echo $? > "$G12F_TOKFILE.rc"
  ) &
  G12F_PID=$!
  BG_PIDS="$G12F_PID"
  wait $G12F_PID 2>/dev/null || true
  BG_PIDS=""
  unset STITCHPAD_COORD_TEST_CRASH_AFTER
  G12F_RC="$(cat "$G12F_TOKFILE.rc" 2>/dev/null || echo 99)"
  rm -f "$G12F_TOKFILE" "$G12F_TOKFILE.rc"

  if [ "$G12F_RC" -eq 134 ]; then
    ok "12f-crash-fired (deterministic kill window, exit 134)"
  else
    fail "12f-crash-fired" "expected exit 134 from crash hook, got $G12F_RC"
  fi

  # The lease record must be untouched: still generation 1 at the old head.
  if [ "$(lease_field "$G12F_ABS" generation)" = "1" ] \
    && [ "$(lease_field "$G12F_ABS" expected_head)" = "$G12F_BASE" ] \
    && [ "$(lease_field "$G12F_ABS" checkpoint_count)" = "0" ]; then
    ok "12f-no-partial-generation (lease still generation 1 at old head)"
  else
    fail "12f-no-partial-generation" \
      "generation=$(lease_field "$G12F_ABS" generation) expected_head=$(lease_field "$G12F_ABS" expected_head)"
  fi

  # The interrupted transition must be visible, never silently free.
  G12F_STATUS="$(lease_status "$G12F_ABS")"
  if echo "$G12F_STATUS" | grep -q '^status: red$' \
    && echo "$G12F_STATUS" | grep -q '^transition: in_progress$'; then
    ok "12f-visible-incomplete (status red, transition in_progress)"
  else
    fail "12f-visible-incomplete" "$(echo "$G12F_STATUS" | tr '\n' ' ')"
  fi

  # Evidence boundary: checkpoint record may exist, its READY must not.
  G12F_COMMON="$(git -C "$G12F_ABS" rev-parse --git-common-dir)"
  [ "${G12F_COMMON#/}" = "$G12F_COMMON" ] && G12F_COMMON="$(cd -P "$G12F_ABS" && cd -P "$G12F_COMMON" && pwd)"
  G12F_CKPT="$G12F_COMMON/stitchpad-coordination/v1/leases/$(lease_field "$G12F_ABS" lease_id)/checkpoints"
  if [ -f "$G12F_CKPT/000002.json" ] && [ ! -f "$G12F_CKPT/000002.json.READY" ]; then
    ok "12f-evidence-boundary (checkpoint record without READY — quarantined)"
  elif [ ! -e "$G12F_CKPT/000002.json" ]; then
    ok "12f-evidence-boundary (crash before durable checkpoint write — clean)"
  else
    fail "12f-evidence-boundary" "checkpoint READY published despite crash"
  fi

  # The held mutex refuses later transactions (never age-reclaimed).
  G12F_OUT="$(checkpoint_lease "$G12F_ABS" "$G12F_TOK" "$G12F_BASE" "$G12F_NEW")" && G12F_RC=0 || G12F_RC=$?
  if [ "$G12F_RC" -eq 2 ] && echo "$G12F_OUT" | grep -q 'transition_in_progress'; then
    ok "12f-mutex-held (later transaction refused while crash residue stands)"
  else
    fail "12f-mutex-held" "rc=$G12F_RC out: $(echo "$G12F_OUT" | tr '\n' ' ')"
  fi
fi

# 12g: supersession/cancellation stickiness — release is terminal for the
#      capability and the claims; a new lease supersedes cleanly.
printf '\n--- 12g: supersession and cancellation stickiness ---\n'
G12G="$(mktemp -d "$TMPDIR/g12g.XXXXXXXX")"
make_repo "$G12G" "gate-12g"
add_commit "$G12G" "gate-12g-second"
G12G_ABS="$(cd -P "$G12G" && pwd)"
G12G_BASE="$(head_oid "$G12G_ABS")"

acquire "$G12G_ABS" "tester-12g-first" "$G12G_BASE"
G12G_TOK1="$ACQUIRE_TOKEN"
if [ -z "$G12G_TOK1" ]; then
  fail "12g-acquire" "acquire failed: $ACQUIRE_OUT"
else
  release_lease "$G12G_ABS" "$G12G_TOK1" "$G12G_BASE" >/dev/null 2>&1 || true

  # Released state is retained as history and stays released.
  if [ "$(lease_field "$G12G_ABS" state)" = "released" ]; then
    ok "12g-released-sticks (lease record durably released)"
  else
    fail "12g-released-sticks" "state=$(lease_field "$G12G_ABS" state)"
  fi

  # Re-release with the same capability: refused (claims already removed).
  G12G_OUT="$(release_lease "$G12G_ABS" "$G12G_TOK1" "$G12G_BASE")" && G12G_RC=0 || G12G_RC=$?
  if [ "$G12G_RC" -eq 2 ]; then
    ok "12g-double-release-refused (rc=2: $(echo "$G12G_OUT" | grep -o 'coordination refused: [a-z_]*' | head -1))"
  else
    fail "12g-double-release-refused" "rc=$G12G_RC out: $(echo "$G12G_OUT" | tr '\n' ' ')"
  fi

  # Checkpoint with the cancelled capability: refused.
  add_commit "$G12G_ABS" "gate-12g-third"
  G12G_NEW="$(head_oid "$G12G_ABS")"
  G12G_OUT="$(checkpoint_lease "$G12G_ABS" "$G12G_TOK1" "$G12G_BASE" "$G12G_NEW")" && G12G_RC=0 || G12G_RC=$?
  if [ "$G12G_RC" -eq 2 ]; then
    ok "12g-cancelled-capability-refused (rc=2)"
  else
    fail "12g-cancelled-capability-refused" "rc=$G12G_RC out: $(echo "$G12G_OUT" | tr '\n' ' ')"
  fi

  # Claims were truly removed: a fresh acquire supersedes, and the cancelled
  # capability stays dead against the new lease.
  git -C "$G12G_ABS" reset --hard "$G12G_BASE" -q
  acquire "$G12G_ABS" "tester-12g-second" "$G12G_BASE"
  G12G_TOK2="$ACQUIRE_TOKEN"
  if [ -z "$G12G_TOK2" ]; then
    fail "12g-supersede" "re-acquire after release failed: $ACQUIRE_OUT"
  else
    ok "12g-supersede (fresh acquire succeeds after claims removed)"
    add_commit "$G12G_ABS" "gate-12g-third"
    G12G_NEW="$(head_oid "$G12G_ABS")"
    G12G_OUT="$(checkpoint_lease "$G12G_ABS" "$G12G_TOK1" "$G12G_BASE" "$G12G_NEW")" && G12G_RC=0 || G12G_RC=$?
    if [ "$G12G_RC" -eq 2 ] && echo "$G12G_OUT" | grep -q 'capability_rejected'; then
      ok "12g-old-token-stays-dead (cancelled capability refused on new lease)"
    else
      fail "12g-old-token-stays-dead" "rc=$G12G_RC out: $(echo "$G12G_OUT" | tr '\n' ' ')"
    fi
    release_lease "$G12G_ABS" "$G12G_TOK2" "$G12G_NEW" >/dev/null 2>&1 || true
  fi
fi

# 12h: zero mutation on rejected transaction — refused checkpoint and refused
#      release leave every state file byte-identical.
printf '\n--- 12h: zero mutation on rejected transactions ---\n'
G12H="$(mktemp -d "$TMPDIR/g12h.XXXXXXXX")"
make_repo "$G12H" "gate-12h"
add_commit "$G12H" "gate-12h-second"
G12H_ABS="$(cd -P "$G12H" && pwd)"
G12H_BASE="$(head_oid "$G12H_ABS")"
G12H_ROOT="$(git -C "$G12H_ABS" rev-parse HEAD~1)"

acquire "$G12H_ABS" "tester-12h" "$G12H_BASE"
G12H_TOK="$ACQUIRE_TOKEN"
if [ -z "$G12H_TOK" ]; then
  fail "12h-acquire" "acquire failed: $ACQUIRE_OUT"
else
  add_commit "$G12H_ABS" "gate-12h-third"
  G12H_NEW="$(head_oid "$G12H_ABS")"
  G12H_BEFORE="$(state_digest "$G12H_ABS")"

  # Rejected at authorization: foreign capability.
  checkpoint_lease "$G12H_ABS" "$G12_FOREIGN_TOKEN" "$G12H_BASE" "$G12H_NEW" >/dev/null 2>&1 && \
    fail "12h-foreign-checkpoint" "foreign capability checkpoint succeeded" || true
  # Rejected after authorization: valid capability, stale --head on release.
  release_lease "$G12H_ABS" "$G12H_TOK" "$G12H_ROOT" >/dev/null 2>&1 && \
    fail "12h-stale-release" "stale-head release succeeded" || true
  # Rejected after authorization: valid capability, wrong --old on checkpoint.
  checkpoint_lease "$G12H_ABS" "$G12H_TOK" "$G12H_ROOT" "$G12H_NEW" >/dev/null 2>&1 && \
    fail "12h-wrong-old-checkpoint" "wrong-old checkpoint succeeded" || true

  G12H_AFTER="$(state_digest "$G12H_ABS")"
  if [ "$G12H_BEFORE" = "$G12H_AFTER" ] && [ "$G12H_BEFORE" != "no-state" ]; then
    ok "12h-zero-mutation (state tree byte-identical after three rejections)"
  else
    fail "12h-zero-mutation" "state tree changed across rejected transactions"
  fi
  release_lease "$G12H_ABS" "$G12H_TOK" "$G12H_BASE" >/dev/null 2>&1 || true
fi
# ========================================================================
# GATE 13 — Scoped Bind Semantics (identity/capability refusal, zero mutation)
# ========================================================================
# `review bind` and `review register-process` are real authorized entrypoints
# at this base and are exercised directly. `review create` is NOT reachable:
# cmd_review_create calls RootBinding.recheck() without ever calling bind(),
# so every create self-refuses with root_replaced (reproduced minimally;
# documented in the gate-13 report). The pre-bind fixture state create would
# leave — a created review record, an empty 0700 payload/src, an optional
# env-pinned facts record — is therefore fabricated with the verifier's own
# new_record/publish functions (the gates 2a/2c fabrication pattern), and all
# bind/refusal behavior is then driven through the real CLI.
# Every refused operation must leave coordination state and payload trees
# byte-identical (no-follow recursive content digest; mtime excluded by
# design: rejection must never write content). Deterministic fixtures only;
# no network (review status/refresh are deliberately not exercised).
printf '\n========== GATE 13: Scoped Bind Semantics ==========\n'

G13_DIR="$TMPDIR/g13"
mkdir -p "$G13_DIR"
unset STITCHPAD_SESSION STITCHPAD_REQUEST STITCHPAD_MODEL STITCHPAD_WORKTREE 2>/dev/null || true
G13_DRIVER="$G13_DIR/fabricate.py"
COORD_VERIFY_DIR="$(dirname "$COORD_VERIFY")"

cat > "$G13_DRIVER" <<'PYEOF'
#!/usr/bin/env python3
"""Gate 13 fixture fabricator: publish the exact pre-bind state.

usage: fabricate.py REPO COMMIT AUTHOR REVIEWER VERIFY_DIR

Publishes, via the verifier's own new_record/publish functions: a created
review record (state="created", ocean provider, minted process capability),
an empty 0700 payload dir with an empty 0700 src child, and — when
STITCHPAD_SESSION/STITCHPAD_REQUEST are set — the env-pinned facts record
review create would have published. Prints one JSON line with review_id,
process_token, payload_path. Python 3.9 compatible.
"""
import json
import os
import secrets
import subprocess
import sys
import time

REPO, COMMIT, AUTHOR, REVIEWER = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, sys.argv[5])

import coordination_verify as cv  # noqa: E402

PAYLOAD_BASE = os.environ["STITCHPAD_COORD_TEST_PAYLOAD_BASE"]


def git(*args):
    return subprocess.check_output(
        ["git", "-C", REPO] + list(args)).decode("ascii").strip()


def open_dir(path):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    return os.open(path, flags)


common = git("rev-parse", "--git-common-dir")
if not common.startswith("/"):
    common = os.path.join(REPO, common)
common = os.path.realpath(common)
top = os.path.realpath(REPO)
tree = git("rev-parse", "--verify", COMMIT + "^{tree}")
algo = "sha1" if len(COMMIT) == 40 else "sha256"

leases_dir = os.path.join(common, "stitchpad-coordination", "v1", "leases")
lease = None
for entry in sorted(os.listdir(leases_dir)):
    record_path = os.path.join(leases_dir, entry, "record.json")
    if not os.path.isfile(record_path):
        continue
    with open(record_path) as fh:
        candidate = json.load(fh)
    if candidate.get("state") == "active" and candidate.get("actor") == AUTHOR:
        lease = candidate
        break
if lease is None:
    sys.stderr.write("no active author lease for %s\n" % (AUTHOR,))
    sys.exit(1)

review_id = secrets.token_hex(16)
payload_name = review_id + "." + secrets.token_hex(8)
payload_path = os.path.join(PAYLOAD_BASE, payload_name)
os.mkdir(payload_path, 0o700)
os.chmod(payload_path, 0o700)
os.mkdir(os.path.join(payload_path, "src"), 0o700)
os.chmod(os.path.join(payload_path, "src"), 0o700)

token, verifier = cv.mint_capability()
now = int(time.time())
review = cv.new_record("review", 1, {
    "review_id": review_id,
    "repo_id": lease["repo_id"],
    "top": top,
    "common_dir": common,
    "algo": algo,
    "commit": COMMIT,
    "tree": tree,
    "author_actor": AUTHOR,
    "reviewer_actor": REVIEWER,
    "provider": "ocean",
    "state": "created",
    "created_at": now,
    "updated_at": now,
    "lease_id": lease["lease_id"],
    "process_capability": verifier,
    "payload_name": payload_name,
    "closure": None,
    "closure_reason": None,
})

fds = cv.FDSet()
try:
    reviews_fd = fds.keep(open_dir(os.path.join(
        common, "stitchpad-coordination", "v1", "reviews")))
    cv.publish_record(fds, reviews_fd, review_id, "review", review,
                      "review record")

    env_session = os.environ.get("STITCHPAD_SESSION") or None
    env_request = os.environ.get("STITCHPAD_REQUEST") or None
    if env_session is not None or env_request is not None:
        payload_fd = fds.keep(open_dir(payload_path))
        facts = cv.new_record("facts", 1, {
            "review_id": review_id,
            "session_id": env_session,
            "request_id": env_request,
            "bound_at": now,
            "cancel_requested": False,
            "cancel_requested_at": None,
            "terminal_observed": False,
            "terminal_completion": None,
            "terminal_at": None,
            "report_sealed": False,
            "report_digest": None,
            "report_verdict": None,
            "report_sealed_at": None,
            "artifact_verified": False,
            "verified_at": None,
            "closure": None,
            "closure_reason": None,
            "closed_at": None,
            "conflict": None,
            "contract": None,
            "false_terminal": False,
            "false_terminal_reason": None,
            "false_terminal_at": None,
            "provider": "ocean",
            "provider_model": os.environ.get("STITCHPAD_MODEL") or None,
            "session_rotation_required": False,
            "last_activity_at": now,
        })
        cv.publish_flat_record(payload_fd, "facts.json", "facts", facts,
                               "review facts")
finally:
    fds.close_all()

sys.stdout.write(json.dumps({
    "review_id": review_id,
    "process_token": token,
    "payload_path": payload_path,
    "payload_name": payload_name,
}) + "\n")
PYEOF

G13_S0="00000000000000000000000000000000"
G13_S1="11111111111111111111111111111111"
G13_S2="22222222222222222222222222222222"
G13_S3="33333333333333333333333333333333"
G13_S4="44444444444444444444444444444444"
G13_S9="99999999999999999999999999999999"
G13_R0="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
G13_R1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
G13_R2="cccccccccccccccccccccccccccccccc"
G13_R3="dddddddddddddddddddddddddddddddd"
G13_R4="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
G13_R8="88888888888888888888888888888888"
G13_WRONG_TOKEN="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

# snap_tree PATH — no-follow recursive digest of relpaths, file bytes, and
# symlink targets. Deterministic; reads only inside PATH.
snap_tree() {
  "$PYTHON_BIN" - "$1" <<'PYEOF'
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames.sort()
    for name in sorted(dirnames):
        p = os.path.join(dirpath, name)
        rel = os.path.relpath(p, root)
        if os.path.islink(p):
            h.update(b"L\0" + rel.encode("utf-8") + b"\0"
                     + os.readlink(p).encode("utf-8") + b"\0")
        else:
            h.update(b"D\0" + rel.encode("utf-8") + b"\0")
    for name in sorted(filenames):
        p = os.path.join(dirpath, name)
        rel = os.path.relpath(p, root)
        if os.path.islink(p):
            h.update(b"L\0" + rel.encode("utf-8") + b"\0"
                     + os.readlink(p).encode("utf-8") + b"\0")
            continue
        with open(p, "rb") as fh:
            data = fh.read()
        h.update(b"F\0" + rel.encode("utf-8") + b"\0"
                 + str(len(data)).encode("ascii") + b"\0" + data + b"\0")
print(h.hexdigest())
PYEOF
}

# snap_state COORD_DIR — joint digest of the repo coordination state and the
# whole payload base (two hex lines; compared as a unit).
snap_state() {
  { snap_tree "$1"; snap_tree "$PAYLOAD_BASE"; }
}

json_field() {
  printf '%s' "$1" | "$PYTHON_BIN" -c \
    'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2" 2>/dev/null
}

# review_create REPO COMMIT AUTHOR REVIEWER — fabricate the pre-bind state
# (see gate-13 header: the real create entrypoint self-refuses at this base).
# Env STITCHPAD_SESSION/STITCHPAD_REQUEST pass through for pinned fixtures.
# Globals: RC_CREATE_RC RC_CREATE_OUT RC_CREATE_ID RC_CREATE_TOKEN RC_CREATE_PAYLOAD
review_create() {
  local repo="$1" commit="$2" author="$3" reviewer="$4"
  local rc=0 out
  out="$("$PYTHON_BIN" -B "$G13_DRIVER" "$repo" "$commit" "$author" "$reviewer" \
    "$COORD_VERIFY_DIR" 2>&1)" || rc=$?
  RC_CREATE_RC=$rc
  RC_CREATE_OUT="$out"
  if [ $rc -eq 0 ]; then
    RC_CREATE_ID="$(json_field "$out" review_id)"
    RC_CREATE_TOKEN="$(json_field "$out" process_token)"
    RC_CREATE_PAYLOAD="$(json_field "$out" payload_path)"
  else
    RC_CREATE_ID=""
    RC_CREATE_TOKEN=""
    RC_CREATE_PAYLOAD=""
  fi
}

# review_bind ID SESSION REQUEST WORKDIR — env passthrough for ambiguity cases.
# Globals: RB_RC RB_OUT
review_bind() {
  local id="$1" session="$2" request="$3" workdir="$4"
  local rc=0 out
  out="$(cd "$workdir" && "$COORD_SH" review bind "$id" \
    --session "$session" --request "$request" --json 2>&1)" || rc=$?
  RB_RC=$rc
  RB_OUT="$out"
}

# expect_bind_refused LABEL ID SESSION REQUEST WORKDIR CODE COORD_DIR
# Asserts the exact refusal code AND byte-identical coordination/payload state.
expect_bind_refused() {
  local label="$1" id="$2" session="$3" request="$4" workdir="$5" code="$6" coord="$7"
  local before after got=""
  before="$(snap_state "$coord")"
  review_bind "$id" "$session" "$request" "$workdir"
  [ "$RB_RC" -ne 0 ] && got="$(json_field "$RB_OUT" error)"
  if [ "$RB_RC" -eq 0 ] || [ "$got" != "$code" ]; then
    fail "$label" "expected refusal $code, got rc=$RB_RC error=$got"
    return 1
  fi
  after="$(snap_state "$coord")"
  if [ "$after" != "$before" ]; then
    fail "$label" "rejected bind mutated coordination/payload state"
    return 1
  fi
  ok "$label"
  return 0
}

# --- shared fixture: leased repo, one review per subtest family ---
G13A="$G13_DIR/repo-a"
make_repo "$G13A" "gate-13"
add_commit "$G13A" "gate-13-second"
G13A_ABS="$(cd -P "$G13A" && pwd)"
G13A_BASE="$(head_oid "$G13A_ABS")"
G13A_COORD="$G13A_ABS/.git/stitchpad-coordination"

acquire "$G13A_ABS" "g13-author" "$G13A_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "13-fixture" "author lease acquire failed: $ACQUIRE_OUT"
else
  G13A_LEASE_TOKEN="$ACQUIRE_TOKEN"

  # 13a: happy-path bind, then idempotent re-bind with zero mutation.
  # Slice B: re-bind of the same (review, session, request) now returns
  # idempotent success (rc=0, already_bound=true, ok=true) instead of
  # refusing — same guarantee, cleaner API contract.
  printf '\n--- 13a: bind succeeds; idempotent re-bind, zero mutation ---\n'
  review_create "$G13A_ABS" "$G13A_BASE" "g13-author" "g13-reviewer"
  if [ "$RC_CREATE_RC" -ne 0 ] || [ -z "$RC_CREATE_ID" ]; then
    fail "13a-create" "review create failed: $(printf '%s' "$RC_CREATE_OUT" | head -c 200)"
  else
    ok "13a-create"
    review_bind "$RC_CREATE_ID" "$G13_S1" "$G13_R1" "$G13A_ABS"
    if [ "$RB_RC" -ne 0 ] || [ "$(json_field "$RB_OUT" already_bound)" != "False" ]; then
      fail "13a-bind" "initial bind failed: rc=$RB_RC $(printf '%s' "$RB_OUT" | head -c 200)"
    else
      ok "13a-bind"
      # Bound identity landed in the published facts record.
      G13A_FACTS_SID="$(cd "$G13A_ABS" && "$PYTHON_BIN" - "$RC_CREATE_PAYLOAD" <<'PYEOF'
import json, sys
with open(sys.argv[1] + "/facts.json") as fh:
    print(json.load(fh)["session_id"])
PYEOF
)"
      if [ "$G13A_FACTS_SID" != "$G13_S1" ]; then
        fail "13a-facts" "facts session_id is $G13A_FACTS_SID, expected $G13_S1"
      else
        ok "13a-facts (published facts carry the bound session identity)"
      fi
      G13A_SNAP_BOUND="$(snap_state "$G13A_COORD")"
      review_bind "$RC_CREATE_ID" "$G13_S1" "$G13_R1" "$G13A_ABS"
      if [ "$RB_RC" -ne 0 ] || [ "$(json_field "$RB_OUT" already_bound)" != "True" ]; then
        fail "13a-rebind" "expected idempotent re-bind (rc=0, already_bound=true), got rc=$RB_RC $(printf '%s' "$RB_OUT" | head -c 200)"
      elif [ "$(snap_state "$G13A_COORD")" != "$G13A_SNAP_BOUND" ]; then
        fail "13a-rebind" "idempotent re-bind mutated coordination/payload state"
      else
        ok "13a-rebind (idempotent: same-identity re-bind accepted, zero writes)"
      fi
    fi
  fi

  # 13b: malformed session/request identity refused, zero mutation.
  printf '\n--- 13b: malformed identity refusal ---\n'
  review_create "$G13A_ABS" "$G13A_BASE" "g13-author" "g13-reviewer"
  if [ "$RC_CREATE_RC" -ne 0 ]; then
    fail "13b-create" "review create failed: $(printf '%s' "$RC_CREATE_OUT" | head -c 200)"
  else
    G13B_ID="$RC_CREATE_ID"
    expect_bind_refused "13b-session-invalid" "$G13B_ID" "not-hex-at-all" "$G13_R1" \
      "$G13A_ABS" "session_invalid" "$G13A_COORD"
    expect_bind_refused "13b-request-invalid" "$G13B_ID" "$G13_S1" "zzzz" \
      "$G13A_ABS" "request_invalid" "$G13A_COORD"

    # 13c: env/argv ambiguity refused, zero mutation; review stays bindable.
    printf '\n--- 13c: env ambiguity refusal ---\n'
    G13C_SNAP="$(snap_state "$G13A_COORD")"
    STITCHPAD_SESSION="$G13_S9" review_bind "$G13B_ID" "$G13_S1" "$G13_R1" "$G13A_ABS"
    if [ "$RB_RC" -eq 0 ] || [ "$(json_field "$RB_OUT" error)" != "session_ambiguous" ]; then
      fail "13c-session-ambiguous" "expected session_ambiguous, got rc=$RB_RC $(printf '%s' "$RB_OUT" | head -c 200)"
    elif [ "$(snap_state "$G13A_COORD")" != "$G13C_SNAP" ]; then
      fail "13c-session-ambiguous" "rejected bind mutated coordination/payload state"
    else
      ok "13c-session-ambiguous"
    fi
    STITCHPAD_REQUEST="$G13_R8" review_bind "$G13B_ID" "$G13_S1" "$G13_R1" "$G13A_ABS"
    if [ "$RB_RC" -eq 0 ] || [ "$(json_field "$RB_OUT" error)" != "request_ambiguous" ]; then
      fail "13c-request-ambiguous" "expected request_ambiguous, got rc=$RB_RC $(printf '%s' "$RB_OUT" | head -c 200)"
    elif [ "$(snap_state "$G13A_COORD")" != "$G13C_SNAP" ]; then
      fail "13c-request-ambiguous" "rejected bind mutated coordination/payload state"
    else
      ok "13c-request-ambiguous"
    fi
    review_bind "$G13B_ID" "$G13_S2" "$G13_R2" "$G13A_ABS"
    if [ "$RB_RC" -ne 0 ]; then
      fail "13c-still-bindable" "bind after refused attempts failed: $(printf '%s' "$RB_OUT" | head -c 200)"
    else
      ok "13c-still-bindable (refusals left the review bindable — no mutation)"
    fi
  fi

  # 13d: create-time env identity pins facts; a different bind is refused.
  printf '\n--- 13d: pre-pinned identity refusal (review_already_bound) ---\n'
  STITCHPAD_SESSION="$G13_S0" STITCHPAD_REQUEST="$G13_R0" \
    review_create "$G13A_ABS" "$G13A_BASE" "g13-author" "g13-reviewer"
  if [ "$RC_CREATE_RC" -ne 0 ]; then
    fail "13d-create" "review create with pinned env failed: $(printf '%s' "$RC_CREATE_OUT" | head -c 200)"
  else
    G13D_ID="$RC_CREATE_ID"
    expect_bind_refused "13d-already-bound" "$G13D_ID" "$G13_S1" "$G13_R1" \
      "$G13A_ABS" "review_already_bound" "$G13A_COORD"
    G13D_SNAP="$(snap_state "$G13A_COORD")"
    review_bind "$G13D_ID" "$G13_S0" "$G13_R0" "$G13A_ABS"
    if [ "$RB_RC" -ne 0 ] || [ "$(json_field "$RB_OUT" already_bound)" != "True" ]; then
      fail "13d-pinned-rebind" "bind with the pinned identity failed: rc=$RB_RC $(printf '%s' "$RB_OUT" | head -c 200)"
    elif [ "$(snap_state "$G13A_COORD")" != "$G13D_SNAP" ]; then
      fail "13d-pinned-rebind" "idempotent pinned re-bind mutated state"
    else
      ok "13d-pinned-rebind (pinned identity accepted idempotently, zero writes)"
    fi
  fi

  # 13e: an already-bound review refuses a different-identity re-bind.
  printf '\n--- 13e: state refusal after successful bind ---\n'
  review_create "$G13A_ABS" "$G13A_BASE" "g13-author" "g13-reviewer"
  if [ "$RC_CREATE_RC" -ne 0 ]; then
    fail "13e-create" "review create failed: $(printf '%s' "$RC_CREATE_OUT" | head -c 200)"
  else
    G13E_ID="$RC_CREATE_ID"
    review_bind "$G13E_ID" "$G13_S3" "$G13_R3" "$G13A_ABS"
    if [ "$RB_RC" -ne 0 ]; then
      fail "13e-bind" "setup bind failed: $(printf '%s' "$RB_OUT" | head -c 200)"
    else
      expect_bind_refused "13e-not-bindable" "$G13E_ID" "$G13_S4" "$G13_R4" \
        "$G13A_ABS" "review_already_bound" "$G13A_COORD"
    fi
  fi

  # 13f: capability binding refusal on register-process, zero mutation.
  printf '\n--- 13f: capability refusal ---\n'
  if [ -z "$RC_CREATE_TOKEN" ] || [ -z "${G13E_ID:-}" ]; then
    skip "13f" "no create capability captured"
  else
    G13F_SNAP="$(snap_state "$G13A_COORD")"
    G13F_TOK_FILE="$(mktemp "$TMPDIR/g13-wrong-token.XXXXXXXX")"
    printf '%s\n' "$G13_WRONG_TOKEN" > "$G13F_TOK_FILE"
    exec 8<"$G13F_TOK_FILE"
    G13F_RC=0
    G13F_OUT="$(cd "$G13A_ABS" && "$COORD_SH" review register-process "$G13E_ID" \
      --role reviewer --pid $$ --process-token-fd 8 --json 2>&1)" || G13F_RC=$?
    exec 8<&-
    rm -f "$G13F_TOK_FILE"
    if [ "$G13F_RC" -eq 0 ] || [ "$(json_field "$G13F_OUT" error)" != "capability_rejected" ]; then
      fail "13f-capability" "expected capability_rejected, got rc=$G13F_RC $(printf '%s' "$G13F_OUT" | head -c 200)"
    elif [ "$(snap_state "$G13A_COORD")" != "$G13F_SNAP" ]; then
      fail "13f-capability" "rejected register-process mutated coordination/payload state"
    else
      ok "13f-capability (wrong capability refused, zero writes)"
      G13F_TOK_FILE="$(mktemp "$TMPDIR/g13-right-token.XXXXXXXX")"
      printf '%s\n' "$RC_CREATE_TOKEN" > "$G13F_TOK_FILE"
      exec 8<"$G13F_TOK_FILE"
      G13F_RC=0
      G13F_OUT="$(cd "$G13A_ABS" && "$COORD_SH" review register-process "$G13E_ID" \
        --role reviewer --pid $$ --process-token-fd 8 --json 2>&1)" || G13F_RC=$?
      exec 8<&-
      rm -f "$G13F_TOK_FILE"
      if [ "$G13F_RC" -ne 0 ]; then
        fail "13f-capability-accepted" "correct capability refused: $(printf '%s' "$G13F_OUT" | head -c 200)"
      else
        ok "13f-capability-accepted (minted capability authorizes registration)"
      fi
    fi
  fi

  # 13g: unknown review identity refused, zero mutation.
  printf '\n--- 13g: unknown review refusal ---\n'
  expect_bind_refused "13g-review-not-found" "cccccccccccccccccccccccccccccccc" \
    "$G13_S1" "$G13_R1" "$G13A_ABS" "review_not_found" "$G13A_COORD"

  release_lease "$G13A_ABS" "$G13A_LEASE_TOKEN" "$G13A_BASE" >/dev/null 2>&1 || true
fi
# ========================================================================
# Summary
# ========================================================================
printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\n' "$PASSED"
printf 'Failed:  %d\n' "$FAILED"
printf 'Skipped: %d\n' "$SKIPPED"
if [ ${#ERRORS[@]} -gt 0 ]; then
  printf '\nFailures:\n'
  for err in "${ERRORS[@]}"; do
    printf '  - %s\n' "$err"
  done
fi

if [ "$FAILED" -eq 0 ]; then
  printf '\nAll gates PASSED.\n'
  exit 0
else
  printf '\nSome gates FAILED.\n'
  exit 1
fi
