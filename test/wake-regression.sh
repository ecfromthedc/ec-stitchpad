#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_STEAL=1   # allow each case to claim the TTY from the prior case
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
  "$SP" daemon stop >/dev/null 2>&1 || true
  pkill -9 -f "fswatch.*$d" 2>/dev/null || true
  for _pidfile in "$d"/.stitchpad/.state/alive-ticker.*.pid "$d"/.stitchpad/.state/heartbeat.*.lock/pid; do
    [ -f "$_pidfile" ] || continue
    _pid="$(timeout 2 cat "$_pidfile" 2>/dev/null || true)"
    [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null || true
  done
  sleep 0.2
}

tmp="$(mktemp -d /tmp/stitchpad-wake-regression.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export STITCHPAD_HOME="$ROOT/tool"

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
	# Regression 12: Adapter FAILURE clears pending — no delivery means
	# no crash recovery target, so the stamp must be cleared to prevent
	# the next watcher cycle from deferring forever (the deadlock bug).

	# --- Regression 10: Watcher defer-or-queue (production) ---
	case10="$tmp/case10"
	mkdir "$case10"
	cd "$case10"
	"$SP" init --name case10 >/dev/null
	"$SP" join agent herdr push >/dev/null     # push adapter, NOT pull
	stop_watcher "$case10"

	# Build: one mention consumed (seen=1), second stamped pending=2 then
	# consumed (turn crashed), third mention posted — watcher must defer.
	STITCHPAD_NAME=fable "$SP" say '@agent first mention' >/dev/null
	"$SP" wake agent >/dev/null                                      # seen=1
	STITCHPAD_NAME=smaths "$SP" say '@agent second - CRITICAL' >/dev/null
	printf '2' > "$case10/.stitchpad/.state/pending.agent"           # crash stamp
	"$SP" wake agent >/dev/null                                      # seen=2
	STITCHPAD_NAME=other "$SP" say '@agent third mention' >/dev/null

	# Start watcher backgrounded, CAPTURE output, trigger fswatch.
	"$SP" watch > "$case10/watcher.out" 2>&1 &
	WATCH_PID=$!
	sleep 0.5
	printf '\n' >> "$case10/.stitchpad/stitchpad.md"
	sleep 1.5
	kill -9 $WATCH_PID 2>/dev/null || true
	wait $WATCH_PID 2>/dev/null || true
	pkill -9 -f "fswatch.*$case10" 2>/dev/null || true
	rm -rf "$case10/.stitchpad/.state/watch.lock.d" 2>/dev/null || true

	# Assert: the DEFER branch actually RAN (deferring line present).
	grep -q 'deferring.*pending recovery target.*ordinal 2' "$case10/watcher.out" \
	  || fail 'invariant5: watcher did NOT defer — branch not exercised'

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

	# --- Regression 12: Adapter failure clears pending (production) ---
	case12="$tmp/case12"
	mkdir "$case12"
	cd "$case12"
	"$SP" init --name case12 >/dev/null
	"$SP" join agent test-fail push >/dev/null    # push adapter that always exits 1
	stop_watcher "$case12"

	# Post a mention and start the watcher — the test-fail adapter exits 1,
	# so fire_adapter returns failure. The watcher must create then CLEAR
	# the pending stamp (no delivery = nothing to recover from crash).
	STITCHPAD_NAME=fable "$SP" say '@agent delivery test' >/dev/null

	# Watcher captures output; trigger TWO fswatch events to prove
	# both cycles ran (adapter failure -> clear -> retry -> clear again).
	"$SP" watch > "$case12/watcher.out" 2>&1 &
	WATCH_PID=$!
	sleep 0.5

	# EVENT 1: trigger fswatch, adapter fails, pending cleared.
	printf '\n' >> "$case12/.stitchpad/stitchpad.md"
	sleep 1.5
	[ ! -f "$case12/.stitchpad/.state/pending.agent" ] \
	  || fail 'invariant5: pending not cleared after event-1 adapter failure'
	_s12_1="$(cat "$case12/.stitchpad/.state/seen.agent" 2>/dev/null || echo 0)"
	[ "${_s12_1:-0}" -eq 0 ] \
	  || fail "invariant5: seen advanced after event-1 failure; seen=$_s12_1"

	# EVENT 2: trigger fswatch again — same mention is still unanswered,
	# watcher must fire adapter again (no deadlock from stale pending).
	printf '\n' >> "$case12/.stitchpad/stitchpad.md"
	sleep 1.5
	[ ! -f "$case12/.stitchpad/.state/pending.agent" ] \
	  || fail 'invariant5: pending not cleared after event-2 adapter failure'
	_s12_2="$(cat "$case12/.stitchpad/.state/seen.agent" 2>/dev/null || echo 0)"
	[ "${_s12_2:-0}" -eq 0 ] \
	  || fail "invariant5: seen advanced after event-2 failure; seen=$_s12_2"

	kill -9 $WATCH_PID 2>/dev/null || true
	wait $WATCH_PID 2>/dev/null || true
	pkill -9 -f "fswatch.*$case12" 2>/dev/null || true
	rm -rf "$case12/.stitchpad/.state/watch.lock.d" 2>/dev/null || true

	# Assert: TWO adapter failure calls (branch ran twice, not once,
	# not zero — proves event 2 retried instead of deferring forever).
	_failcount="$(grep -c 'exit 1 (not consuming gate)' "$case12/watcher.out" 2>/dev/null || echo 0)"
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
	rm -f "$case13/.stitchpad/.state/alive.agent"
	[ "$(cat "$case13/.stitchpad/.state/sessions/ocean-session" 2>/dev/null)" = "agent" ] \
	  || fail 'ocean join did not bind push session identity'

	# Fake the daemon status probe and heartbeat binary: idle session + successful
	# durable turn delivery, without touching the operator's live daemon.
	mockbin="$case13/mockbin"
	mkdir "$mockbin"
	cat > "$mockbin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"session":{"active_turn":null}}\n'
EOF
	cat > "$mockbin/ocean-heartbeat" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "$mockbin/curl" "$mockbin/ocean-heartbeat"

	STITCHPAD_NAME=sender "$SP" say '@agent exactly once over ocean push' >/dev/null
	PATH="$mockbin:$PATH" "$SP" watch > "$case13/watcher.out" 2>&1 &
	WATCH_PID=$!
	sleep 0.5
	printf '\n' >> "$case13/.stitchpad/stitchpad.md"
	for _ in 1 2 3 4 5 6 7 8 9 10; do
	  [ "$(cat "$case13/.stitchpad/.state/seen.agent" 2>/dev/null || echo 0)" -eq 1 ] && break
	  sleep 0.5
	done
	kill -9 $WATCH_PID 2>/dev/null || true
	wait $WATCH_PID 2>/dev/null || true
	pkill -9 -f "fswatch.*$case13" 2>/dev/null || true
	rm -rf "$case13/.stitchpad/.state/watch.lock.d" 2>/dev/null || true

	grep -q 'unanswered @agent -> firing ocean (push)' "$case13/watcher.out" \
	  || fail 'ocean exactly-once branch did not fire adapter'
	[ "$(cat "$case13/.stitchpad/.state/seen.agent" 2>/dev/null || echo 0)" -eq 1 ] \
	  || fail 'ocean successful delivery did not consume seen cursor'
	[ ! -f "$case13/.stitchpad/.state/pending.agent" ] \
	  || fail 'ocean successful delivery left replay-causing pending stamp'

	# Regression 14: Per-sender reply ledger — the deafness gate.
	# The old sp_engagement pinned last_mention to the FIRST mention found
	# and the caller compared the NEWEST reply against it. Once bob replied
	# to alice, bob's global last_reply advanced past alice's first mention,
	# so every later mention — from alice or anyone — was falsely declared
	# "handled." Four of six live seats were in this state.
	#
	# 14a: alice→bob, bob→alice, alice→bob ⇒ bob must have a pending mention.
	# Bob's reply at ordinal 2 answers alice's mention at ordinal 1, but
	# alice's second mention at ordinal 3 came AFTER bob's reply and is
	# unanswered.
	case14a="$tmp/case14a"
	mkdir "$case14a"
	cd "$case14a"
	"$SP" init --name case14a >/dev/null
	"$SP" join bob codex >/dev/null
	stop_watcher "$case14a"
	STITCHPAD_NAME=alice "$SP" say '@bob first ping' >/dev/null
	STITCHPAD_NAME=bob "$SP" say '@alice thanks for the first ping' >/dev/null
	STITCHPAD_NAME=alice "$SP" say '@bob second ping after my reply' >/dev/null
	out14a="$("$SP" wake bob --peek)"
	contains "$out14a" 'second ping after my reply' \
	  || fail 'per-sender ledger (14a): second mention from same sender masked by earlier reply'
	if contains "$out14a" 'first ping'; then
	  fail 'per-sender ledger (14a): already-replied mention re-appeared'
	fi

	# 14b: Cross-sender — replying to X must not clear Y's unanswered mention.
	# Alice and charlie both mention agent. Agent replies to alice without
	# consuming either mention first. Charlie's mention must survive.
	case14b="$tmp/case14b"
	mkdir "$case14b"
	cd "$case14b"
	"$SP" init --name case14b >/dev/null
	"$SP" join agent codex >/dev/null
	stop_watcher "$case14b"
	STITCHPAD_NAME=alice "$SP" say '@agent alice pings agent' >/dev/null
	STITCHPAD_NAME=charlie "$SP" say '@agent charlie also pings agent' >/dev/null
	STITCHPAD_NAME=agent "$SP" say '@alice got it alice' >/dev/null
	out14b="$("$SP" wake agent --peek)"
	contains "$out14b" 'charlie also pings agent' \
	  || fail 'per-sender ledger (14b): reply to alice swallowed charlie mention'
	if contains "$out14b" 'alice pings agent'; then
	  fail 'per-sender ledger (14b): already-replied alice mention re-appeared'
	fi

	printf 'wake regression ok\n'
