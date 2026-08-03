#!/usr/bin/env bash
# authority-hardfix-regression.sh — km2's non-author fix lane for fx1's
# authority findings on kimi2's 636cbc4:
#   A-1 HIGH  authority check crashed on the AUTHORIZED path ($seat unbound)
#   A-2 MED   authority LEVEL was seat-writable pad state (forgeable input)
#   A-3 LOW   operator key perms not enforced (0644 key still granted)
#   A-4 HIGH  $HOME-scoped key root + ungated keygen = self-minted universe
#   A-5 HIGH  legitimate grants failed whenever seat HOME != operator HOME
# Isolated mktemp fixtures, isolated HOME, explicit operator-key override
# (never the real operator key), no network, children reaped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-ahf.XXXXXX")"
cleanup() { ( cd "$tmp/pad" 2>/dev/null && "$SP" daemon stop >/dev/null 2>&1 ); rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/home"
export HOME="$tmp/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
# A-4/A-5 fixture discipline: the operator root is explicit, isolated, and
# never the real passwd-home key.
export STITCHPAD_OPERATOR_KEY_PATH="$tmp/operator-root/operator.key"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

PASSED=0; FAILED=0
ok()   { PASSED=$((PASSED + 1)); printf '  PASS %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL %s: %s\n' "$1" "$2" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

PAD="$tmp/pad/.stitchpad"
mkdir -p "$tmp/pad"
( cd "$tmp/pad" && "$SP" init --name ahftest >/dev/null 2>&1 && "$SP" daemon stop >/dev/null 2>&1 )
( cd "$tmp/pad" && "$SP" join alice codex pull - >/dev/null 2>&1 )
( cd "$tmp/pad" && "$SP" join bob codex pull - >/dev/null 2>&1 )
( cd "$tmp/pad" && "$SP" operator keygen >/dev/null 2>&1 )
TOK="$(cat "$STITCHPAD_OPERATOR_KEY_PATH")"

printf '\n=== A-1: authority check works on the AUTHORIZED path ===\n'
( cd "$tmp/pad" && STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" operator grant alice publish >/dev/null 2>&1 )
( cd "$tmp/pad" && STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" authority set alice deploy >/dev/null 2>&1 )
out="$( cd "$tmp/pad" && "$SP" authority check alice publish 2>&1 )"; rc=$?
check 'R1 authorized check exits 0 (was: unbound $seat crash)' '0' "$rc"
case "$out" in *'✓ @alice is authorized for: publish'*) ok 'R1b authorized check prints the seat' ;; *) bad 'R1b authorized check prints the seat' "$out" ;; esac
case "$out" in *unbound*) bad 'R1c no unbound-variable crash' "$out" ;; *) ok 'R1c no unbound-variable crash' ;; esac
out="$( cd "$tmp/pad" && "$SP" authority check alice reset-others 2>&1 )"; rc=$?
check 'R1d denied check still exits 1' '1' "$([ $rc -ne 0 ] && echo 1 || echo 0)"

printf '\n=== A-2: hand-written level is detected and ignored ===\n'
printf 'deploy' > "$PAD/.state/authority.bob"; rm -f "$PAD/.state/authority.bob.seal"
out="$( cd "$tmp/pad" && "$SP" authority show bob 2>/dev/null )"
check 'R2 forged level reads as write (keyed universe)' 'write' "$out"
out="$( cd "$tmp/pad" && "$SP" authority show bob 2>&1 >/dev/null )"
case "$out" in *UNSEALED*) ok 'R2b forged level is LOUD' ;; *) bad 'R2b forged level is LOUD' "$out" ;; esac
out="$( cd "$tmp/pad" && STITCHPAD_NAME=bob "$SP" authority check bob publish 2>&1 )"; rc=$?
check 'R2c forged level does not authorize' '1' "$([ $rc -ne 0 ] && echo 1 || echo 0)"
out="$( cd "$tmp/pad" && "$SP" authority show alice 2>&1 )"
check 'R3 legitimate sealed level reads deploy' 'deploy' "$out"
check 'R3b authority set wrote the seal sidecar' '1' "$([ -s "$PAD/.state/authority.alice.seal" ] && echo 1 || echo 0)"
out="$( cd "$tmp/pad" && "$SP" authority show 2>&1 )"
case "$out" in *.seal*) bad 'R3c show does not list seal sidecars as seats' "$out" ;; *) ok 'R3c show does not list seal sidecars as seats' ;; esac
# legacy advisory path: no key anywhere → hand-written level still honored
out="$( cd "$tmp/pad" && env STITCHPAD_OPERATOR_KEY_PATH="$tmp/nonexistent-dir/k" "$SP" authority show bob 2>/dev/null )"
check 'R4 keyless pad keeps advisory legacy level' 'deploy' "$out"

printf '\n=== A-3: key perms enforced ===\n'
chmod 644 "$STITCHPAD_OPERATOR_KEY_PATH"
out="$( cd "$tmp/pad" && STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" operator grant carol deploy 2>&1 )"; rc=$?
check 'R5 0644 key refuses to grant' '1' "$([ $rc -ne 0 ] && echo 1 || echo 0)"
case "$out" in *'chmod 600'*) ok 'R5b refusal names the perms fix' ;; *) bad 'R5b refusal names the perms fix' "$out" ;; esac
chmod 600 "$STITCHPAD_OPERATOR_KEY_PATH"
out="$( cd "$tmp/pad" && STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" operator grant carol deploy 2>&1 )"; rc=$?
check 'R5c 0600 key grants again' '0' "$rc"

printf '\n=== A-4/A-5: the key root is not $HOME-derived ===\n'
kp="$( env -u STITCHPAD_OPERATOR_KEY_PATH HOME="$tmp/fake-home" PAD_DIR="$PAD" PAD_STATE="$PAD/.state" bash -c \
  '. "'"$ROOT"'/tool/bin/scope-authority.sh" >/dev/null 2>&1; _sp_operator_key_path' )"
case "$kp" in *fake-home*) bad 'R6 key path ignores ambient HOME' "$kp" ;; *) ok 'R6 key path ignores ambient HOME' ;; esac
# seat under a DIFFERENT HOME verifies the operator's grant via the shared root
out="$( cd "$tmp/pad" && env HOME="$tmp/fake-home" STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" operator grant dave deploy 2>&1 )"; rc=$?
check 'R7 A-5: grant mint works from a seat with a different HOME' '0' "$rc"
# a self-minted universe under a fake HOME cannot authorize the protected op
mkdir -p "$tmp/fake-home2/.stitchpad"
openssl rand -hex 32 > "$tmp/fake-home2/.stitchpad/operator.key" 2>/dev/null || od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$tmp/fake-home2/.stitchpad/operator.key"
chmod 600 "$tmp/fake-home2/.stitchpad/operator.key"
FAKETOK="$(cat "$tmp/fake-home2/.stitchpad/operator.key")"
out="$( cd "$tmp/pad" && env -u STITCHPAD_OPERATOR_KEY_PATH HOME="$tmp/fake-home2" STITCHPAD_OPERATOR_TOKEN="$FAKETOK" "$SP" authority set bob deploy 2>&1 )"; rc=$?
# refused: either the real passwd-home key exists (token mismatch) or no key
# exists there at all (credential required) — the fake universe never applies
check 'R8 A-4: fake-HOME self-minted key cannot elevate' '1' "$([ $rc -ne 0 ] && echo 1 || echo 0)"
check 'R8b bob level untouched by the fake-universe attempt' 'write' \
  "$( cd "$tmp/pad" && "$SP" authority show bob 2>/dev/null )"

printf '\n=== A-4 hardening: rotation is an operator act ===\n'
out="$( cd "$tmp/pad" && "$SP" operator keygen --force 2>&1 )"; rc=$?
check 'R9 rotation without the current token refused' '1' "$([ $rc -ne 0 ] && echo 1 || echo 0)"
check 'R9b key unchanged after refused rotation' "$TOK" "$(cat "$STITCHPAD_OPERATOR_KEY_PATH")"
out="$( cd "$tmp/pad" && STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" operator keygen --force 2>&1 )"; rc=$?
check 'R9c rotation with the current token succeeds' '0' "$rc"

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll authority-hardfix gates PASSED.\n'; exit 0; }
printf '\nSome authority-hardfix gates FAILED.\n'; exit 1
