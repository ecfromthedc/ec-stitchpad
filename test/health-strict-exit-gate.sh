#!/usr/bin/env bash
# health-strict-exit-gate.sh — `stitchpad health --strict` must make the severity
# roll-up reachable from an exit code, and must not change stdout doing it.
#
# THE BUG (evidence/reviews, k3 F3): health printed
#   summary: error — 0 ok, 1 warning, 1 error, 0 pad issue(s)
# and exited 0. It computed the roll-up correctly and discarded it at the exact
# boundary a caller consumes, so `stitchpad health && echo healthy` said healthy
# and any orchestrator scripting `health || alert` never alerted.
#
# The default exit code is deliberately still 0 — health is captured elsewhere
# under `set -euo pipefail` with no guard (test/test-health-readonly.sh:194), and
# flipping it unannounced would turn a reporting fix into an outage on a live
# fleet whose callers are not all in this repo. That compromise is itself gated
# here (S5), so it stays a decision rather than drifting into an accident.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-health-strict.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
export TMPDIR="$TMP"
export HOME="$TMP/home"; mkdir -p "$HOME"
# Nothing here starts a watcher or a ticker, so nothing needs killing (ledger P9).
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT
export STITCHPAD_HEARTBEAT_AUTOSTART=0
export STITCHPAD_WATCH_START_GRACE=0
export STITCHPAD_STEAL=1

PAD="$TMP/proj"; mkdir -p "$PAD"
( cd "$PAD" && "$SP" init --name proj >/dev/null 2>&1 ) || { bad "setup: init"; echo "=== RESULTS: $pass PASS, $((fail+1)) FAIL ==="; exit 1; }
( cd "$PAD" && "$SP" join dale claude pull >/dev/null 2>&1 ) || { bad "setup: join"; echo "=== RESULTS: $pass PASS, $((fail+1)) FAIL ==="; exit 1; }

echo "=== health --strict: the roll-up must reach the exit code ==="

# Force an ERROR: point the seat at an adapter that does not exist.
# missing_adapter is an error-tier token in health.py's classifier.
sed -i '' 's/^dale | claude |/dale | nosuchadapter |/' "$PAD/.stitchpad/stitchpad.md" 2>/dev/null \
  || sed -i 's/^dale | claude |/dale | nosuchadapter |/' "$PAD/.stitchpad/stitchpad.md" 2>/dev/null

_sum="$( cd "$PAD" && "$SP" health 2>&1 | tail -1 )"
case "$_sum" in
  *"summary: error"*) ok "S0: fixture really is in an error state (mutation applied)" ;;
  *) bad "S0: fixture is not in an error state — every assertion below is vacuous (got: $_sum)" ;;
esac

( cd "$PAD" && "$SP" health --strict >/dev/null 2>&1 ); _rc_err=$?
[ "$_rc_err" -eq 1 ] \
  && ok "S1: --strict exits 1 when the summary is error" \
  || bad "S1: --strict exited $_rc_err on an error summary, expected 1"

# The orchestrator pattern from the finding, asserted directly.
if ( cd "$PAD" && "$SP" health --strict >/dev/null 2>&1 ); then
  bad "S2: 'health --strict && ok' still reports healthy on a broken pad"
else
  ok "S2: 'health --strict || alert' actually alerts"
fi

# stdout is a contract of its own: --strict changes the exit code, nothing else.
_a="$( cd "$PAD" && "$SP" health 2>/dev/null )"
_b="$( cd "$PAD" && "$SP" health --strict 2>/dev/null )"
[ "$_a" = "$_b" ] \
  && ok "S3: --strict leaves stdout byte-identical" \
  || bad "S3: --strict changed stdout"

# Warnings-only tier: repair the adapter, keep the seat heartbeat-less.
sed -i '' 's/^dale | nosuchadapter |/dale | claude |/' "$PAD/.stitchpad/stitchpad.md" 2>/dev/null \
  || sed -i 's/^dale | nosuchadapter |/dale | claude |/' "$PAD/.stitchpad/stitchpad.md" 2>/dev/null
_sum2="$( cd "$PAD" && "$SP" health 2>&1 | tail -1 )"
( cd "$PAD" && "$SP" health --strict >/dev/null 2>&1 ); _rc_warn=$?
case "$_sum2" in
  *"summary: warn"*)
    [ "$_rc_warn" -eq 2 ] \
      && ok "S4: --strict exits 2 when there are warnings but no errors" \
      || bad "S4: --strict exited $_rc_warn on a warn summary, expected 2" ;;
  *"summary: ok"*)
    [ "$_rc_warn" -eq 0 ] \
      && ok "S4: --strict exits 0 on a clean summary" \
      || bad "S4: --strict exited $_rc_warn on a clean summary, expected 0" ;;
  *) bad "S4: could not reach a warn-or-clean summary to test the middle tier (got: $_sum2)" ;;
esac

# S5 pins the deliberate compromise: the DEFAULT stays 0, so existing callers
# that capture health under `set -e` keep working. If someone later decides the
# default should be strict, this assertion is the place that argument happens.
sed -i '' 's/^dale | claude |/dale | nosuchadapter |/' "$PAD/.stitchpad/stitchpad.md" 2>/dev/null \
  || sed -i 's/^dale | claude |/dale | nosuchadapter |/' "$PAD/.stitchpad/stitchpad.md" 2>/dev/null
( cd "$PAD" && "$SP" health >/dev/null 2>&1 ); _rc_def=$?
[ "$_rc_def" -eq 0 ] \
  && ok "S5: the DEFAULT exit code is still 0 (back-compat, on purpose)" \
  || bad "S5: default health exit changed to $_rc_def — callers capturing it under set -e will now die"

( cd "$PAD" && "$SP" health --json >/dev/null 2>&1 ); _rc_json=$?
[ "$_rc_json" -eq 0 ] \
  && ok "S6: --json without --strict still exits 0" \
  || bad "S6: --json exit changed to $_rc_json"

echo ""
echo "=== RESULTS: $pass PASS, $fail FAIL ==="
[ "$fail" -eq 0 ] || exit 1
