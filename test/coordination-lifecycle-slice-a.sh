#!/bin/bash
# coordination-lifecycle-slice-a.sh — gate 14 regression tests for DeepSeek slice A
# Bash 3.2 compatible. Isolated mktemp fixtures. No side effects outside owned paths.
set -uo pipefail

# ---------- helpers ----------
COORD_SH="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../tool/bin" && pwd)/coordination.sh"
COORD_VERIFY="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../tool/bin" && pwd)/coordination_verify.py"
COORD_VERIFY_DIR="$(dirname "$COORD_VERIFY")"
PYTHON_BIN="${STITCHPAD_COORD_PYTHON:-python3}"
PASSED=0
FAILED=0
SKIPPED=0
declare -a ERRORS=()

ok() { PASSED=$((PASSED + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); ERRORS+=("$1: $2"); printf '  FAIL %s: %s\n' "$1" "$2"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  SKIP %s: %s\n' "$1" "$2"; }

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

add_commit() {
  local dir="$1" message="${2:-second}"
  echo "$message" >> "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -m "$message" -q
}

head_oid() { git -C "$1" rev-parse HEAD; }

setup_test_root() {
  local root
  root="$(mktemp -d /private/tmp/coord-slice-a-test.XXXXXXXX)"
  chmod 700 "$root"
  touch "$root/TEST_MODE_V1"
  chmod 600 "$root/TEST_MODE_V1"
  echo "$root"
}

# ---------- coordination wrappers ----------

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

json_field() {
  printf '%s' "$1" | "$PYTHON_BIN" -c \
    'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2" 2>/dev/null
}

# review_create REPO COMMIT AUTHOR REVIEWER
# Globals: RC_CREATE_RC RC_CREATE_OUT RC_CREATE_ID RC_CREATE_TOKEN RC_CREATE_PAYLOAD
review_create() {
  local repo="$1" commit="$2" author="$3" reviewer="$4"
  local rc=0 out
  out="$("$PYTHON_BIN" -B "$G14_DRIVER" "$repo" "$commit" "$author" "$reviewer" \
    "$COORD_VERIFY_DIR" 2>/dev/null)" || rc=$?
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

# review_bind ID SESSION REQUEST WORKDIR
# Globals: RB_RC RB_OUT
review_bind() {
  local id="$1" session="$2" request="$3" workdir="$4"
  local rc=0 out
  out="$(cd "$workdir" && "$COORD_SH" review bind "$id" \
    --session "$session" --request "$request" --json 2>&1)" || rc=$?
  RB_RC=$rc
  RB_OUT="$out"
}

# ---------- preamble ----------
printf '\n=== coordination-lifecycle-slice-a.sh gate 14 ===\n'
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

# ---------- shared fixture: fabricate.py driver ----------
G14_DIR="$TMPDIR/g14"
mkdir -p "$G14_DIR"
unset STITCHPAD_SESSION STITCHPAD_REQUEST STITCHPAD_MODEL STITCHPAD_WORKTREE 2>/dev/null || true
G14_DRIVER="$G14_DIR/fabricate.py"

cat > "$G14_DRIVER" <<'PYEOF'
#!/usr/bin/env python3
"""Slice-A fixture fabricator: publish the exact pre-bind state.

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

# Shared identity tokens
S1="11111111111111111111111111111111"
S2="22222222222222222222222222222222"
R1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# ========================================================================
# GATE 14 — DeepSeek Slice A Regressions (observation bound, stale threshold,
#            dead-conditional removal)
# ========================================================================
printf '\n========== GATE 14: DeepSeek Slice A Regressions ==========\n'

# ------- 14a: observation ceiling enforced at MAX_OBSERVATIONS -------
printf '\n--- 14a: observation ceiling ---\n'
G14A="$G14_DIR/repo-a"
make_repo "$G14A" "gate-14a"
add_commit "$G14A" "gate-14a-second"
G14A_ABS="$(cd -P "$G14A" && pwd)"
G14A_BASE="$(head_oid "$G14A_ABS")"

acquire "$G14A_ABS" "g14a-author" "$G14A_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "14a-acquire" "lease acquire failed: $ACQUIRE_OUT"
else
  review_create "$G14A_ABS" "$G14A_BASE" "g14a-author" "g14a-reviewer"
  if [ "$RC_CREATE_RC" -ne 0 ] || [ -z "$RC_CREATE_ID" ]; then
    fail "14a-create" "review create failed: $(printf '%s' "$RC_CREATE_OUT" | head -c 200)"
  else
    review_bind "$RC_CREATE_ID" "$S1" "$R1" "$G14A_ABS"
    if [ "$RB_RC" -ne 0 ]; then
      fail "14a-bind" "bind failed: rc=$RB_RC $(printf '%s' "$RB_OUT" | head -c 200)"
    else
      G14A_PAYLOAD="$(json_field "$RC_CREATE_OUT" payload_path)"
      "$PYTHON_BIN" -B - "$G14A_PAYLOAD" "$RC_CREATE_ID" "$COORD_VERIFY_DIR" <<'PYEOF14A'
import json, os, sys, time
payload, rid, vdir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, vdir)
import coordination_verify as cv
fds = cv.FDSet()
try:
    pfd = fds.keep(os.open(payload, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
    pstat = os.stat(payload)
    payload_identity = {"dev": pstat.st_dev, "ino": pstat.st_ino, "type": "directory"}
    sstat = os.stat(os.path.join(payload, "src"))
    src_identity = {"dev": sstat.st_dev, "ino": sstat.st_ino, "type": "directory"}
    # pointer.json
    cv.publish_flat_record(pfd, "pointer.json", "pointer", cv.new_record("pointer", 1, {
        "review_id": rid,
        "payload_base": os.environ["STITCHPAD_COORD_TEST_PAYLOAD_BASE"],
        "payload_path": payload, "payload_name": os.path.basename(payload),
        "payload_identity": payload_identity, "src_identity": src_identity,
        "manifest_digest": "."*64, "inventory_digest": "."*64,
        "created_at": int(time.time()),
    }), "pointer")
    # manifest.json
    cv.publish_flat_record(pfd, "manifest.json", "manifest", cv.new_record("manifest", 1, {
        "review_id": rid, "algo": "sha256", "commit": "."*64, "tree": "."*64,
        "repo_id": "."*32, "entry_count": 0, "inventory_digest": "."*64,
        "src_identity": src_identity, "payload_identity": payload_identity,
        "launch_digest": "."*64, "helper_digest": "."*64,
        "created_at": int(time.time()), "ceiling": "/",
    }), "manifest")
    # 4096 observation stubs
    obs = os.path.join(payload, "observations")
    os.mkdir(obs, 0o700)
    for n in range(4096):
        with open(os.path.join(obs, "%d.json" % n), "w") as fh:
            fh.write("{}")
finally:
    fds.close_all()
PYEOF14A
      if [ $? -ne 0 ]; then
        fail "14a-fixture" "failed to fabricate pointer + observation stubs"
      else
        G14A_ROWS="$(mktemp "$TMPDIR/g14a-rows.XXXXXXXX")"
        printf '[{"request":"%s","session":"%s","state":"running"}]\n' \
          "$R1" "$S1" > "$G14A_ROWS"
        exec 7<"$G14A_ROWS"
        G14A_RC=0
        G14A_OUT="$(cd "$G14A_ABS" && "$COORD_SH" review refresh "$RC_CREATE_ID" \
          --provider-rows-fd 7 --json 2>/dev/null)" || G14A_RC=$?
        exec 7<&-
        rm -f "$G14A_ROWS"
        if [ "$G14A_RC" -eq 0 ]; then
          fail "14a-ceiling" "refresh with 4096 obs stubs unexpectedly succeeded"
        elif [ "$(json_field "$G14A_OUT" error)" != "observation_limit" ]; then
          fail "14a-ceiling" "expected observation_limit, got: $(printf '%s' "$G14A_OUT" | head -c 200)"
        else
          ok "14a-ceiling (MAX_OBSERVATIONS=4096 ceiling enforced)"
        fi
      fi
    fi
  fi
  release_lease "$G14A_ABS" "$ACQUIRE_TOKEN" "$G14A_BASE" >/dev/null 2>&1 || true
fi

# ------- 14b: observation ceiling not hit below MAX_OBSERVATIONS -------
printf '\n--- 14b: below ceiling still works ---\n'
G14B="$G14_DIR/repo-b"
make_repo "$G14B" "gate-14b"
add_commit "$G14B" "gate-14b-second"
G14B_ABS="$(cd -P "$G14B" && pwd)"
G14B_BASE="$(head_oid "$G14B_ABS")"

acquire "$G14B_ABS" "g14b-author" "$G14B_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "14b-acquire" "lease acquire failed: $ACQUIRE_OUT"
else
  review_create "$G14B_ABS" "$G14B_BASE" "g14b-author" "g14b-reviewer"
  if [ "$RC_CREATE_RC" -ne 0 ] || [ -z "$RC_CREATE_ID" ]; then
    fail "14b-create" "review create failed: $(printf '%s' "$RC_CREATE_OUT" | head -c 200)"
  else
    review_bind "$RC_CREATE_ID" "$S1" "$R1" "$G14B_ABS"
    if [ "$RB_RC" -ne 0 ]; then
      fail "14b-bind" "bind failed: rc=$RB_RC $(printf '%s' "$RB_OUT" | head -c 200)"
    else
      G14B_PAYLOAD="$(json_field "$RC_CREATE_OUT" payload_path)"
      "$PYTHON_BIN" -B - "$G14B_PAYLOAD" "$RC_CREATE_ID" "$COORD_VERIFY_DIR" <<'PYEOF14B'
import json, os, sys, time
payload, rid, vdir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, vdir)
import coordination_verify as cv
fds = cv.FDSet()
try:
    pfd = fds.keep(os.open(payload, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
    pstat = os.stat(payload)
    payload_identity = {"dev": pstat.st_dev, "ino": pstat.st_ino, "type": "directory"}
    sstat = os.stat(os.path.join(payload, "src"))
    src_identity = {"dev": sstat.st_dev, "ino": sstat.st_ino, "type": "directory"}
    cv.publish_flat_record(pfd, "pointer.json", "pointer", cv.new_record("pointer", 1, {
        "review_id": rid,
        "payload_base": os.environ["STITCHPAD_COORD_TEST_PAYLOAD_BASE"],
        "payload_path": payload, "payload_name": os.path.basename(payload),
        "payload_identity": payload_identity, "src_identity": src_identity,
        "manifest_digest": "."*64, "inventory_digest": "."*64,
        "created_at": int(time.time()),
    }), "pointer")
    cv.publish_flat_record(pfd, "manifest.json", "manifest", cv.new_record("manifest", 1, {
        "review_id": rid, "algo": "sha256", "commit": "."*64, "tree": "."*64,
        "repo_id": "."*32, "entry_count": 0, "inventory_digest": "."*64,
        "src_identity": src_identity, "payload_identity": payload_identity,
        "launch_digest": "."*64, "helper_digest": "."*64,
        "created_at": int(time.time()), "ceiling": "/",
    }), "manifest")
finally:
    fds.close_all()
PYEOF14B
      G14B_ROWS1="$(mktemp "$TMPDIR/g14b-rows1.XXXXXXXX")"
      printf '[{"request":"%s","session":"%s","state":"running"}]\n' \
        "$R1" "$S1" > "$G14B_ROWS1"
      exec 7<"$G14B_ROWS1"
      G14B_RC=0
      G14B_OUT="$(cd "$G14B_ABS" && "$COORD_SH" review refresh "$RC_CREATE_ID" \
        --provider-rows-fd 7 --json 2>&1)" || G14B_RC=$?
      exec 7<&-
      rm -f "$G14B_ROWS1"
      if [ "$G14B_RC" -ne 0 ]; then
        fail "14b-refresh1" "first refresh failed: $(printf '%s' "$G14B_OUT" | head -c 200)"
      else
        G14B_ROWS2="$(mktemp "$TMPDIR/g14b-rows2.XXXXXXXX")"
        printf '[{"request":"%s","session":"%s","state":"completed"}]\n' \
          "$R1" "$S1" > "$G14B_ROWS2"
        exec 7<"$G14B_ROWS2"
        G14B_RC=0
        G14B_OUT="$(cd "$G14B_ABS" && "$COORD_SH" review refresh "$RC_CREATE_ID" \
          --provider-rows-fd 7 --json 2>&1)" || G14B_RC=$?
        exec 7<&-
        rm -f "$G14B_ROWS2"
        if [ "$G14B_RC" -ne 0 ]; then
          fail "14b-refresh2" "second refresh failed: $(printf '%s' "$G14B_OUT" | head -c 200)"
        else
          obs_count="$("$PYTHON_BIN" -c "
import json
with open('$G14B_PAYLOAD/latest.json') as fh:
    print(json.load(fh)['observation_count'])
" 2>/dev/null)"
          if [ "$obs_count" != "2" ]; then
            fail "14b-count" "expected 2 observations, got $obs_count"
          else
            ok "14b-below-ceiling (2 observations under the limit)"
          fi
        fi
      fi
    fi
  fi
  release_lease "$G14B_ABS" "$ACQUIRE_TOKEN" "$G14B_BASE" >/dev/null 2>&1 || true
fi

# ------- 14c: configurable stale threshold via env var -------
printf '\n--- 14c: configurable stale threshold ---\n'
G14C="$G14_DIR/repo-c"
make_repo "$G14C" "gate-14c"
add_commit "$G14C" "gate-14c-second"
G14C_ABS="$(cd -P "$G14C" && pwd)"
G14C_BASE="$(head_oid "$G14C_ABS")"

acquire "$G14C_ABS" "g14c-author" "$G14C_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "14c-acquire" "lease acquire failed: $ACQUIRE_OUT"
else
  review_create "$G14C_ABS" "$G14C_BASE" "g14c-author" "g14c-reviewer"
  if [ "$RC_CREATE_RC" -ne 0 ] || [ -z "$RC_CREATE_ID" ]; then
    fail "14c-create" "review create failed: $(printf '%s' "$RC_CREATE_OUT" | head -c 200)"
  else
    review_bind "$RC_CREATE_ID" "$S1" "$R1" "$G14C_ABS"
    if [ "$RB_RC" -ne 0 ]; then
      fail "14c-bind" "bind failed: rc=$RB_RC $(printf '%s' "$RB_OUT" | head -c 200)"
    else
      G14C_PAYLOAD="$(json_field "$RC_CREATE_OUT" payload_path)"
      G14C_OLD_TS="$(( $(date +%s) - 90000 ))"  # 25h ago (> default 24h)
      "$PYTHON_BIN" -B - "$G14C_PAYLOAD" "$RC_CREATE_ID" "$G14C_OLD_TS" "$COORD_VERIFY_DIR" <<'PYEOF14C'
import json, os, sys, time
payload, rid, old_ts_str, vdir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, vdir)
import coordination_verify as cv
fds = cv.FDSet()
try:
    pfd = fds.keep(os.open(payload, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
    pstat = os.stat(payload)
    payload_identity = {"dev": pstat.st_dev, "ino": pstat.st_ino, "type": "directory"}
    sstat = os.stat(os.path.join(payload, "src"))
    src_identity = {"dev": sstat.st_dev, "ino": sstat.st_ino, "type": "directory"}
    cv.publish_flat_record(pfd, "pointer.json", "pointer", cv.new_record("pointer", 1, {
        "review_id": rid,
        "payload_base": os.environ["STITCHPAD_COORD_TEST_PAYLOAD_BASE"],
        "payload_path": payload, "payload_name": os.path.basename(payload),
        "payload_identity": payload_identity, "src_identity": src_identity,
        "manifest_digest": "."*64, "inventory_digest": "."*64,
        "created_at": int(time.time()),
    }), "pointer")
    cv.publish_flat_record(pfd, "manifest.json", "manifest", cv.new_record("manifest", 1, {
        "review_id": rid, "algo": "sha256", "commit": "."*64, "tree": "."*64,
        "repo_id": "."*32, "entry_count": 0, "inventory_digest": "."*64,
        "src_identity": src_identity, "payload_identity": payload_identity,
        "launch_digest": "."*64, "helper_digest": "."*64,
        "created_at": int(time.time()), "ceiling": "/",
    }), "manifest")
    facts = cv.read_flat_record(pfd, "facts.json", "facts", "facts", allow_missing=False)
    facts["last_activity_at"] = int(old_ts_str)
    facts["generation"] = facts["generation"] + 1
    cv.publish_flat_record(pfd, "facts.json", "facts", facts, "facts")
finally:
    fds.close_all()
PYEOF14C
      # Default 24h threshold -> stale_session appears.
      G14C_STATUS="$(cd "$G14C_ABS" && "$COORD_SH" review status "$RC_CREATE_ID" --json 2>/dev/null)"
      G14C_BLOCKERS="$(json_field "$G14C_STATUS" blockers)"
      case "$G14C_BLOCKERS" in
        *stale_session*) ok "14c-default-stale (stale_session present)" ;;
        *) fail "14c-default-stale" "expected stale_session in blockers, got: $G14C_BLOCKERS" ;;
      esac

      # Custom 26h threshold -> stale_session absent (25h < 26h).
      G14C_STATUS="$(cd "$G14C_ABS" && STITCHPAD_COORD_STALE_SECONDS=93600 \
        "$COORD_SH" review status "$RC_CREATE_ID" --json 2>/dev/null)"
      G14C_BLOCKERS="$(json_field "$G14C_STATUS" blockers)"
      case "$G14C_BLOCKERS" in
        *stale_session*)
          fail "14c-custom-threshold" "stale_session unexpectedly present with 93600s threshold" ;;
        *) ok "14c-custom-threshold (25h age below 26h threshold)" ;;
      esac

      # Invalid threshold: non-integer -> refuses with stale_threshold_invalid.
      G14C_REFUSE="$(cd "$G14C_ABS" && STITCHPAD_COORD_STALE_SECONDS=abc \
        "$COORD_SH" review status "$RC_CREATE_ID" --json 2>/dev/null)" || true
      G14C_ERR="$(json_field "$G14C_REFUSE" error)"
      if [ "$G14C_ERR" = "stale_threshold_invalid" ]; then
        ok "14c-invalid-nonint (stale_threshold_invalid for abc)"
      else
        fail "14c-invalid-nonint" "expected stale_threshold_invalid, got: $G14C_REFUSE"
      fi

      # Invalid threshold: out of range -> refuses.
      G14C_REFUSE="$(cd "$G14C_ABS" && STITCHPAD_COORD_STALE_SECONDS=30 \
        "$COORD_SH" review status "$RC_CREATE_ID" --json 2>/dev/null)" || true
      G14C_ERR="$(json_field "$G14C_REFUSE" error)"
      if [ "$G14C_ERR" = "stale_threshold_invalid" ]; then
        ok "14c-invalid-range (stale_threshold_invalid for 30 < 60)"
      else
        fail "14c-invalid-range" "expected stale_threshold_invalid, got: $G14C_REFUSE"
      fi
    fi
  fi
  release_lease "$G14C_ABS" "$ACQUIRE_TOKEN" "$G14C_BASE" >/dev/null 2>&1 || true
fi

# ------- 14d: dead-conditional removal --- terminal_completion always assigned -------
printf '\n--- 14d: dead-conditional removal verified ---\n'
G14D="$G14_DIR/repo-d"
make_repo "$G14D" "gate-14d"
add_commit "$G14D" "gate-14d-second"
G14D_ABS="$(cd -P "$G14D" && pwd)"
G14D_BASE="$(head_oid "$G14D_ABS")"

acquire "$G14D_ABS" "g14d-author" "$G14D_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "14d-acquire" "lease acquire failed: $ACQUIRE_OUT"
else
  review_create "$G14D_ABS" "$G14D_BASE" "g14d-author" "g14d-reviewer"
  if [ "$RC_CREATE_RC" -ne 0 ] || [ -z "$RC_CREATE_ID" ]; then
    fail "14d-create" "review create failed: $(printf '%s' "$RC_CREATE_OUT" | head -c 200)"
  else
    review_bind "$RC_CREATE_ID" "$S1" "$R1" "$G14D_ABS"
    if [ "$RB_RC" -ne 0 ]; then
      fail "14d-bind" "bind failed: rc=$RB_RC $(printf '%s' "$RB_OUT" | head -c 200)"
    else
      G14D_PAYLOAD="$(json_field "$RC_CREATE_OUT" payload_path)"
      "$PYTHON_BIN" -B - "$G14D_PAYLOAD" "$RC_CREATE_ID" "$COORD_VERIFY_DIR" <<'PYEOF14D'
import json, os, sys, time
payload, rid, vdir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, vdir)
import coordination_verify as cv
fds = cv.FDSet()
try:
    pfd = fds.keep(os.open(payload, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
    pstat = os.stat(payload)
    payload_identity = {"dev": pstat.st_dev, "ino": pstat.st_ino, "type": "directory"}
    sstat = os.stat(os.path.join(payload, "src"))
    src_identity = {"dev": sstat.st_dev, "ino": sstat.st_ino, "type": "directory"}
    cv.publish_flat_record(pfd, "pointer.json", "pointer", cv.new_record("pointer", 1, {
        "review_id": rid,
        "payload_base": os.environ["STITCHPAD_COORD_TEST_PAYLOAD_BASE"],
        "payload_path": payload, "payload_name": os.path.basename(payload),
        "payload_identity": payload_identity, "src_identity": src_identity,
        "manifest_digest": "."*64, "inventory_digest": "."*64,
        "created_at": int(time.time()),
    }), "pointer")
    cv.publish_flat_record(pfd, "manifest.json", "manifest", cv.new_record("manifest", 1, {
        "review_id": rid, "algo": "sha256", "commit": "."*64, "tree": "."*64,
        "repo_id": "."*32, "entry_count": 0, "inventory_digest": "."*64,
        "src_identity": src_identity, "payload_identity": payload_identity,
        "launch_digest": "."*64, "helper_digest": "."*64,
        "created_at": int(time.time()), "ceiling": "/",
    }), "manifest")
finally:
    fds.close_all()
PYEOF14D
      G14D_ROWS="$(mktemp "$TMPDIR/g14d-rows.XXXXXXXX")"
      printf '[{"request":"%s","session":"%s","state":"completed","completion":"done"}]\n' \
        "$R1" "$S1" > "$G14D_ROWS"
      exec 7<"$G14D_ROWS"
      G14D_RC=0
      G14D_OUT="$(cd "$G14D_ABS" && "$COORD_SH" review refresh "$RC_CREATE_ID" \
        --provider-rows-fd 7 --json 2>&1)" || G14D_RC=$?
      exec 7<&-
      rm -f "$G14D_ROWS"
      if [ "$G14D_RC" -ne 0 ]; then
        fail "14d-refresh" "refresh failed: $(printf '%s' "$G14D_OUT" | head -c 200)"
      else
        G14D_COMPLETION="$("$PYTHON_BIN" -c "
import json
with open('$G14D_PAYLOAD/facts.json') as fh:
    print(json.load(fh).get('terminal_completion', 'MISSING'))
" 2>/dev/null)"
        if [ "$G14D_COMPLETION" = "done" ]; then
          ok "14d-completion (terminal_completion=$G14D_COMPLETION recorded without dead guard)"
        else
          fail "14d-completion" "expected terminal_completion='done', got: $G14D_COMPLETION"
        fi
      fi
    fi
  fi
  release_lease "$G14D_ABS" "$ACQUIRE_TOKEN" "$G14D_BASE" >/dev/null 2>&1 || true
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
