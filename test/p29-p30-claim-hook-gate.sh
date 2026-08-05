#!/usr/bin/env bash
# p29-p30-claim-hook-gate.sh — the PreToolUse write guard must deny ONLY a real
# lease conflict, and must never claim a project it has no business governing.
#
# WHY THIS GATE EXISTS (both found live, blocking the captain, 2026-08-04):
#
#   P29  `claim` has THREE documented outcomes — 0 = I hold it, 1 = someone else
#        holds a FRESH lease, 2 = no identity. claim-hook treated every non-zero
#        as case 1, so rc=2 (no identity) came back as
#          "another agent holds a fresh write-lease on this file (<path>)"
#        while `stitchpad claims` printed "(no active claims)". The named holder
#        was `${holder:-$fp}` degrading to the file's own path — the message
#        accused the file of holding itself. Every Edit in the session was denied.
#
#   P30  The hook's pad walk-up ran to "/", found $HOME/.stitchpad, and declared
#        EVERY directory under the operator's home to be inside that pad —
#        including a worktree that correctly has no pad. That is the opposite of
#        the fail-open intent stated in the hook's own comment.
#
#   G1  rc=2 (no identity)            -> ALLOW   (never accuse)
#   G2  rc=1 (foreign fresh lease)    -> DENY
#   G3  rc=0 (lease is mine)          -> ALLOW
#   G4  the denial names the REAL holder, not the target path
#   G5  a pad-less project nested under a padded $HOME -> ALLOW  (P30)
#   G6  MUTANT: non-zero == deny      -> G1 flips to DENY
#   G7  MUTANT: unbounded walk        -> G5 flips to DENY
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/p29-claimhook.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# Run claim-hook exactly the way Claude Code does: PreToolUse JSON on stdin.
# Empty stdout == allow; a permissionDecision:deny object == deny.
hook() { # $1=tool root  $2=cwd  $3=file_path  [$4=STITCHPAD_NAME]
  local tool="$1" cwd="$2" fp="$3" who="${4:-}"
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"cwd":"%s","session_id":"p29"}' "$fp" "$cwd" \
  | env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_ENV -u HERDR_SOCKET_PATH -u HERDR_WORKSPACE_ID \
        -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u STITCHPAD_SESSION \
        HOME="$FAKE_HOME" STITCHPAD_HOME="$tool" STITCHPAD_NAME="$who" \
        STITCHPAD_TERMINAL_NAMESPACE="p29gate" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        bash "$tool/bin/stitchpad" claim-hook 2>/dev/null
}
denied() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }

# Plant a FRESH lease held by somebody else, in the real on-disk format:
#   .state/claims/<encoded-abs-path>.d/holder  <=  "<name> <epoch> <abspath>"
plant_foreign_lease() { # $1=pad dir  $2=abs file  $3=holder name
  local enc lockd real
  # `claim` normalises with `cd "$(dirname)" && pwd`, which on macOS resolves
  # /var -> /private/var. Encode the SAME string or the lease is invisible.
  real="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
  enc="$(printf '%s' "$real" | tr '/' '_' | tr -cd '[:alnum:]_.-')"
  lockd="$1/.state/claims/$enc.d"
  mkdir -p "$lockd"
  printf '%s %s %s\n' "$3" "$(date +%s)" "$2" > "$lockd/holder"
}

echo "=== P29/P30: claim-hook write guard ==="
echo ""

# ── fixture: a padded project, plus a padded $HOME with a pad-less project ──
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"
PROJ="$TMP/proj"; mkdir -p "$PROJ"
( cd "$PROJ" && env -u HERDR_PANE_ID HOME="$FAKE_HOME" STITCHPAD_HOME="$ROOT/tool" \
    STITCHPAD_NAME=alice STITCHPAD_TERMINAL_NAMESPACE=p29gate \
    "$ROOT/tool/bin/stitchpad" init --name p29proj >/dev/null 2>&1 ) || true
PAD="$PROJ/.stitchpad"
TARGET="$PROJ/shared.txt"; echo x > "$TARGET"

[ -d "$PAD" ] || { echo "FIXTURE FAILED: no pad at $PAD" >&2; exit 1; }

# ── G1: no identity (claim rc=2) must ALLOW ─────────────────────────────────
out="$(hook "$ROOT/tool" "$PROJ" "$TARGET" "")"
if denied "$out"; then
  bad "G1: rc=2 (no identity) was DENIED — the phantom-agent accusation is back"
else
  ok "G1: rc=2 (no identity) allows the write"
fi

# ── G2/G4: a REAL foreign lease must DENY, and name the real holder ─────────
plant_foreign_lease "$PAD" "$TARGET" "bob"
out="$(hook "$ROOT/tool" "$PROJ" "$TARGET" "alice")"
if denied "$out"; then
  ok "G2: a fresh lease held by another agent is DENIED"
  if printf '%s' "$out" | grep -q 'bob'; then
    ok "G4: the denial names the real holder (@bob)"
  else
    bad "G4: denial does not name the holder — it said: $(printf '%s' "$out" | head -c 160)"
  fi
else
  bad "G2: a genuine lease conflict was ALLOWED — the guard does not guard"
fi
rm -rf "$PAD/.state/claims"

# ── G3: my own lease must ALLOW ─────────────────────────────────────────────
plant_foreign_lease "$PAD" "$TARGET" "alice"
out="$(hook "$ROOT/tool" "$PROJ" "$TARGET" "alice")"
if denied "$out"; then
  bad "G3: my own lease was DENIED"
else
  ok "G3: a lease I already hold allows the write"
fi
rm -rf "$PAD/.state/claims"

# ── G5 (P30): pad-less project under a PADDED $HOME must ALLOW ──────────────
# This is the shape that broke the captain: the worktree correctly has no pad,
# but the walk climbed into $HOME and governed it from there.
( cd "$FAKE_HOME" && env -u HERDR_PANE_ID HOME="$FAKE_HOME" STITCHPAD_HOME="$ROOT/tool" \
    STITCHPAD_NAME=alice STITCHPAD_TERMINAL_NAMESPACE=p29home \
    "$ROOT/tool/bin/stitchpad" init --name p29home >/dev/null 2>&1 ) || true
[ -d "$FAKE_HOME/.stitchpad" ] || { echo "FIXTURE FAILED: no pad at \$HOME" >&2; exit 1; }
NOPAD="$FAKE_HOME/nested/project"; mkdir -p "$NOPAD"; echo y > "$NOPAD/file.txt"
[ -d "$NOPAD/.stitchpad" ] && { echo "FIXTURE FAILED: nested project must have NO pad" >&2; exit 1; }

# Give the HOME pad a fresh lease on the nested file, held by someone else, and
# use a real identity — so if the walk reaches $HOME the hook MUST deny. Passing
# here therefore proves the walk stopped, not merely that identity was missing.
plant_foreign_lease "$FAKE_HOME/.stitchpad" "$NOPAD/file.txt" "bob"
out="$(hook "$ROOT/tool" "$NOPAD" "$NOPAD/file.txt" "alice")"
if denied "$out"; then
  bad "G5: a pad-less project under a padded \$HOME was DENIED — the walk escaped again"
else
  ok "G5: a pad-less project under a padded \$HOME allows the write (walk stopped at \$HOME)"
fi

# ── mutants ─────────────────────────────────────────────────────────────────
mutate() { # $1=dest tool root  $2=old  $3=new  $4=label → 0 applied, 1 not
  cp -R "$ROOT/tool" "$1"
  python3 - "$1/bin/stitchpad" "$2" "$3" <<'PY_MUT'
import sys
p,old,new=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p,encoding='utf-8').read()
if s.count(old)!=1: sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY_MUT
}

# G6: restore "any non-zero means someone else holds it"
if mutate "$TMP/mut-rc" \
   '[ "$_claim_rc" -ne 1 ] && exit 0   # no identity / internal error → FAIL OPEN, never accuse' \
   ': # MUTANT: fail-open removed' "G6"; then
  out="$(hook "$TMP/mut-rc" "$PROJ" "$TARGET" "")"
  if denied "$out"; then
    ok "G6: MUTANT (non-zero == deny) resurfaces the phantom accusation — gate bites"
  else
    bad "G6: MUTANT applied but G1 still allowed — this gate cannot see the defect"
  fi
else
  bad "G6: MUTANT DID NOT APPLY — inconclusive, never treat as a pass"
fi

# G7: restore the unbounded walk
if mutate "$TMP/mut-walk" \
   '      if [ -n "$_home_real" ] && [ "$_d" = "$_home_real" ] && [ "$_start" != "$_home_real" ]; then break; fi' \
   '      : # MUTANT: boundary removed' "G7"; then
  # same identity as G5 — otherwise claim exits 2 and fails open for the OTHER
  # reason, and the mutant would look harmless.
  out="$(hook "$TMP/mut-walk" "$NOPAD" "$NOPAD/file.txt" "alice")"
  if denied "$out"; then
    ok "G7: MUTANT (unbounded walk) governs a pad-less project again — gate bites"
  else
    bad "G7: MUTANT applied but G5 still allowed — this gate cannot see the escape"
  fi
else
  bad "G7: MUTANT DID NOT APPLY — inconclusive, never treat as a pass"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
