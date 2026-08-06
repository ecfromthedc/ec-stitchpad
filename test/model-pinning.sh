#!/usr/bin/env bash
# model-pinning.sh — TASK-1 regression tests: requested vs resolved model truth.
# Bash 3.2 compatible. Isolated mktemp fixture, mocked curl/ocean-heartbeat,
# no live daemon, no side effects outside owned paths.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
OCEAN_ADAPTER="$ROOT/tool/adapters/ocean.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-model-pin.XXXXXX")"
cleanup() {
  for n in codex jseat rejoinseat wakeok unpinned refuseunpin refusemis telemis keeperseat handoffseat; do
    STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" heartbeat --stop "$n" >/dev/null 2>&1 || true
  done
  STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/home"
export HOME="$tmp/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

PASSED=0; FAILED=0
ok()   { PASSED=$((PASSED + 1)); printf '  PASS %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL %s: %s\n' "$1" "$2" >&2; }
check(){ # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

STATE="$tmp/.stitchpad/.state"

cd "$tmp"
"$SP" init --name model-pin >/dev/null 2>&1
"$SP" daemon stop >/dev/null 2>&1 || true

printf '\n--- helpers: record/requested/policy ---\n'
# shellcheck disable=SC2034
BIN_DIR="$ROOT/tool/bin"
source "$ROOT/tool/bin/lib.sh"

printf 'gpt-5.6-sol' > "$STATE/seat-model.codex"
check 'requested round-trip' 'gpt-5.6-sol' "$(sp_model_pin_requested "$STATE" codex)"
sp_model_pin_record_resolved "$STATE" codex 'gpt-5.6-sol' 'openai' 'unit' 'sid-1'
check 'resolved recorded' 'gpt-5.6-sol' "$(cat "$STATE/resolved-model.codex")"
check 'resolved provider recorded' 'openai' "$(cat "$STATE/resolved-provider.codex")"
check 'resolved meta provenance' 'unit' "$(cut -d'|' -f1 "$STATE/resolved-model-meta.codex")"
sp_model_pin_record_resolved "$STATE" codex '' '' 'unit' 'sid-1'
check 'empty read never erases resolved truth' 'gpt-5.6-sol' "$(cat "$STATE/resolved-model.codex")"
if sp_model_pin_record_resolved "$STATE" '../escape' 'x' '' 'unit' 2>/dev/null; then
  bad 'hostile seat name refused' 'rc!=0' 'rc=0'
else
  ok 'hostile seat name refused'
fi
check 'default policy is surface' 'surface' "$(sp_model_pin_policy "$STATE")"
check 'env policy override' 'refuse' "$(STITCHPAD_MODEL_PIN_POLICY=refuse sp_model_pin_policy "$STATE")"
printf 'refuse' > "$STATE/model-pin-policy"
check 'policy file honored' 'refuse' "$(sp_model_pin_policy "$STATE")"
rm -f "$STATE/model-pin-policy"

printf '\n--- check: match / mismatch / heal ---\n'
sp_model_pin_check "$STATE" codex
check 'matching requested/resolved: rc 0' '0' "$?"
[ ! -f "$STATE/model-mismatch.codex" ] && ok 'matching: no marker' || bad 'matching: no marker' 'marker present' ''
sp_model_pin_record_resolved "$STATE" codex 'claude-fable-5' '' 'unit' 'sid-2'
merr="$(sp_model_pin_check "$STATE" codex 2>&1 >/dev/null)"
check 'mismatch: rc 2' '2' "$?"
check 'mismatch marker requested field' 'gpt-5.6-sol' "$(cut -d'|' -f1 "$STATE/model-mismatch.codex")"
check 'mismatch marker resolved field' 'claude-fable-5' "$(cut -d'|' -f2 "$STATE/model-mismatch.codex")"
case "$merr" in *"MISMATCH @codex"*"gpt-5.6-sol"*"claude-fable-5"*) ok 'mismatch loud stderr line' ;; *) bad 'mismatch loud stderr line' 'loud line' "$merr" ;; esac
sp_model_pin_record_resolved "$STATE" codex 'gpt-5.6-sol' '' 'unit' 'sid-3'
sp_model_pin_check "$STATE" codex
[ ! -f "$STATE/model-mismatch.codex" ] && ok 'healed truth clears marker' || bad 'healed truth clears marker' 'marker survived' ''
rm -f "$STATE/resolved-model.codex" "$STATE/resolved-provider.codex" "$STATE/resolved-model-meta.codex"

printf '\n--- bind-session: env telemetry becomes resolved truth ---\n'
# ACCEPTANCE SCENARIO (2026-08-02 incident): the seat pins gpt-5.6-sol but the
# binding runtime's env reports claude-fable-5. The mechanism must record the
# resolved drift and surface it loudly.
berr="$(CODEX_MODEL='claude-fable-5' STITCHPAD_PAD_DIR="$tmp/.stitchpad" \
  "$SP" bind-session sid-codex codex 2>&1 >/dev/null)"
check 'bind-session resolved from env' 'claude-fable-5' "$(cat "$STATE/resolved-model.codex")"
check 'bind-session meta source' 'bind-session-env' "$(cut -d'|' -f1 "$STATE/resolved-model-meta.codex")"
check 'bind-session meta session' 'sid-codex' "$(cut -d'|' -f3 "$STATE/resolved-model-meta.codex")"
check 'bind-session keeps legacy model file' 'claude-fable-5' "$(cat "$STATE/model.codex")"
check 'bind-session leaves requested pin untouched' 'gpt-5.6-sol' "$(cat "$STATE/seat-model.codex")"
check 'ACCEPTANCE: drift marker active' 'gpt-5.6-sol|claude-fable-5' \
  "$(cut -d'|' -f1,2 "$STATE/model-mismatch.codex")"
case "$berr" in *'MISMATCH @codex'*) ok 'ACCEPTANCE: drift surfaced loudly' ;; *) bad 'ACCEPTANCE: drift surfaced loudly' 'loud line' "$berr" ;; esac
# Heal: rebind with the pinned model.
CODEX_MODEL='gpt-5.6-sol' STITCHPAD_PAD_DIR="$tmp/.stitchpad" \
  "$SP" bind-session sid-codex codex >/dev/null 2>&1
[ ! -f "$STATE/model-mismatch.codex" ] && ok 'bind-session heal clears marker' || bad 'bind-session heal clears marker' 'marker survived' ''

printf '\n--- join / rejoin funnel through bind-session ---\n'
CODEX_MODEL='kimi-k3' STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" join jseat ocean push sid-jseat >/dev/null 2>&1
check 'join records resolved' 'kimi-k3' "$(cat "$STATE/resolved-model.jseat" 2>/dev/null)"
# Rejoin after session end (resume path): marker set, bind again, resolved updated.
printf 'kimi-k3' > "$STATE/seat-model.rejoinseat"
STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" join rejoinseat ocean push sid-rejoin >/dev/null 2>&1
touch "$STATE/session-end.sid-rejoin"
CODEX_MODEL='kimi-k3-r2' STITCHPAD_PAD_DIR="$tmp/.stitchpad" \
  "$SP" bind-session sid-rejoin rejoinseat >/dev/null 2>&1
check 'rejoin/resume records new resolved' 'kimi-k3-r2' "$(cat "$STATE/resolved-model.rejoinseat")"
check 'rejoin mismatch vs old pin marked' 'kimi-k3|kimi-k3-r2' \
  "$(cut -d'|' -f1,2 "$STATE/model-mismatch.rejoinseat")"

printf '\n--- handoff re-entry: fresh session bind records resolved ---\n'
# shift-change delivers a handoff into a FRESH session; that session's first
# identity act is bind-session, which now records resolved truth.
printf 'glm-5' > "$STATE/seat-model.handoffseat"
touch "$STATE/session-end.sid-handoff"
CODEX_MODEL='glm-5' STITCHPAD_PAD_DIR="$tmp/.stitchpad" \
  "$SP" bind-session sid-handoff handoffseat >/dev/null 2>&1
check 'handoff re-entry resolved recorded' 'glm-5' "$(cat "$STATE/resolved-model.handoffseat")"
[ ! -f "$STATE/model-mismatch.handoffseat" ] && ok 'handoff matching pin: no marker' || bad 'handoff matching pin: no marker' 'marker present' ''

printf '\n--- ocean adapter wake path ---\n'
mockbin="$tmp/mockbin"; mkdir -p "$mockbin"
calls="$tmp/ocean.calls"
cat > "$mockbin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  */config)
    printf '{"model":"%s","provider":"openai"}\n' "${MOCK_CONFIG_MODEL:-gpt-5.6-sol}" ;;
  *)  printf '{"session":{"active_turn":null}}\n' ;;
esac
EOF
cat > "$mockbin/ocean-heartbeat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OCEAN_CALLS"
printf '{"ok": true}\n'
EOF
chmod +x "$mockbin/curl" "$mockbin/ocean-heartbeat"

run_adapter() { # run_adapter <name> <sid> [extra env via caller]
  printf 'task body for %s\n' "$1" > "$tmp/taskfile.$1"
  ( cd "$tmp" && PATH="$mockbin:$PATH" OCEAN_CALLS="$calls" SP_TARGET="$2" \
      bash "$OCEAN_ADAPTER" mention "$1" "$tmp/.stitchpad/stitchpad.md" "$tmp/taskfile.$1" )
}

# 1) pinned + daemon agrees: wake proceeds, resolved recorded, no marker.
STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" join wakeok ocean push sid-wakeok >/dev/null 2>&1
printf 'gpt-5.6-sol' > "$STATE/seat-model.wakeok"
out="$(run_adapter wakeok sid-wakeok 2>"$tmp/wakeok.err")"
check 'wakeok adapter rc' '0' "$?"
case "$(tr '\n' ' ' < "$calls")" in *'--session-id sid-wakeok'*'--model gpt-5.6-sol'*) ok 'wakeok pinned model passed to wake' ;; *) bad 'wakeok pinned model passed to wake' 'pin in wake args' "$(tr '\n' ' ' < "$calls" | tail -c 300)" ;; esac
check 'wakeok resolved recorded from daemon config' 'gpt-5.6-sol' "$(cat "$STATE/resolved-model.wakeok")"
check 'wakeok resolved provider' 'openai' "$(cat "$STATE/resolved-provider.wakeok")"
check 'wakeok meta source' 'ocean-wake-config-rpc' "$(cut -d'|' -f1 "$STATE/resolved-model-meta.wakeok")"
[ ! -f "$STATE/model-mismatch.wakeok" ] && ok 'wakeok no marker' || bad 'wakeok no marker' 'marker present' ''
[ ! -s "$tmp/wakeok.err" ] && ok 'wakeok quiet stderr' || bad 'wakeok quiet stderr' 'empty' "$(cat "$tmp/wakeok.err")"

# 2) unpinned seat, surface policy: loud unpinned line, wake still proceeds.
STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" join unpinned ocean push sid-unpinned >/dev/null 2>&1
: > "$calls"
out="$(run_adapter unpinned sid-unpinned 2>"$tmp/unpinned.err")"
check 'unpinned surface rc 0' '0' "$?"
[ -s "$calls" ] && ok 'unpinned surface: wake proceeded' || bad 'unpinned surface: wake proceeded' 'wake call' 'none'
case "$(cat "$tmp/unpinned.err")" in *'NO requested pin'*'daemon global default'*) ok 'unpinned surfaced loudly' ;; *) bad 'unpinned surfaced loudly' 'unpinned line' "$(cat "$tmp/unpinned.err")" ;; esac

# 3) unpinned seat, refuse policy: no wake, rc 1.
STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" join refuseunpin ocean push sid-refuseunpin >/dev/null 2>&1
: > "$calls"
out="$(STITCHPAD_MODEL_PIN_POLICY=refuse run_adapter refuseunpin sid-refuseunpin 2>"$tmp/refuseunpin.err")"
check 'refuse unpinned rc 1' '1' "$?"
[ ! -s "$calls" ] && ok 'refuse unpinned: no wake call' || bad 'refuse unpinned: no wake call' 'none' "$(cat "$calls")"
case "$(cat "$tmp/refuseunpin.err")" in *'refusing unpinned wake'*) ok 'refuse unpinned loud reason' ;; *) bad 'refuse unpinned loud reason' 'reason' "$(cat "$tmp/refuseunpin.err")" ;; esac

# 4) active mismatch + refuse policy: no wake.
STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" join refusemis ocean push sid-refusemis >/dev/null 2>&1
printf 'gpt-5.6-sol' > "$STATE/seat-model.refusemis"
printf 'claude-fable-5' > "$STATE/resolved-model.refusemis"
: > "$calls"
out="$(STITCHPAD_MODEL_PIN_POLICY=refuse run_adapter refusemis sid-refusemis 2>"$tmp/refusemis.err")"
check 'refuse mismatch rc 1' '1' "$?"
[ ! -s "$calls" ] && ok 'refuse mismatch: no wake call' || bad 'refuse mismatch: no wake call' 'none' "$(cat "$calls")"
case "$(cat "$tmp/refusemis.err")" in *'MISMATCH @refusemis'*'refusing wake'*) ok 'refuse mismatch loud reason' ;; *) bad 'refuse mismatch loud reason' 'reason' "$(cat "$tmp/refusemis.err")" ;; esac

# 5) surface policy: daemon readback disagrees with pin → marker after wake, rc 0.
STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" join telemis ocean push sid-telemis >/dev/null 2>&1
printf 'gpt-5.6-sol' > "$STATE/seat-model.telemis"
: > "$calls"
out="$(MOCK_CONFIG_MODEL='claude-fable-5' run_adapter telemis sid-telemis 2>"$tmp/telemis.err")"
check 'telemetry mismatch surface rc 0' '0' "$?"
check 'telemetry mismatch resolved recorded' 'claude-fable-5' "$(cat "$STATE/resolved-model.telemis")"
check 'telemetry mismatch marker' 'gpt-5.6-sol|claude-fable-5' \
  "$(cut -d'|' -f1,2 "$STATE/model-mismatch.telemis")"
case "$(cat "$tmp/telemis.err")" in *'MISMATCH @telemis'*) ok 'telemetry mismatch surfaced loudly' ;; *) bad 'telemetry mismatch surfaced loudly' 'loud line' "$(cat "$tmp/telemis.err")" ;; esac

printf '\n--- keeper recovery path: REMOVED, see ledger P47 ---\n'
# These assertions drove the task-parser keeper, which no longer ships: production
# invokes the keeper bare through launchd every two minutes, and that keeper
# answers a bare invocation with usage + exit 2, so keeping it would have switched
# the fleet's watchdog off silently. The mention-oracle keeper (v2) ships instead.
#
# The model-pin CORE above is untouched and still fully gated (50 assertions). The
# resolved-model telemetry these five checked HAS been ported into v2 — it records
# `keeper-wake-config-rpc` after an accepted wake exactly as before — but v2 also
# probes daemon health and session state, so exercising it needs a fixture shaped
# around that control flow rather than this one. That fixture is owed, and is
# filed as P47 rather than left as a silent hole.
#
# Keeper behaviour is NOT uncovered in the meantime: test/seat-keeper.sh gates v2
# directly, including the invariant this file never checked — that a keeper run
# does not advance any seen.<name> cursor.

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll model-pinning gates PASSED.\n'; exit 0; }
printf '\nSome model-pinning gates FAILED.\n'; exit 1
