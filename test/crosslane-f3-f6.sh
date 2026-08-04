#!/usr/bin/env bash
# Fixtures must not inherit the caller's ambient session identity: sp_this_surface()
# falls back to $CLAUDE_CODE_SESSION_ID/$CODEX_SESSION_ID, which makes every simulated
# agent in this suite share ONE surface and trip "one terminal = one (pad,name)".
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
# crosslane-f3-f6.sh — regression gates for the fx1 cross-lane findings F3-F6
# (integration candidate review, sealed 2026-08-03). Bash 3.2 compatible.
# Isolated mktemp fixtures, mocked relay via PATH curl, no network, no side
# effects outside owned paths. stdout/stderr kept separate at every parse.
#
#   F3  reset --redeliver / cross-seat reset is a replay INJECTION — gated on
#       self-or-operator-authority and recorded in an append-only audit trail
#   F4  relay wake seen-cursor + telemetry are keyed PER PAD (no cross-pad
#       swallow, no undiscriminated telemetry bucket)
#   F5  --peek-ordinal polls are classified as `poll` events, never recorded
#       as wake peek/zero_run (telemetry stays a truthful delivery signal)
#   F6  sid_for_name resolves the NEWEST binding (mtime), so rotate/terminal/
#       redeliver attribute to the post-rotation session
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-crosslane-f3f6.XXXXXX")"
cleanup() {
  for n in probe victim deployer alice idle relayseat; do
    STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" heartbeat --stop "$n" >/dev/null 2>&1 || true
  done
  STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/home"
export HOME="$tmp/home"
# A-4/A-5 fix: explicit override keeps this fixture off the real operator key
export STITCHPAD_OPERATOR_KEY_PATH="$tmp/home/.stitchpad/operator.key"
export STITCHPAD_OPERATOR_KEY_OVERRIDE_ACK=1
mkdir -p "$HOME"
# Authority model (C2/C2b): operator flows require the credential — a key
# OUTSIDE the pad (isolated fixture HOME) presented via env token.
"$SP" operator keygen >/dev/null
TOK="$(cat "$HOME/.stitchpad/operator.key")"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
# Harness hygiene: never inherit the runner's terminal surface — fixtures
# would collide on ~/.stitchpad-terminals/<surface> with concurrent suites.
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true

PASSED=0; FAILED=0
ok()   { PASSED=$((PASSED + 1)); printf '  PASS %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL %s: %s\n' "$1" "$2" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

STATE="$tmp/.stitchpad/.state"
AUDIT="$STATE/reset-audit.jsonl"

printf '\n=== F3: cross-seat reset / redeliver injection gate ===\n'
cd "$tmp"
"$SP" init --name f3 >/dev/null 2>&1
"$SP" daemon stop >/dev/null 2>&1 || true
"$SP" join probe codex pull - >/dev/null
"$SP" join victim codex pull - >/dev/null
"$SP" join deployer codex pull - >/dev/null
"$SP" heartbeat --stop probe >/dev/null 2>&1 || true
"$SP" heartbeat --stop victim >/dev/null 2>&1 || true
"$SP" heartbeat --stop deployer >/dev/null 2>&1 || true
STITCHPAD_NAME=alpha "$SP" say '@victim historical mention one' >/dev/null
STITCHPAD_NAME=beta "$SP" say '@victim recovery target two' >/dev/null
STITCHPAD_PAD_DIR="$tmp" "$SP" bind-session sid-victim-001 victim >/dev/null

# 1) read-authority seat cannot reset another seat (fx1 repro).
printf 'read' > "$STATE/authority.probe"
err="$(STITCHPAD_NAME=probe "$SP" reset victim 2>&1 >/dev/null)"
rc=$?
check 'F3 read-seat cross-seat reset refused (rc 1)' '1' "$rc"
case "$err" in *'AUTHORITY'*reset-others*) ok 'F3 refusal names reset-others authority' ;; *) bad 'F3 refusal names reset-others authority' "$err" ;; esac
[ ! -f "$STATE/pending.victim" ] && ok 'F3 refused reset queued nothing' || bad 'F3 refused reset queued nothing' 'pending.victim exists' ''
check 'F3 refused attempt audited' 'reset-denied' \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("op",""))' "$(tail -1 "$AUDIT")")"

# 2) read-authority seat cannot inject a replay into another seat's queue.
err="$(STITCHPAD_NAME=probe "$SP" reset victim --redeliver 2 2>&1 >/dev/null)"
check 'F3 read-seat redeliver injection refused (rc 1)' '1' "$?"
[ ! -f "$STATE/pending.victim" ] && [ ! -f "$STATE/pending.victim.reset" ] \
  && ok 'F3 refused injection left no pending state' \
  || bad 'F3 refused injection left no pending state' 'pending files exist' ''

# 3) operator (non-roster caller) MAY reset another seat — audited.
rm -f "$AUDIT"
out="$(STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" reset victim 2>/dev/null)"
check 'F3 operator cross-seat reset allowed' '0' "$?"
audit_op="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("op",""), d.get("target",""), d.get("actor",""))' "$(tail -1 "$AUDIT")")"
check 'F3 operator reset audited (op target actor)' 'reset victim operator' "$audit_op"

# 4) deploy seat WITH one-shot operator grant may reset; grant is consumed.
# A-2 (fx1) model: levels are operator-sealed — set via the gated CLI path.
STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" authority set deployer deploy >/dev/null
STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" operator grant deployer reset-others >/dev/null
out="$(STITCHPAD_NAME=deployer "$SP" reset victim 2>/dev/null)"
check 'F3 deploy+grant cross-seat reset allowed' '0' "$?"
[ ! -f "$STATE/operator-grant.deployer.reset-others" ] \
  && ok 'F3 operator grant consumed after use' \
  || bad 'F3 operator grant consumed after use' 'grant file survived' ''
check 'F3 grant reset audited with seat actor' 'reset victim deployer' \
  "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("op",""), d.get("target",""), d.get("actor",""))' "$(tail -1 "$AUDIT")")"
# Second attempt without a fresh grant refuses.
err="$(STITCHPAD_NAME=deployer "$SP" reset victim 2>&1 >/dev/null)"
check 'F3 deploy without fresh grant refused' '1' "$?"

# 5) self-reset needs no grant.
out="$(STITCHPAD_NAME=victim "$SP" reset victim 2>/dev/null)"
check 'F3 self-reset allowed without grant' '0' "$?"

# 6) operator redeliver injection is audited with the ordinal BEFORE landing.
rm -f "$AUDIT"
out="$(STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" reset victim --redeliver 2 2>/dev/null)"
check 'F3 operator redeliver allowed' '0' "$?"
check 'F3 redeliver audited (op target ordinal)' 'redeliver victim 2' \
  "$(python3 -c 'import json,sys
for line in open(sys.argv[1]):
    d = json.loads(line)
    if d.get("op") == "redeliver":
        print(d.get("op",""), d.get("target",""), d.get("ordinal",""))' "$AUDIT")"
[ -f "$STATE/pending.victim" ] && ok 'F3 audited injection landed' || bad 'F3 audited injection landed' 'no pending.victim' ''

# 7) audit trail fail-closed: a symlinked audit file refuses the injection.
rm -f "$STATE/pending.victim" "$STATE/pending.victim.reset" "$AUDIT"
ln -s /dev/null "$AUDIT"
err="$(STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" reset victim --redeliver 2 2>&1 >/dev/null)"
check 'F3 audit-fail refuses injection (fail-closed)' '1' "$?"
[ ! -f "$STATE/pending.victim" ] && ok 'F3 fail-closed queued nothing' || bad 'F3 fail-closed queued nothing' 'pending exists' ''
rm -f "$AUDIT"

# 8) F7: --recovery-counters is counters-ONLY — never falls through into the
# seat/pad sweep (fx1 lens2: fallthrough restarted tickers/cancelled turns).
mkdir -p "$STATE/recovery-attempts"
printf '3' > "$STATE/recovery-attempts/victim.stop_hook"
printf '9' > "$STATE/seen.victim.probe" 2>/dev/null || true
seen_before="$(cat "$STATE/seen.victim" 2>/dev/null || echo none)"
out="$(STITCHPAD_NAME=operator STITCHPAD_OPERATOR_TOKEN="$TOK" "$SP" reset --recovery-counters 2>/dev/null)"
case "$out" in *'recovery counters cleared'*) ok 'F7 counters cleared' ;; *) bad 'F7 counters cleared' "$out" ;; esac
case "$out" in *'reset pad'*|*'reset @'*) bad 'F7 no fallthrough into seat/pad sweep' "$out" ;; *) ok 'F7 no fallthrough into seat/pad sweep' ;; esac
[ ! -f "$STATE/recovery-attempts/victim.stop_hook" ] && ok 'F7 counter file removed' \
  || bad 'F7 counter file removed' 'counter survived' ''
check 'F7 seat state untouched by counter clear' "$seen_before" \
  "$(cat "$STATE/seen.victim" 2>/dev/null || echo none)"
rm -f "$STATE/seen.victim.probe"

printf '\n=== F6: sid_for_name resolves the NEWEST binding ===\n'
STATE6="$tmp/f6/.stitchpad/.state"
mkdir -p "$tmp/f6"
( cd "$tmp/f6" && "$SP" init --name f6 >/dev/null 2>&1 && "$SP" daemon stop >/dev/null 2>&1 || true )
( cd "$tmp/f6" && "$SP" join probe codex pull - >/dev/null )
( cd "$tmp/f6" && STITCHPAD_PAD_DIR="$tmp/f6" "$SP" bind-session sid-probe-001 probe >/dev/null )
( cd "$tmp/f6" && STITCHPAD_PAD_DIR="$tmp/f6" "$SP" bind-session sid-probe-002 probe >/dev/null )
# same-second mtimes: deterministic tie-break (lexicographically larger = later bind)
check 'F6 two live bindings: newest sid wins' 'sid-probe-002' \
  "$(bash -c '
    source "'"$ROOT"'/tool/bin/lib.sh" >/dev/null 2>&1
    source "'"$ROOT"'/tool/bin/session-registry.sh" >/dev/null 2>&1
    PAD_STATE="'"$STATE6"'"
    sp_session_registry_sid_for_name probe')"
# reverse mtime order: older-named sid with NEWER mtime must still win
touch -t 202001010000 "$STATE6/sessions/sid-probe-002"
touch -t 202601010000 "$STATE6/sessions/sid-probe-001"
check 'F6 mtime beats lexicographic order' 'sid-probe-001' \
  "$(bash -c '
    source "'"$ROOT"'/tool/bin/lib.sh" >/dev/null 2>&1
    source "'"$ROOT"'/tool/bin/session-registry.sh" >/dev/null 2>&1
    PAD_STATE="'"$STATE6"'"
    sp_session_registry_sid_for_name probe')"
# rotate attributes to the post-rotation sid (fx1 repro shape)
touch -t 202001010000 "$STATE6/sessions/sid-probe-001"
touch -t 202601010000 "$STATE6/sessions/sid-probe-002"
printf 'handoff body\n' > "$tmp/f6/handoff.txt"
( cd "$tmp/f6" && "$SP" shift-change --save probe --file "$tmp/f6/handoff.txt" >/dev/null 2>&1 )
rotate_sid="$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    try: d = json.loads(line)
    except Exception: continue
    if d.get("event") == "rotate" and d.get("name") == "probe":
        print(d.get("session_id", "")); break
' "$STATE6/session-registry.jsonl" 2>/dev/null)"
check 'F6 rotate attributed to post-rotation sid' 'sid-probe-002' "$rotate_sid"

printf '\n=== F5: peek-ordinal polls classified as poll events ===\n'
STATE5="$tmp/f5/.stitchpad/.state"
mkdir -p "$tmp/f5"
( cd "$tmp/f5" && "$SP" init --name f5 >/dev/null 2>&1 && "$SP" daemon stop >/dev/null 2>&1 || true )
( cd "$tmp/f5" && "$SP" join victim codex pull - >/dev/null && "$SP" join idle codex pull - >/dev/null )
( cd "$tmp/f5" && "$SP" heartbeat --stop victim >/dev/null 2>&1 || true )
( cd "$tmp/f5" && "$SP" heartbeat --stop idle >/dev/null 2>&1 || true )
( cd "$tmp/f5" && STITCHPAD_NAME=alpha "$SP" say '@victim doctor poll target' >/dev/null )
rm -rf "$STATE5/telemetry"
out="$(cd "$tmp/f5" && STITCHPAD_MODEL=k3 "$SP" wake victim --peek-ordinal 2>/dev/null)"
check 'F5 peek-ordinal prints the open ordinal' '1' "$out"
wake_events="$(find "$STATE5/telemetry" -name '*.jsonl' -exec cat {} + 2>/dev/null | python3 -c '
import json, sys
w = p = 0
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("e") == "wake": w += 1
    if d.get("e") == "poll": p += 1
print(w, p)')"
check 'F5 open-mention poll: 0 wake events, 1 poll event' '0 1' "$wake_events"
poll_outcome="$(find "$STATE5/telemetry" -name '*.jsonl' -exec cat {} + 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("e") == "poll": print(d.get("outcome", "")); break
')"
check 'F5 poll outcome is peek (kept, not deleted)' 'peek' "$poll_outcome"
# idle seat poll: classified idle, no zero_run inflation
out="$(cd "$tmp/f5" && STITCHPAD_MODEL=k3 "$SP" wake idle --peek-ordinal 2>/dev/null)"
idle_line="$(find "$STATE5/telemetry" -name '*.jsonl' -exec cat {} + 2>/dev/null | python3 -c '
import json, sys
w = 0; polls = []
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("e") == "wake": w += 1
    if d.get("e") == "poll": polls.append(d.get("outcome", ""))
print(w, " ".join(polls))')"
check 'F5 idle poll: still 0 wake events; outcomes peek+idle' '0 peek idle' "$idle_line"
# summary keeps wake_runs truthful
wake_runs="$(cd "$tmp/f5" && "$SP" telemetry --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(sum(m.get("wake_runs", 0) for m in d.get("models", [])))' 2>/dev/null)"
check 'F5 summary wake_runs unaffected by polls' '0' "$wake_runs"
# a REAL wake still records a wake event (guard against over-correction)
out="$(cd "$tmp/f5" && STITCHPAD_MODEL=k3 "$SP" wake victim 2>/dev/null)"
real="$(find "$STATE5/telemetry" -name '*.jsonl' -exec cat {} + 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("e") == "wake": print(d.get("outcome", "")); break
')"
check 'F5 real wake still records wake/delivered' 'delivered' "$real"

printf '\n=== F4: relay seen-cursor + telemetry keyed per pad ===\n'
# Two pads served by one stub relay; one shared relay state dir (the bug
# shape). Mock curl answers /pad?pad=<name> with that pad's raw markdown.
RELAY_STATE="$tmp/relay-state"
mkdir -p "$RELAY_STATE" "$tmp/relay-pads"
cat > "$tmp/relay-pads/padA.md" <<'EOF'
# padA
## Roster
alice | codex | pull | -
## @op 2026-08-03T00:00:00Z
@alice padA mention one
EOF
cat > "$tmp/relay-pads/padB.md" <<'EOF'
# padB
## Roster
alice | codex | pull | -
## @op 2026-08-03T00:00:00Z
@alice padB mention one
## @op 2026-08-03T00:01:00Z
@alice padB mention two
EOF
mockbin="$tmp/mockbin"; mkdir -p "$mockbin"
cat > "$mockbin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *pad=padA*) cat "$RELAY_PADS/padA.md" ;;
  *pad=padB*) cat "$RELAY_PADS/padB.md" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$mockbin/curl"
relay_wake() { # relay_wake <pad> — run a relay wake for @alice against <pad>
  PATH="$mockbin:$PATH" RELAY_PADS="$tmp/relay-pads" \
    STITCHPAD_RELAY="http://stub" STITCHPAD_TOKEN=t STITCHPAD_PAD="$1" \
    STITCHPAD_RELAY_STATE_DIR="$RELAY_STATE" STITCHPAD_NAME=alice \
    STITCHPAD_MODEL=k3 "$SP" wake alice --relay 2>/dev/null
}
out_a="$(relay_wake padA)"
check 'F4 padA relay wake delivers' '1' "$(cat "$RELAY_STATE"/seen.relay.*.alice 2>/dev/null | head -1)"
case "$out_a" in *'padA mention one'*) ok 'F4 padA delivered its own mention' ;; *) bad 'F4 padA delivered its own mention' "$out_a" ;; esac
out_b="$(relay_wake padB)"
check 'F4 padB relay wake NOT swallowed by padA cursor (regression)' '1' \
  "$(ls "$RELAY_STATE"/seen.relay.*padB*.alice >/dev/null 2>&1 && echo 1 || echo 0)"
case "$out_b" in *'padB mention one'*) ok 'F4 padB delivered its own first mention' ;; *) bad 'F4 padB delivered its own first mention' "$out_b" ;; esac
# cursors are independent: advancing padB does not disturb padA's cursor
out_b2="$(relay_wake padB)"
case "$out_b2" in *'padB mention two'*) ok 'F4 padB cursor steps independently to mention two' ;; *) bad 'F4 padB cursor steps independently to mention two' "$out_b2" ;; esac
check 'F4 padA cursor untouched by padB deliveries' '1' \
  "$(cat "$RELAY_STATE"/seen.relay.*padA*.alice 2>/dev/null)"
# telemetry is per-pad: two keyed buckets, no undiscriminated global bucket
check 'F4 two per-pad telemetry buckets' '2' \
  "$(find "$RELAY_STATE/telemetry.pads" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
[ ! -d "$RELAY_STATE/telemetry" ] && ok 'F4 no global relay telemetry bucket' \
  || bad 'F4 no global relay telemetry bucket' 'global bucket exists' ''
check 'F4 each pad bucket holds exactly its own events (padA=1 padB=2)' '1 2' \
  "$(for d in "$RELAY_STATE/telemetry.pads"/*/; do find "$d" -name '*.jsonl' -exec cat {} + 2>/dev/null | wc -l | tr -d ' '; done | sort | tr '\n' ' ' | sed 's/ $//')"
# migration: a legacy shared cursor seeds the per-pad cursor (no mass replay)
rm -rf "$RELAY_STATE"
mkdir -p "$RELAY_STATE"
printf '1' > "$RELAY_STATE/seen.relay.alice"
out_a2="$(relay_wake padA)"
check 'F4 legacy shared cursor migrated (no replay of ordinal 1)' '' "$out_a2"
check 'F4 migrated cursor value' '1' "$(cat "$RELAY_STATE"/seen.relay.*padA*.alice 2>/dev/null)"

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll F3-F6 gates PASSED.\n'; exit 0; }
printf '\nSome F3-F6 gates FAILED.\n'; exit 1
