#!/usr/bin/env bash
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
# deleted-pad-claim-lockout-gate.sh — a terminal claim naming a pad that no
# longer exists must not lock the operator out of their real pad.
#
# Found live: running `stitchpad test` claimed the lead's terminal for a fixture
# pad under $TMPDIR (as @bob). The fixture's cleanup trap deleted the directory,
# and every subsequent post to the REAL pad was refused with a remedy that could
# not be followed — "cd there" is impossible once the directory is gone, and the
# printed `stitchpad leave` is missing the <name> argument the command requires.
#
# Proves:
#   D1: a claim for a DELETED pad is not evidence (no refusal)
#   D2: a claim for a pad that still EXISTS still refuses (guard intact — this
#       is not a weakening; the cross-pad ghost post is what it exists to kill)
#   D3: the check is READ-ONLY — it must not reap the claim file itself, since
#       `say` calls it and `say` must not mutate lock state
#   D4: both refusal messages name a RUNNABLE command (`stitchpad leave <name>`
#       with the name filled in), not the bare `stitchpad leave` that a user
#       cannot run
#
set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

echo "=== deleted-pad-claim-lockout-gate ==="
echo ""
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-lockout.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

source "$ROOT/tool/bin/lib.sh" 2>/dev/null || true
type sp_term_lock_check >/dev/null 2>&1 || { echo "cannot source sp_term_lock_check"; exit 1; }

export SP_TERMDIR="$WORK/terms"; mkdir -p "$SP_TERMDIR"
export PAD_DIR="$WORK/real-pad"; mkdir -p "$PAD_DIR"
SURFACE="surface-1"
# sp_term_surface_of must resolve our fake target to itself.
sp_term_surface_of() { printf '%s' "$1"; }
# The claim must read as honored, or the guard short-circuits before the branch
# under test and every assertion below becomes vacuous.
_sp_term_claim_honored() { return 0; }

claim_for() {  # $1 = pad path recorded in the claim
  printf '%s|bob|%s\n' "$1" "$(date +%s)" > "$SP_TERMDIR/$SURFACE"
}

# D1: the claim names a pad directory that does not exist
GHOST="$WORK/deleted-fixture-pad"          # never created
claim_for "$GHOST"
if sp_term_lock_check "$SURFACE" lead >/dev/null 2>&1; then
  ok "D1: a claim naming a DELETED pad does not refuse"
else
  bad "D1: a claim naming a deleted pad still locks the operator out (the live bug)"
fi

# D3: and it did so WITHOUT reaping the file
[ -f "$SP_TERMDIR/$SURFACE" ] \
  && ok "D3: the check left the stale claim file for sp_term_lock_claim to reap" \
  || bad "D3: the check DELETED the claim file — say must not mutate lock state"

# D2: a claim naming a pad that still exists must still refuse
OTHER="$WORK/other-live-pad"; mkdir -p "$OTHER"
claim_for "$OTHER"
if sp_term_lock_check "$SURFACE" lead >/dev/null 2>&1; then
  bad "D2: a LIVE different pad no longer refuses — the ghost-post guard is gone"
else
  ok "D2: a live different pad still refuses (guard intact)"
fi

# D4: the refusal text must name a runnable command
bad_msgs=0
while IFS= read -r line; do
  case "$line" in
    *"'stitchpad leave'"*) bad_msgs=$((bad_msgs+1)) ;;
  esac
done < <(grep -n "REFUSED — this terminal is bound to\|REFUSED — @\$from is live-bound" "$ROOT/tool/bin/stitchpad")
if [ "$bad_msgs" = "0" ]; then
  ok "D4: no refusal prints the bare 'stitchpad leave' (which the CLI rejects without <name>)"
else
  bad "D4: $bad_msgs refusal message(s) still print a bare 'stitchpad leave' the user cannot run"
fi

echo ""
printf "%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
