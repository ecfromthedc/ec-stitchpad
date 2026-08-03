#!/usr/bin/env bash
# authority-redesign-regression.sh — C2/C2b authority model redesign gates
#
# flash C2/C2b (CONFIRMED): the TASK-5 operator gate was a SELF-ASSERTION —
# STITCHPAD_I_AM_OPERATOR had no producer anywhere in tool/ (any process
# could export it), and the roster lives in pad markdown the seat can edit,
# so a seat could EDIT ITSELF OUT of the roster and pass the non-roster
# check. An authority model whose input the subject can forge is not an
# authority model.
#
# Redesign: authority derives ONLY from an operator credential rooted at
# $HOME/.stitchpad/operator.key (outside every pad, explicit human keygen),
# presented out-of-band via STITCHPAD_OPERATOR_TOKEN. Grants are sp-auth-v1
# HMAC-sealed and bound to the canonical pad path + seat + operation +
# expiry. The roster is REMOVED as an authority input (kept only as a
# best-effort deny signal).
#
# This suite proves the two flash probes now REFUSE, plus the positive
# paths, grant forgery classes, and pad binding.
#
# Fixture discipline (fleet findings): isolated mktemp pads, isolated HOME
# (never touch the operator's real key), HERDR_* unset, no network.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SP="$ROOT/tool/bin/stitchpad"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0
ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }
check() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-auth-redesign.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Never inherit the runner's terminal surface (fleet finding).
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export HOME="$tmp/home"
mkdir -p "$HOME"

PAD="$tmp/pad/.stitchpad"
STATE="$PAD/.state"
mkdir -p "$STATE/sessions" "$STATE/claims"
cat > "$PAD/stitchpad.md" <<'EOF'
```roster
victim | ocean | push | tgt-v
probe  | ocean | push | tgt-p
```

## @victim · 2026-08-03 09:00
hello
EOF

run_sp() { # env-pairs... -- args...
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  # bash 3.2: guard empty-array expansion under set -u
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" ${envs[@]+"${envs[@]}"} \
    STITCHPAD_PAD_DIR="$PAD" STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" "$@"
}

echo "=== authority redesign regression (C2/C2b) ==="

# ── A. C2 probe REFUSES: env boolean + non-roster name, no credential ──
out="$(run_sp STITCHPAD_NAME=intruder STITCHPAD_I_AM_OPERATOR=1 -- reset --recovery-counters 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'A1: C2 probe refused (I_AM_OPERATOR=1 + non-roster name, no credential)' \
  || bad 'A1: C2 probe NOT refused — env boolean still proves operator-ness'
printf '%s' "$out" | grep -q 'operator credential' \
  && ok 'A2: refusal names the credential requirement' \
  || bad "A2: refusal message unhelpful: $(printf '%s' "$out" | head -c 120)"

# ── B. keygen discipline ──
run_sp -- operator status >"$tmp/status0" 2>&1 || true
grep -q 'MISSING' "$tmp/status0" && ok 'B1: status reports missing key before keygen' \
  || bad 'B1: status did not report missing key'
run_sp -- operator keygen >/dev/null
check 'B2: keygen creates the key' '1' "$([ -s "$HOME/.stitchpad/operator.key" ] && echo 1 || echo 0)"
run_sp -- operator keygen >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok 'B3: keygen refuses overwrite without --force' || bad 'B3: keygen silently overwrote the key'
TOK="$(cat "$HOME/.stitchpad/operator.key")"
run_sp STITCHPAD_OPERATOR_TOKEN="$TOK" -- operator status >"$tmp/status1" 2>&1
grep -q 'PRESENTED' "$tmp/status1" && ok 'B4: status confirms presented credential' \
  || bad 'B4: status did not confirm presented credential'

# ── C. credential present but NOT presented → still refuses ──
out="$(run_sp STITCHPAD_NAME=intruder STITCHPAD_I_AM_OPERATOR=1 -- reset --recovery-counters 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'C1: key existing is not enough — unpresented credential refuses' \
  || bad 'C1: gate passed without presenting the token'
out="$(run_sp STITCHPAD_NAME=intruder STITCHPAD_OPERATOR_TOKEN=wrong-token -- reset --recovery-counters 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'C2: wrong token refuses' || bad 'C2: wrong token passed the gate'

# ── D. positive: presented credential → operator flows work ──
mkdir -p "$STATE/recovery-attempts"
printf '5|%d' "$(date +%s)" > "$STATE/recovery-attempts/journal:test"
out="$(run_sp STITCHPAD_NAME=intruder STITCHPAD_OPERATOR_TOKEN="$TOK" -- reset --recovery-counters 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ ! -f "$STATE/recovery-attempts/journal:test" ] \
  && ok 'D1: presented credential clears recovery counters' \
  || bad "D1: credential-carrying operator clear failed (rc=$rc): $(printf '%s' "$out" | head -c 120)"
out="$(run_sp STITCHPAD_OPERATOR_TOKEN="$TOK" -- reset victim 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok 'D2: presented credential permits cross-seat operator reset' \
  || bad "D2: operator reset failed (rc=$rc): $(printf '%s' "$out" | head -c 120)"

# ── E. C2b probe REFUSES: seat edits ITSELF OUT of the roster ──
# Simulate the seat's own write: remove @probe from the roster markdown.
python3 - "$PAD/stitchpad.md" <<'EOF'
import sys
p = sys.argv[1]
lines = open(p).readlines()
open(p, 'w').write(''.join(l for l in lines if not l.startswith('probe ')))
EOF
! grep -q '^probe ' "$PAD/stitchpad.md" && ok 'E0: fixture — probe removed itself from roster markdown' \
  || bad 'E0: fixture roster edit failed'
out="$(run_sp STITCHPAD_NAME=probe -- reset --recovery-counters 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'E1: C2b probe refused (self-removed seat clears counters)' \
  || bad 'E1: C2b probe NOT refused — roster self-edit still proves operator-ness'
out="$(run_sp STITCHPAD_NAME=probe -- reset victim 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'E2: C2b probe refused (self-removed seat resets cross-seat)' \
  || bad 'E2: C2b probe NOT refused — cross-seat reset passed on roster self-edit'
printf '%s' "$out" | grep -q 'seat-editable' \
  && ok 'E3: refusal names the roster-edit forgery class' \
  || bad "E3: refusal message unhelpful: $(printf '%s' "$out" | head -c 120)"

# ── F. grant forgery classes ──
printf 'deploy' > "$STATE/authority.probe"
# restore probe to roster for the grant section
python3 - "$PAD/stitchpad.md" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, 'w').write(s.replace('```\n\n## @victim', 'probe  | ocean | push | tgt-p\n```\n\n## @victim'))
EOF

# F1: raw hand-written (unsealed) grant — the old TASK-5 format — must deny
printf 'probe 2026-08-03T00:00:00Z\n' > "$STATE/operator-grant.probe.reset-others"
out="$(run_sp STITCHPAD_NAME=probe -- reset victim 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'F1: unsealed hand-written grant refuses (legacy format = forgery)' \
  || bad 'F1: unsealed grant PASSED — old forgery path still open'

# F2: sealed grant via CLI → allows, one-shot
run_sp STITCHPAD_OPERATOR_TOKEN="$TOK" -- operator grant probe reset-others >/dev/null
out="$(run_sp STITCHPAD_NAME=probe -- reset victim 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok 'F2: sealed grant authorizes the deploy operation' \
  || bad "F2: sealed grant refused (rc=$rc): $(printf '%s' "$out" | head -c 120)"
[ ! -f "$STATE/operator-grant.probe.reset-others" ] \
  && ok 'F3: sealed grant consumed (one-shot)' || bad 'F3: sealed grant not consumed'

# F4: tampered seal refuses
run_sp STITCHPAD_OPERATOR_TOKEN="$TOK" -- operator grant probe reset-others >/dev/null
sed -i '' 's/^seal=./seal=0/' "$STATE/operator-grant.probe.reset-others"
out="$(run_sp STITCHPAD_NAME=probe -- reset victim 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'F4: tampered seal refuses' || bad 'F4: tampered seal PASSED'
rm -f "$STATE/operator-grant.probe.reset-others"

# F5: grant copied from ANOTHER pad refuses (pad binding)
PAD2="$tmp/pad2/.stitchpad"
mkdir -p "$PAD2/.state/sessions" "$PAD2/.state/claims"
cat > "$PAD2/stitchpad.md" <<'EOF'
```roster
victim | ocean | push | tgt-v
probe  | ocean | push | tgt-p
```

## @victim · 2026-08-03 09:00
hello
EOF
STITCHPAD_PAD_DIR="$PAD2" STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" operator grant probe reset-others >/dev/null
cp "$PAD2/.state/operator-grant.probe.reset-others" "$STATE/operator-grant.probe.reset-others"
out="$(run_sp STITCHPAD_NAME=probe -- reset victim 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'F5: grant copied from another pad refuses (pad-bound seal)' \
  || bad 'F5: foreign-pad grant PASSED — seal is not pad-bound'
rm -f "$STATE/operator-grant.probe.reset-others"

# F6: expired grant refuses
run_sp STITCHPAD_OPERATOR_TOKEN="$TOK" -- operator grant probe reset-others --ttl 1 >/dev/null
sleep 2
out="$(run_sp STITCHPAD_NAME=probe -- reset victim 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'F6: expired grant refuses' || bad 'F6: expired grant PASSED'
rm -f "$STATE/operator-grant.probe.reset-others"

# ── G. authority set is operator-only ──
out="$(run_sp STITCHPAD_NAME=probe -- authority set probe deploy 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'G1: authority set without credential refuses (no self-elevation)' \
  || bad 'G1: seat elevated itself to deploy'
out="$(run_sp STITCHPAD_OPERATOR_TOKEN="$TOK" -- authority set probe deploy 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok 'G2: authority set with credential succeeds' || bad 'G2: operator authority set failed'

# ── H. self-reset remains ungated (self-repair, F3 contract intact) ──
out="$(run_sp STITCHPAD_NAME=victim -- reset victim 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok 'H1: seat self-reset still ungated (stop-hook recovery flow)' \
  || bad "H1: self-reset broke (rc=$rc)"

# ── I. fx2 mutation-round-3 gates (G-A1/A5/A8/A9/A10): contract assertions ──
# fx2 proved the guards WORK (mutant probes) but the suite was silent on them.
HOME2="$tmp/home-symlink"; mkdir -p "$HOME2/.stitchpad"

# G-A1: symlinked operator.key must be refused even with the CORRECT token
mkdir -p "$tmp/elsewhere"
run_sp -- operator keygen >/dev/null 2>&1  # ensure real key exists in $HOME first? no — fresh: build a real key file elsewhere
SECRET="$tmp/elsewhere/operator.key.real"
run_sp -- operator keygen >/dev/null; TOK2="$(cat "$HOME/.stitchpad/operator.key")"
cp "$HOME/.stitchpad/operator.key" "$SECRET"
rm "$HOME/.stitchpad/operator.key"
ln -s "$SECRET" "$HOME/.stitchpad/operator.key"
out="$(run_sp STITCHPAD_OPERATOR_TOKEN="$TOK2" -- reset --recovery-counters 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'G-A1: symlinked operator.key refused even with correct token'   || bad 'G-A1: symlinked key accepted (TOCTOU contract broken)'
rm "$HOME/.stitchpad/operator.key"; cp "$SECRET" "$HOME/.stitchpad/operator.key"; chmod 600 "$HOME/.stitchpad/operator.key"

# G-A5: key exists but NO token presented → grant mint must refuse
rm -f "$STATE/operator-grant.probe.reset-others"
out="$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" STITCHPAD_PAD_DIR="$PAD" STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" operator grant probe reset-others 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$STATE/operator-grant.probe.reset-others" ]   && ok 'G-A5: grant mint refused with key-exists-but-no-token (the C2 scenario)'   || bad "G-A5: grant minted without token (rc=$rc)"

# G-A8: symlinked grant file must fail verification (one-shot under swap)
run_sp STITCHPAD_OPERATOR_TOKEN="$TOK" -- operator grant probe reset-others >/dev/null
mv "$STATE/operator-grant.probe.reset-others" "$tmp/grant.aside"
ln -s "$tmp/grant.aside" "$STATE/operator-grant.probe.reset-others"
out="$(run_sp STITCHPAD_NAME=probe -- reset victim 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'G-A8: symlinked grant refused (verify reads no symlink)'   || bad 'G-A8: symlinked grant accepted (TOCTOU/swap contract broken)'
rm -f "$STATE/operator-grant.probe.reset-others"

# G-A9: ~/.stitchpad itself a symlink → keygen must refuse
rm -rf "$HOME/.stitchpad"
mkdir -p "$tmp/a9-target"
ln -s "$tmp/a9-target" "$HOME/.stitchpad"
out="$(run_sp -- operator keygen --force 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$tmp/a9-target/operator.key" ]   && ok 'G-A9: keygen refuses to write through a symlinked ~/.stitchpad'   || bad 'G-A9: keygen wrote through symlinked dir'
rm "$HOME/.stitchpad"; mkdir -p "$HOME/.stitchpad"; cp "$SECRET" "$HOME/.stitchpad/operator.key"; chmod 600 "$HOME/.stitchpad/operator.key"

# G-A10: traversal seat/op names refused at mint (sanitize contract)
out="$(run_sp STITCHPAD_OPERATOR_TOKEN="$TOK" -- operator grant '../../tmp/kimi2-a10' owned 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'G-A10: traversal seat name refused at grant mint'   || bad "G-A10: traversal seat minted (rc=$rc)"
[ ! -e "$tmp/tmp/kimi2-a10" ] && ok 'G-A10b: no file landed outside PAD_STATE'   || bad 'G-A10b: file escaped PAD_STATE'

echo ""
echo "Passed:  $pass"
echo "Failed:  $fail"
echo ""
[ "$fail" -eq 0 ] && echo "All authority-redesign gates PASSED." || echo "Some authority-redesign gates FAILED."
[ "$fail" -eq 0 ]
