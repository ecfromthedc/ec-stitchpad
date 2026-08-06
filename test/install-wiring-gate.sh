#!/usr/bin/env bash
# install-wiring-gate.sh — k3 F16: the installer must never claim it wired a
# fleet it did not wire.
#
# THE PAIN: `tool/install.sh` printed
#     ✓ stitchpad installed — multi-agent collaboration is wired.
# unconditionally, rc=0. With a trailing comma in ~/.claude/settings.json — the
# commonest JSON wound, and one a NEW machine hits before anything else — all
# three python3 merges raised JSONDecodeError, NOTHING was wired, and the banner
# still said it was. The resulting fleet can never be woken, and F1/F10's
# silence means it is never diagnosed. Reproduced before the fix: 3 tracebacks,
# zero hooks in settings.json, banner printed, rc=0.
#
#   G1  a corrupt settings.json makes the installer exit NON-ZERO
#   G2  ... and the success banner is NOT printed
#   G3  ... and the corrupt file is left byte-identical (we never overwrite a
#       user's real config to make our own step succeed)
#   G4  ... and the refusal names the file and the reason
#   G5  a valid settings.json still wires: rc=0 and the banner prints
#   G6  ... with the Stop hook and claim hook really in settings.json and the
#       MCP server really in ~/.claude.json — the file Claude actually reads
#       (k3 F17). The banner is checked against the files, never trusted.
#   G7  ... and pre-existing user keys survive the merge
#   G8  a second run is idempotent: rc=0, still exactly one Stop entry
#   G9  no python3 at all → non-zero, and the ledger says why
#   G10 MUTANT: banner printed unconditionally → G2 goes RED
#   G11 MUTANT: exit status dropped → G1 goes RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
INSTALLER="$TOP/tool/install.sh"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-install.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT   # nothing here spawns; no pkill (P9)

# A hermetic PATH. npm and pi are deliberately absent: the installer would
# otherwise run `npm install` inside the REPO's tool/mcp, i.e. a test mutating
# the tree it is testing. claude/codex absence only affects the advisory list.
STUB="$TMP/bin"; mkdir -p "$STUB"
for b in dirname mkdir ln python3 grep touch cat rm sed; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$STUB/$b"
done

run_installer() {  # $1 = home dir; prints output, sets RC
  local h="$1"
  out="$( PATH="$STUB" HOME="$h" /bin/bash "$INSTALLER" "$h/bin" 2>&1 )"
  RC=$?
}
run_mutant() {  # $1 = installer path, $2 = home dir
  local i="$1" h="$2"
  mout="$( PATH="$STUB" HOME="$h" /bin/bash "$i" "$h/bin" 2>&1 )"
  MRC=$?
}

echo "=== k3 F16: no success banner for a step that did not happen ==="
echo ""

# ── the wound: a trailing comma, the commonest JSON injury ──────────────────
BAD_HOME="$TMP/bad"; mkdir -p "$BAD_HOME/.claude"
printf '{\n  "model": "opus",\n}\n' > "$BAD_HOME/.claude/settings.json"
cp "$BAD_HOME/.claude/settings.json" "$TMP/settings.orig"
run_installer "$BAD_HOME"

if [ "$RC" -ne 0 ]; then
  ok "G1 a corrupt settings.json makes the installer exit non-zero (rc=$RC)"
else
  bad "G1 installer exited 0 on a corrupt settings.json — an unattended install cannot tell"
fi

case "$out" in
  *"collaboration is wired"*)
    bad "G2 the success banner printed even though nothing was wired" ;;
  *) ok "G2 the success banner is withheld when the wiring did not happen" ;;
esac

if cmp -s "$TMP/settings.orig" "$BAD_HOME/.claude/settings.json"; then
  ok "G3 the unparseable settings.json was left byte-identical"
else
  bad "G3 the installer rewrote a config it could not parse — user settings destroyed"
fi

case "$out" in
  *"REFUSING"*"settings.json"*) ok "G4 the refusal names the file and the reason" ;;
  *) bad "G4 the refusal does not name the offending file: $(printf '%s' "$out" | tail -5)" ;;
esac

# ── the happy path must be untouched ────────────────────────────────────────
GOOD_HOME="$TMP/good"; mkdir -p "$GOOD_HOME/.claude"
printf '{"model":"opus","env":{"KEEP":"me"}}\n' > "$GOOD_HOME/.claude/settings.json"
run_installer "$GOOD_HOME"
S="$GOOD_HOME/.claude/settings.json"

if [ "$RC" -eq 0 ]; then ok "G5 a valid settings.json still installs cleanly (rc=0)"
else bad "G5 a valid settings.json now fails the install (rc=$RC): $(printf '%s' "$out" | tail -5)"; fi
case "$out" in
  *"collaboration is wired"*) ok "G5b the success banner prints on the good path" ;;
  *) bad "G5b the success banner is missing on a fully wired install" ;;
esac

# The MCP server belongs in ~/.claude.json, NOT settings.json: proven with two
# isolated HOMEs and `claude mcp list` — an entry in settings.json is invisible
# to Claude, an entry in ~/.claude.json is listed (k3 F17). So this checks the
# hooks in settings.json and the MCP registration in ~/.claude.json.
python3 - "$S" "$GOOD_HOME/.claude.json" <<'PY' >"$TMP/g6" 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
h=d.get("hooks",{})
def has(sec,frag):
    return any(frag in (x.get("command") or "") for blk in h.get(sec,[]) for x in blk.get("hooks",[]))
print("stop"  if has("Stop","stop-hook.sh") else "-")
print("claim" if has("PreToolUse","claim-hook.sh") else "-")
try:
    j=json.load(open(sys.argv[2]))
except Exception:
    j={}
print("mcp"   if "stitchpad" in j.get("mcpServers",{}) else "-")
print("keep"  if d.get("env",{}).get("KEEP")=="me" and d.get("model")=="opus" else "-")
print("nodead" if "stitchpad" not in d.get("mcpServers",{}) else "-")
PY
_g6="$(tr '\n' ' ' < "$TMP/g6" 2>/dev/null)"
case "$_g6" in
  "stop claim mcp keep nodead "*) ok "G6 hooks in settings.json, MCP in ~/.claude.json — all really present" ;;
  *) bad "G6 the banner claimed more than the files contain: [$_g6]" ;;
esac
case "$_g6" in
  *"nodead "*) ok "G6b nothing was written to settings.json's mcpServers, which Claude never reads" ;;
  *) bad "G6b the MCP server went back into settings.json, where Claude cannot see it" ;;
esac
case "$_g6" in
  *"keep "*) ok "G7 pre-existing user keys survived the merge" ;;
  *) bad "G7 the merge dropped pre-existing user keys" ;;
esac

# ── idempotence: the installer is expected to be re-run ─────────────────────
run_installer "$GOOD_HOME"
_n="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for b in d.get("hooks",{}).get("Stop",[]) for h in b.get("hooks",[]) if "stop-hook.sh" in (h.get("command") or "")))' "$S" 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ "$_n" = "1" ]; then
  ok "G8 a second run is idempotent (rc=0, exactly one Stop entry)"
else
  bad "G8 re-running the installer: rc=$RC, Stop entries=$_n (want rc=0, 1)"
fi

# ── no python3 → nothing can be wired, and it must say so ───────────────────
NOPY="$TMP/nopy"; mkdir -p "$NOPY"
STUB2="$TMP/bin2"; mkdir -p "$STUB2"
for b in dirname mkdir ln grep touch cat rm sed; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$STUB2/$b"
done
out2="$( PATH="$STUB2" HOME="$NOPY" /bin/bash "$INSTALLER" "$NOPY/bin" 2>&1 )"; RC2=$?
if [ "$RC2" -ne 0 ]; then
  case "$out2" in
    *python3*) ok "G9 with no python3 the install fails loudly and names python3" ;;
    *) bad "G9 non-zero without saying python3 is the reason" ;;
  esac
else
  bad "G9 with no python3 nothing can be wired, yet the installer exited 0"
fi

# ── G10 MUTANT: print the banner unconditionally ────────────────────────────
echo ""
echo "  -- mutant: banner unconditional --"
MUT1="$TMP/mutant-banner.sh"; cp "$INSTALLER" "$MUT1"
python3 - "$MUT1" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='if [ -n "$WIRE_FAILED" ]; then'
new='if false; then'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "G10 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  M1="$TMP/mhome1"; mkdir -p "$M1/.claude"
  printf '{\n  "model": "opus",\n}\n' > "$M1/.claude/settings.json"
  run_mutant "$MUT1" "$M1"
  case "$mout" in
    *"collaboration is wired"*) ok "G10 without the branch the false banner returns — G2 detects it" ;;
    *) bad "G10 mutant applied but the banner stayed away — G2 may be testing nothing" ;;
  esac
fi

# ── G11 MUTANT: drop the exit status ────────────────────────────────────────
echo "  -- mutant: exit status dropped --"
MUT2="$TMP/mutant-rc.sh"; cp "$INSTALLER" "$MUT2"
python3 - "$MUT2" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='[ -z "$WIRE_FAILED" ] || exit 1'
new='true'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "G11 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  M2="$TMP/mhome2"; mkdir -p "$M2/.claude"
  printf '{\n  "model": "opus",\n}\n' > "$M2/.claude/settings.json"
  run_mutant "$MUT2" "$M2"
  if [ "$MRC" -eq 0 ]; then
    ok "G11 without the final exit the rc lies again (rc=0) — G1 detects it"
  else
    bad "G11 mutant applied but rc stayed $MRC — G1 may be testing nothing"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "F16 GREEN — the installer's banner and rc now follow what actually happened"
