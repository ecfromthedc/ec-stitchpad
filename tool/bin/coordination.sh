#!/bin/bash
# stitchpad coordination — Bash 3.2 front control for the durability MVP core.
#
# This script is argument-shape validation and dispatch ONLY. It never reads,
# writes, logs, or forwards a capability value: tokens travel exclusively
# through inherited file descriptors whose NUMBERS (never contents) appear on
# the command line. All exact semantics live in coordination_verify.py.
#
# Stock /bin/bash 3.2 contract: no associative arrays, mapfile, wait -n,
# namerefs, globstar, GNU flags, realpath/readlink -f, flock, setsid, /proc,
# jq, source, or eval. Indexed collections are not needed; parsing is flat.
#
#   coordination.sh lease acquire --worktree PATH --actor ACTOR --base FULL_OID --token-out-fd FD
#   coordination.sh lease status --worktree PATH [--json]
#   coordination.sh lease checkpoint --worktree PATH --token-fd FD --old FULL_OID --new FULL_OID
#   coordination.sh lease release --worktree PATH --token-fd FD --head FULL_OID
#   coordination.sh review create --repo PATH --commit FULL_OID ...
#   coordination.sh review <verb> ID [flags]
#
# Every review verb except `create` takes the review ID as the first
# POSITIONAL argument, exactly as design v5 section 2 specifies. There is no
# `--id` flag: the positional form is the frozen contract (audit P2-6).

set -uo pipefail

# Symlink-safe self-location (plain readlink only; no readlink -f).
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
BIN_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
VERIFY="$BIN_DIR/coordination_verify.py"
PYTHON_BIN="${STITCHPAD_COORD_PYTHON:-python3}"

usage() {
  cat <<'EOF'
usage: coordination.sh <area> <verb> [flags]

areas and verbs:
  lease acquire       --worktree PATH --actor ACTOR --base FULL_OID --token-out-fd FD
  lease status        --worktree PATH [--json]
  lease checkpoint    --worktree PATH --token-fd FD --old FULL_OID --new FULL_OID
  lease release       --worktree PATH --token-fd FD --head FULL_OID
  review create       --repo PATH --commit FULL_OID --author-actor A --reviewer-actor B
                      --provider ocean --process-token-out-fd FD
  review bind         ID --session UUID --request UUID
  review register-process ID --role ROLE --pid PID --process-token-fd FD
  review cancel-requested ID
  review refresh      ID --provider-rows-fd FD [--json]
  review status       ID [--json]
  review submit-report ID
  review verify       ID
  review close        ID --verified | ID --abandoned

review IDs are positional and must be exactly 32 lowercase hex characters.

capabilities travel only through inherited FDs; token values never appear in
argv, output, logs, or diagnostics. exit codes: 0 ok, 2 coordination refusal,
64 usage error.
EOF
}

die_usage() {
  printf 'coordination usage error: %s\n' "$1" >&2
  usage >&2
  exit 64
}

# Every accepted flag takes exactly one value except the boolean switches
# --json/--verified/--abandoned. Unknown flags, missing values, and stray
# positionals are usage errors; nothing reaches the helper unvalidated.
validate_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json|--verified|--abandoned)
        shift
        ;;
      --worktree|--repo|--actor|--base|--old|--new|--head|--commit|\
--author-actor|--reviewer-actor|--provider|--session|--request|--role|--pid|\
--token-fd|--token-out-fd|--process-token-fd|--process-token-out-fd|\
--provider-rows-fd)
        [ $# -ge 2 ] || die_usage "flag $1 requires a value"
        case "$2" in
          --*) die_usage "flag $1 is missing its value" ;;
        esac
        case "$1" in
          --token-fd|--token-out-fd|--process-token-fd|--process-token-out-fd|\
          --provider-rows-fd|--pid)
            case "$2" in
              ''|*[!0-9]*) die_usage "$1 must be a non-negative integer" ;;
            esac
            ;;
        esac
        shift 2
        ;;
      *)
        die_usage "unexpected argument: $1"
        ;;
    esac
  done
}

# Confirm an inherited FD is actually open in this process (best-effort front
# check via /dev/fd; the helper performs the authoritative owner/mode/type/
# offset/size validation). FD contents are never read here.
check_fd_open() {
  _fd="$1"
  [ -e "/dev/fd/$_fd" ] || die_usage "fd $_fd is not open in this process"
}

extract_fd_value() {
  # $1 = flag name, remaining args = the validated flag stream.
  _want="$1"
  shift
  while [ $# -gt 0 ]; do
    if [ "$1" = "$_want" ]; then
      printf '%s\n' "$2"
      return 0
    fi
    case "$1" in
      --json|--verified|--abandoned) shift ;;
      *) shift 2 ;;
    esac
  done
  return 1
}

area="${1:-help}"
case "$area" in
  help|--help|-h)
    usage
    exit 0
    ;;
esac
[ $# -ge 2 ] || die_usage "expected an area and a verb"
verb="$2"
shift 2

# needs_id=1 marks the verbs whose first argument is the positional review ID.
needs_id=0
case "$area/$verb" in
  lease/acquire)            pyverb="lease-acquire" ;;
  lease/status)             pyverb="lease-status" ;;
  lease/checkpoint)         pyverb="lease-checkpoint" ;;
  lease/release)            pyverb="lease-release" ;;
  review/create)            pyverb="review-create" ;;
  review/bind)              pyverb="review-bind" ;            needs_id=1 ;;
  review/register-process)  pyverb="review-register-process" ; needs_id=1 ;;
  review/cancel-requested)  pyverb="review-cancel-requested" ; needs_id=1 ;;
  review/refresh)           pyverb="review-refresh" ;         needs_id=1 ;;
  review/status)            pyverb="review-status" ;          needs_id=1 ;;
  review/submit-report)     pyverb="review-submit-report" ;   needs_id=1 ;;
  review/verify)            pyverb="review-verify" ;          needs_id=1 ;;
  review/close)             pyverb="review-close" ;           needs_id=1 ;;
  *)
    die_usage "unknown command: $area $verb"
    ;;
esac

# Frozen positional-ID contract (design v5 section 2; audit P2-6). The ID is
# shape-checked here as exactly 32 lowercase hex characters and is never a
# flag value; the helper re-validates it against ID_RE before any state read.
review_id=""
if [ "$needs_id" = "1" ]; then
  [ $# -ge 1 ] || die_usage "$area $verb requires a positional review ID"
  review_id="$1"
  case "$review_id" in
    --*) die_usage "$area $verb requires the review ID before any flag" ;;
    ''|*[!0-9a-f]*) die_usage "review ID must be exactly 32 lowercase hex characters" ;;
  esac
  if [ ${#review_id} -ne 32 ]; then
    die_usage "review ID must be exactly 32 lowercase hex characters"
  fi
  shift
fi

validate_flags "$@"

for _fdflag in --token-fd --token-out-fd --process-token-fd --process-token-out-fd --provider-rows-fd; do
  if _fdv="$(extract_fd_value "$_fdflag" "$@")"; then
    check_fd_open "$_fdv"
  fi
done

[ -f "$VERIFY" ] || die_usage "helper not found: $VERIFY"

# exec so the helper inherits the exact capability FD table and its exit code
# is the exit code the caller observes. The positional review ID, when the verb
# takes one, is passed ahead of the flags in the exact frozen order.
if [ "$needs_id" = "1" ]; then
  exec "$PYTHON_BIN" "$VERIFY" "$pyverb" "$review_id" "$@"
fi
exec "$PYTHON_BIN" "$VERIFY" "$pyverb" "$@"
