#!/bin/bash
# coordination-lifecycle-sliceB.sh — regression gates for production lifecycle
# slice B (kimi). Bash 3.2 compatible. Isolated mktemp fixtures. No side
# effects outside owned paths.
#
# Defects under test (four audited items; slice A — bounded history, stale
# threshold, dead conditional — is owned by deepseek and NOT touched here):
#   B1  missing global identity uniqueness at bind (session/request pair
#       must authorize exactly one review repository-wide)
#   B2  raw provider/model mismatch must be refused (bind) or recorded as a
#       sticky, truthfully-coded conflict (refresh) — never silently accepted
#       or misreported
#   B3  review status double-sampling must be SUFFICIENT: transition-mutex
#       absence sampled before/between/after the two snapshots, and full
#       canonical-JSON snapshot comparison (the review generation alone
#       misses facts/latest rewrites, permitting transient false state)
#   B4  closure must PRESERVE audit truth: every mutating verb
#       (refresh, cancel-requested, register-process, submit-report)
#       refuses a closed review and leaves coordination+payload state
#       byte-identical; status retains recorded blockers and history on
#       closed reviews
#
# Harness pattern mirrors gate 13: `review create` self-refuses at this base
# (root_replaced), so pre-bind/bound/closed fixture state is fabricated with
# the verifier's own new_record/publish functions and every behavior under
# test is driven through the real CLI. Deterministic fixtures; no network.
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
  git -C "$dir" add "$dir/file.txt"
  git -C "$dir" commit -m "$message" -q
}

head_oid() { git -C "$1" rev-parse HEAD; }

setup_test_root() {
  local root
  root="$(mktemp -d /private/tmp/coord-sliceB-test.XXXXXXXX)"
  chmod 700 "$root"
  touch "$root/TEST_MODE_V1"
  chmod 600 "$root/TEST_MODE_V1"
  echo "$root"
}

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

# snap_state COORD_DIR — joint digest of coordination state and payload base.
snap_state() {
  { snap_tree "$1"; snap_tree "$PAYLOAD_BASE"; }
}

json_field() {
  printf '%s' "$1" | "$PYTHON_BIN" -c \
    'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2" 2>/dev/null
}

json_has_blocker() {
  printf '%s' "$1" | "$PYTHON_BIN" -c \
    'import json,sys; d=json.load(sys.stdin); print("yes" if sys.argv[1] in (d.get("blockers") or []) else "no")' "$2" 2>/dev/null
}

# ---------- coordination wrappers ----------
# Every wrapper captures stdout (JSON) and stderr (diagnostics/warnings)
# separately.  Python 3.13+ emits a DeprecationWarning for utcfromtimestamp
# on stderr; merging it into stdout corrupts JSON parsing.  The _ERR
# globals are available for diagnostic messages but never fed to json_field.

# acquire WORKTREE ACTOR BASE — lease acquire (fixture realism + repo_id).
# Globals: ACQUIRE_RC ACQUIRE_OUT ACQUIRE_ERR ACQUIRE_LEASE_ID ACQUIRE_TOKEN
acquire() {
  local worktree="$1" actor="$2" base="$3"
  local token_file
  token_file="$(mktemp "$TMPDIR/acquire-token.XXXXXXXX")"
  exec 9>"$token_file"
  local rc=0
  local out err
  err_file="$(mktemp "$TMPDIR/acquire-err.XXXXXXXX")"
  out="$("$COORD_SH" lease acquire --worktree "$worktree" --actor "$actor" --base "$base" --token-out-fd 9 2>"$err_file")" || rc=$?
  exec 9>&-
  ACQUIRE_RC=$rc
  ACQUIRE_OUT="$out"
  ACQUIRE_ERR="$(cat "$err_file")"
  if [ -s "$token_file" ]; then
    ACQUIRE_TOKEN="$(head -c 64 "$token_file" | tr -d '\n')"
  else
    ACQUIRE_TOKEN=""
  fi
  rm -f "$token_file" "$err_file"
  if [ $rc -eq 0 ]; then
    ACQUIRE_LEASE_ID="$(echo "$out" | sed -n 's/^lease_id: //p')"
  else
    ACQUIRE_LEASE_ID=""
  fi
}

# fabricate SUBCOMMAND ... — publish fixture state via the verifier's own
# record functions. Prints one JSON line on stdout. See FAB_DRIVER for
# subcommands.
# Globals: FAB_RC FAB_OUT FAB_ERR FAB_ID FAB_TOKEN FAB_PAYLOAD
fabricate() {
  local rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/fab-err.XXXXXXXX")"
  out="$("$PYTHON_BIN" -B "$FAB_DRIVER" "$@" 2>"$err_file")" || rc=$?
  FAB_RC=$rc
  FAB_OUT="$out"
  FAB_ERR="$(cat "$err_file")"
  rm -f "$err_file"
  if [ $rc -eq 0 ]; then
    FAB_ID="$(json_field "$out" review_id)"
    FAB_TOKEN="$(json_field "$out" process_token)"
    FAB_PAYLOAD="$(json_field "$out" payload_path)"
  else
    FAB_ID=""
    FAB_TOKEN=""
    FAB_PAYLOAD=""
  fi
}

# review_bind ID SESSION REQUEST WORKDIR
# Globals: RB_RC RB_OUT RB_ERR
review_bind() {
  local id="$1" session="$2" request="$3" workdir="$4"
  local rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/rb-err.XXXXXXXX")"
  out="$(cd "$workdir" && "$COORD_SH" review bind "$id" \
    --session "$session" --request "$request" --json 2>"$err_file")" || rc=$?
  RB_RC=$rc
  RB_OUT="$out"
  RB_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# review_status ID WORKDIR
# Globals: RS_RC RS_OUT RS_ERR
review_status() {
  local id="$1" workdir="$2"
  local rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/rs-err.XXXXXXXX")"
  out="$(cd "$workdir" && "$COORD_SH" review status "$id" --json 2>"$err_file")" || rc=$?
  RS_RC=$rc
  RS_OUT="$out"
  RS_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# review_refresh ID ROWS_FILE WORKDIR
# Globals: RF_RC RF_OUT RF_ERR
review_refresh() {
  local id="$1" rows_file="$2" workdir="$3"
  local rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/rf-err.XXXXXXXX")"
  exec 7<"$rows_file"
  out="$(cd "$workdir" && "$COORD_SH" review refresh "$id" \
    --provider-rows-fd 7 --json 2>"$err_file")" || rc=$?
  exec 7<&-
  RF_RC=$rc
  RF_OUT="$out"
  RF_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# review_cancel ID WORKDIR
# Globals: RCX_RC RCX_OUT RCX_ERR
review_cancel() {
  local id="$1" workdir="$2"
  local rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/rcx-err.XXXXXXXX")"
  out="$(cd "$workdir" && "$COORD_SH" review cancel-requested "$id" --json 2>"$err_file")" || rc=$?
  RCX_RC=$rc
  RCX_OUT="$out"
  RCX_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# review_register ID ROLE PID TOKEN_FILE WORKDIR
# Globals: RR_RC RR_OUT RR_ERR
review_register() {
  local id="$1" role="$2" pid="$3" token_file="$4" workdir="$5"
  local rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/rr-err.XXXXXXXX")"
  exec 6<"$token_file"
  out="$(cd "$workdir" && "$COORD_SH" review register-process "$id" \
    --role "$role" --pid "$pid" --process-token-fd 6 --json 2>"$err_file")" || rc=$?
  exec 6<&-
  RR_RC=$rc
  RR_OUT="$out"
  RR_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# review_submit ID WORKDIR
# Globals: RSUB_RC RSUB_OUT RSUB_ERR
review_submit() {
  local id="$1" workdir="$2"
  local rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/rsub-err.XXXXXXXX")"
  out="$(cd "$workdir" && "$COORD_SH" review submit-report "$id" --json 2>"$err_file")" || rc=$?
  RSUB_RC=$rc
  RSUB_OUT="$out"
  RSUB_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# expect_refusal LABEL CODE COORD_DIR — re-runs the command captured in
# $REFUSAL_RUN (a function name + args already executed by caller pattern is
# unwieldy in bash 3.2; callers instead use snap_refused_begin/end below).

# snap refusal protocol: SNAP_BEFORE="$(snap_state ...)"; run op;
# assert_refusal LABEL RC OUT CODE; assert_state_unchanged LABEL COORD_DIR
assert_refusal() {
  local label="$1" rc="$2" out="$3" code="$4"
  local got=""
  if [ "$rc" -ne 0 ]; then
    got="$(json_field "$out" error)"
  fi
  if [ "$rc" -eq 0 ] || [ "$got" != "$code" ]; then
    fail "$label" "expected refusal $code, got rc=$rc error=$got out=$(printf '%s' "$out" | head -c 160)"
    return 1
  fi
  ok "$label"
  return 0
}

assert_state_unchanged() {
  local label="$1" coord="$2" before="$3"
  local after
  after="$(snap_state "$coord")"
  if [ "$after" != "$before" ]; then
    fail "$label" "refused operation mutated coordination/payload state"
    return 1
  fi
  ok "$label"
  return 0
}

# ---------- preamble ----------
printf '\n=== coordination-lifecycle-sliceB.sh gates B1-B4 ===\n'
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
unset STITCHPAD_SESSION STITCHPAD_REQUEST STITCHPAD_MODEL STITCHPAD_WORKTREE 2>/dev/null || true

cleanup() {
  local rc=$?
  if [ -n "${FIXTURE:-}" ] && [ -d "$FIXTURE" ]; then
    rm -rf "$FIXTURE"
  fi
  exit $rc
}
trap cleanup EXIT

printf 'Fixture root: %s\n' "$FIXTURE"

# ---------- fabricator driver ----------
FAB_DIR="$TMPDIR/fab"
mkdir -p "$FAB_DIR"
FAB_DRIVER="$FAB_DIR/fabricate.py"

cat > "$FAB_DRIVER" <<'PYEOF'
#!/usr/bin/env python3
"""Slice-B fixture fabricator: publish exact review states.

usage: fabricate.py SUBCOMMAND REPO COMMIT AUTHOR REVIEWER VERIFY_DIR [args]

subcommands:
  created                               created review, payload, no facts
  created-pinned MODEL                  + facts(null session/request,
                                        provider="ocean", provider_model=MODEL)
  bound SESSION REQUEST MODEL PROVIDER  bound review + facts + pointer/manifest
  closed SESSION REQUEST CONFLICT       closed_verified review + facts(conflict,
                                        use "-" for none) + pointer/manifest
                                        + latest + one observation record

Prints one JSON line: review_id, process_token, payload_path, payload_name.
Mirrors the gate-13 fabrication pattern (create self-refuses at this base).
Python 3.9 compatible.
"""
import json
import os
import secrets
import subprocess
import sys
import time

SUB = sys.argv[1]
# Subcommand-specific positional args come before the common trailing args
# (REPO COMMIT AUTHOR REVIEWER VERIFY_DIR). Parse them out by reading from
# the end so the subcommand's extra args don't shift the common positions.
_VERIFY_DIR = sys.argv[-1]
_AUTHOR = sys.argv[-3]
_REVIEWER = sys.argv[-2]
_COMMIT = sys.argv[-4]
REPO = sys.argv[-5]
VERIFY_DIR = _VERIFY_DIR
AUTHOR = _AUTHOR
REVIEWER = _REVIEWER
COMMIT = _COMMIT
_SUB_ARGS = sys.argv[2:-5]
sys.path.insert(0, VERIFY_DIR)

import coordination_verify as cv  # noqa: E402

PAYLOAD_BASE = os.environ["STITCHPAD_COORD_TEST_PAYLOAD_BASE"]
ZERO64 = "0" * 64


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

state = "created"
closure = None
closure_reason = None
if SUB == "bound":
    state = "bound"
elif SUB == "closed":
    state = "closed"
    closure = "closed_verified"
    closure_reason = "verified"

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
    "state": state,
    "created_at": now,
    "updated_at": now,
    "lease_id": lease["lease_id"],
    "process_capability": verifier,
    "payload_name": payload_name,
    "closure": closure,
    "closure_reason": closure_reason,
})


def facts_record(session, request, model, provider, conflict):
    closed = SUB == "closed"
    return cv.new_record("facts", 1, {
        "review_id": review_id,
        "session_id": session,
        "request_id": request,
        "bound_at": now,
        "cancel_requested": False,
        "cancel_requested_at": None,
        "terminal_observed": closed,
        "terminal_completion": "completed" if closed else None,
        "terminal_at": now if closed else None,
        "report_sealed": closed,
        "report_digest": ZERO64 if closed else None,
        "report_verdict": "PASS" if closed else None,
        "report_sealed_at": now if closed else None,
        "artifact_verified": closed,
        "verified_at": now if closed else None,
        "closure": "closed_verified" if closed else None,
        "closure_reason": "verified" if closed else None,
        "closed_at": now if closed else None,
        "conflict": conflict,
        "contract": None,
        "false_terminal": False,
        "false_terminal_reason": None,
        "false_terminal_at": None,
        "provider": provider,
        "provider_model": model,
        "session_rotation_required": False,
        "last_activity_at": now,
    })


def pointer_record():
    return cv.new_record("pointer", 1, {
        "review_id": review_id,
        "payload_base": PAYLOAD_BASE,
        "payload_path": payload_path,
        "payload_name": payload_name,
        "payload_identity": None,
        "src_identity": None,
        "manifest_digest": ZERO64,
        "inventory_digest": ZERO64,
        "created_at": now,
    })


def manifest_record():
    return cv.new_record("manifest", 1, {
        "review_id": review_id,
        "algo": algo,
        "commit": COMMIT,
        "tree": tree,
        "repo_id": lease["repo_id"],
        "entry_count": 0,
        "inventory_digest": ZERO64,
        "src_identity": None,
        "payload_identity": None,
        "launch_digest": ZERO64,
        "helper_digest": ZERO64,
        "created_at": now,
        "ceiling": 0,
    })


fds = cv.FDSet()
try:
    reviews_fd = fds.keep(open_dir(os.path.join(
        common, "stitchpad-coordination", "v1", "reviews")))
    cv.publish_record(fds, reviews_fd, review_id, "review", review,
                      "review record")
    payload_fd = fds.keep(open_dir(payload_path))

    if SUB == "created-pinned":
        model = _SUB_ARGS[0]
        cv.publish_flat_record(
            payload_fd, "facts.json", "facts",
            facts_record(None, None, model, "ocean", None), "review facts")
    elif SUB == "bound":
        session, request, model, provider = _SUB_ARGS[0:4]
        cv.publish_flat_record(
            payload_fd, "facts.json", "facts",
            facts_record(session, request, model, provider, None),
            "review facts")
        cv.publish_flat_record(payload_fd, "pointer.json", "pointer",
                               pointer_record(), "review pointer")
        cv.publish_flat_record(payload_fd, "manifest.json", "manifest",
                               manifest_record(), "review manifest")
    elif SUB == "closed":
        session, request = _SUB_ARGS[0], _SUB_ARGS[1]
        conflict = _SUB_ARGS[2]
        if conflict == "-":
            conflict = None
        cv.publish_flat_record(
            payload_fd, "facts.json", "facts",
            facts_record(session, request, "k3", "ocean", conflict),
            "review facts")
        cv.publish_flat_record(payload_fd, "pointer.json", "pointer",
                               pointer_record(), "review pointer")
        cv.publish_flat_record(payload_fd, "manifest.json", "manifest",
                               manifest_record(), "review manifest")
        latest = cv.new_record("latest", 1, {
            "review_id": review_id,
            "phase": "terminal",
            "raw_state": "completed",
            "observed_at": now,
            "diagnostic": None,
            "diagnostic_at": None,
            "observation_count": 1,
        })
        cv.publish_flat_record(payload_fd, "latest.json", "latest", latest,
                               "review latest")
        obs_fd, _ = cv.ensure_owned_dir(fds, payload_fd, "observations",
                                        "observations directory",
                                        mode=cv.DIR_MODE)
        observation = cv.new_record("observation", 1, {
            "review_id": review_id,
            "raw_state": "completed",
            "phase": "terminal",
            "terminal": True,
            "observed_at": now,
            "evidence_digest": ZERO64,
            "diagnostic": None,
            "raw_model": "k3",
        })
        cv.publish_flat_record(obs_fd, "0.json", "observation", observation,
                               "observation 0")
    elif SUB != "created":
        sys.stderr.write("unknown subcommand %s\n" % (SUB,))
        sys.exit(1)
finally:
    fds.close_all()

sys.stdout.write(json.dumps({
    "review_id": review_id,
    "process_token": token,
    "payload_path": payload_path,
    "payload_name": payload_name,
}) + "\n")
PYEOF

# ---------- shared leased repo ----------
SB_REPO="$TMPDIR/repo-b"
make_repo "$SB_REPO" "slice-b"
add_commit "$SB_REPO" "slice-b-second"
SB_ABS="$(cd -P "$SB_REPO" && pwd)"
SB_BASE="$(head_oid "$SB_ABS")"
SB_COORD="$SB_ABS/.git/stitchpad-coordination/v1"

acquire "$SB_ABS" "slice-b-author" "$SB_BASE"
if [ "$ACQUIRE_RC" -ne 0 ]; then
  fail "fixture-lease" "author lease acquire failed: $ACQUIRE_OUT"
  exit 1
fi
ok "fixture-lease"

S1="11111111111111111111111111111111"
S2="22222222222222222222222222222222"
S3="33333333333333333333333333333333"
S4="44444444444444444444444444444444"
S5="55555555555555555555555555555555"
S6="66666666666666666666666666666666"
R1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
R2="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
R3="cccccccccccccccccccccccccccccccc"
R4="dddddddddddddddddddddddddddddddd"
R5="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
R6="ffffffffffffffffffffffffffffffff"

# ========================================================================
# GATE B1 — Global identity uniqueness at bind
# ========================================================================
printf '\n========== GATE B1: Global Identity Uniqueness ==========\n'

fabricate created "$SB_ABS" "$SB_BASE" "slice-b-author" "slice-b-reviewer" "$COORD_VERIFY_DIR"
if [ "$FAB_RC" -ne 0 ]; then
  fail "B1-fabricate-A" "fabrication failed: $FAB_OUT"
else
  RA="$FAB_ID"
  review_bind "$RA" "$S1" "$R1" "$SB_ABS"
  if [ "$RB_RC" -ne 0 ]; then
    fail "B1-bind-A" "first bind refused unexpectedly: $RB_OUT"
  else
    ok "B1-bind-A"

    fabricate created "$SB_ABS" "$SB_BASE" "slice-b-author" "slice-b-reviewer" "$COORD_VERIFY_DIR"
    RB2="$FAB_ID"

    # B1.1: the same (session, request) pair on a SECOND review must refuse
    # closed with session_request_in_use and mutate nothing.
    SNAP_BEFORE="$(snap_state "$SB_COORD")"
    review_bind "$RB2" "$S1" "$R1" "$SB_ABS"
    assert_refusal "B1.1-cross-review-collision" "$RB_RC" "$RB_OUT" "session_request_in_use" \
      && assert_state_unchanged "B1.1-zero-mutation" "$SB_COORD" "$SNAP_BEFORE"

    # B1.2: a distinct pair binds cleanly (no false positive from the scan).
    review_bind "$RB2" "$S2" "$R2" "$SB_ABS"
    if [ "$RB_RC" -ne 0 ]; then
      fail "B1.2-distinct-pair-binds" "bind with distinct pair refused: $RB_OUT"
    else
      ok "B1.2-distinct-pair-binds"
    fi

    # B1.3: idempotent re-bind of the original review still succeeds (the
    # scan must not collide a review with itself).
    review_bind "$RA" "$S1" "$R1" "$SB_ABS"
    if [ "$RB_RC" -ne 0 ] || [ "$(json_field "$RB_OUT" already_bound)" != "True" ]; then
      fail "B1.3-idempotent-rebind" "rc=$RB_RC out=$RB_OUT"
    else
      ok "B1.3-idempotent-rebind"
    fi
  fi
fi

# ========================================================================
# GATE B2 — Raw provider/model mismatch refused / truthfully reported
# ========================================================================
printf '\n========== GATE B2: Provider/Model Truthfulness ==========\n'

# B2.1: bind against a review whose create-time facts pinned provider_model
# "k3" with a DIFFERENT invoking model must refuse provider_model_mismatch.
fabricate created-pinned k3 "$SB_ABS" "$SB_BASE" "slice-b-author" "slice-b-reviewer" "$COORD_VERIFY_DIR"
if [ "$FAB_RC" -ne 0 ]; then
  fail "B2-fabricate-pinned" "fabrication failed: $FAB_OUT"
else
  RC="$FAB_ID"
  export STITCHPAD_MODEL="rogue-model"
  SNAP_BEFORE="$(snap_state "$SB_COORD")"
  review_bind "$RC" "$S3" "$R3" "$SB_ABS"
  unset STITCHPAD_MODEL
  assert_refusal "B2.1-bind-model-mismatch" "$RB_RC" "$RB_OUT" "provider_model_mismatch" \
    && assert_state_unchanged "B2.1-zero-mutation" "$SB_COORD" "$SNAP_BEFORE"

  # B2.2: an UNSET invoking model against a pinned model is not a match;
  # it must refuse rather than silently re-pin to null.
  SNAP_BEFORE="$(snap_state "$SB_COORD")"
  review_bind "$RC" "$S3" "$R3" "$SB_ABS"
  assert_refusal "B2.2-bind-unset-model" "$RB_RC" "$RB_OUT" "provider_model_mismatch" \
    && assert_state_unchanged "B2.2-zero-mutation" "$SB_COORD" "$SNAP_BEFORE"

  # B2.3: the pinned model itself binds successfully.
  export STITCHPAD_MODEL="k3"
  review_bind "$RC" "$S3" "$R3" "$SB_ABS"
  unset STITCHPAD_MODEL
  if [ "$RB_RC" -ne 0 ]; then
    fail "B2.3-bind-pinned-model-ok" "bind with pinned model refused: $RB_OUT"
  else
    ok "B2.3-bind-pinned-model-ok"
  fi
fi

# B2.4/B2.5/B2.6: refresh-time raw model mismatch becomes a sticky,
# truthfully-coded conflict (never silently accepted, never erased).
fabricate bound "$S4" "$R4" "k3" "ocean" "$SB_ABS" "$SB_BASE" "slice-b-author" "slice-b-reviewer" "$COORD_VERIFY_DIR"
if [ "$FAB_RC" -ne 0 ]; then
  fail "B2-fabricate-bound" "fabrication failed: $FAB_OUT"
else
  RD="$FAB_ID"
  ROWS_OK="$TMPDIR/rows-ok.json"
  ROWS_BADMODEL="$TMPDIR/rows-badmodel.json"
  printf '[{"request":"%s","session":"%s","state":"running","model":"k3","provider":"ocean"}]\n' \
    "$R4" "$S4" > "$ROWS_OK"
  printf '[{"request":"%s","session":"%s","state":"running","model":"gpt-5.6-sol","provider":"ocean"}]\n' \
    "$R4" "$S4" > "$ROWS_BADMODEL"

  # B2.4: agreeing rows produce no conflict blocker.
  review_refresh "$RD" "$ROWS_OK" "$SB_ABS"
  if [ "$RF_RC" -ne 0 ]; then
    fail "B2.4-refresh-agreeing" "refresh refused: $RF_OUT"
  else
    review_status "$RD" "$SB_ABS"
    if [ "$RS_RC" -eq 0 ] \
        && [ "$(json_has_blocker "$RS_OUT" model_mismatch)" = "no" ] \
        && [ "$(json_has_blocker "$RS_OUT" provider_mismatch)" = "no" ]; then
      ok "B2.4-refresh-agreeing"
    else
      fail "B2.4-refresh-agreeing" "unexpected mismatch blocker: $RS_OUT"
    fi
  fi

  # B2.5: a substituted raw model is recorded as sticky model_mismatch.
  review_refresh "$RD" "$ROWS_BADMODEL" "$SB_ABS"
  if [ "$RF_RC" -ne 0 ]; then
    fail "B2.5-refresh-model-mismatch" "refresh refused: $RF_OUT"
  else
    review_status "$RD" "$SB_ABS"
    if [ "$RS_RC" -eq 0 ] && [ "$(json_has_blocker "$RS_OUT" model_mismatch)" = "yes" ]; then
      ok "B2.5-refresh-model-mismatch"
    else
      fail "B2.5-refresh-model-mismatch" "model_mismatch blocker missing: $RS_OUT"
    fi
  fi

  # B2.6: a later agreeing refresh must NOT erase the recorded conflict.
  review_refresh "$RD" "$ROWS_OK" "$SB_ABS"
  review_status "$RD" "$SB_ABS"
  if [ "$RS_RC" -eq 0 ] && [ "$(json_has_blocker "$RS_OUT" model_mismatch)" = "yes" ]; then
    ok "B2.6-conflict-sticky"
  else
    fail "B2.6-conflict-sticky" "conflict erased by later refresh: $RS_OUT"
  fi
fi

# B2.7: a substituted raw provider is reported under its own truthful code.
fabricate bound "$S5" "$R5" "k3" "ocean" "$SB_ABS" "$SB_BASE" "slice-b-author" "slice-b-reviewer" "$COORD_VERIFY_DIR"
if [ "$FAB_RC" -ne 0 ]; then
  fail "B2-fabricate-bound2" "fabrication failed: $FAB_OUT"
else
  RE="$FAB_ID"
  ROWS_BADPROV="$TMPDIR/rows-badprov.json"
  printf '[{"request":"%s","session":"%s","state":"running","model":"k3","provider":"bogus-provider"}]\n' \
    "$R5" "$S5" > "$ROWS_BADPROV"
  review_refresh "$RE" "$ROWS_BADPROV" "$SB_ABS"
  if [ "$RF_RC" -ne 0 ]; then
    fail "B2.7-refresh-provider-mismatch" "refresh refused: $RF_OUT"
  else
    review_status "$RE" "$SB_ABS"
    if [ "$RS_RC" -eq 0 ] && [ "$(json_has_blocker "$RS_OUT" provider_mismatch)" = "yes" ]; then
      ok "B2.7-refresh-provider-mismatch"
    else
      fail "B2.7-refresh-provider-mismatch" "provider_mismatch blocker missing: $RS_OUT"
    fi
  fi
fi

# ========================================================================
# GATE B3 — Sufficient double-sampling in review status
# ========================================================================
printf '\n========== GATE B3: Status Sampling Sufficiency ==========\n'

fabricate bound "$S6" "$R6" "k3" "ocean" "$SB_ABS" "$SB_BASE" "slice-b-author" "slice-b-reviewer" "$COORD_VERIFY_DIR"
if [ "$FAB_RC" -ne 0 ]; then
  fail "B3-fabricate" "fabrication failed: $FAB_OUT"
else
  RF3="$FAB_ID"

  # B3.1: a stable review reports concurrent_mutation=false.
  review_status "$RF3" "$SB_ABS"
  if [ "$RS_RC" -eq 0 ] && [ "$(json_field "$RS_OUT" concurrent_mutation)" = "False" ]; then
    ok "B3.1-stable-not-concurrent"
  else
    fail "B3.1-stable-not-concurrent" "rc=$RS_RC out=$RS_OUT"
  fi

  # B3.2: a held transition mutex at sample time MUST surface as
  # concurrent_mutation=true (before the fix, status never sampled the
  # mutex and reported a transient false stable state).
  mkdir "$SB_COORD/transition.lock.d"
  chmod 700 "$SB_COORD/transition.lock.d"
  review_status "$RF3" "$SB_ABS"
  if [ "$RS_RC" -eq 0 ] && [ "$(json_field "$RS_OUT" concurrent_mutation)" = "True" ]; then
    ok "B3.2-mutex-detected"
  else
    fail "B3.2-mutex-detected" "held mutex not reported: rc=$RS_RC out=$RS_OUT"
  fi
  rmdir "$SB_COORD/transition.lock.d"

  # B3.3: after the mutex is gone, status recovers to a truthful stable read.
  review_status "$RF3" "$SB_ABS"
  if [ "$RS_RC" -eq 0 ] && [ "$(json_field "$RS_OUT" concurrent_mutation)" = "False" ]; then
    ok "B3.3-recovery"
  else
    fail "B3.3-recovery" "rc=$RS_RC out=$RS_OUT"
  fi
fi

# ========================================================================
# GATE B4 — Closure preserves blockers/history; closed review is immutable
# ========================================================================
printf '\n========== GATE B4: Closure Preservation ==========\n'

fabricate closed "$S1" "$R1" "model_mismatch" "$SB_ABS" "$SB_BASE" "slice-b-author" "slice-b-reviewer" "$COORD_VERIFY_DIR"
if [ "$FAB_RC" -ne 0 ]; then
  fail "B4-fabricate-closed" "fabrication failed: $FAB_OUT"
else
  RG="$FAB_ID"

  # B4.1: status on the closed review RETAINS the recorded conflict blocker,
  # the closure fields, and the bounded observation history.
  review_status "$RG" "$SB_ABS"
  if [ "$RS_RC" -ne 0 ]; then
    fail "B4.1-closed-status" "status on closed review failed: $RS_OUT"
  else
    B4_STATE="$(json_field "$RS_OUT" state)"
    B4_CLOSURE="$(json_field "$RS_OUT" closure)"
    B4_OBS="$(json_field "$RS_OUT" observation_count)"
    B4_BLOCK="$(json_has_blocker "$RS_OUT" model_mismatch)"
    if [ "$B4_STATE" = "closed" ] && [ "$B4_CLOSURE" = "closed_verified" ] \
        && [ "$B4_OBS" = "1" ] && [ "$B4_BLOCK" = "yes" ]; then
      ok "B4.1-closed-status-preserves"
    else
      fail "B4.1-closed-status-preserves" \
        "state=$B4_STATE closure=$B4_CLOSURE obs=$B4_OBS blocker=$B4_BLOCK"
    fi
  fi

  # B4.2: post-closure refresh refuses and mutates nothing.
  ROWS_C="$TMPDIR/rows-closed.json"
  printf '[{"request":"%s","session":"%s","state":"completed","model":"k3","provider":"ocean"}]\n' \
    "$R1" "$S1" > "$ROWS_C"
  SNAP_BEFORE="$(snap_state "$SB_COORD")"
  review_refresh "$RG" "$ROWS_C" "$SB_ABS"
  assert_refusal "B4.2-refresh-closed" "$RF_RC" "$RF_OUT" "review_already_closed" \
    && assert_state_unchanged "B4.2-zero-mutation" "$SB_COORD" "$SNAP_BEFORE"

  # B4.3: post-closure cancel-requested refuses and mutates nothing.
  SNAP_BEFORE="$(snap_state "$SB_COORD")"
  review_cancel "$RG" "$SB_ABS"
  assert_refusal "B4.3-cancel-closed" "$RCX_RC" "$RCX_OUT" "review_already_closed" \
    && assert_state_unchanged "B4.3-zero-mutation" "$SB_COORD" "$SNAP_BEFORE"

  # B4.4: post-closure register-process refuses and mutates nothing.
  TOKEN_FILE="$TMPDIR/process-token.txt"
  printf '%s\n' "$FAB_TOKEN" > "$TOKEN_FILE"
  SNAP_BEFORE="$(snap_state "$SB_COORD")"
  review_register "$RG" "reviewer" "$$" "$TOKEN_FILE" "$SB_ABS"
  assert_refusal "B4.4-register-closed" "$RR_RC" "$RR_OUT" "review_already_closed" \
    && assert_state_unchanged "B4.4-zero-mutation" "$SB_COORD" "$SNAP_BEFORE"

  # B4.5: post-closure submit-report refuses and mutates nothing.
  SNAP_BEFORE="$(snap_state "$SB_COORD")"
  review_submit "$RG" "$SB_ABS"
  assert_refusal "B4.5-submit-closed" "$RSUB_RC" "$RSUB_OUT" "review_already_closed" \
    && assert_state_unchanged "B4.5-zero-mutation" "$SB_COORD" "$SNAP_BEFORE"

  # B4.6: the observation history itself survived every refused verb.
  review_status "$RG" "$SB_ABS"
  if [ "$RS_RC" -eq 0 ] && [ "$(json_field "$RS_OUT" observation_count)" = "1" ] \
      && [ "$(json_has_blocker "$RS_OUT" model_mismatch)" = "yes" ]; then
    ok "B4.6-history-intact"
  else
    fail "B4.6-history-intact" "audit truth changed after refusals: $RS_OUT"
  fi
fi

# ========================================================================
# GATE B5 — actor_self refusal in cmd_review_create
# ========================================================================
printf '\n========== GATE B5: Actor Self Refusal ==========\n'

# B5.1: author==reviewer must refuse with a distinct "actor_self" code
# BEFORE any payload/git work (not "actor_not_distinct", not "not_implemented").
# stdout/stderr separated: JSON result (or error JSON) on stdout, diagnostics
# on stderr. --process-token-out-fd points to a spare fd to avoid clobbering
# the JSON stream.
B5_TOKEN_FILE="$TMPDIR/b5-token.txt"
B5_OUT_FILE="$TMPDIR/b5-out.txt"
B5_ERR_FILE="$TMPDIR/b5-err.txt"
B5_RC=0
(cd "$SB_ABS" && exec 3>"$B5_TOKEN_FILE" && "$COORD_SH" review create \
  --repo "$SB_ABS" \
  --author-actor "self-actor" --reviewer-actor "self-actor" \
  --commit "$SB_BASE" --provider ocean --json \
  --process-token-out-fd 3 >"$B5_OUT_FILE" 2>"$B5_ERR_FILE") || B5_RC=$?

B5_ERROR="$(json_field "$(cat "$B5_OUT_FILE" 2>/dev/null)" error)"
if [ "$B5_RC" -ne 0 ] && [ "$B5_ERROR" = "actor_self" ]; then
  ok "B5.1-self-actor-refusal-code"
else
  fail "B5.1-self-actor-refusal-code" "expected actor_self, got rc=$B5_RC error=$B5_ERROR out=$(head -c 160 "$B5_OUT_FILE" 2>/dev/null) err=$(head -c 160 "$B5_ERR_FILE" 2>/dev/null)"
fi

# B5.2: distinct actors must NOT hit actor_self (they may fail later for
# other reasons at this base, but the code must not be actor_self).
B5B_TOKEN_FILE="$TMPDIR/b5b-token.txt"
B5B_OUT="$TMPDIR/b5b-out.txt"
B5B_ERR="$TMPDIR/b5b-err.txt"
B5B_RC=0
(cd "$SB_ABS" && exec 3>"$B5B_TOKEN_FILE" && "$COORD_SH" review create \
  --repo "$SB_ABS" \
  --author-actor "author-x" --reviewer-actor "reviewer-y" \
  --commit "$SB_BASE" --provider ocean --json \
  --process-token-out-fd 3 >"$B5B_OUT" 2>"$B5B_ERR") || B5B_RC=$?

B5B_ERROR="$(json_field "$(cat "$B5B_OUT" 2>/dev/null)" error)"
if [ "$B5B_ERROR" = "actor_self" ]; then
  fail "B5.2-distinct-not-self" "distinct actors wrongly got actor_self"
else
  ok "B5.2-distinct-not-self"
fi

# ---------- summary ----------
printf '\n=== summary ===\n'
printf 'Passed: %d\nFailed: %d\nSkipped: %d\n' "$PASSED" "$FAILED" "$SKIPPED"
if [ "$FAILED" -gt 0 ]; then
  printf '\nFailures:\n'
  for e in "${ERRORS[@]}"; do
    printf '  - %s\n' "$e"
  done
  exit 1
fi
printf 'All gates passed.\n'
exit 0
