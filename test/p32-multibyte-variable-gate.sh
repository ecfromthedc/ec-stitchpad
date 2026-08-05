#!/usr/bin/env bash
# p32-multibyte-variable-gate.sh — no bare "$VAR" may sit directly against a
# multibyte character in any shell source we ship.
#
# THE PLATFORM DEFECT (bash 3.2, the macOS default, verified by G1 below):
#   bash folds the UTF-8 LEAD BYTE of the following character into the variable
#   NAME. Write a bare <dollar>X immediately against an arrow and bash parses the
#   name as X<0xe2>, which dies under `set -u`:
#     bare   -> bash: X?: unbound variable   (rc=127)
#     braced -> 1(arrow)2                    (rc=0)
#   G1 and G2 below execute both forms, so the exact shapes live in code rather
#   than in this comment — otherwise the lint flags its own explanation.
#
# WHY IT MATTERS: this is invisible until the line is REACHED, and then it is
# fatal. It killed test/oversight-gate.sh at assertion 6 of 14 — which then
# reported rc=0 (an EXIT trap masks the abort, see P31) and was baselined 14/0 by
# a builder who never got there. Six sites carried it, including PRODUCTION:
# tool/bin/stitchpad's wake nudge (a bare <dollar>_open against an em-dash).
# Arrows and em-dashes are all over this codebase's user-facing strings, so this
# lint is the only thing that keeps the class from coming back.
#
#   G1  the platform defect is real here (if this ever stops failing, say so)
#   G2  braces make it safe
#   G3  LINT: zero occurrences across tool/ and test/
#   G4  MUTANT: plant one occurrence -> the lint must catch it
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/p32-multibyte.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# The offending shape: $NAME immediately followed by a non-ASCII byte.
# grep -P is not available everywhere; perl is, and it is already a dependency
# of the tripwire's ANSI stripping.
scan() { # $1=root dir → prints "file:line" for every occurrence
  # SHELL SOURCE ONLY. An earlier version also took anything with +x and walked
  # tool/tui-rs/target/debug/deps/* — compiled Rust binaries are full of byte
  # sequences that look like the pattern, and 415 "hits" told us nothing.
  find "$1" -type f \
       ! -path '*/target/*' ! -path '*/node_modules/*' ! -path '*/.git/*' \
       ! -path '*/__pycache__/*' ! -name '*.pyc' 2>/dev/null \
  | while read -r f; do
      case "$f" in
        *.sh) : ;;
        *) head -c 2 "$f" 2>/dev/null | grep -q '^#!' || continue
           head -1 "$f" 2>/dev/null | grep -q 'sh\b' || continue ;;
      esac
      perl -ne 'print "$ARGV:$.\n" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/' "$f" 2>/dev/null
    done
}

echo "=== P32: multibyte-adjacent variable expansion ==="
echo ""

# ── G1/G2: the platform behaviour this lint defends against ────────────────
set +e
bare="$(bash -c 'set -u; X=1; Y=2; echo "$X'$'→''$Y"' 2>&1)"; bare_rc=$?
braced="$(bash -c 'set -u; X=1; Y=2; echo "${X}'$'→''${Y}"' 2>&1)"; braced_rc=$?
set -e

if [ "$bare_rc" -ne 0 ] && printf '%s' "$bare" | LC_ALL=C grep -aqi 'unbound variable'; then
  ok "G1: bare \$VAR before a multibyte char still dies here (rc=$bare_rc) — lint is required"
else
  bad "G1: the platform no longer folds the lead byte (rc=$bare_rc, out=$bare). If this is a NEW bash, say so in the ledger before relaxing anything."
fi

if [ "$braced_rc" -eq 0 ] && [ "$braced" = "1"$'→'"2" ]; then
  ok "G2: \${VAR} is safe (got '$braced')"
else
  bad "G2: braced form failed (rc=$braced_rc, out=$braced)"
fi

# ── G3: the lint over everything we ship ───────────────────────────────────
hits_tool="$(scan "$ROOT/tool" || true)"
hits_test="$(scan "$ROOT/test" || true)"
hits="$(printf '%s\n%s' "$hits_tool" "$hits_test" | grep -v '^$' || true)"
n="$(printf '%s' "$hits" | grep -c . || true)"
if [ "${n:-0}" -eq 0 ]; then
  ok "G3: zero bare \$VAR-before-multibyte sites in tool/ and test/"
else
  bad "G3: $n site(s) would die under set -u:"
  printf '%s\n' "$hits" | sed 's/^/        /'
fi

# ── G4: MUTANT — plant one and require the lint to see it ──────────────────
MUT="$TMP/mut"; mkdir -p "$MUT"
printf '#!/usr/bin/env bash\nset -u\nA=1; B=2\necho "$A%s$B"\n' $'→' > "$MUT/planted.sh"
if [ -n "$(perl -ne 'print "hit" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/' "$MUT/planted.sh")" ]; then
  planted="$(scan "$MUT" || true)"
  if printf '%s' "$planted" | grep -q 'planted.sh'; then
    ok "G4: MUTANT — a planted occurrence is caught by the lint, gate bites"
  else
    bad "G4: MUTANT planted but the lint did not see it — this gate cannot enforce G3"
  fi
else
  bad "G4: MUTANT DID NOT APPLY — the planted file lacks the pattern; inconclusive"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
