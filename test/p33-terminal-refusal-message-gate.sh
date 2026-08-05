#!/usr/bin/env bash
# p33-terminal-refusal-message-gate.sh — the one-terminal-one-pad refusal must
# name the axis that ACTUALLY differs.
#
# WHAT WENT WRONG: sp_term_lock_check() refuses when the pad OR the name differs
# (lib.sh), but the refusal text only ever talked about the pad:
#     "REFUSED — this terminal is bound to <PATH> (as @fable), not <PATH>."
# On an identity mismatch both halves are the SAME PATH, so the operator is told
# a pad differs from itself. The message named a cause that was not the cause.
#
# It is not cosmetic. Three suites were dying inside `>/dev/null 2>&1` blocks and
# this message was the only clue; rewriting it to say "claimed by @fable, but you
# are @operator" is what located P34 and recovered ~30 assertions in one pass.
#
#   G1  identity mismatch  -> names BOTH identities and says the identity differs
#   G2  identity mismatch  -> never prints the same path twice
#   G3  pad mismatch       -> still names both pads and points at the other one
#   G4  MUTANT: restore the single pad-only message -> G1/G2 go RED
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/p33-refusal.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# Every path printed twice in one message is the exact defect — count duplicates.
dup_path() { printf '%s' "$1" | grep -oE '/[^ ()]*/\.stitchpad' | sort | uniq -d | head -1; }

# $1=tool root $2=namespace $3=cwd $4=identity  → whatever `say` printed
say_as() {
  ( cd "$3" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_ENV -u HERDR_SOCKET_PATH \
      -u HERDR_WORKSPACE_ID -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID \
      HOME="$TMP/home" STITCHPAD_HOME="$1" STITCHPAD_SESSION="p33sess" \
      STITCHPAD_TERMINAL_NAMESPACE="$2" STITCHPAD_NAME="$4" \
      STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$1/bin/stitchpad" say "probe from $4" 2>&1 ) || true
}
join_as() {
  ( cd "$3" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_ENV -u HERDR_SOCKET_PATH \
      -u HERDR_WORKSPACE_ID -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID \
      HOME="$TMP/home" STITCHPAD_HOME="$1" STITCHPAD_SESSION="p33sess" \
      STITCHPAD_TERMINAL_NAMESPACE="$2" STITCHPAD_NAME="$4" \
      STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$1/bin/stitchpad" join "$4" claude pull - >/dev/null 2>&1 ) || true
}
init_pad() {
  ( cd "$2" && env -u HERDR_PANE_ID HOME="$TMP/home" STITCHPAD_HOME="$1" \
      STITCHPAD_NAME=setup STITCHPAD_TERMINAL_NAMESPACE=p33setup \
      STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$1/bin/stitchpad" init --name "$3" >/dev/null 2>&1 ) || true
}

mkdir -p "$TMP/home"

echo "=== P33: terminal refusal message ==="
echo ""

run_cases() { # $1=tool root, $2=namespace suffix → sets IDENT_MSG and PAD_MSG
  local tool="$1" sfx="$2" A B
  A="$TMP/padA-$sfx"; B="$TMP/padB-$sfx"; mkdir -p "$A" "$B"
  init_pad "$tool" "$A" "p33a$sfx"
  init_pad "$tool" "$B" "p33b$sfx"
  # one terminal surface claims pad A as @fable
  join_as "$tool" "term-$sfx" "$A" fable
  # same surface, same pad, DIFFERENT identity  → identity axis
  IDENT_MSG="$(say_as "$tool" "term-$sfx" "$A" operator)"
  # same surface, DIFFERENT pad                 → pad axis
  PAD_MSG="$(say_as "$tool" "term-$sfx" "$B" fable)"
}

run_cases "$ROOT/tool" fix

if printf '%s' "$IDENT_MSG" | grep -q 'REFUSED'; then
  if printf '%s' "$IDENT_MSG" | grep -qi 'IDENTITY differs' \
     && printf '%s' "$IDENT_MSG" | grep -q 'fable' \
     && printf '%s' "$IDENT_MSG" | grep -q 'operator'; then
    ok "G1: identity mismatch names both identities and the identity axis"
  else
    bad "G1: identity mismatch did not name the axis: $(printf '%s' "$IDENT_MSG" | head -1)"
  fi
  d="$(dup_path "$IDENT_MSG")"
  if [ -z "$d" ]; then
    ok "G2: identity mismatch never prints the same path twice"
  else
    bad "G2: the same path is printed twice ($d) — 'bound to X ... not X' is back"
  fi
else
  bad "G1: no refusal at all — the terminal guard did not engage (fixture broken)"
  bad "G2: skipped, no refusal to inspect"
fi

if printf '%s' "$PAD_MSG" | grep -q 'REFUSED' && printf '%s' "$PAD_MSG" | grep -q 'bound to'; then
  if [ -z "$(dup_path "$PAD_MSG")" ]; then
    ok "G3: pad mismatch names two DIFFERENT pads"
  else
    bad "G3: pad mismatch printed the same pad twice"
  fi
else
  bad "G3: pad mismatch produced no 'bound to' refusal: $(printf '%s' "$PAD_MSG" | head -1)"
fi

# ── G4: MUTANT — put the pad-only message back ─────────────────────────────
MUT="$TMP/mut-tool"
cp -R "$ROOT/tool" "$MUT"
python3 - "$MUT/bin/stitchpad" <<'PY_MUT'
import sys
p=sys.argv[1]
s=open(p,encoding='utf-8').read()
start=s.find('        if [ "$_hpad" = "$PAD_DIR" ]; then')
if start<0: sys.exit(9)
end=s.find('        fi\n', start)
if end<0: sys.exit(9)
old=s[start:end+len('        fi\n')]
new=('        echo "stitchpad: REFUSED — this terminal is bound to $_hpad '
     '(as @$_hname), not $PAD_DIR. cd there or \'stitchpad leave\' first." >&2\n')
open(p,'w',encoding='utf-8').write(s[:start]+new+s[end+len('        fi\n'):])
PY_MUT
if [ $? -eq 0 ] && ! grep -q 'IDENTITY differs' "$MUT/bin/stitchpad"; then
  run_cases "$MUT" mut
  d="$(dup_path "$IDENT_MSG")"
  if printf '%s' "$IDENT_MSG" | grep -q 'REFUSED' && [ -n "$d" ]; then
    ok "G4: MUTANT — the pad-only message prints the same path twice again, gate bites"
  else
    bad "G4: MUTANT applied but the defect did not resurface — this gate cannot see it"
  fi
else
  bad "G4: MUTANT DID NOT APPLY — inconclusive, never treat as a pass"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
