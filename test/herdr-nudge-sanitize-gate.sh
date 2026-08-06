#!/usr/bin/env bash
# herdr-nudge-sanitize-gate.sh — k3 F15: pad text is TYPED into a raw pty, so it
# must not be able to act as a command.
#
# F15 was filed UNPROVEN because it needs two things at once. This suite settles
# the half that can be settled, and removes the dependency on the other half.
#
# PROVEN by execution: `herdr pane run` types the nudge plus Enter into a raw
# pty, and the nudge is `stitchpad wake --peek` output — i.e. the message BODY,
# which is untrusted pad text. The old sanitizer stripped control bytes ONLY, so
# posting
#     @eve check $(id) and `whoami` ; echo pwned | sh && ls > /tmp/x
# produced a nudge carrying every one of those bytes intact. Handed to a shell,
# the `;` alone ran a second command (measured: "SECOND-COMMAND-RAN").
#
# NOT PROVEN, and deliberately made irrelevant: that the pane is a SHELL rather
# than an agent TUI. That is a herdr property this adapter cannot verify, so
# instead of arguing about how often an agent exits and leaves its pane at a
# prompt, the metacharacters are neutralised and the question stops mattering.
#
#   G1  the pad's words really do reach the text that gets typed
#   G2  that text carries no shell metacharacter, and a real shell handed it
#       runs nothing the pad author wrote
#   G3  ... while staying readable to the agent it is meant for
#   G4  the typed text is length-capped (pane run types it keystroke by keystroke)
#   G5  MUTANT: restore the control-bytes-only sanitizer → G2 goes RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-herdr.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT   # nothing here spawns (P9)
# The marker paths must be SHORT. With a $TMPDIR-length path the injected
# command ran past the 600-char nudge cap and was truncated mid-backquote, so
# the shell rejected the whole line and NOTHING ran — the mutant then looked
# like the sanitizer had saved us when it was the cap, accidentally.
MARKDIR="/tmp/sp-f15.$$"; mkdir -p "$MARKDIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

# A stub herdr: `agent get` returns a live unfocused pane, `pane run` records
# EXACTLY what the adapter asked to have typed. That recording is the artifact
# under test — it is what reaches the pty.
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/herdr" <<STUBEOF
#!/bin/bash
case "\$1 \$2" in
  "agent get") printf '{"result":{"agent":{"pane_id":"pane-1","focused":false,"terminal_id":"term_x"}}}\n' ;;
  "pane run")  printf '%s' "\$4" >> "$TMP/typed.txt"; printf '\n--RUN--\n' >> "$TMP/typed.txt" ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/herdr"

MENTION='@eve check $(printf %s P > '"$MARKDIR"'/m1) and `id` ; printf %s S > '"$MARKDIR"'/m2'

build_and_wake() {  # $1 = tool root, $2 = tag → leaves the typed text in $TMP/typed.txt
  local rt="$1" d="$TMP/pad.$2"
  rm -f "$TMP/typed.txt" "$MARKDIR/m1" "$MARKDIR/m2"
  mkdir -p "$d"
  ( cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="h$2-a" "$rt/bin/stitchpad" init --name "h$2" >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="h$2-a" "$rt/bin/stitchpad" join larry cli pull - >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=eve \
      STITCHPAD_TERMINAL_NAMESPACE="h$2-b" "$rt/bin/stitchpad" join eve cli pull - >/dev/null 2>&1
    cd "$d" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE="h$2-a" "$rt/bin/stitchpad" say "$MENTION" >/dev/null 2>&1 ) || true
  printf 'a mention body\n' > "$TMP/taskfile"
  ( cd "$d" && PATH="$STUB:$rt/bin:$PATH" SP_PAD_DIR="$d/.stitchpad" SP_TARGET=term_x \
      STITCHPAD_HEARTBEAT_AUTOSTART=0 /bin/bash "$rt/adapters/herdr.sh" \
        mention eve "$d/.stitchpad/stitchpad.md" "$TMP/taskfile" ) >/dev/null 2>&1 || true
}

echo "=== k3 F15: what gets typed into a pty must not be able to run ==="
echo ""

build_and_wake "$TOP/tool" 1
TYPED="$(head -1 "$TMP/typed.txt" 2>/dev/null || true)"
if [ -z "$TYPED" ]; then
  bad "INVALID PROBE — the adapter typed nothing; nothing below measures anything"
else
  case "$TYPED" in
    *check*) ok "G1 pad text really does reach the string that gets typed" ;;
    *) bad "G1 the nudge does not contain the pad text at all: $TYPED" ;;
  esac
  # G2 — the decisive one, asserted as a PROPERTY of the bytes rather than as
  # "did this particular line happen to execute". A long nudge can contain an
  # unbalanced backquote that makes sh reject the whole line, which would let a
  # dangerous string score as safe for a reason that has nothing to do with the
  # sanitizer. The invariant is simpler and always true: nothing that can act as
  # a shell operator survives into the text that gets typed.
  _meta="$(printf '%s' "$TYPED" | LC_ALL=C tr -cd '`$;|&<>()\\' || true)"
  if [ -n "$_meta" ]; then
    bad "G2 the typed text still carries live shell metacharacters [$_meta] — a pane at a shell prompt runs whatever a teammate posts"
  else
    ok "G2 the typed text carries no shell metacharacter at all"
  fi
  # ...and belt-and-braces: hand the exact bytes to a real shell and prove no
  # pad-authored command runs.
  ( cd "$TMP" && /bin/sh -c "$TYPED" ) >/dev/null 2>&1 || true
  if [ -e "$MARKDIR/m1" ] || [ -e "$MARKDIR/m2" ]; then
    bad "G2b a real shell executed pad-authored commands from the nudge"
  else
    ok "G2b a real shell handed the nudge executed no pad-authored command"
  fi
  case "$TYPED" in
    *"reply with"*|*check*) ok "G3 the nudge is still readable to the agent it is for" ;;
    *) bad "G3 sanitising destroyed the message: $TYPED" ;;
  esac
  if [ "${#TYPED}" -le 700 ]; then
    ok "G4 the typed text is bounded (${#TYPED} chars) — pane run types it keystroke by keystroke"
  else
    bad "G4 the adapter types ${#TYPED} characters into a live TUI"
  fi
fi

# ── G5 MUTANT: restore the pre-fix adapter exactly ────────────────────────
# BOTH halves have to come off. Reverting only the sanitizer left the 600-char
# cap in place, the cut landed inside an unbalanced backquote, sh refused to
# parse the line, and nothing ran — the mutant looked survivable when it was the
# cap saving us by accident. A mutant that "passes" for a reason you did not
# intend is the same false-success class this whole build is about.
echo "  -- mutant: sanitize control bytes only, no cap (the pre-fix adapter) --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/adapters/herdr.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='''nudge="$(printf '%s' "$nudge" \\
  | LC_ALL=C tr -d '\\000-\\037\\177' \\
  | LC_ALL=C tr '`$;|&<>()\\\\' '          ' \\
  | tr -s ' ')"'''
new='''nudge="$(printf '%s' "$nudge" | LC_ALL=C tr -d '\\000-\\037\\177' | tr -s ' ')"'''
cap='if [ "${#nudge}" -gt "$_n_max" ]; then'
if s.count(old)!=1 or s.count(cap)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new).replace(cap,'if false; then'))
PY
if [ $? -eq 9 ]; then
  bad "G5 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  build_and_wake "$MUT" 2
  MTYPED="$(head -1 "$TMP/typed.txt" 2>/dev/null || true)"
  if [ -z "$MTYPED" ]; then
    bad "G5 INVALID PROBE — the mutant adapter typed nothing"
  else
    _mmeta="$(printf '%s' "$MTYPED" | LC_ALL=C tr -cd '`$;|&<>()\\' || true)"
    if [ -n "$_mmeta" ]; then
      ok "G5 the pre-fix adapter types live metacharacters [$(printf '%s' "$_mmeta" | cut -c1-12)] straight into the pty — G2 detects it"
    else
      bad "G5 mutant applied but the typed text was still clean — G2 may be testing nothing"
    fi
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "F15 GREEN — pad text can be read by an agent, not run by a shell"
