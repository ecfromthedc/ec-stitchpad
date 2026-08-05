#!/usr/bin/env bash
# p38-task-list-readable-gate.sh — `task list` must be readable by a human AND
# stay parseable by a machine.
#
# THE PAIN: every card printed as ONE pipe-delimited line with the entire body
# inline. TASK-1 in the live arena runs to ~700 characters; six cards fill a
# screen and nothing can be scanned. The board was unreadable exactly when an
# operator was trying to see where the fleet was (sits with P20/P21).
#
# THE CONSTRAINT: the pipe format is load-bearing — suites parse '^TASK-N|' —
# so it must survive BYTE FOR BYTE anywhere output is not a terminal.
#
#   G1  default, piped        -> machine format (every line is a card record)
#   G2  --porcelain           -> machine format even on a terminal
#   G3  --human               -> rendered board: header + one short line per card
#   G4  --human lines are bounded (no 700-character rows)
#   G5  MUTANT: render by default -> G1 goes RED (machine parsing broken)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/p38-tasklist.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

sp() { # $1=tool root, rest=args
  local root="$1"; shift
  ( cd "$TMP/proj"
    env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_ENV -u HERDR_SOCKET_PATH \
        -u HERDR_WORKSPACE_ID -u CLAUDE_CODE_SESSION_ID -u STITCHPAD_SESSION \
        HOME="$TMP/home" STITCHPAD_HOME="$root" STITCHPAD_NAME=tester \
        STITCHPAD_TERMINAL_NAMESPACE=p38gate STITCHPAD_HEARTBEAT_AUTOSTART=0 \
        "$root/bin/stitchpad" "$@" ) 2>/dev/null
}

echo "=== P38: task list readability ==="
echo ""

mkdir -p "$TMP/proj" "$TMP/home"
sp "$ROOT/tool" init --name p38gate >/dev/null 2>&1 || true
sp "$ROOT/tool" join tester claude pull - >/dev/null 2>&1 || true
# A card with a LONG body — the shape that made the board unreadable.
LONGBODY="OBSERVED: $(printf 'x%.0s' $(seq 1 400)) END"
sp "$ROOT/tool" task new "short title here" --priority high >/dev/null 2>&1 || true
sp "$ROOT/tool" task new "$LONGBODY" >/dev/null 2>&1 || true

# ── G1: piped default must be the machine format ───────────────────────────
DEF="$(sp "$ROOT/tool" task list || true)"
_bad_lines="$(printf '%s\n' "$DEF" | grep -v '^$' | grep -cv '^TASK-[0-9][0-9]*|' || true)"
if [ -n "$DEF" ] && [ "${_bad_lines:-1}" -eq 0 ]; then
  ok "G1: piped default is the machine format (every line is a card record)"
else
  bad "G1: piped default is NOT the machine format — ${_bad_lines} non-record line(s); suites parse this"
fi

# ── G2: --porcelain is always machine ──────────────────────────────────────
POR="$(sp "$ROOT/tool" task list --porcelain || true)"
if [ "$POR" = "$DEF" ]; then
  ok "G2: --porcelain matches the piped default byte for byte"
else
  bad "G2: --porcelain diverged from the piped default"
fi

# ── G3/G4: --human renders a bounded board ─────────────────────────────────
HUM="$(sp "$ROOT/tool" task list --human || true)"
_hdr="$(printf '%s\n' "$HUM" | head -1)"
_rows="$(printf '%s\n' "$HUM" | tail -n +3 | grep -c '^TASK-' || true)"
if printf '%s' "$_hdr" | grep -q 'ID' && printf '%s' "$_hdr" | grep -q 'TITLE' && [ "${_rows:-0}" -ge 2 ]; then
  ok "G3: --human prints a header and one row per card ($_rows rows)"
else
  bad "G3: --human did not render a board (header='$_hdr' rows=$_rows)"
fi

_longest="$(printf '%s\n' "$HUM" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')"
if [ "${_longest:-9999}" -le 200 ]; then
  ok "G4: longest rendered line is ${_longest} chars (bounded)"
else
  bad "G4: a rendered line is ${_longest} chars — the unreadable board is back"
fi

# ── G5: MUTANT — render by default, which breaks every machine consumer ────
MUT="$TMP/mutant-tool"
cp -R "$ROOT/tool" "$MUT"
_DEFAULT_GUARD='elif [ "$_tl_human" = "1" ] || [ -t 1 ]; then'
_MUT_GUARD='elif true; then'
python3 - "$MUT/bin/stitchpad" "$_DEFAULT_GUARD" "$_MUT_GUARD" <<'PY_MUT'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
if s.count(old) != 1: sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY_MUT
if [ $? -eq 0 ] && grep -qF "$_MUT_GUARD" "$MUT/bin/stitchpad"; then
  MUT_OUT="$(sp "$MUT" task list || true)"
  _mut_bad="$(printf '%s\n' "$MUT_OUT" | grep -v '^$' | grep -cv '^TASK-[0-9][0-9]*|' || true)"
  if [ "${_mut_bad:-0}" -gt 0 ]; then
    ok "G5: MUTANT — rendering by default breaks machine parsing, gate bites"
  else
    bad "G5: MUTANT applied but G1 still saw the machine format — this gate cannot protect suites"
  fi
else
  bad "G5: MUTANT DID NOT APPLY — inconclusive, never treat as a pass"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
