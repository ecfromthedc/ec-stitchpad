#!/usr/bin/env bash
# p46-supervise-gate.sh — a dispatch must not be one-shot.
#
# THE PAIN (measured, five dispatches, two model families): every seat returned
# rc=0 having written only its stub header. One given four SPECIFIC claims to
# verify still produced a scaffold, so the limit is not prompt breadth — a wake
# turn executes a short explicit sequence and does not sustain open-ended work.
# What is OURS to fix is that nobody checks the contract when a turn ends and
# nobody tells the agent it is not finished.
#
#   G1  a seat whose artifact IS produced is reported DONE and its contract cleared
#   G2  a seat whose artifact is MISSING gets a continuation posted to the pad
#   G3  the continuation says CONTINUE, not start over (or the loop never converges)
#   G4  an EMPTY artifact counts as missing (existence is not sufficiency)
#   G5  strikes accumulate across runs
#   G6  after --max strikes the seat is FAILED, said out loud, and NOT re-woken
#   G7  a seat with no contract is left alone
#   G8  --all supervises every seat under contract
#   G9  MUTANT: treat an empty artifact as produced -> G4 goes RED
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/p46-sv.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

RT="$ROOT/tool"; PJ="$TMP/proj"; mkdir -p "$PJ" "$TMP/home" "$TMP/out"
sp() { local who="$1"; shift
  ( cd "$PJ"; env -u HERDR_PANE_ID -u HERDR_TAB_ID -u CLAUDE_CODE_SESSION_ID -u STITCHPAD_SESSION \
      HOME="$TMP/home" STITCHPAD_HOME="$RT" STITCHPAD_NAME="$who" \
      STITCHPAD_TERMINAL_NAMESPACE=p46 STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$RT/bin/stitchpad" "$@" ) 2>&1; }

echo "=== P46: contract supervision ==="
echo ""
sp lead init --name p46 >/dev/null 2>&1 || true
sp lead join lead cli pull - >/dev/null 2>&1 || true
sp lead spawn worker1 --brief 'do the thing' --artifact "$TMP/out/w1.md" >/dev/null 2>&1 || true
sp lead spawn worker2 --brief 'do the other'  --artifact "$TMP/out/w2.md" >/dev/null 2>&1 || true
STATE="$PJ/.stitchpad/.state"; PAD="$PJ/.stitchpad/stitchpad.md"

# G1 — produced
printf 'real content\n' > "$TMP/out/w1.md"
out="$(sp lead supervise worker1)"
case "$out" in *DONE*) ok "G1 a produced artifact is reported DONE" ;; *) bad "G1 not reported DONE: $out" ;; esac
[ -f "$STATE/artifact-expect.worker1" ] && bad "G1b contract not cleared after DONE" || ok "G1b contract cleared after DONE"

# G4 — empty is missing
: > "$TMP/out/w2.md"
out="$(sp lead supervise worker2)"
case "$out" in *continued*) ok "G4 an EMPTY artifact counts as missing" ;; *) bad "G4 empty artifact treated as produced: $out" ;; esac

# G2/G3 — continuation posted, and it says continue
if grep -q 'artifact is still missing or empty' "$PAD" 2>/dev/null; then
  ok "G2 a continuation was posted to the pad"
else
  bad "G2 no continuation reached the pad"
fi
if grep -qi 'do NOT start over' "$PAD" 2>/dev/null; then
  ok "G3 the continuation says CONTINUE, not restart"
else
  bad "G3 continuation does not forbid starting over — the loop cannot converge"
fi

# G5 — strikes accumulate
sp lead supervise worker2 >/dev/null 2>&1
n="$(cat "$STATE/supervise-strikes.worker2" 2>/dev/null || echo 0)"
[ "$n" = "2" ] && ok "G5 strikes accumulate across runs (n=$n)" || bad "G5 strike count is $n, expected 2"

# G6 — exhausted -> FAILED, no further continuation
before="$(grep -c 'artifact is still missing or empty' "$PAD" 2>/dev/null || echo 0)"
out="$(sp lead supervise worker2 --max 2 2>&1)"
case "$out" in *FAILED*) ok "G6 exhausted strikes report FAILED" ;; *) bad "G6 no FAILED verdict: $out" ;; esac
after="$(grep -c 'artifact is still missing or empty' "$PAD" 2>/dev/null || echo 0)"
[ "$before" = "$after" ] && ok "G6b a FAILED seat is not woken again" || bad "G6b kept waking a FAILED seat ($before -> $after)"
grep -q 'is FAILED after' "$PAD" 2>/dev/null && ok "G6c the failure is said out loud on the pad" || bad "G6c failure never announced"

# G7 — no contract, left alone
out="$(sp lead supervise nobody 2>&1)"
case "$out" in *'nothing to supervise'*) ok "G7 a seat with no contract is left alone" ;; *) bad "G7 unexpected: $out" ;; esac

# G8 — --all
sp lead spawn worker3 --brief x --artifact "$TMP/out/w3.md" >/dev/null 2>&1 || true
out="$(sp lead supervise --all 2>&1)"
case "$out" in *worker3*) ok "G8 --all supervises every seat under contract" ;; *) bad "G8 --all missed worker3: $out" ;; esac

# G9 — MUTANT
echo ""
echo "  -- mutant: an empty artifact counts as produced --"
MUT="$TMP/mut"; mkdir -p "$MUT"; cp -R "$RT/." "$MUT/"
python3 - "$MUT/bin/lib.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='  [ -s "$path" ]'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,'  [ -e "$path" ]'))
PY
if [ $? -eq 9 ]; then
  bad "G9 MUTANT DID NOT APPLY -- INCONCLUSIVE, not a pass"
else
  mkdir -p "$TMP/proj2" "$TMP/home2" ; PJ2="$TMP/proj2"
  sp2() { local who="$1"; shift
    ( cd "$PJ2"; env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID HOME="$TMP/home2" \
        STITCHPAD_HOME="$MUT" STITCHPAD_NAME="$who" STITCHPAD_TERMINAL_NAMESPACE=p46m \
        STITCHPAD_HEARTBEAT_AUTOSTART=0 "$MUT/bin/stitchpad" "$@" ) 2>&1; }
  sp2 lead init --name p46m >/dev/null 2>&1 || true
  sp2 lead join lead cli pull - >/dev/null 2>&1 || true
  sp2 lead spawn w --brief x --artifact "$TMP/out/mut.md" >/dev/null 2>&1 || true
  : > "$TMP/out/mut.md"
  out="$(sp2 lead supervise w 2>&1)"
  case "$out" in
    *DONE*) ok "G9 with the mutant an empty file reads DONE — G4 detects it" ;;
    *) bad "G9 mutant applied but behaviour unchanged: $out" ;;
  esac
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "P46 GREEN — a dispatch is no longer one-shot"
