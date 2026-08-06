#!/usr/bin/env bash
# busy-retry-bound-gate.sh — deepseek F5 / k3 F14: a mention to a seat that can
# never accept it must not retry forever.
#
# THE PAIN, measured on a live pad: claude.sh cannot inject into a running TUI —
# by design — so it exits 3 every single time. The watcher read 3 as "transient
# busy" and retried every SP_DELIVERY_RETRY_SECONDS with no attempt count, no
# backoff and no terminal state. One @mention to an idle claude seat produced a
# desktop notification WITH SOUND every ~2.5s indefinitely, one delivery-log
# line per retry (~34k/day/seat), and a delivery stuck in `busy` forever.
#
# The dangerous fix is the obvious one. A seat that goes SILENT is worse than a
# seat that is noisy, so this gate spends most of its assertions proving the
# message still gets through and new work is still fast:
#
#   G1  the retry is bounded — a permanently-busy adapter stops being called
#   G2  it lands in a NAMED terminal state, not a stuck `busy`
#   G3  the give-up is ANNOUNCED on the pad, exactly once
#   G4  the announcement says the message is not lost
#   G5  a NEW mention resets the bound and is delivered immediately — the seat
#       is not silenced by having given up once
#   G6  a busy seat that becomes idle still completes (no regression)
#   G7  backoff actually grows, and is capped
#   G8  claude.sh notifies ONCE per ordinal however many times it is called
#   G9  a respawned worker does not restart the storm
#   G10 MUTANT: remove the bound → G1 goes RED
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-busy.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT   # workers here are run in the foreground; nothing to reap (P9)

echo "=== ds F5 / k3 F14: the busy retry is bounded, and the seat stays alive ==="
echo ""

# ── a tool home whose only push adapter can NEVER succeed ──────────────────
TEST_TOOL="$TMP/tool"; mkdir -p "$TEST_TOOL/adapters"
ln -s "$ROOT/tool/bin" "$TEST_TOOL/bin"
cat > "$TEST_TOOL/adapters/busy.sh" <<'MOCK'
#!/usr/bin/env bash
set -u
name="$2"; state="$SP_PAD_DIR/.state"
printf '%s|%s\n' "$(date +%s)" "${SP_ORDINAL:-}" >> "$state/busy.$name.calls"
mode="$(cat "$state/busy.$name.mode" 2>/dev/null || printf always)"
case "$mode" in
  always) exit 3 ;;
  idle-now) exit 0 ;;
esac
exit 3
MOCK
chmod +x "$TEST_TOOL/adapters/busy.sh"
export STITCHPAD_HOME="$TEST_TOOL"
BIN_DIR="$ROOT/tool/bin"
# shellcheck disable=SC1090
source "$ROOT/tool/bin/lib.sh"

new_case() {  # $1=label $2=roster row
  CASE_DIR="$TMP/case-$1"; CASE_PAD="$CASE_DIR/.stitchpad"
  mkdir -p "$CASE_PAD/.state"
  { printf '# busy fixture\n\n```roster\n'; printf '%s\n' "$2"; printf '```\n'; } > "$CASE_PAD/stitchpad.md"
  unset PAD_DIR PAD_MD PAD_GIT PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
  sp_init_paths "$CASE_PAD" >/dev/null
}
append_message() { printf '\n## @%s · 00:00\n\n%s\n' "$1" "$2" >> "$PAD_MD"; }
state_value() { sed -n "s/^${2}=//p" "$(delivery_state_file "$1")" 2>/dev/null | tail -1; }
calls() { wc -l < "$PAD_STATE/busy.$1.calls" 2>/dev/null | tr -d ' ' || echo 0; }

new_case bootstrap 'bootstrap | busy | push | t'
STITCHPAD_WATCH_LIB_ONLY=1
# shellcheck disable=SC1090
source "$ROOT/tool/bin/watch.sh"
unset STITCHPAD_WATCH_LIB_ONLY

# Small numbers so the suite runs in seconds; the SHAPE is what is under test.
export SP_DELIVERY_RETRY_SECONDS=1 SP_DELIVERY_BUSY_MAX_ATTEMPTS=4 SP_DELIVERY_BUSY_RETRY_CAP=2

# ── G1..G4: a seat that can never accept ──────────────────────────────────
new_case bound 'stuck | busy | push | t'
append_message operator '@stuck please look at the tripwire'
_t0="$(date +%s)"
delivery_enqueue stuck busy push t
( delivery_worker stuck "$(cat "$(delivery_worker_lock stuck)/token" 2>/dev/null)" ) >/dev/null 2>&1 || true
_t1="$(date +%s)"
_n="$(calls stuck)"
if [ "${_n:-0}" -ge 1 ] && [ "${_n:-0}" -le "$SP_DELIVERY_BUSY_MAX_ATTEMPTS" ]; then
  ok "G1 the adapter was called $_n times and then stopped (bound=$SP_DELIVERY_BUSY_MAX_ATTEMPTS)"
elif [ "${_n:-0}" -eq 0 ]; then
  bad "G1 INVALID PROBE — the adapter was never called, so nothing was bounded"
else
  bad "G1 the adapter was called $_n times, past the bound of $SP_DELIVERY_BUSY_MAX_ATTEMPTS"
fi
_st="$(state_value stuck state)"
if [ "$_st" = "deferred_permanent" ]; then
  ok "G2 the delivery reached a named terminal state (deferred_permanent), not a stuck busy"
else
  bad "G2 delivery state is '$_st' — a mention nobody will ever retry is still shown as in-flight"
fi
_ann="$(grep -c 'could not be woken after' "$PAD_MD" 2>/dev/null || echo 0)"
if [ "${_ann:-0}" -eq 1 ]; then
  ok "G3 the give-up is announced on the pad, exactly once"
else
  bad "G3 pad carries $_ann give-up notices (want exactly 1) — silence, or spam"
fi
if grep -q 'is NOT lost' "$PAD_MD" 2>/dev/null && grep -q 'turn boundary' "$PAD_MD" 2>/dev/null; then
  ok "G4 the notice says where the message went and that it is not lost"
else
  bad "G4 the notice does not tell the operator the message survives"
fi
echo "    (bounded run took $(( _t1 - _t0 ))s)"
# G3b — found while building this fix, and it made the cure worse than the
# disease: the give-up notice named the seat a second time as " @name", which is
# a MENTION. Posting it minted a new delivery generation, which restarted the
# retry, which gave up again, which posted again — an unbounded loop that also
# GREW THE PAD. Measured: ordinal 1 → 3 in two rounds. The notice must announce
# the end of delivery without re-triggering it.
_gen_before="$(cut -d'|' -f1 "$(delivery_pending_file stuck)" 2>/dev/null)"
_ord_before="$(cut -d'|' -f2 "$(delivery_pending_file stuck)" 2>/dev/null)"
delivery_enqueue stuck busy push t
_gen_after="$(cut -d'|' -f1 "$(delivery_pending_file stuck)" 2>/dev/null)"
_ord_after="$(cut -d'|' -f2 "$(delivery_pending_file stuck)" 2>/dev/null)"
if [ "$_gen_before" = "$_gen_after" ] && [ "$_ord_before" = "$_ord_after" ]; then
  ok "G3b the give-up notice is not itself a mention — no new generation ($_gen_after|$_ord_after)"
else
  bad "G3b the notice re-mentioned the seat: generation $_gen_before→$_gen_after, ordinal $_ord_before→$_ord_after — the give-up re-arms the retry it announces"
fi

# ── G5: a NEW mention must be delivered at full speed ─────────────────────
printf idle-now > "$PAD_STATE/busy.stuck.mode"
append_message operator '@stuck second, different question'
delivery_enqueue stuck busy push t
( delivery_worker stuck "$(cat "$(delivery_worker_lock stuck)/token" 2>/dev/null)" ) >/dev/null 2>&1 || true
if [ "$(state_value stuck state)" = "completed" ]; then
  ok "G5 a NEW mention resets the bound and is delivered — giving up once does not deafen the seat"
else
  bad "G5 the seat stayed deaf to a new mention (state=$(state_value stuck state)) — the fix is worse than the bug"
fi

# ── G6: a busy seat that frees up still completes ─────────────────────────
new_case recover 'flaky | busy | push | t'
printf idle-now > "$PAD_STATE/busy.flaky.mode"
append_message operator '@flaky are you free'
delivery_enqueue flaky busy push t
( delivery_worker flaky "$(cat "$(delivery_worker_lock flaky)/token" 2>/dev/null)" ) >/dev/null 2>&1 || true
[ "$(state_value flaky state)" = "completed" ] \
  && ok "G6 an adapter that succeeds still completes normally" \
  || bad "G6 normal delivery regressed (state=$(state_value flaky state))"

# ── G7: the backoff curve ─────────────────────────────────────────────────
_b1="$(_busy_backoff_seconds 1 2 60)"; _b2="$(_busy_backoff_seconds 2 2 60)"
_b3="$(_busy_backoff_seconds 3 2 60)"; _b9="$(_busy_backoff_seconds 9 2 60)"
_bf="$(_busy_backoff_seconds 3 0.05 60)"
if [ "$_b1" = 2 ] && [ "$_b2" = 4 ] && [ "$_b3" = 8 ] && [ "$_b9" = 60 ]; then
  ok "G7 backoff grows 2→4→8 and is capped at 60 (attempt 9 → ${_b9}s)"
else
  bad "G7 backoff curve is wrong: $_b1 $_b2 $_b3 ... $_b9"
fi
if [ "$_bf" = "0.05" ]; then
  ok "G7b a fractional retry interval survives untouched (no arithmetic crash)"
else
  bad "G7b fractional interval mangled to '$_bf' — this crashes the delivery suite"
fi

# ── G8: claude.sh notifies once per ordinal ───────────────────────────────
NOTI="$TMP/notifier"; mkdir -p "$NOTI"
cat > "$NOTI/terminal-notifier" <<'NOTIFY'
#!/bin/bash
printf 'notified\n' >> "$NOTIFY_LOG"
NOTIFY
chmod +x "$NOTI/terminal-notifier"
new_case notify 'frank | claude | push | t'
printf 'a mention body\n' > "$TMP/taskfile"
export NOTIFY_LOG="$TMP/notify.log"; : > "$NOTIFY_LOG"
for _i in 1 2 3 4 5; do
  PATH="$NOTI:$PATH" SP_PAD_DIR="$CASE_PAD" SP_ORDINAL=7 \
    bash "$ROOT/tool/adapters/claude.sh" mention frank "$PAD_MD" "$TMP/taskfile" >/dev/null 2>&1
done
_nn="$(wc -l < "$NOTIFY_LOG" | tr -d ' ')"
if [ "${_nn:-0}" = "1" ]; then
  ok "G8 five adapter calls for one ordinal produced ONE notification"
else
  bad "G8 five calls for one ordinal produced $_nn notifications — the storm is still there"
fi
PATH="$NOTI:$PATH" SP_PAD_DIR="$CASE_PAD" SP_ORDINAL=8 \
  bash "$ROOT/tool/adapters/claude.sh" mention frank "$PAD_MD" "$TMP/taskfile" >/dev/null 2>&1
_nn2="$(wc -l < "$NOTIFY_LOG" | tr -d ' ')"
[ "${_nn2:-0}" = "2" ] \
  && ok "G8b a NEW ordinal still notifies — dedup did not mute the seat" \
  || bad "G8b a new mention produced no notification (total $_nn2) — the seat went silent"
_stamps="$(ls "$CASE_PAD/.state"/notified.frank.* 2>/dev/null | wc -l | tr -d ' ')"
[ "${_stamps:-0}" = "1" ] \
  && ok "G8c the dedup stamps do not accumulate (1 file, not one per mention)" \
  || bad "G8c $_stamps stamp files left in .state — unbounded growth by another route"

# ── G9: a respawned worker does not restart the storm ─────────────────────
new_case respawn 'again | busy | push | t'
append_message operator '@again a question'
delivery_enqueue again busy push t
( delivery_worker again "$(cat "$(delivery_worker_lock again)/token" 2>/dev/null)" ) >/dev/null 2>&1 || true
_c1="$(calls again)"
for _r in 1 2 3; do
  delivery_enqueue again busy push t
  ( delivery_worker again "$(cat "$(delivery_worker_lock again)/token" 2>/dev/null)" ) >/dev/null 2>&1 || true
done
_c2="$(calls again)"
if [ "${_c1:-0}" -gt 0 ] && [ "${_c2:-0}" = "${_c1:-0}" ]; then
  ok "G9 three worker respawns after the bound added ZERO adapter calls ($_c1 → $_c2)"
else
  bad "G9 respawning restarted the storm ($_c1 → $_c2) — the bound does not survive a new worker"
fi

# ── G10 MUTANT: take the bound away ───────────────────────────────────────
echo "  -- mutant: bound removed --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$ROOT/tool/." "$MUT/"
python3 - "$MUT/bin/watch.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='      if [ "$_busy_n" -ge "$busy_max_attempts" ]; then'
new='      if false; then'
old2='''    if [ "$(_busy_retry_read "$name" "$generation" "$ordinal")" -ge "$busy_max_attempts" ]; then
      break
    fi'''
if s.count(old)!=1 or s.count(old2)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new).replace(old2,':'))
PY
if [ $? -eq 9 ]; then
  bad "G10 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  # The mutant loops forever by construction, so it runs in a background shell
  # whose pid this suite captured, and is stopped by that exact pid (P9).
  MUT_TOOL="$TMP/mut-tool"; mkdir -p "$MUT_TOOL/adapters"
  ln -s "$MUT/bin" "$MUT_TOOL/bin"; cp "$TEST_TOOL/adapters/busy.sh" "$MUT_TOOL/adapters/"
  new_case mutant 'runaway | busy | push | t'
  append_message operator '@runaway a question'
  # Point the spawner at the MUTANT tree so the worker that actually runs is the
  # mutant one. Flat 1s retry makes the count unambiguous: bounded stops at 4,
  # the mutant should be well past that after 8 seconds.
  _saved_bin="$BIN_DIR"; _saved_home="$STITCHPAD_HOME"
  BIN_DIR="$MUT/bin"; export STITCHPAD_HOME="$MUT_TOOL" SP_DELIVERY_BUSY_RETRY_CAP=1
  delivery_enqueue runaway busy push t
  sleep 8
  # Kill ONLY the pid this suite's own worker lock recorded, and only after
  # confirming that pid is that worker (P9: never a bare pkill).
  _mpid="$(cut -d'|' -f1 "$(delivery_worker_lock runaway)/owner" 2>/dev/null || true)"
  case "${_mpid:-}" in
    ''|*[!0-9]*) ;;
    *) ps -p "$_mpid" -o command= 2>/dev/null | grep -q -- "--delivery-worker runaway" \
         && { kill "$_mpid" 2>/dev/null || true; } ;;
  esac
  sleep 1
  BIN_DIR="$_saved_bin"; export STITCHPAD_HOME="$_saved_home" SP_DELIVERY_BUSY_RETRY_CAP=2
  _mc="$(calls runaway)"
  if [ "${_mc:-0}" -gt $(( SP_DELIVERY_BUSY_MAX_ATTEMPTS + 1 )) ]; then
    ok "G10 without the bound the adapter was called $_mc times in 8s and was still going — G1 detects it"
  else
    bad "G10 mutant applied but only $_mc calls in 8s — G1 may be testing nothing"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "F14 GREEN — bounded, backed off, announced, and still awake"
