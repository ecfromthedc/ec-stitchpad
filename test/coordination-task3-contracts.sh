#!/bin/bash
# coordination-task3-contracts.sh — regression gates for TASK-3: assignment
# artifact contracts and false-terminal detection. Bash 3.2 compatible.
# Isolated mktemp fixtures. No network. No side effects outside owned paths.
#
# Contract under test (EC roadmap TASK-3):
#   1. A contract (expected commit/report/sidecar) recorded at dispatch is
#      persisted as facts.contract.
#   2. Terminal completion without its contracted artifacts is flagged
#      false_terminal — sticky, never erased.
#   3. Zero-duration completions (provider row started_at == finished_at,
#      the 2026-08-02 zero-run signature) are refused as completion evidence.
#   4. Satisfaction is verified by existence + series-sidecar checksum and
#      git object existence — never by seat claim.
#
# Harness mirrors the sliceB pattern: review create self-refuses at this base
# (root_replaced), so `created` fixtures are fabricated with the verifier's
# own record functions; contract ingestion and every behavior under test are
# driven through the REAL CLI (bind/refresh/status/close).
set -uo pipefail

# ---------- helpers ----------
COORD_SH="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../tool/bin" && pwd)/coordination.sh"
COORD_VERIFY="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../tool/bin" && pwd)/coordination_verify.py"
COORD_VERIFY_DIR="$(dirname "$COORD_VERIFY")"
PYTHON_BIN="${STITCHPAD_COORD_PYTHON:-python3}"
PASSED=0
FAILED=0
declare -a ERRORS=()

ok()   { PASSED=$((PASSED + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); ERRORS+=("$1: $2"); printf '  FAIL %s: %s\n' "$1" "$2" >&2; }
check(){ # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  echo "initial" > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -m "initial" -q
}

setup_test_root() {
  # The coordination test hook hard-requires the fixture root directly
  # beneath /private/tmp (canonicalized, no-follow, component-trusted —
  # DEFAULT_PAYLOAD_BASE_PARENT in coordination_verify.py). This mirrors the
  # sealed sliceB harness exactly.
  local root
  root="$(mktemp -d /private/tmp/coord-task3-test.XXXXXXXX)"
  chmod 700 "$root"
  touch "$root/TEST_MODE_V1"
  chmod 600 "$root/TEST_MODE_V1"
  echo "$root"
}

json_field() {
  printf '%s' "$1" | "$PYTHON_BIN" -c \
    'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit(0)
v = d
for part in sys.argv[1].split("."):
    if not isinstance(v, dict):
        v = ""; break
    v = v.get(part, "")
print("" if v is None else v)' "$2" 2>/dev/null
}

json_has_blocker() {
  printf '%s' "$1" | "$PYTHON_BIN" -c \
    'import json,sys
d = json.load(sys.stdin)
print("yes" if any(sys.argv[1] in b for b in (d.get("blockers") or [])) else "no")' "$2" 2>/dev/null
}

# acquire WORKTREE ACTOR — lease acquire (fixture realism + repo_id).
acquire() {
  local worktree="$1" actor="$2" token_file err_file rc=0 out
  token_file="$(mktemp "$TMPDIR/acquire-token.XXXXXXXX")"
  err_file="$(mktemp "$TMPDIR/acquire-err.XXXXXXXX")"
  exec 9>"$token_file"
  out="$("$COORD_SH" lease acquire --worktree "$worktree" --actor "$actor" \
    --base "$(git -C "$worktree" rev-parse HEAD)" --token-out-fd 9 2>"$err_file")" || rc=$?
  exec 9>&-
  rm -f "$token_file" "$err_file"
  [ "$rc" -eq 0 ] || { fail "acquire-$actor" "lease acquire rc=$rc: $out"; return 1; }
}

# fabricate_created REPO — publish a created (pre-bind) review fixture.
# Globals: FAB_ID FAB_PAYLOAD
fabricate_created() {
  local rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/fab-err.XXXXXXXX")"
  out="$("$PYTHON_BIN" -B "$FAB_DRIVER" "$1" "$2" 2>"$err_file")" || rc=$?
  FAB_ERR="$(cat "$err_file")"
  rm -f "$err_file"
  if [ "$rc" -eq 0 ]; then
    FAB_ID="$(json_field "$out" review_id)"
  else
    FAB_ID=""
    fail "fabricate_created" "rc=$rc: $FAB_ERR"
  fi
}

# review_bind ID WORKDIR [contract env set by caller]
# Globals: RB_RC RB_OUT RB_ERR
review_bind() {
  local id="$1" workdir="$2" rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/rb-err.XXXXXXXX")"
  out="$(cd "$workdir" && STITCHPAD_MODEL=k3 "$COORD_SH" review bind "$id" \
    --session "$T_SESSION" --request "$T_REQUEST" --json 2>"$err_file")" || rc=$?
  RB_RC=$rc; RB_OUT="$out"; RB_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# review_refresh ID ROWS_FILE WORKDIR
# Globals: RF_RC RF_OUT RF_ERR
review_refresh() {
  local id="$1" rows_file="$2" workdir="$3" rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/rf-err.XXXXXXXX")"
  exec 7<"$rows_file"
  out="$(cd "$workdir" && "$COORD_SH" review refresh "$id" \
    --provider-rows-fd 7 --json 2>"$err_file")" || rc=$?
  exec 7<&-
  RF_RC=$rc; RF_OUT="$out"; RF_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# review_status ID WORKDIR
# Globals: RS_RC RS_OUT RS_ERR
review_status() {
  local id="$1" workdir="$2" rc=0 out err_file
  err_file="$(mktemp "$TMPDIR/rs-err.XXXXXXXX")"
  out="$(cd "$workdir" && "$COORD_SH" review status "$id" --json 2>"$err_file")" || rc=$?
  RS_RC=$rc; RS_OUT="$out"; RS_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# rows FILE STATE [extra json fragment]
rows_file() {
  local f="$1" state="$2" extra="${3:-}"
  printf '[{"request":"%s","session":"%s","state":"%s","model":"k3","provider":"ocean"%s}]\n' \
    "$T_REQUEST" "$T_SESSION" "$state" "$extra" > "$f"
}

# make_artifacts DIR — write report.md + valid series sidecar; prints
# "<report> <sidecar> <sidecar_digest>".
make_artifacts() {
  local dir="$1" rep side digest
  mkdir -p "$dir"
  rep="$dir/report.md"; side="$dir/report.md.sha256"
  printf '# sealed report\nverdict: HELD\n' > "$rep"
  ( cd "$dir" && shasum -a 256 report.md > report.md.sha256 )
  digest="$(shasum -a 256 "$side" | awk '{print $1}')"
  printf '%s %s %s\n' "$rep" "$side" "$digest"
}

# fresh_review LABEL — make repo+lease+created fixture, bind with caller-set
# STITCHPAD_CONTRACT_* env. Globals: RV_ID RV_REPO
T_SESSION="11111111111111111111111111111111"
T_REQUEST="22222222222222222222222222222222"
RV_N=0
fresh_review() {
  RV_N=$((RV_N + 1))
  RV_REPO="$TMPDIR/repo-$1-$RV_N"
  make_repo "$RV_REPO"
  acquire "$RV_REPO" "t3-author-$RV_N"
  fabricate_created "$RV_REPO" "$(head_oid "$RV_REPO")"
  review_bind "$FAB_ID" "$RV_REPO"
  RV_ID="$FAB_ID"
  if [ "$RB_RC" -ne 0 ]; then fail "bind-$1" "rc=$RB_RC: $RB_OUT $RB_ERR"; fi
}
head_oid() { git -C "$1" rev-parse HEAD; }

# ---------- preamble ----------
printf '\n=== coordination-task3-contracts.sh: TASK-3 contract gates ===\n'
printf 'Date: %s\n' "$(date)"
printf 'Coordination: %s\n' "$COORD_SH"

FIXTURE="$(setup_test_root)"
TMPDIR="$FIXTURE/tmp"
PAYLOAD_BASE="$FIXTURE/payloads"
mkdir -p "$TMPDIR" "$PAYLOAD_BASE"
chmod 700 "$TMPDIR" "$PAYLOAD_BASE"
export STITCHPAD_COORD_TEST_ROOT="$FIXTURE"
export STITCHPAD_COORD_TEST_PAYLOAD_BASE="$PAYLOAD_BASE"
export TMPDIR
unset STITCHPAD_SESSION STITCHPAD_REQUEST STITCHPAD_MODEL STITCHPAD_WORKTREE 2>/dev/null || true
unset STITCHPAD_CONTRACT_COMMIT STITCHPAD_CONTRACT_REPORT \
      STITCHPAD_CONTRACT_SIDECAR STITCHPAD_CONTRACT_SIDECAR_DIGEST 2>/dev/null || true
cleanup() {
  local rc=$?
  [ -n "${FIXTURE:-}" ] && [ -d "$FIXTURE" ] && rm -rf "$FIXTURE"
  exit $rc
}
trap cleanup EXIT
printf 'Fixture root: %s\n' "$FIXTURE"

# ---------- fabricator driver (created fixtures only) ----------
FAB_DIR="$TMPDIR/fab"; mkdir -p "$FAB_DIR"
FAB_DRIVER="$FAB_DIR/fabricate.py"
cat > "$FAB_DRIVER" <<'PYEOF'
#!/usr/bin/env python3
"""TASK-3 fixture fabricator: publish a created (pre-bind) review.
usage: fabricate.py REPO COMMIT
Prints one JSON line: review_id, payload_path.
Mirrors the sliceB/gate-13 fabrication pattern (create self-refuses at this
base). Python 3.9 compatible.
"""
import json, os, secrets, subprocess, sys, time

REPO, COMMIT = sys.argv[1], sys.argv[2]
VERIFY_DIR = os.environ["FAB_VERIFY_DIR"]
sys.path.insert(0, VERIFY_DIR)
import coordination_verify as cv  # noqa: E402

PAYLOAD_BASE = os.environ["STITCHPAD_COORD_TEST_PAYLOAD_BASE"]

def git(*args):
    return subprocess.check_output(
        ["git", "-C", REPO] + list(args)).decode("ascii").strip()

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
    if candidate.get("state") == "active":
        lease = candidate
        break
if lease is None:
    sys.stderr.write("no active lease in %s\n" % (REPO,))
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
    "author_actor": "t3-author",
    "reviewer_actor": "t3-reviewer",
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

# Publish the review record to the coordination state tree, plus the payload
# pointer/manifest the bound-review readers (status/refresh/close) resolve
# facts through — mirrors cmd_review_create's publication contract and the
# sliceB fabricator. Facts come from the REAL bind under test.
ZERO64 = "0" * 64
pointer = cv.new_record("pointer", 1, {
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
manifest = cv.new_record("manifest", 1, {
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
    reviews_fd = fds.keep(os.open(os.path.join(
        common, "stitchpad-coordination", "v1", "reviews"),
        os.O_RDONLY | os.O_DIRECTORY))
    cv.publish_record(fds, reviews_fd, review_id, "review", review,
                      "review record")
    payload_fd = fds.keep(os.open(payload_path,
                                  os.O_RDONLY | os.O_DIRECTORY))
    cv.publish_flat_record(payload_fd, "pointer.json", "pointer", pointer,
                           "review pointer")
    cv.publish_flat_record(payload_fd, "manifest.json", "manifest", manifest,
                           "review manifest")
finally:
    fds.close_all()
print(json.dumps({"review_id": review_id, "payload_path": payload_path}))
PYEOF
export FAB_VERIFY_DIR="$COORD_VERIFY_DIR"

printf '\n--- T3.1/T3.2: contract recorded at dispatch (bind ingestion) ---\n'
ART="$FIXTURE/artifacts"
read -r REP SIDE SIDE_DIGEST <<EOF
$(make_artifacts "$ART")
EOF
COMMIT_SHA=""
STITCHPAD_CONTRACT_REPORT="$REP" STITCHPAD_CONTRACT_SIDECAR="$SIDE" \
STITCHPAD_CONTRACT_SIDECAR_DIGEST="$SIDE_DIGEST" \
  fresh_review full-contract
if [ "$RB_RC" -eq 0 ]; then
  COMMIT_SHA="$(head_oid "$RV_REPO")"
  review_status "$RV_ID" "$RV_REPO"
  check 'T3.1 contract.report persisted' "$REP" "$(json_field "$RS_OUT" contract.report)"
  check 'T3.1 contract.sidecar persisted' "$SIDE" "$(json_field "$RS_OUT" contract.sidecar)"
  check 'T3.1 contract.sidecar_digest persisted' "$SIDE_DIGEST" \
    "$(json_field "$RS_OUT" contract.sidecar_digest)"
else
  fail 'T3.1 bind with contract env' "$RB_OUT $RB_ERR"
fi

fresh_review no-contract
if [ "$RB_RC" -eq 0 ]; then
  review_status "$RV_ID" "$RV_REPO"
  check 'T3.2 no contract env: contract null' "" "$(json_field "$RS_OUT" contract)"
  check 'T3.2 false_terminal default false' "False" "$(json_field "$RS_OUT" false_terminal)"
fi

printf '\n--- T3.3/T3.4: terminal completion vs contract ---\n'
# Satisfied contract: completed + report + valid sidecar → clean terminal.
STITCHPAD_CONTRACT_REPORT="$REP" STITCHPAD_CONTRACT_SIDECAR="$SIDE" \
  fresh_review satisfied
rows_file "$TMPDIR/rows-completed.json" completed
review_refresh "$RV_ID" "$TMPDIR/rows-completed.json" "$RV_REPO"
if [ "$RF_RC" -ne 0 ]; then fail 'T3.3 refresh' "$RF_OUT $RF_ERR"; fi
review_status "$RV_ID" "$RV_REPO"
check 'T3.3 satisfied contract: no false_terminal' "False" "$(json_field "$RS_OUT" false_terminal)"
check 'T3.3 satisfied contract: completion recorded' "completed" \
  "$(json_field "$RS_OUT" terminal_completion)"

# Unsatisfied contract: report missing at terminal → sticky false_terminal.
STITCHPAD_CONTRACT_REPORT="$FIXTURE/artifacts-absent/report.md" \
STITCHPAD_CONTRACT_SIDECAR="$FIXTURE/artifacts-absent/report.md.sha256" \
  fresh_review missing-report
rows_file "$TMPDIR/rows-completed2.json" completed
review_refresh "$RV_ID" "$TMPDIR/rows-completed2.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
check 'T3.4 terminal without artifacts: false_terminal' "True" \
  "$(json_field "$RS_OUT" false_terminal)"
case "$(json_field "$RS_OUT" false_terminal_reason)" in
  *contract_report_missing*contract_sidecar_missing*|*contract_sidecar_missing*contract_report_missing*)
    ok 'T3.4 reason names missing artifacts' ;;
  *) fail 'T3.4 reason names missing artifacts' \
       "got [$(json_field "$RS_OUT" false_terminal_reason)]" ;;
esac
# Stickiness: produce the artifacts LATER, refresh again — flag must survive.
make_artifacts "$FIXTURE/artifacts-absent" >/dev/null
review_refresh "$RV_ID" "$TMPDIR/rows-completed2.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
check 'T3.4 false_terminal is sticky (never erased)' "True" \
  "$(json_field "$RS_OUT" false_terminal)"

printf '\n--- T3.5/T3.6/T3.7: sidecar checksum semantics ---\n'
# Malformed sidecar (exists, but not series format).
BAD_ART="$FIXTURE/artifacts-bad"
mkdir -p "$BAD_ART"
printf '# report\n' > "$BAD_ART/report.md"
printf 'not-a-digest sidecar\n' > "$BAD_ART/report.md.sha256"
STITCHPAD_CONTRACT_REPORT="$BAD_ART/report.md" \
STITCHPAD_CONTRACT_SIDECAR="$BAD_ART/report.md.sha256" \
  fresh_review malformed-sidecar
rows_file "$TMPDIR/rows-completed3.json" completed
review_refresh "$RV_ID" "$TMPDIR/rows-completed3.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
case "$(json_field "$RS_OUT" false_terminal_reason)" in
  *contract_sidecar_malformed*) ok 'T3.5 malformed sidecar flagged' ;;
  *) fail 'T3.5 malformed sidecar flagged' \
       "got [$(json_field "$RS_OUT" false_terminal_reason)]" ;;
esac

# Seat-claim forgery: report rewritten AFTER the sidecar was sealed.
FORGE_ART="$FIXTURE/artifacts-forge"
read -r FREP FSIDE FDIGEST <<EOF
$(make_artifacts "$FORGE_ART")
EOF
printf '# TAMPERED report — seat claims success anyway\n' >> "$FREP"
STITCHPAD_CONTRACT_REPORT="$FREP" STITCHPAD_CONTRACT_SIDECAR="$FSIDE" \
  fresh_review forged-report
rows_file "$TMPDIR/rows-completed4.json" completed
review_refresh "$RV_ID" "$TMPDIR/rows-completed4.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
case "$(json_field "$RS_OUT" false_terminal_reason)" in
  *contract_report_digest_mismatch*) ok 'T3.6 tampered report caught by sidecar checksum (never seat claim)' ;;
  *) fail 'T3.6 tampered report caught by sidecar checksum (never seat claim)' \
       "got [$(json_field "$RS_OUT" false_terminal_reason)]" ;;
esac

# sidecar_digest pin mismatch (contract pins sidecar bytes).
STITCHPAD_CONTRACT_REPORT="$REP" STITCHPAD_CONTRACT_SIDECAR="$SIDE" \
STITCHPAD_CONTRACT_SIDECAR_DIGEST="0000000000000000000000000000000000000000000000000000000000000000" \
  fresh_review sidecar-digest-pin
rows_file "$TMPDIR/rows-completed5.json" completed
review_refresh "$RV_ID" "$TMPDIR/rows-completed5.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
case "$(json_field "$RS_OUT" false_terminal_reason)" in
  *contract_sidecar_digest_mismatch*) ok 'T3.7 sidecar_digest pin mismatch flagged' ;;
  *) fail 'T3.7 sidecar_digest pin mismatch flagged' \
       "got [$(json_field "$RS_OUT" false_terminal_reason)]" ;;
esac

printf '\n--- T3.8..T3.11: zero-duration refusal ---\n'
# Zero-duration (integer epoch equality — the 2026-08-02 zero-run signature).
fresh_review zero-run
rows_file "$TMPDIR/rows-zero.json" completed ',"started_at":1785729000,"finished_at":1785729000'
review_refresh "$RV_ID" "$TMPDIR/rows-zero.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
check 'T3.8 zero-duration: completion refused as false_terminal' "false_terminal" \
  "$(json_field "$RS_OUT" terminal_completion)"
check 'T3.8 zero-duration: reason' "zero_duration" "$(json_field "$RS_OUT" false_terminal_reason)"
check 'T3.8 zero-duration: flag sticky field' "True" "$(json_field "$RS_OUT" false_terminal)"

# Float equality also caught.
fresh_review zero-run-float
rows_file "$TMPDIR/rows-zerof.json" completed ',"started_at":1785729000.5,"finished_at":1785729000.5'
review_refresh "$RV_ID" "$TMPDIR/rows-zerof.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
check 'T3.9 float zero-duration refused' "zero_duration" "$(json_field "$RS_OUT" false_terminal_reason)"

# Non-zero duration with satisfied contract: NOT flagged (no false positives).
fresh_review honest-duration
rows_file "$TMPDIR/rows-honest.json" completed ',"started_at":1785729000,"finished_at":1785729123'
review_refresh "$RV_ID" "$TMPDIR/rows-honest.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
check 'T3.10 non-zero duration not flagged' "False" "$(json_field "$RS_OUT" false_terminal)"
check 'T3.10 non-zero duration completion kept' "completed" \
  "$(json_field "$RS_OUT" terminal_completion)"

# Non-numeric duration fields: ignored (no crash, no flag).
fresh_review nonnumeric-duration
rows_file "$TMPDIR/rows-nonstr.json" completed ',"started_at":"soon","finished_at":"done"'
review_refresh "$RV_ID" "$TMPDIR/rows-nonstr.json" "$RV_REPO"
check 'T3.11 non-numeric duration fields ignored' "0" "$RF_RC"
review_status "$RV_ID" "$RV_REPO"
check 'T3.11 non-numeric: not flagged' "False" "$(json_field "$RS_OUT" false_terminal)"

printf '\n--- T3.12..T3.14: contracted commit verification ---\n'
STITCHPAD_CONTRACT_COMMIT="not-a-hex-sha" fresh_review bad-commit-shape
rows_file "$TMPDIR/rows-c1.json" completed
review_refresh "$RV_ID" "$TMPDIR/rows-c1.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
case "$(json_field "$RS_OUT" false_terminal_reason)" in
  *contract_commit_invalid*) ok 'T3.12 non-hex contract commit flagged' ;;
  *) fail 'T3.12 non-hex contract commit flagged' \
       "got [$(json_field "$RS_OUT" false_terminal_reason)]" ;;
esac

STITCHPAD_CONTRACT_COMMIT="ffffffffffffffffffffffffffffffffffffffff" \
  fresh_review absent-commit
rows_file "$TMPDIR/rows-c2.json" completed
review_refresh "$RV_ID" "$TMPDIR/rows-c2.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
case "$(json_field "$RS_OUT" false_terminal_reason)" in
  *contract_commit_missing*) ok 'T3.13 commit absent from object store flagged' ;;
  *) fail 'T3.13 commit absent from object store flagged' \
       "got [$(json_field "$RS_OUT" false_terminal_reason)]" ;;
esac

# Commit that IS the review's own repo HEAD: satisfied. The contract must be
# bound against the SAME repo the review is bound to — fresh_review builds a
# brand-new repo per call, so capture the HEAD first and bind explicitly.
RV_N=$((RV_N + 1))
RV_REPO="$TMPDIR/repo-real-commit-$RV_N"
make_repo "$RV_REPO"
acquire "$RV_REPO" "t3-author-$RV_N"
fabricate_created "$RV_REPO" "$(head_oid "$RV_REPO")"
STITCHPAD_CONTRACT_COMMIT="$(head_oid "$RV_REPO")" review_bind "$FAB_ID" "$RV_REPO"
RV_ID="$FAB_ID"
if [ "$RB_RC" -ne 0 ]; then fail 'bind-real-commit' "$RB_OUT $RB_ERR"; fi
rows_file "$TMPDIR/rows-c3.json" completed
review_refresh "$RV_ID" "$TMPDIR/rows-c3.json" "$RV_REPO"
review_status "$RV_ID" "$RV_REPO"
check 'T3.14 existing contract commit: no false_terminal' "False" \
  "$(json_field "$RS_OUT" false_terminal)"

printf '\n--- T3.15: closure refuses false_terminal ---\n'
# A false_terminal review must never close; refusal names the blocker.
fresh_review close-guard
rows_file "$TMPDIR/rows-cg.json" completed ',"started_at":9,"finished_at":9'
review_refresh "$RV_ID" "$TMPDIR/rows-cg.json" "$RV_REPO"
out="$(cd "$RV_REPO" && "$COORD_SH" review close "$RV_ID" --verified --json 2>/dev/null)"
CG_RC=$?
CG_CODE="$(json_field "$out" error)"
if [ "$CG_RC" -ne 0 ] && [ "$CG_CODE" = "closure_blocked" ]; then
  case "$(json_field "$out" detail)" in
    *'false_terminal:zero_duration'*)
      ok 'T3.15 closure blocked with false_terminal:<reason> blocker' ;;
    *)
      fail 'T3.15 closure blocked with false_terminal:<reason> blocker' \
        "detail missing blocker: $(json_field "$out" detail)" ;;
  esac
else
  fail 'T3.15 closure blocked with false_terminal:<reason> blocker' \
    "rc=$CG_RC code=$CG_CODE out=$(printf '%s' "$out" | head -c 200)"
fi

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
  printf '\nFailures:\n'
  for e in "${ERRORS[@]}"; do printf '  - %s\n' "$e"; done
  printf '\nSome TASK-3 gates FAILED.\n'
  exit 1
fi
printf '\nAll TASK-3 gates PASSED.\n'
exit 0
