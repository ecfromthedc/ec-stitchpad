#!/usr/bin/env bash
# multipad-isolation.sh — MULTI-PAD SAFETY gates (km2 lane, base 732d61a).
# Every gate runs TWO pads simultaneously. Isolated mktemp fixtures, isolated
# HOME (SP_TERMDIR + STITCHPAD_HOME derive from it), mocked relay via PATH
# curl, no network, no side effects outside owned paths. Bash 3.2 compatible.
#
#   P1  relay seen-cursor + telemetry keyed PER PAD (rc7 F1 / fx1 F4):
#       two relay pads on ONE shared relay state dir must never swallow each
#       other's wakes, share cursors, or merge telemetry
#   P2  relay-hook env is per-session authority (rc7 F2): a session-id'd Stop
#       hook never sources the machine-global shared env (pad B's creds)
#   P3  ghost-post guard (rc7 F3): non-herdr / surface-less shells cannot post
#       as a name live-claimed in a different pad
#   P4  claim steal checks owner LIVENESS (rc7 F4): a stale-timestamp claim
#       with a live owner process is still honored; dead owners are evictable
#   P5  claims are atomic (rc7 F5): concurrent same-surface claims never both
#       succeed
#   P6  claim mutex stale-break: a dead claimant's mutex never wedges a surface
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-multipad.XXXXXX")"
SLEEP_PIDS=""
cleanup() {
  for p in $SLEEP_PIDS; do kill "$p" 2>/dev/null || true; done
  ( cd "$tmp/padA" && "$SP" daemon stop >/dev/null 2>&1 ) || true
  ( cd "$tmp/padB" && "$SP" daemon stop >/dev/null 2>&1 ) || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/home"
export HOME="$tmp/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
# Harness hygiene: never inherit the runner's terminal surface or session env —
# fixtures would collide on the machine-global terminal registry.
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
unset STITCHPAD_RELAY STITCHPAD_TOKEN STITCHPAD_PAD STITCHPAD_RELAY_STATE_DIR 2>/dev/null || true

PASSED=0; FAILED=0
ok()   { PASSED=$((PASSED + 1)); printf '  PASS %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL %s: %s\n' "$1" "$2" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

TERMDIR="$HOME/.stitchpad-terminals"

# ── P1: relay seen-cursor + telemetry keyed per pad ──────────────────
printf '\n=== P1: relay cursor + telemetry per-pad (two pads, one relay state dir) ===\n'
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
[ -n "${CURL_LOG:-}" ] && printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *pad=padA*) cat "$RELAY_PADS/padA.md" ;;
  *pad=padB*) cat "$RELAY_PADS/padB.md" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$mockbin/curl"
relay_wake() { # relay_wake <pad> — relay wake for @alice against <pad>
  PATH="$mockbin:$PATH" RELAY_PADS="$tmp/relay-pads" \
    STITCHPAD_RELAY="http://stub" STITCHPAD_TOKEN=t STITCHPAD_PAD="$1" \
    STITCHPAD_RELAY_STATE_DIR="$RELAY_STATE" STITCHPAD_NAME=alice \
    "$SP" wake alice --relay 2>/dev/null
}
out_a="$(relay_wake padA)"
case "$out_a" in *'padA mention one'*) ok 'P1a padA relay wake delivers its own mention' ;; *) bad 'P1a padA relay wake delivers its own mention' "$out_a" ;; esac
out_b="$(relay_wake padB)"
case "$out_b" in *'padB mention one'*) ok 'P1b padB wake NOT swallowed by padA cursor' ;; *) bad 'P1b padB wake NOT swallowed by padA cursor' "got: $out_b" ;; esac
check 'P1c two distinct per-pad cursor files' '2' \
  "$(ls "$RELAY_STATE"/seen.relay.*.alice 2>/dev/null | wc -l | tr -d ' ')"
check 'P1c2 no legacy shared cursor created by new wakes' '0' \
  "$(ls "$RELAY_STATE"/seen.relay.alice 2>/dev/null | wc -l | tr -d ' ')"
out_b2="$(relay_wake padB)"
case "$out_b2" in *'padB mention two'*) ok 'P1d padB cursor steps independently to mention two' ;; *) bad 'P1d padB cursor steps independently to mention two' "$out_b2" ;; esac
check 'P1d2 padA cursor untouched by padB deliveries' '1' \
  "$(cat "$RELAY_STATE"/seen.relay.*padA*.alice 2>/dev/null)"
check 'P1e two per-pad telemetry buckets' '2' \
  "$(find "$RELAY_STATE/telemetry.pads" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
[ ! -d "$RELAY_STATE/telemetry" ] && ok 'P1e2 no undiscriminated global telemetry bucket' \
  || bad 'P1e2 no undiscriminated global telemetry bucket' 'global bucket exists'
# migration: legacy shared cursor seeds the per-pad cursor without replay
rm -rf "$RELAY_STATE"; mkdir -p "$RELAY_STATE"
printf '1' > "$RELAY_STATE/seen.relay.alice"
out_a2="$(relay_wake padA)"
check 'P1f legacy shared cursor migrated (no replay of ordinal 1)' '' "$out_a2"
check 'P1f2 migrated cursor value seeded' '1' "$(cat "$RELAY_STATE"/seen.relay.*padA*.alice 2>/dev/null)"
# migration must never write through a symlinked per-pad cursor
rm -rf "$RELAY_STATE"; mkdir -p "$RELAY_STATE"
printf '1' > "$RELAY_STATE/seen.relay.alice"
akey="$(printf 'padA' | shasum -a 256 | cut -c1-12)"
victim="$tmp/victim-outside"; printf 'ORIGINAL' > "$victim"
ln -s "$victim" "$RELAY_STATE/seen.relay.padA-$akey.alice"
out_a3="$(relay_wake padA)"
check 'P1g migration refuses symlinked per-pad cursor (no write-through)' 'ORIGINAL' "$(cat "$victim")"

# ── P2: relay-hook env is per-session authority ──────────────────────
printf '\n=== P2: relay-hook env per-session (stop-hook never sources a foreign pad) ===\n'
ST_HOME="$tmp/sthome"; HSTATE="$ST_HOME/.state"; mkdir -p "$HSTATE"
printf 'STITCHPAD_RELAY=%s\nSTITCHPAD_TOKEN=%s\nSTITCHPAD_PAD=%s\nSTITCHPAD_NAME=%s\n' \
  "'http://stub'" "'t'" "'padB'" "'alice'" > "$HSTATE/relay-hook.env"
CURL_LOG="$tmp/curl.log"; export CURL_LOG
run_hook() { # run_hook <session-id-or-empty>
  local sid="$1" json
  if [ -n "$sid" ]; then
    json="{\"cwd\":\"$tmp/nowhere\",\"session_id\":\"$sid\"}"
  else
    json="{\"cwd\":\"$tmp/nowhere\"}"
  fi
  printf '%s' "$json" | PATH="$mockbin:$PATH" RELAY_PADS="$tmp/relay-pads" \
    STITCHPAD_HOME="$ST_HOME" "$SP" hook >/dev/null 2>&1
}
: > "$CURL_LOG"
run_hook sess-alpha
check 'P2a sid present, no per-sid file → shared env NOT sourced (no padB curl)' '0' \
  "$(wc -l < "$CURL_LOG" | tr -d ' ')"
printf 'STITCHPAD_RELAY=%s\nSTITCHPAD_TOKEN=%s\nSTITCHPAD_PAD=%s\nSTITCHPAD_NAME=%s\n' \
  "'http://stub'" "'t'" "'padA'" "'alice'" > "$HSTATE/relay-hook.sess-alpha.env"
: > "$CURL_LOG"
run_hook sess-alpha
check 'P2b per-sid file IS sourced when present (padA curl)' '1' \
  "$(grep -c 'pad=padA' "$CURL_LOG" 2>/dev/null | head -1)"
: > "$CURL_LOG"
run_hook ''
check 'P2c legacy no-sid hook still consults shared env (padB curl)' '1' \
  "$(grep -c 'pad=padB' "$CURL_LOG" 2>/dev/null | head -1)"
unset CURL_LOG

# ── P3: ghost-post guard — two real local pads ───────────────────────
printf '\n=== P3: surface-less ghost-post refusal (two local pads) ===\n'
mkdir -p "$tmp/padA" "$tmp/padB" "$tmp/nowhere"
( cd "$tmp/padA" && "$SP" init --name padA >/dev/null 2>&1 && "$SP" daemon stop >/dev/null 2>&1 )
( cd "$tmp/padB" && "$SP" init --name padB >/dev/null 2>&1 && "$SP" daemon stop >/dev/null 2>&1 )
( cd "$tmp/padA" && STITCHPAD_SESSION=s1 "$SP" join alice codex pull - >/dev/null 2>&1 )
check 'P3a join claims session-fallback surface' '1' \
  "$(ls "$TERMDIR"/sess-s1 >/dev/null 2>&1 && echo 1 || echo 0)"
out="$( cd "$tmp/padB" && STITCHPAD_SESSION=s1 STITCHPAD_NAME=alice "$SP" say 'ghost via session surface' 2>&1 )"
case "$out" in *REFUSED*) ok 'P3b session-surface say into padB refused' ;; *) bad 'P3b session-surface say into padB refused' "$out" ;; esac
# pane-id fallback: herdr binary absent but HERDR_PANE_ID exported — the claim
# and the guard key on pane-<id> consistently (rc7's F3 fix direction)
( cd "$tmp/padA" && env PATH="/usr/bin:/bin" HOME="$HOME" HERDR_PANE_ID="w9:pZ" STITCHPAD_NAME=carol \
    "$SP" join carol codex pull - >/dev/null 2>&1 )
check 'P3c pane-fallback join claims pane-<id> surface' '1' \
  "$(ls "$TERMDIR"/pane-w9:pZ >/dev/null 2>&1 && echo 1 || echo 0)"
out="$( cd "$tmp/padB" && env PATH="/usr/bin:/bin" HOME="$HOME" HERDR_PANE_ID="w9:pZ" STITCHPAD_NAME=carol \
    "$SP" say 'ghost via pane fallback' 2>&1 )"
case "$out" in *REFUSED*) ok 'P3c2 pane-fallback say into padB refused' ;; *) bad 'P3c2 pane-fallback say into padB refused' "$out" ;; esac
# fully identity-less shell (no herdr, no pane, no session): permissive BY
# DESIGN — claims are per-terminal and cannot bind a shell with no identity
out="$( cd "$tmp/padB" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" STITCHPAD_NAME=alice "$SP" say 'identity-less shell post' 2>&1 )"
case "$out" in *REFUSED*) bad 'P3d identity-less shell stays permissive (documented limit)' "$out" ;; *) ok 'P3d identity-less shell stays permissive (documented limit)' ;; esac
out="$( cd "$tmp/padA" && STITCHPAD_SESSION=s1 STITCHPAD_NAME=alice "$SP" say 'legit post in my own pad' 2>&1 )"
case "$out" in *REFUSED*) bad 'P3e owning-surface say into OWNING pad allowed' "$out" ;; *) ok 'P3e owning-surface say into OWNING pad allowed' ;; esac
( cd "$tmp/padA" && STITCHPAD_SESSION=s1 STITCHPAD_NAME=alice "$SP" leave >/dev/null 2>&1 )
out="$( cd "$tmp/padB" && STITCHPAD_SESSION=s1 STITCHPAD_NAME=alice "$SP" say 'alice after leaving padA' 2>&1 )"
case "$out" in *REFUSED*) bad 'P3f leave clears the claim (post allowed)' "$out" ;; *) ok 'P3f leave clears the claim (post allowed)' ;; esac

# ── P4: steal checks owner liveness ──────────────────────────────────
printf '\n=== P4: claim steal honors live owners (stale ts ≠ dead owner) ===\n'
sleep 300 & SPID=$!; SLEEP_PIDS="$SLEEP_PIDS $SPID"
( cd "$tmp/padA" && STITCHPAD_NAME=alice STITCHPAD_HEARTBEAT_PARENT_PID=$SPID \
    "$SP" join alice codex pull term_live >/dev/null 2>&1 )
check 'P4a claim records owner pid' "$SPID" \
  "$(cut -d'|' -f4 "$TERMDIR/term_live" 2>/dev/null)"
# age the claim past the 300s TTL while the owner stays alive
now="$(date +%s)"
IFS='|' read -r cpad cname cts cpid cstart < "$TERMDIR/term_live"
printf '%s|%s|%s|%s|%s' "$cpad" "$cname" "$((now - 301))" "$cpid" "$cstart" > "$TERMDIR/term_live"
out="$( cd "$tmp/padB" && STITCHPAD_NAME=bob "$SP" join bob codex pull term_live 2>&1 )"
case "$out" in *REFUSED*) ok 'P4b stale-ts claim with LIVE owner refuses steal' ;; *) bad 'P4b stale-ts claim with LIVE owner refuses steal' "$out" ;; esac
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; SLEEP_PIDS=""
out="$( cd "$tmp/padB" && STITCHPAD_NAME=bob "$SP" join bob codex pull term_live 2>&1 )"
case "$out" in *REFUSED*) bad 'P4c dead owner (stale ts) is evictable' "$out" ;; *) ok 'P4c dead owner (stale ts) is evictable' ;; esac
# legacy 3-field stale claim: timestamp-only semantics preserved
printf '%s|%s|%s' "$tmp/padA/.stitchpad" "alice" "$((now - 301))" > "$TERMDIR/term_legacy"
out="$( cd "$tmp/padB" && STITCHPAD_NAME=bob "$SP" join bob codex pull term_legacy 2>&1 )"
case "$out" in *REFUSED*) bad 'P4d legacy 3-field stale claim evictable (compat)' "$out" ;; *) ok 'P4d legacy 3-field stale claim evictable (compat)' ;; esac
# pid-reuse guard: stale claim whose pid now belongs to a DIFFERENT process
sleep 300 & SPID2=$!; SLEEP_PIDS="$SLEEP_PIDS $SPID2"
printf '%s|%s|%s|%s|%s' "$tmp/padA/.stitchpad" "alice" "$((now - 301))" "$SPID2" "bogus-start-token" > "$TERMDIR/term_reuse"
out="$( cd "$tmp/padB" && STITCHPAD_NAME=bob "$SP" join bob codex pull term_reuse 2>&1 )"
case "$out" in *REFUSED*) bad 'P4e start-time mismatch (pid reuse) does NOT block eviction' "$out" ;; *) ok 'P4e start-time mismatch (pid reuse) does NOT block eviction' ;; esac
kill "$SPID2" 2>/dev/null; wait "$SPID2" 2>/dev/null; SLEEP_PIDS=""

# ── P5: concurrent claims never both succeed ─────────────────────────
printf '\n=== P5: atomic claim under concurrency (two pads, one surface) ===\n'
double=0; round=1
while [ $round -le 10 ]; do
  rm -f "$TERMDIR/term_race" "$tmp/raceA" "$tmp/raceB"
  ( cd "$tmp/padA" && PAD_DIR="$tmp/padA/.stitchpad" HOME="$HOME" bash -c \
      '. "'"$ROOT"'/tool/bin/lib.sh" >/dev/null 2>&1; sp_term_lock_claim term_race alice >/dev/null 2>&1' \
      && touch "$tmp/raceA" ) &
  ( cd "$tmp/padB" && PAD_DIR="$tmp/padB/.stitchpad" HOME="$HOME" bash -c \
      '. "'"$ROOT"'/tool/bin/lib.sh" >/dev/null 2>&1; sp_term_lock_claim term_race bob >/dev/null 2>&1' \
      && touch "$tmp/raceB" ) &
  wait
  [ -f "$tmp/raceA" ] && [ -f "$tmp/raceB" ] && double=$((double + 1))
  round=$((round + 1))
done
check 'P5a zero double-claim rounds in 10 concurrent races' '0' "$double"
wins=$(( $([ -f "$tmp/raceA" ] && echo 1 || echo 0) + $([ -f "$tmp/raceB" ] && echo 1 || echo 0) ))
check 'P5b exactly one winner in the final round' '1' "$wins"
check 'P5c claim file matches a single winner' '1' \
  "$(grep -c '|' "$TERMDIR/term_race" 2>/dev/null || echo 0)"

# ── P6: stale mutex never wedges a surface ───────────────────────────
printf '\n=== P6: claim mutex stale-break ===\n'
mkdir -p "$TERMDIR/.mutex.term_wedged"
touch -t 202001010000 "$TERMDIR/.mutex.term_wedged" 2>/dev/null || true
out="$( cd "$tmp/padA" && STITCHPAD_NAME=alice "$SP" join alice codex pull term_wedged 2>&1 )"
case "$out" in *REFUSED*) bad 'P6a stale mutex broken, claim proceeds' "$out" ;; *) ok 'P6a stale mutex broken, claim proceeds' ;; esac
check 'P6b claim written after stale break' '1' \
  "$(ls "$TERMDIR/term_wedged" >/dev/null 2>&1 && echo 1 || echo 0)"

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll MULTI-PAD isolation gates PASSED.\n'; exit 0; }
printf '\nSome MULTI-PAD isolation gates FAILED.\n'; exit 1
