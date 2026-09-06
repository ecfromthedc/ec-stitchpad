#!/usr/bin/env bash
# Fixtures must not inherit the caller's ambient session identity.
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
# recovery-exhaustion-quiet-gate.sh — an exhausted recovery key is a VERDICT,
# not a tally, and a standing fact is said once.
#
# Found live on the tides fleet: two journal orphans stuck since Aug 30 had
# reached 273/3 and 207/3 attempts, and every single `stitchpad say` by every
# seat re-walked them, re-incremented them, and re-printed RECOVERY EXHAUSTED
# on stderr — the same stream that carries UNREACHABLE PUSH SEAT, SESSION
# BINDING DIVERGED and the unknown-flag refusal. A permanent warning drowns
# the transient actionable ones.
#
# Proves:
#   Q1: a key at the bound does NOT increment further (saturation)
#   Q2: saturation does not un-exhaust the key
#   Q3: the terminal refusal is emitted ONCE, not once per operation
#   Q4: sp_recovery_reset clears the once-only marker, so a key that becomes
#       terminal again is announced again
#   Q5: E5a survives — a poisoned count (>999) still reaches the sanitizer and
#       is NOT swallowed by the saturation short-circuit
#   Q6: a key whose sanitized name would collide with another key's ".refused"
#       marker cannot silence it
#
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

source "$ROOT/tool/bin/recovery-policy.sh"

echo "=== recovery-exhaustion-quiet-gate ==="
echo ""

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-quiet.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export PAD_STATE="$WORK/state"
mkdir -p "$PAD_STATE"

export SP_RECOVERY_MAX_ATTEMPTS=3
export SP_RECOVERY_BUDGET_SECONDS=99999   # keep the TIME budget out of the way

K="journal:.registry-journal.QuietQ"

# ── Q1: saturation ─────────────────────────────────────────────────────────
for _ in 1 2 3; do sp_recovery_attempt_record "$PAD_STATE" "$K"; done
c="$(sp_recovery_attempt_count "$PAD_STATE" "$K")"
[ "$c" = "3" ] || bad "Q1 setup: count=$c after three attempts (expected 3)"
for _ in 1 2 3 4 5 6 7 8 9 10; do sp_recovery_attempt_record "$PAD_STATE" "$K"; done
c="$(sp_recovery_attempt_count "$PAD_STATE" "$K")"
if [ "$c" = "3" ]; then
  ok "Q1: count saturates at max=3 across ten further attempts"
else
  bad "Q1: count=$c after ten further attempts (expected 3 — it is still counting)"
fi

# ── Q2: saturation must not un-exhaust ─────────────────────────────────────
# (Preservation check: green before AND after the fix. Its job is to catch a
#  future "optimisation" of the short-circuit that disarms the bound.)
if sp_recovery_is_exhausted "$PAD_STATE" "$K"; then
  ok "Q2: still exhausted after saturation"
else
  bad "Q2: NOT exhausted after saturation — the bound has been disarmed"
fi

# ── Q3: said once ──────────────────────────────────────────────────────────
e1="$(sp_recovery_terminal_refuse system journal-recovery "$K" 2>&1 >/dev/null)"
e2="$(sp_recovery_terminal_refuse system journal-recovery "$K" 2>&1 >/dev/null)"
e3="$(sp_recovery_terminal_refuse system journal-recovery "$K" 2>&1 >/dev/null)"
n1=$(printf '%s' "$e1" | grep -c 'RECOVERY EXHAUSTED')
nrest=$(printf '%s\n%s' "$e2" "$e3" | grep -c 'RECOVERY EXHAUSTED')
if [ "$n1" = "1" ] && [ "$nrest" = "0" ]; then
  ok "Q3: RECOVERY EXHAUSTED said once, silent on the next two calls"
else
  bad "Q3: first-call lines=$n1 (expected 1), later-call lines=$nrest (expected 0)"
fi
case "$e1" in
  *"stitchpad doctor"*) ok "Q3b: the one diagnostic names the surface that lists what is stuck" ;;
  *) bad "Q3b: the diagnostic does not point anywhere: $e1" ;;
esac

# ── Q4: reset re-arms the announcement ─────────────────────────────────────
# Q4a asserts the marker EXISTS before the reset as well as being gone after.
# Checking only "gone after" passes trivially in a build that never writes a
# marker at all — a test that cannot fail for the reason its name gives.
mk="$(_sp_recovery_file "$PAD_STATE" "$K").refused"
if [ ! -e "$mk" ]; then
  bad "Q4a: no once-only marker exists to clear (Q3 never wrote one)"
else
  sp_recovery_reset "$PAD_STATE" "$K"
  [ -e "$mk" ] \
    && bad "Q4a: reset left the once-only marker behind" \
    || ok "Q4a: marker written, then cleared by reset"
fi
sp_recovery_reset "$PAD_STATE" "$K"
e4="$(sp_recovery_terminal_refuse system journal-recovery "$K" 2>&1 >/dev/null)"
if printf '%s' "$e4" | grep -q 'RECOVERY EXHAUSTED'; then
  ok "Q4b: a key that becomes terminal again is announced again"
else
  bad "Q4b: still silent after reset — the diagnostic is lost, not deferred"
fi

# ── Q5: E5a must survive the short-circuit ─────────────────────────────────
# (Preservation check: green before AND after the fix, deliberately. The
#  short-circuit must not swallow the one case it is not allowed to skip.)
KP="poisoned-key"
mkdir -p "$PAD_STATE/recovery-attempts"
printf '999999|%s' "$(date +%s)" > "$PAD_STATE/recovery-attempts/$KP"
out="$(sp_recovery_attempt_record "$PAD_STATE" "$KP" 2>&1)"
c="$(sp_recovery_attempt_count "$PAD_STATE" "$KP")"
if [ "$c" = "1" ]; then
  ok "Q5: a poisoned count (999999) still reaches the sanitizer and lands at 1"
else
  bad "Q5: poisoned count sanitized to $c (expected 1) — the short-circuit swallowed it"
fi

# ── Q6: the marker namespace cannot be squatted ────────────────────────────
KA="squat-target"
KB="squat-target.refused"
fa="$(_sp_recovery_file "$PAD_STATE" "$KA")"
fb="$(_sp_recovery_file "$PAD_STATE" "$KB")"
if [ "${fa}.refused" != "$fb" ]; then
  ok "Q6: a key ending in .refused cannot land on another key's marker"
else
  bad "Q6: key '$KB' maps onto '$KA''s marker ($fb) — its diagnostic can be silenced"
fi

echo ""
printf "%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
