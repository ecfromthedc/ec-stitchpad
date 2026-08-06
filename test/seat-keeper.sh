#!/usr/bin/env bash
# seat-keeper.sh — gate for the anti-starvation keeper (v2, mention-oracle).
#
# WHY THIS FILE CHANGED SHAPE: two keeper designs existed in parallel — a
# task-parser one on the hardening branch and this mention-oracle one on the
# live branch. The live one ships, for one decisive reason: production invokes
# `/bin/bash ~/.pasture/bin/seat-keeper.sh` with NO ARGUMENTS every two minutes
# via launchd, and the task-parser keeper answers a bare invocation with a usage
# message and exit 2 — it would have silently switched the fleet's watchdog off.
#
# The previous version of this suite asserted "the keeper source contains no
# wake/peek call" — a grep against the source, standing in for the invariant that
# actually matters: THE KEEPER MUST NOT MOVE A SEAT'S CURSOR. That invariant is
# testable directly, and is stronger than the proxy, because `--peek-ordinal` is
# non-consuming by design and banning it by name forbids a safe read.
#
#   G1  a bare invocation exits 0 (the production path)
#   G2  the conf file is honoured, and a missing conf is not fatal
#   G3  a keeper run does NOT advance any seen.<name> cursor
#   G4  an unreachable daemon FAILS CLOSED WITH A VOICE — no wake, and it says so
#   G5  the quarantine bound exists and is finite
#   G6  no pkill / kill -9 / rm -rf anywhere in the keeper
#   G7  MUTANT: let the keeper consume a mention -> G3 goes RED
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPER="$ROOT/tool/bin/seat-keeper.sh"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sk-gate.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

run_keeper() { # $1=keeper path, rest=env assignments already exported by caller
  ( cd "$TMP" && SEAT_KEEPER_CONF="$TMP/keeper.conf" SEAT_KEEPER_LOG="$TMP/keeper.log" \
      /bin/bash "$1" ) 2>&1
}

echo "=== seat-keeper (v2) ==="
echo ""

# ── G1: the production invocation ───────────────────────────────────
: > "$TMP/keeper.conf"
out="$(run_keeper "$KEEPER")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "G1 bare invocation exits 0 (the launchd path)"
else bad "G1 bare invocation exited $rc — production watchdog would be broken: $(printf '%s' "$out" | head -2)"; fi

# ── G2: conf handling ───────────────────────────────────────────────
printf '%s\n' "$TMP/nosuchrepo" > "$TMP/keeper.conf"
out="$(run_keeper "$KEEPER")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "G2 a conf naming a missing repo is survivable, not fatal"
else bad "G2 keeper exited $rc on a missing repo: $(printf '%s' "$out" | head -2)"; fi

# ── G3: THE INVARIANT — cursors belong to the watcher ───────────────
PAD="$TMP/repo/.stitchpad"; mkdir -p "$PAD/.state"
printf '5' > "$PAD/.state/seen.alpha"
printf '7' > "$PAD/.state/seen.beta"
printf '%s\n' "$TMP/repo" > "$TMP/keeper.conf"
before="$(cat "$PAD/.state/seen.alpha")|$(cat "$PAD/.state/seen.beta")"
run_keeper "$KEEPER" >/dev/null 2>&1
after="$(cat "$PAD/.state/seen.alpha")|$(cat "$PAD/.state/seen.beta")"
if [ "$before" = "$after" ]; then ok "G3 a keeper run left every seen cursor untouched ($after)"
else bad "G3 the keeper MOVED a cursor: $before -> $after"; fi

# ── G4: fail closed, with a voice ───────────────────────────────────
# SEAT_KEEPER_RELOG_S=0 defeats the alert rate limiter. That limiter is correct in
# production — the keeper runs every 120s and must not spam — but its stamp file
# outlives a test run, so without this the alert is emitted once and every later
# run of this gate sees silence and calls it a regression. (It did exactly that.)
out="$( cd "$TMP" && SEAT_KEEPER_CONF="$TMP/keeper.conf" SEAT_KEEPER_LOG="$TMP/k2.log" \
        SEAT_KEEPER_RELOG_S=0 OCEAN_DAEMON_URL="http://127.0.0.1:59999" \
        /bin/bash "$KEEPER" 2>&1 )"
combined="$out$(cat "$TMP/k2.log" 2>/dev/null || true)"
case "$combined" in
  *DAEMON*|*daemon*|*unreachable*) ok "G4 an unreachable daemon is reported, not passed over in silence" ;;
  *) bad "G4 unreachable daemon produced NO voice — the fleet would sit unattended silently" ;;
esac

# ── G4b: a test run must not write into the live install ────────────
# The alert stamp used to be pinned to $HOME/.pasture/ regardless of where the
# log was pointed, so running this very gate suppressed the real fleet's
# daemon-unreachable alert for an hour.
if [ -f "$TMP/.keeper-daemon-unreachable" ]; then
  ok "G4b the alert stamp follows SEAT_KEEPER_LOG — the install is untouched"
else
  bad "G4b no stamp beside the test log; it is being written somewhere else (the install?)"
fi

# ── G5/G6: bounds and blast radius ──────────────────────────────────
if grep -qE '^MAX_STRIKES=[0-9]+' "$KEEPER"; then ok "G5 quarantine bound present ($(grep -oE '^MAX_STRIKES=[0-9]+' "$KEEPER"))"
else bad "G5 no MAX_STRIKES bound — a no-effect wake could repeat forever"; fi
if grep -qE 'pkill|kill -9|kill -KILL|rm -rf' "$KEEPER"; then
  bad "G6 keeper contains pkill/kill -9/rm -rf: $(grep -nE 'pkill|kill -9|kill -KILL|rm -rf' "$KEEPER" | head -1)"
else ok "G6 no pkill, no kill -9, no rm -rf"; fi

# ── G7: MUTANT — a keeper that consumes the mention ─────────────────
echo ""
echo "  -- mutant: keeper consumes the cursor --"
MUT="$TMP/keeper-mutant.sh"; cp "$KEEPER" "$MUT"
python3 - "$MUT" "$PAD/.state" <<'PY'
import sys
p, state = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8').read()
anchor = 'echo "=== seat-keeper'
inject = '\nprintf 99 > "%s/seen.alpha" 2>/dev/null || true\n' % state
i = s.index('\n', s.index('set -uo pipefail'))
open(p, 'w', encoding='utf-8').write(s[:i] + inject + s[i:])
PY
if [ $? -ne 0 ]; then
  bad "G7 MUTANT DID NOT APPLY -- INCONCLUSIVE, not a pass"
else
  printf '5' > "$PAD/.state/seen.alpha"
  run_keeper "$MUT" >/dev/null 2>&1
  if [ "$(cat "$PAD/.state/seen.alpha")" != "5" ]; then
    ok "G7 a cursor-consuming keeper is detected by G3"
  else
    bad "G7 mutant applied but G3 would not have caught it"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "seat keeper ok"
