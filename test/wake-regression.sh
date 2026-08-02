#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_STEAL=1   # allow each case to claim the TTY from the prior case
export STITCHPAD_HEARTBEAT_AUTOSTART=0
# Unset herdr context: in a managed pane, sp_this_surface returns a terminal id
# that activates the one-terminal-one-pad lock, which blocks multi-sender test
# scenarios. The test suite doesn't run inside herdr, but manual runs might.
unset HERDR_PANE_ID 2>/dev/null || true

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

stop_watcher() {
  local d="$1"
  # Stop heartbeat producers first: a ticker may already be inside its
  # ensure-watcher call and can otherwise recreate the watcher after an
  # initial daemon stop.
  for _lock in "$d"/.stitchpad/.state/heartbeat.*.lock; do
    [ -d "$_lock" ] || continue
    _name="$(basename "$_lock")"; _name="${_name#heartbeat.}"; _name="${_name%.lock}"
    STITCHPAD_PAD_DIR="$d/.stitchpad" "$SP" heartbeat --stop "$_name" >/dev/null 2>&1 || true
  done
  "$SP" daemon stop >/dev/null 2>&1 || true
  sleep 0.2
}

wait_for_fswatch() {
  local d="$1"
  d="$(cd -P "$d" && pwd)"
  for _ in $(seq 1 100); do
    pgrep -f "fswatch -0 $d/.stitchpad/stitchpad.md" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  sed -n '1,120p' "$d/watcher.out" >&2 || true
  find "$d/.stitchpad/.state" -maxdepth 2 -type f -print -exec sh -c \
    'printf "  "; sed -n "1,12p" "$1"; printf "\n"' _ {} \; >&2 || true
  fail "watcher fswatch did not become ready for $d"
}

HOST_HOME="$HOME"
tmp="$(mktemp -d /tmp/stitchpad-wake-regression.XXXXXX)"
mkdir -p "$tmp/home"
export HOME="$tmp/home"

cleanup_fixture_registry() {
  local registry claim value
  for registry in "$HOST_HOME/.stitchpad-terminals" "$HOST_HOME/.pasture-terminals"; do
    [ -d "$registry" ] || continue
    for claim in "$registry"/*; do
      [ -f "$claim" ] || continue
      value="$(cat "$claim" 2>/dev/null || true)"
      case "$value" in "$tmp"/*) rm -f "$claim" ;; esac
    done
  done
}

fixture_registry_is_clean() {
  local registry claim value
  for registry in "$HOST_HOME/.stitchpad-terminals" "$HOST_HOME/.pasture-terminals"; do
    [ -d "$registry" ] || continue
    for claim in "$registry"/*; do
      [ -f "$claim" ] || continue
      value="$(cat "$claim" 2>/dev/null || true)"
      case "$value" in "$tmp"/*) return 1 ;; esac
    done
  done
  return 0
}

fixture_watchers_are_clean() {
  local case_dir found
  for case_dir in "$tmp"/*; do
    [ -d "$case_dir/.stitchpad" ] || continue
    found="$(
      STITCHPAD_PAD_DIR="$case_dir/.stitchpad" bash -c \
        'BIN_DIR="$1/tool/bin"; source "$BIN_DIR/lib.sh"; sp_init_paths >/dev/null 2>&1; sp_watch_processes_for_pad' \
        _ "$ROOT" 2>/dev/null || true
    )"
    if [ -n "$found" ]; then
      echo "fixture watcher leak under $case_dir: $found" >&2
      return 1
    fi
  done
  return 0
}

stop_all_fixture_runtime() {
  local lock name case_dir
  for lock in "$tmp"/*/.stitchpad/.state/heartbeat.*.lock; do
    [ -d "$lock" ] || continue
    name="$(basename "$lock")"; name="${name#heartbeat.}"; name="${name%.lock}"
    STITCHPAD_PAD_DIR="$(dirname "$(dirname "$lock")")" "$SP" heartbeat --stop "$name" >/dev/null 2>&1 || true
  done
  for case_dir in "$tmp"/*; do
    [ -d "$case_dir/.stitchpad" ] || continue
    STITCHPAD_PAD_DIR="$case_dir/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  done
}

cleanup() {
  cleanup_rc=$?
  set +e
  # Stop only fixture-owned watcher parents, heartbeat PIDs, and fswatch children.
  stop_all_fixture_runtime
  fixture_watchers_are_clean || cleanup_rc=1
  # A nested runtime may restore the host HOME and claim any fixture surface,
  # not only ocean-session. Remove every exact claim whose pad is under this
  # fixture root, then prove none remains before deleting the fixture itself.
  cleanup_fixture_registry
  fixture_registry_is_clean || cleanup_rc=1
  rm -rf "$tmp"
  trap - EXIT
  exit "$cleanup_rc"
}
trap cleanup EXIT

export STITCHPAD_HOME="$ROOT/tool"

# Startup/stop race: pause a foreground watcher after exact owner publication
# but before fswatch. Stop must remove that generation, make the signal handler
# exit (not continue), and leave neither a lock nor an orphan process.
startup_case="$tmp/startup-race"
mkdir "$startup_case"
cd "$startup_case"
"$SP" init --name startup-race >/dev/null
stop_watcher "$startup_case"
startup_barrier="$tmp/startup-barrier"
(
  trap - EXIT
  STITCHPAD_WATCH_TEST_BEFORE_FSWATCH_BARRIER="$startup_barrier" exec "$SP" watch
) > "$startup_case/watcher.out" 2>&1 &
startup_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
  [ -f "$startup_barrier.ready" ] && break
  sleep 0.05
done
[ -f "$startup_barrier.ready" ] || fail 'paused watcher never published startup ownership'
[ -s "$startup_case/.stitchpad/.state/watch.lock.d/owner" ] \
  || fail 'paused watcher omitted exact owner metadata'
STITCHPAD_PAD_DIR="$startup_case/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
touch "$startup_barrier.release"
wait "$startup_pid" 2>/dev/null || true
[ ! -d "$startup_case/.stitchpad/.state/watch.lock.d" ] \
  || fail 'paused watcher stop left its generation lock'
startup_left="$(
  STITCHPAD_PAD_DIR="$startup_case/.stitchpad" bash -c \
    'BIN_DIR="$1/tool/bin"; source "$BIN_DIR/lib.sh"; sp_init_paths >/dev/null 2>&1; sp_watch_processes_for_pad' \
    _ "$ROOT" 2>/dev/null || true
)"
[ -z "$startup_left" ] || fail "paused watcher stop left fixture processes: $startup_left"

# Normal ensure_watcher/CLI start publishes the same contract and remains a
# singleton. A concurrent foreground contender must exit without replacing the
# live owner's generation or starting a second fswatch.
singleton_case="$tmp/start-singleton"
mkdir "$singleton_case"
cd "$singleton_case"
"$SP" init --name start-singleton >/dev/null
"$SP" join agent codex pull - >/dev/null
stop_watcher "$singleton_case"
printf '{}' > "$singleton_case/.stitchpad/.state/alive.agent"
"$SP" start >/dev/null
singleton_pairs=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
  singleton_pairs="$(
    STITCHPAD_PAD_DIR="$singleton_case/.stitchpad" bash -c \
      'BIN_DIR="$1/tool/bin"; source "$BIN_DIR/lib.sh"; sp_init_paths >/dev/null 2>&1; sp_watch_pairs_for_pad' \
      _ "$ROOT" 2>/dev/null || true
  )"
  [ "$(printf '%s\n' "$singleton_pairs" | grep -c .)" -eq 1 ] && break
  sleep 0.05
done
if [ "$(printf '%s\n' "$singleton_pairs" | grep -c .)" -ne 1 ]; then
  sed -n '1,120p' "$singleton_case/.stitchpad/.state/watch.log" >&2 2>/dev/null || true
  ls -la "$singleton_case/.stitchpad/.state/watch.lock.d" >&2 2>/dev/null || true
  fail 'normal CLI start did not produce exactly one fswatch pair'
fi
singleton_owner="$singleton_case/.stitchpad/.state/watch.lock.d/owner"
[ -s "$singleton_owner" ] || fail 'normal CLI start omitted owner manifest'
owner_before="$(cksum < "$singleton_owner")"
"$SP" start >/dev/null
if "$SP" watch > "$singleton_case/contender.out" 2>&1; then
  fail 'foreground contender stole a live watcher generation'
fi
owner_after="$(cksum < "$singleton_owner")"
[ "$owner_after" = "$owner_before" ] || fail 'foreground contender replaced live owner manifest'
singleton_pairs="$(
  STITCHPAD_PAD_DIR="$singleton_case/.stitchpad" bash -c \
    'BIN_DIR="$1/tool/bin"; source "$BIN_DIR/lib.sh"; sp_init_paths >/dev/null 2>&1; sp_watch_pairs_for_pad' \
    _ "$ROOT" 2>/dev/null || true
)"
[ "$(printf '%s\n' "$singleton_pairs" | grep -c .)" -eq 1 ] \
  || fail 'repeated CLI start/contender created duplicate fswatch processes'
stop_watcher "$singleton_case"

# Regression 1: an addressed block should not sweep later replies into the wake
# prompt. The hook prompt should contain only the addressed message block.
case1="$tmp/case1"
mkdir "$case1"
cd "$case1"
"$SP" init --name case1 >/dev/null
"$SP" join dale codex >/dev/null
stop_watcher "$case1"
STITCHPAD_NAME=tester "$SP" say '@dale first ping' >/dev/null
STITCHPAD_NAME=larry "$SP" say 'unrelated after first ping' >/dev/null
out="$("$SP" wake dale)"
contains "$out" '@dale first ping' || fail 'wake did not include addressed message'
if contains "$out" 'unrelated after first ping'; then
  fail 'wake included a later unrelated block'
fi

# Regression 2: an unrelated commit must not clear an unanswered mention; only
# an addressed reply by that agent clears it.
case2="$tmp/case2"
mkdir "$case2"
cd "$case2"
"$SP" init --name case2 >/dev/null
"$SP" join dale codex >/dev/null
stop_watcher "$case2"
STITCHPAD_NAME=tester "$SP" say '@dale one-shot ping' >/dev/null
first="$("$SP" wake dale --peek)"
contains "$first" '@dale one-shot ping' || fail 'first wake missed addressed message'
STITCHPAD_NAME=larry "$SP" say 'unrelated status update' >/dev/null
second="$("$SP" wake dale --peek)"
contains "$second" '@dale one-shot ping' || fail 'unrelated commit incorrectly cleared unanswered mention'
STITCHPAD_NAME=dale "$SP" say '@tester addressed reply clears ping' >/dev/null
third="$("$SP" wake dale)"
if [ -n "$third" ]; then
  printf '%s\n' "$third" >&2
  fail 'addressed reply did not clear unanswered mention'
fi

# Regression 3: Stop-hook identity is session-authoritative. A hook with no bound
# session is silent even if STITCHPAD_NAME leaks from the runtime environment;
# a bound Larry session wakes Larry even when that stale env names Dale.
case3="$tmp/case3"
mkdir "$case3"
cd "$case3"
"$SP" init --name case3 >/dev/null
"$SP" join larry codex >/dev/null
"$SP" join dale claude >/dev/null
stop_watcher "$case3"
STITCHPAD_NAME=tester "$SP" say '@larry identity ping' >/dev/null
unbound="$(printf '{"cwd":"%s","stop_hook_active":false}' "$case3" | STITCHPAD_NAME=larry "$SP" hook)"
[ -z "$unbound" ] || fail 'unbound hook should not trust an environment identity'
STITCHPAD_CWD="$case3" "$SP" bind-session larry-session larry >/dev/null
pinned="$(printf '{"cwd":"%s","session_id":"larry-session","stop_hook_active":false}' "$case3" | STITCHPAD_NAME=dale "$SP" hook)"
contains "$pinned" '"decision":"block"' || fail 'session-bound Larry hook did not block'
contains "$pinned" '@larry identity ping' || fail 'session-bound Larry hook missed message'

# Regression 4: real chat often includes a speaker prefix before the mention
# ("dale @larry ..."). That should still wake larry; requiring @name at column 1
# makes agents silently miss messages.
case4="$tmp/case4"
mkdir "$case4"
cd "$case4"
"$SP" init --name case4 >/dev/null
"$SP" join larry codex >/dev/null
stop_watcher "$case4"
STITCHPAD_NAME=dale "$SP" say 'dale @larry inline ping' >/dev/null
inline="$(STITCHPAD_NAME=larry "$SP" wake --peek)"
contains "$inline" 'dale @larry inline ping' || fail 'inline @mention did not wake larry'

# Regression 5: compact wake nudges must name the sender, not the recipient.
# Otherwise the nudge says "NEW from @larry ... reply with @larry" for a ping
# sent by @tester, and agents reply to themselves.
case5="$tmp/case5"
mkdir "$case5"
cd "$case5"
"$SP" init --name case5 >/dev/null
"$SP" join larry codex >/dev/null
stop_watcher "$case5"
STITCHPAD_NAME=tester "$SP" say '@larry sender header ping' >/dev/null
sender_line="$("$SP" wake larry --peek)"
contains "$sender_line" 'NEW from @tester' || fail 'wake nudge did not name sender'
contains "$sender_line" 'reply with @tester' || fail 'wake nudge did not route reply to sender'
if contains "$sender_line" 'NEW from @larry'; then
  fail 'wake nudge incorrectly named recipient as sender'
fi

	# Regression 6: FIFO cursor — two mentions from different senders are
	# delivered in oldest-first order, not newest-first. A burst of "@agent A"
	# then "@agent B" must wake on A's mention first, then B's on the next
	# wake cycle. This is the fix for incident-2: codex's CLEAR was shadowed
	# by ocean's later @fable, and the high-water-mark seen cursor leapt past it.
	case6="$tmp/case6"
	mkdir "$case6"
	cd "$case6"
	"$SP" init --name case6 >/dev/null
	"$SP" join agent codex >/dev/null
	stop_watcher "$case6"
	STITCHPAD_NAME=tester "$SP" say '@agent oldest-first ping' >/dev/null
	STITCHPAD_NAME=other "$SP" say '@agent second burst ping' >/dev/null
	# --peek returns the OLDEST unanswered mention (tester's ping)
	peek1="$("$SP" wake agent --peek)"
	contains "$peek1" '@agent oldest-first ping' || fail 'FIFO: oldest mention not returned first'
	# Consume it (non-peek advances seen cursor)
	"$SP" wake agent >/dev/null
	# Now the next oldest (other's ping) should surface
	peek2="$("$SP" wake agent --peek)"
	contains "$peek2" '@agent second burst ping' || fail 'FIFO: second mention not returned after consuming first'
	if contains "$peek2" 'oldest-first ping'; then
	  fail 'FIFO: already-delivered mention re-appeared'
	fi

	# Regression 7: Same-sender gate — replying to X clears X's gate
	# but leaves Y's unanswered mention open. Regression for "replying to
	# @alpha swallowed @beta's mention" (the incident-1 pattern).
	case7="$tmp/case7"
	mkdir "$case7"
	cd "$case7"
	"$SP" init --name case7 >/dev/null
	"$SP" join agent codex >/dev/null
	stop_watcher "$case7"
	STITCHPAD_NAME=alpha "$SP" say '@agent alpha mentions agent' >/dev/null
	STITCHPAD_NAME=beta "$SP" say '@agent beta also mentions agent' >/dev/null
	# Both mentions active — oldest (alpha's) is first in queue
	p1="$("$SP" wake agent --peek)"
	contains "$p1" 'alpha mentions agent' || fail 'same-sender: alpha mention not found'
	# Consume alpha's mention
	"$SP" wake agent >/dev/null
	# Agent replies to alpha — should clear alpha's mention gate
	STITCHPAD_NAME=agent "$SP" say '@alpha thanks for the ping' >/dev/null
	# Beta's mention should STILL be awake (not swallowed by replying to alpha)
	p2="$("$SP" wake agent --peek)"
	contains "$p2" 'beta also mentions agent' || fail 'same-sender: replying to alpha swallowed beta mention'
	# Consume beta's mention
	"$SP" wake agent >/dev/null
	# Now agent replies to beta
	STITCHPAD_NAME=agent "$SP" say '@beta acknowledged' >/dev/null
	# Both gates should be clear
	p3="$("$SP" wake agent --peek)"
	[ -z "$p3" ] || fail 'same-sender: gate not cleared after replying to both senders'

	# Regression 8: --peek-ordinal stamps the correct open-mention ordinal
	# independent of the seen cursor. The ordinal is gate-derived and must
	# match what a non-peek wake would deliver. Verifies the watch.sh pending
	# stamp wire produces the same ordinal the wake loop will consume.
	case8="$tmp/case8"
	mkdir "$case8"
	cd "$case8"
	"$SP" init --name case8 >/dev/null
	"$SP" join agent codex >/dev/null
	stop_watcher "$case8"
	STITCHPAD_NAME=sender "$SP" say '@agent peek-ordinal test' >/dev/null
	ord1="$("$SP" wake agent --peek-ordinal)"
	[ -n "$ord1" ] || fail '--peek-ordinal returned empty for open mention'
	[ "$ord1" -gt 0 ] || fail '--peek-ordinal returned zero ordinal for open mention'
	# --peek-ordinal must not advance seen
	wake1="$("$SP" wake agent --peek)"
	contains "$wake1" 'peek-ordinal test' || fail '--peek-ordinal consumed the gate (must be read-only)'
	# Consume, then --peek-ordinal should be empty (no open mention)
	"$SP" wake agent >/dev/null
	ord2="$("$SP" wake agent --peek-ordinal)"
	[ -z "$ord2" ] && ord2=0
	[ "$ord2" -eq 0 ] || fail '--peek-ordinal returned non-zero after all mentions consumed'


	# Regression 9: Invariant 5 — consumed-but-never-displayed recovery,
	# production stop-hook lifecycle.
	#
	# Covers the full path: watcher stamps pending + consumes seen → turn crashes
	# → stop-hook validates via sp_engagement(since=N-1) independently of seen →
	# re-presents via --force <N> → transitions to delivered_no_reply →
	# an authored say clears the marker.
	case9="$tmp/case9"
	mkdir "$case9"
	cd "$case9"
	"$SP" init --name case9 >/dev/null
	"$SP" join agent codex >/dev/null
	stop_watcher "$case9"

	# Post two mentions from different senders
	STITCHPAD_NAME=fable "$SP" say '@agent first mention' >/dev/null
	STITCHPAD_NAME=smaths "$SP" say '@agent second mention - CRITICAL' >/dev/null

	# Consume first (ordinal 1, seen → 1)
	"$SP" wake agent >/dev/null
	[ "$(cat "$case9/.stitchpad/.state/seen.agent")" -eq 1 ] || fail 'invariant5: seen != 1 after first consume'

	# Stamp pending with ordinal 2 (watcher stamps BEFORE consuming second)
	po="$("$SP" wake agent --peek-ordinal)"
	[ "$po" -eq 2 ] || fail "invariant5: --peek-ordinal should be 2, got $po"
	printf '%s' "$po" > "$case9/.stitchpad/.state/pending.agent"

	# Consume second (ordinal 2, seen → 2)
	"$SP" wake agent >/dev/null
	[ "$(cat "$case9/.stitchpad/.state/seen.agent")" -eq 2 ] || fail 'invariant5: seen != 2 after second consume'

	# Turn crashed — normal wake sees nothing (seen advanced past both)
	peek_after="$("$SP" wake agent --peek)"
	[ -z "$peek_after" ] || fail 'invariant5: normal wake should be silent after both consumed'

	# --peek-ordinal bakes in seen cursor → returns 0 (since=seen=2, nothing > 2)
	# This is the core defect: the hook CANNOT use --peek-ordinal to validate the
	# pending ordinal. Instead it uses sp_engagement(since=pend_ord-1).
	po2="$("$SP" wake agent --peek-ordinal)"
	[ "${po2:-0}" -eq 0 ] || fail "invariant5: --peek-ordinal should be 0 after both consumed, got $po2"

	# Production hook validation: sp_engagement(since=pend_ord-1) bypasses seen
	_pord="$(cat "$case9/.stitchpad/.state/pending.agent")"
	source "$STITCHPAD_HOME/bin/lib.sh"
	PAD_MD="$case9/.stitchpad/stitchpad.md"
	PAD_STATE="$case9/.stitchpad/.state"
	PAD_DIR="$case9/.stitchpad"
	_chk="$(sp_engagement agent "$((_pord - 1))" 2>/dev/null || echo "0 x 0 x")"
	_chk_ord="$(printf '%s' "$_chk" | awk '{print $1}')"
	[ "${_chk_ord:-0}" = "${_pord:-x}" ] || fail "invariant5: sp_engagement(since=$((_pord-1))) = $_chk_ord, expected $_pord"
	unset PAD_MD PAD_STATE PAD_DIR

	# The actual stop-hook subcommand (production path)
	STITCHPAD_CWD="$case9" "$SP" bind-session agent-session agent >/dev/null
	hook_out="$(printf '{"cwd":"%s","session_id":"agent-session","stop_hook_active":false}' "$case9" | "$SP" hook 2>/dev/null)"
	contains "$hook_out" '"decision":"block"' || fail 'invariant5: stop hook did not re-block'
	contains "$hook_out" 'second mention - CRITICAL' || fail 'invariant5: stop hook missed the critical message'
	if contains "$hook_out" 'first mention'; then
	  fail 'invariant5: stop hook recovered wrong (old first) mention'
	fi

	# delivered_no_reply marker set after re-block
	[ -f "$case9/.stitchpad/.state/delivered_no_reply.agent" ] || fail 'invariant5: delivered_no_reply not set'
	[ "$(cat "$case9/.stitchpad/.state/delivered_no_reply.agent")" = "$_pord" ] || fail 'invariant5: delivered_no_reply ordinal mismatch'

	# pending is consumed (deleted by hook after re-block)
	[ ! -f "$case9/.stitchpad/.state/pending.agent" ] || fail 'invariant5: pending should be consumed after re-block'

	# An authored say clears delivered_no_reply
	STITCHPAD_NAME=agent "$SP" say '@smaths got it, thanks' >/dev/null
	[ ! -f "$case9/.stitchpad/.state/delivered_no_reply.agent" ] || fail 'invariant5: delivered_no_reply not cleared after say'

	# Regression 10: Watcher DEFER — production proof.
	# When pending.<name> exists (unresolved crash recovery target), the
	# watcher must defer the ENTIRE fire/consume cycle. Uses a non-pull
	# adapter (herdr, wake=push) so the watcher enters the defer branch
	# rather than skipping at the "pull" guard on line 132.
	#
	# Regression 11: Hook preserves pending when DND suppresses --force.
	#
	# Regression 12: Adapter FAILURE remains durable in the per-seat supervisor.
	# The accepted generation stays pending with state=error, and a later watcher
	# event restarts that same generation instead of losing it or advancing seen.

	# --- Regression 10: Watcher defer-or-queue (production) ---
	case10="$tmp/case10"
	mkdir "$case10"
	cd "$case10"
	"$SP" init --name case10 >/dev/null
	"$SP" join agent herdr push >/dev/null     # push adapter, NOT pull
	stop_watcher "$case10"
	rm -f "$case10/.stitchpad/.state"/alive.*

	# Build: one mention consumed (seen=1), second stamped pending=2 then
	# consumed (turn crashed), third mention posted — watcher must defer.
	STITCHPAD_NAME=fable "$SP" say '@agent first mention' >/dev/null
	"$SP" wake agent >/dev/null                                      # seen=1
	STITCHPAD_NAME=smaths "$SP" say '@agent second - CRITICAL' >/dev/null
	printf '2' > "$case10/.stitchpad/.state/pending.agent"           # crash stamp
	"$SP" wake agent >/dev/null                                      # seen=2
	STITCHPAD_NAME=other "$SP" say '@agent third mention' >/dev/null

	# Start watcher backgrounded, CAPTURE output, trigger fswatch.
	( trap - EXIT; exec "$SP" watch ) > "$case10/watcher.out" 2>&1 &
	WATCH_PID=$!
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	  printf '\n' >> "$case10/.stitchpad/stitchpad.md"
	  grep -q 'deferring.*pending recovery target.*ordinal 2' "$case10/watcher.out" 2>/dev/null && break
	  sleep 0.25
	done
		stop_watcher "$case10"
		wait $WATCH_PID 2>/dev/null || true

	# Assert: the DEFER branch actually RAN (deferring line present).
	if ! grep -q 'deferring.*pending recovery target.*ordinal 2' "$case10/watcher.out"; then
	  sed -n '1,80p' "$case10/watcher.out" >&2
	  fail 'invariant5: watcher did NOT defer — branch not exercised'
	fi

	# Assert: NO adapter was fired (defer happened before --peek).
	! grep -q 'firing' "$case10/watcher.out" \
	  || fail 'invariant5: watcher fired adapter despite pending — defer broken'

	# Assert: pending was NOT overwritten (still ordinal 2).
	_p10="$(cat "$case10/.stitchpad/.state/pending.agent" 2>/dev/null || echo 0)"
	[ "${_p10:-0}" -eq 2 ] || fail "invariant5: watcher overwrote pending; expected 2, got $_p10"

	# Assert: seen did NOT advance past the deferred mention.
	_s10="$(cat "$case10/.stitchpad/.state/seen.agent" 2>/dev/null || echo 0)"
	[ "${_s10:-0}" -le 2 ] || fail "invariant5: watcher consumed deferred mention; seen=$_s10 (>2)"

	# --- Regression 11: Hook preserves pending under DND ---
	case11="$tmp/case11"
	mkdir "$case11"
	cd "$case11"
	"$SP" init --name case11 >/dev/null
	"$SP" join agent codex >/dev/null
	stop_watcher "$case11"

	# Consume one mention (seen=1), stamp pending=1, turn crashes.
	STITCHPAD_NAME=fable "$SP" say '@agent critical message' >/dev/null
	printf '1' > "$case11/.stitchpad/.state/pending.agent"
	"$SP" wake agent >/dev/null                                      # seen=1

	# Enable DND for agent (wake --force exits 0 silently).
	touch "$case11/.stitchpad/.state/dnd.agent"

	# Bind a session and invoke the stop-hook PRODUCTION path.
	STITCHPAD_CWD="$case11" "$SP" bind-session agent-session agent >/dev/null
	hook_out="$(printf '{"cwd":"%s","session_id":"agent-session","stop_hook_active":false}' "$case11" | "$SP" hook 2>/dev/null || true)"

	# Assert: hook did NOT re-block (DND suppressed --force output → msgs empty).
	if contains "$hook_out" 'decision.*block'; then
	  fail 'invariant5: hook re-blocked under DND — should have exited silently'
	fi

	# Assert: pending STILL EXISTS (defer-not-destroy — hook left it intact).
	[ -f "$case11/.stitchpad/.state/pending.agent" ] || fail 'invariant5: hook deleted pending under DND — should preserve it'

	# Assert: delivered_no_reply was NOT created (never recovered the message).
	[ ! -f "$case11/.stitchpad/.state/delivered_no_reply.agent" ] || fail 'invariant5: hook wrote delivered_no_reply under DND without recovering'

	# --- Regression 12: Adapter failure preserves supervised pending (production) ---
	case12="$tmp/case12"
	mkdir "$case12"
	cd "$case12"
	"$SP" init --name case12 >/dev/null
	"$SP" join agent test-fail push >/dev/null    # push adapter that always exits 1
	stop_watcher "$case12"
	rm -f "$case12/.stitchpad/.state"/alive.*

	# Post a mention and start the watcher — the test-fail adapter exits 1,
	# so the seat worker records a durable error and keeps its accepted generation.
	STITCHPAD_NAME=fable "$SP" say '@agent delivery test' >/dev/null

	# Watcher captures output; trigger TWO fswatch events to prove
	# both cycles ran (adapter failure -> clear -> retry -> clear again).
	( trap - EXIT; exec "$SP" watch ) > "$case12/watcher.out" 2>&1 &
	WATCH_PID=$!
	wait_for_fswatch "$case12"

	# EVENT 1: trigger fswatch; adapter fails and supervised pending survives.
	printf '\n' >> "$case12/.stitchpad/stitchpad.md"
	for _ in $(seq 1 100); do
	  grep -q '^state=error$' "$case12/.stitchpad/.state/delivery.agent.state" 2>/dev/null \
	    && [ ! -d "$case12/.stitchpad/.state/delivery.agent.worker.lock.d" ] && break
	  sleep 0.05
	done
	[ -f "$case12/.stitchpad/.state/delivery.agent.pending" ] \
	  || fail 'supervision: adapter failure discarded accepted generation'
	grep -q '^state=error$' "$case12/.stitchpad/.state/delivery.agent.state" \
	  || fail 'supervision: adapter failure did not persist error state'
	_s12_1="$(cat "$case12/.stitchpad/.state/seen.agent" 2>/dev/null || echo 0)"
	[ "${_s12_1:-0}" -eq 0 ] \
	  || fail "invariant5: seen advanced after event-1 failure; seen=$_s12_1"

	# EVENT 2: same mention is still current; watcher restarts the failed
	# generation without creating a duplicate generation or consuming seen.
	_gen12="$(cat "$case12/.stitchpad/.state/delivery.agent.generation")"
	printf '\n' >> "$case12/.stitchpad/stitchpad.md"
	for _ in $(seq 1 100); do
	  [ "$(grep -c 'exit 1 (not consuming gate)' "$case12/.stitchpad/.state/delivery.agent.log" 2>/dev/null || true)" -ge 2 ] \
	    && [ ! -d "$case12/.stitchpad/.state/delivery.agent.worker.lock.d" ] && break
	  sleep 0.05
	done
	[ "$(cat "$case12/.stitchpad/.state/delivery.agent.generation")" = "$_gen12" ] \
	  || fail 'supervision: retry created a duplicate generation'
	[ -f "$case12/.stitchpad/.state/delivery.agent.pending" ] \
	  || fail 'supervision: retry discarded failed generation'
	_s12_2="$(cat "$case12/.stitchpad/.state/seen.agent" 2>/dev/null || echo 0)"
	[ "${_s12_2:-0}" -eq 0 ] \
	  || fail "invariant5: seen advanced after event-2 failure; seen=$_s12_2"

		stop_watcher "$case12"
		wait $WATCH_PID 2>/dev/null || true

	# Assert: TWO adapter failure calls in the independent seat log (branch ran
	# twice, proving event 2 supervised the error instead of wedging forever).
	_failcount="$(grep -c 'exit 1 (not consuming gate)' "$case12/.stitchpad/.state/delivery.agent.log" 2>/dev/null || true)"
	_failcount="${_failcount:-0}"
	[ "${_failcount:-0}" -ge 2 ] \
	  || fail "invariant5: expected >=2 adapter-failure calls, got $_failcount"


	# Regression 13: Ocean push delivery is daemon-durable and must not create a
	# pending crash-recovery stamp. Such a stamp makes the normal Ocean Stop hook
	# force-deliver the same mention again. Also prove that joining with an Ocean
	# session target automatically writes the Stop-hook identity binding.
	case13="$tmp/case13"
	mkdir "$case13"
	cd "$case13"
	"$SP" init --name case13 >/dev/null
	"$SP" join agent ocean push ocean-session >/dev/null
	stop_watcher "$case13"
	rm -f "$case13/.stitchpad/.state"/alive.*
	rm -f "$case13/.stitchpad/.state/alive.agent"
	[ "$(cat "$case13/.stitchpad/.state/sessions/ocean-session" 2>/dev/null)" = "agent" ] \
	  || fail 'ocean join did not bind push session identity'

	# Fake the daemon status probe and heartbeat binary: idle session + successful
	# durable turn delivery, without touching the operator's live daemon.
	mockbin="$case13/mockbin"
	mkdir "$mockbin"
	cat > "$mockbin/curl" <<'EOF'
#!/usr/bin/env bash
case "${!#}" in
  */v1/requests) printf '{"ok":true,"requests":[{"request_id":"turn-13","state":"completed"}]}\n' ;;
  *) printf '{"session":{"active_turn":null}}\n' ;;
esac
EOF
	cat > "$mockbin/ocean-heartbeat" <<'EOF'
#!/usr/bin/env bash
printf '{"ok":true,"session_id":"ocean-session","turn_id":"turn-13"}\n'
exit 0
EOF
	chmod +x "$mockbin/curl" "$mockbin/ocean-heartbeat"

	STITCHPAD_NAME=sender "$SP" say '@agent exactly once over ocean push' >/dev/null
	( trap - EXIT; PATH="$mockbin:$PATH" exec "$SP" watch ) > "$case13/watcher.out" 2>&1 &
	WATCH_PID=$!
	wait_for_fswatch "$case13"
	printf '\n' >> "$case13/.stitchpad/stitchpad.md"
	for _ in 1 2 3 4 5 6 7 8 9 10; do
	  [ "$(cat "$case13/.stitchpad/.state/seen.agent" 2>/dev/null || echo 0)" -eq 1 ] && break
	  sleep 0.5
	done
	stop_watcher "$case13"
	wait $WATCH_PID 2>/dev/null || true

	grep -q '^state=completed$' "$case13/.stitchpad/.state/delivery.agent.state" \
	  || fail 'ocean exactly-once branch did not complete supervised delivery'
	[ "$(cat "$case13/.stitchpad/.state/seen.agent" 2>/dev/null || echo 0)" -eq 1 ] \
	  || fail 'ocean successful delivery did not consume seen cursor'
	[ ! -f "$case13/.stitchpad/.state/delivery.agent.pending" ] \
	  || fail 'ocean successful delivery left supervised pending state'
	[ ! -f "$case13/.stitchpad/.state/pending.agent" ] \
	  || fail 'ocean successful delivery left replay-causing pending stamp'

	stop_all_fixture_runtime
	cleanup_fixture_registry
	fixture_registry_is_clean \
	  || fail 'fixture path leaked into the machine-global terminal registry'
	fixture_watchers_are_clean \
	  || fail 'fixture watcher process survived exact teardown'
	printf 'wake regression ok\n'
