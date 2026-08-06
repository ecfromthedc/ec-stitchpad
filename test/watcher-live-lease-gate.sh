#!/usr/bin/env bash
# watcher-live-lease-gate.sh — a LIVE supervisor is never scored dead on one
# stale wall-clock observation (NEXT-SESSION-PROMPT OPEN #1).
#
# THE BUG, reproduced under full-tripwire and synthetic CPU load: in the
# daemon's ownerless restart gap the supervisor stamps $lock/heartbeat, sleeps
# 2s, and re-proves its own ownership three times (each check forks python3)
# before stamping again. On a busy machine that stretches past the 5s restart
# grace while the supervisor is alive and merely descheduled — and
# sp_watcher_alive then reported "not alive", so ensure-watcher CANCELLED the
# live generation (watcher-races.sh: "ensure-watcher cancelled or replaced the
# live supervisor gap"). The evidence was timing-fragile while the load-robust
# evidence (exact manifest + kill -0) was already computed and discarded.
#
# The fix: process-liveness decides WHO holds the lock; the lease decides only
# whether it is MAKING PROGRESS — and no-progress needs two observations a
# full grace apart with the SAME heartbeat stamp before it means dead.
#
#   L0 fresh lease, live launcher → alive (unchanged baseline)
#   L1 stale lease, live launcher, first observation → still ALIVE
#   L2 ...and the strike ledger is armed
#   L3 second observation inside the grace → still alive (strike not matured)
#   L4 strike matured (same stamp across a full grace) → dead, honestly
#   L5 heartbeat advanced between observations → alive again (progress wins)
#   L6 dead launcher → dead immediately, no strike patience
#   L7 ensure-watcher end-to-end on the stale-live gap → generation preserved
#   L8 MUTANT: drop the verdict from the ownerless branch → L7 goes red
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-live-lease.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
export TMPDIR="$TMP"
export HOME="$TMP/home"; mkdir -p "$HOME"
# The launcher manifests below record THIS shell (live for the whole gate) or
# an already-dead pid; ensure_watcher in L7/L8 never reaches its spawn line
# because the verdict keeps the gap owner. Nothing long-lived starts (P9).
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT
export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV STITCHPAD_NAME 2>/dev/null || true

PROJ="$TMP/proj"; mkdir -p "$PROJ"; cd "$PROJ"
"$ROOT/tool/bin/stitchpad" init --name live-lease >/dev/null 2>&1
"$ROOT/tool/bin/stitchpad" join watcher codex pull - >/dev/null 2>&1
STITCHPAD_NAME=watcher "$ROOT/tool/bin/stitchpad" heartbeat --touch watcher "$$" >/dev/null 2>&1

export STITCHPAD_HOME="$ROOT/tool"
BIN_DIR="$ROOT/tool/bin"
# shellcheck disable=SC1090
source "$ROOT/tool/bin/lib.sh"
sp_init_paths "$PROJ/.stitchpad" >/dev/null

LOCK="$PAD_STATE/watch.lock.d"
STRIKE="$PAD_STATE/.watch-stale-strike"
GEN="$(date +%s).$$.7"

echo "=== OPEN #1: live supervisor, stale lease — patience, then honesty ==="
echo ""

make_gap_lock() {  # live launcher manifest for THIS shell, no owner
  rm -rf "$LOCK" "$STRIKE"
  mkdir "$LOCK"
  sp_watch_generation_write "$LOCK" "$GEN" || return 1
  sp_watch_launcher_write "$LOCK" "$GEN" || return 1
  rm -f "$LOCK/owner" "$LOCK/pid" 2>/dev/null
}

# L0 — fresh lease baseline
make_gap_lock || { bad "setup: gap lock"; echo "=== RESULTS: $pass PASS, $((fail+1)) FAIL ==="; exit 1; }
date +%s > "$LOCK/heartbeat"
if sp_watcher_alive >/dev/null 2>&1; then
  ok "L0: fresh lease on a live launcher reads alive (baseline unchanged)"
else
  bad "L0: fresh-lease gap no longer reads alive — the fix broke the healthy path"
fi

# L1/L2 — stale lease, live launcher, first observation
printf '%s' "$(( $(date +%s) - 60 ))" > "$LOCK/heartbeat"
rm -f "$STRIKE"
if sp_watcher_alive >/dev/null 2>&1; then
  ok "L1: first stale observation on a LIVE launcher still reads alive"
else
  bad "L1: one stale wall-clock observation scored a live supervisor dead"
fi
if [ -f "$STRIKE" ]; then
  ok "L2: the strike ledger is armed ($(cat "$STRIKE"))"
else
  bad "L2: no strike recorded — L4's maturation has nothing to mature"
fi

# L3 — second observation inside the grace window
if sp_watcher_alive >/dev/null 2>&1; then
  ok "L3: a second observation inside the grace still reads alive"
else
  bad "L3: the strike matured early"
fi

# L4 — strike matured: same stamp, observations a full grace apart
_stamp="$(cat "$LOCK/heartbeat")"
printf '%s|%s|%s' "$GEN" "$_stamp" "$(( $(date +%s) - 30 ))" > "$STRIKE"
if sp_watcher_alive >/dev/null 2>&1; then
  bad "L4: no-progress across a full grace still reads alive — a wedged supervisor is now immortal"
else
  ok "L4: provably-not-progressing supervisor is scored dead, honestly"
fi

# L5 — progress between observations resets the judgment
make_gap_lock
printf '%s' "$(( $(date +%s) - 60 ))" > "$LOCK/heartbeat"
printf '%s|%s|%s' "$GEN" "old-stamp-value" "$(( $(date +%s) - 30 ))" > "$STRIKE"
if sp_watcher_alive >/dev/null 2>&1; then
  ok "L5: an advanced heartbeat stamp (progress) resets the strike — alive"
else
  bad "L5: progress since the last observation was ignored"
fi

# L6 — dead launcher: no patience, immediate reclaim
rm -rf "$LOCK" "$STRIKE"
mkdir "$LOCK"
sp_watch_generation_write "$LOCK" "$GEN" || bad "L6 setup: generation"
bash -c 'exit 0' & _dead=$!; wait "$_dead" 2>/dev/null
python3 - "$GEN" "$_dead" "$PAD_MD" > "$LOCK/launcher" <<'PY'
import json, sys
generation, pid, pad = sys.argv[1:]
print(json.dumps({
    "generation": generation,
    "pid": int(pid),
    "processStart": "gone",
    "command": "bash watch.sh",
    "pad": pad,
}, separators=(",", ":")))
PY
printf '%s' "$(( $(date +%s) - 60 ))" > "$LOCK/heartbeat"
if sp_watcher_alive >/dev/null 2>&1; then
  bad "L6: a DEAD launcher with a stale lease read alive"
else
  ok "L6: dead launcher is scored dead immediately — the patience is live-only"
fi

# L7 — the watcher-races invariant, deterministic: ensure-watcher on the
# stale-live gap must preserve the exact generation and launcher.
make_gap_lock
printf '%s' "$(( $(date +%s) - 60 ))" > "$LOCK/heartbeat"
_launcher_before="$(shasum -a 256 "$LOCK/launcher" | awk '{print $1}')"
ensure_watcher >/dev/null 2>&1 || true
_gen_after="$(cat "$LOCK/generation" 2>/dev/null || echo GONE)"
_launcher_after="$(shasum -a 256 "$LOCK/launcher" 2>/dev/null | awk '{print $1}' || echo GONE)"
if [ "$_gen_after" = "$GEN" ] && [ "$_launcher_after" = "$_launcher_before" ]; then
  ok "L7: ensure-watcher left the live supervisor's stale-lease gap untouched"
else
  bad "L7: ensure-watcher cancelled or replaced the live supervisor gap (gen=$_gen_after)"
fi

# L8 — MUTANT: drop the verdict from the ownerless branch; L7 must go red.
echo "  -- mutant: one stale observation means death again --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$ROOT/tool/." "$MUT/"
python3 - "$MUT/bin/lib.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
anchor = '''  # Live launcher, stale lease: one slow moment is not death (OPEN #1).
  if sp_watch_live_launcher_stale_verdict "$watch_lock" "$generation"; then
    return 0
  fi
'''
if s.count(anchor) != 1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once (%d)\n" % s.count(anchor)); sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(anchor, ''))
PY
if [ $? -ne 0 ]; then
  bad "L8 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  _mut_out="$(
    /usr/bin/env bash -c '
      set -u
      MUT="$1"; PROJ="$2"; GEN="$3"
      export STITCHPAD_HOME="$MUT" STITCHPAD_HEARTBEAT_AUTOSTART=0
      BIN_DIR="$MUT/bin"
      source "$MUT/bin/lib.sh"
      sp_init_paths "$PROJ/.stitchpad" >/dev/null
      LOCK="$PAD_STATE/watch.lock.d"
      rm -rf "$LOCK" "$PAD_STATE/.watch-stale-strike"
      mkdir "$LOCK"
      sp_watch_generation_write "$LOCK" "$GEN" || exit 9
      sp_watch_launcher_write "$LOCK" "$GEN" || exit 9
      rm -f "$LOCK/owner" "$LOCK/pid" 2>/dev/null
      printf "%s" "$(( $(date +%s) - 60 ))" > "$LOCK/heartbeat"
      ensure_watcher >/dev/null 2>&1 || true
      gen_after="$(cat "$LOCK/generation" 2>/dev/null || echo GONE)"
      echo "gen_after=$gen_after"
      # kill anything the mutant ensure spawned, by the pids its lock recorded
      for f in "$LOCK/pid"; do
        [ -f "$f" ] || continue
        p="$(cat "$f" 2>/dev/null || true)"
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
      done
      sp_stop_watchers_for_pad >/dev/null 2>&1 || true
    ' _ "$MUT" "$PROJ" "$GEN" 2>/dev/null
  )"
  case "$_mut_out" in
    *"gen_after=$GEN"*)
      bad "L8: mutant applied but the generation survived ($_mut_out) — L7 may be testing nothing" ;;
    *)
      ok "L8: mutant cancels/replaces the live gap ($_mut_out) — L7 detects the regression" ;;
  esac
fi

echo ""
echo "=== RESULTS: $pass PASS, $fail FAIL ==="
[ "$fail" -eq 0 ] || exit 1
