#!/usr/bin/env bash
# seat-keeper v2 — anti-starvation watchdog for pasture/stitchpad Ocean seats.
#
# WHY v1 EXISTED: wakes are mention-driven. A seat with no NEW @mentions but an
# unfinished task queue idles forever (this killed deepseek overnight on
# rust-parity, 2026-08-01).
#
# WHY v2 EXISTS: v1 read `count.<seat>` as a backlog depth. It is neither a
# backlog nor maintained. It is the CUMULATIVE count of pad lines addressing
# @seat or @all (lib.sh sp_count_to), written ONCE at watcher startup
# (watch.sh:45) and never touched again by the react loop — vestigial. So
# `gate > 0` means "has ever been mentioned", not "has unread mentions". On
# rust-parity that misreading woke codex and glm every 10 minutes for two days
# (~570 paid turns) against a pad that mentions neither, while deepseek — the
# seat v1 was written to save — sat untouched because its counter read 0.
#
# v2 asks the oracle the WATCHER asks: `stitchpad wake <name> --peek-ordinal`,
# an unanswered mention resolved against that seat's own seen.<name> cursor.
#
# Three properties are carried over from Daniel Coulbourne's crux (MIT), which
# solves this same class of problem:
#
#   1. FAIL CLOSED WITH A VOICE (crux lib/failover.js). A probe has three
#      outcomes, not two: up, down, and unknown. v1 collapsed unknown into
#      "skip", so an unreachable or reshaped daemon silently stopped the entire
#      watchdog with no log line at all. Here unknown never moves a seat AND
#      never passes in silence.
#
#   2. A CURSOR BELONGS TO THE CONSUMER (crux lib/cursor.js). Position is read
#      relative to what THIS seat has consumed, never as a shared level.
#
#   3. A SUPERVISOR THAT CANNOT SEE ITS WORKER SAYS SO (crux 0.5.1). A wake that
#      leaves the SAME mention unanswered is recorded as a strike; MAX_STRIKES
#      consecutive no-ops quarantine the seat and log loudly instead of retrying
#      forever. v1 could not tell a working wake from a wasted one.
#
# Pads watched: one repo path per line in ~/.pasture/keeper.conf
# Kill switch:  touch ~/.pasture/keeper.off
# Log:          ~/.pasture/keeper.log
# Un-quarantine: rm <repo>/.stitchpad/.state/keeper-strike.<seat>
#
# Flags: --dry-run  decide and log, wake nothing
#        --report   dry-run plus a per-seat table (what `crux leads` is for)
set -uo pipefail

# Overridable so the positive path can be exercised against a throwaway pad
# without touching the live fleet's conf. A refusal you cannot test is a refusal
# that rots (crux's phrasing, and it applies to the wake path just as much).
CONF="${SEAT_KEEPER_CONF:-$HOME/.pasture/keeper.conf}"
LOG="${SEAT_KEEPER_LOG:-$HOME/.pasture/keeper.log}"
# HB/SP/DAEMON were hardcoded to the INSTALL, which is right in production and
# is also why this keeper had no gate: a suite cannot point it at a throwaway
# tree. Same treatment as CONF/LOG above — overridable, identical defaults.
HB="${OCEAN_HEARTBEAT_BIN:-$HOME/dev/ocean-os/target/release/ocean-heartbeat}"
SP="${SEAT_KEEPER_SP:-$HOME/.stitchpad/bin/stitchpad}"   # the mention oracle {@see seat_pending}
DAEMON="${OCEAN_DAEMON_URL:-http://127.0.0.1:4780}"

# Model-pin telemetry helpers live in lib.sh. Resolved the same way every other
# bin/ script does, through the symlink, so the keeper records which model a wake
# ACTUALLY resolved to rather than only which one was requested.
_sk_src="${BASH_SOURCE[0]}"; while [ -h "$_sk_src" ]; do
  _sk_dir="$(cd -P "$(dirname "$_sk_src")" && pwd)"; _sk_src="$(readlink "$_sk_src")"
  [ "${_sk_src#/}" = "$_sk_src" ] && _sk_src="$_sk_dir/$_sk_src"
done
SK_BIN_DIR="$(cd -P "$(dirname "$_sk_src")" && pwd)"
[ -f "$SK_BIN_DIR/lib.sh" ] && . "$SK_BIN_DIR/lib.sh" 2>/dev/null || true
# Overridable for the same reason CONF/LOG/HB are: a rate limit you cannot lower
# is a rate limit no suite can exercise. Defaults unchanged.
DRAIN_MIN_S="${SEAT_KEEPER_DRAIN_MIN_S:-${STITCHPAD_KEEPER_MIN_SECONDS:-600}}"
QUEUE_MIN_S="${SEAT_KEEPER_QUEUE_MIN_S:-${STITCHPAD_KEEPER_MIN_SECONDS:-900}}"
MAX_STRIKES=3         # consecutive no-effect wakes before quarantine
# Overridable like the rest: the rate limit is right in production (do not spam
# the log every 2 minutes) and is precisely what stops a suite from ever
# observing the alert, since the stamp file outlives the run.
RELOG_S="${SEAT_KEEPER_RELOG_S:-3600}"   # re-log a quarantined/unknown seat at most this often

DRY=0; REPORT=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --report)  DRY=1; REPORT=1 ;;
    *) echo "seat-keeper: unknown flag $a" >&2; exit 2 ;;
  esac
done

[ -f "$HOME/.pasture/keeper.off" ] && exit 0
[ -f "$CONF" ] || exit 0
[ -x "$HB" ] || { echo "seat-keeper: no heartbeat binary at $HB" >&2; exit 0; }

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
  [ "$REPORT" -eq 1 ] && printf '  %s\n' "$*"
  return 0
}

# Rate-limited log: writes only if the named stamp file is older than RELOG_S.
log_rl() {
  local stamp="$1"; shift
  local now last
  now=$(date +%s); last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -lt "$RELOG_S" ] && return 0
  echo "$now" > "$stamp" 2>/dev/null
  log "$@"
}

# keep the log bounded
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 2000 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# --- daemon reachability, answered ONCE per run -----------------------------
# v1 probed per seat and, on failure, silently skipped every seat — a watchdog
# that had stopped watching and said nothing about it. Being unable to reach the
# daemon is the single most important thing this script can report.
if ! curl -sf -m 3 "$DAEMON/health" >/dev/null 2>&1; then
  # Stamp lives beside the LOG, not beside the script. It was pinned to
  # $HOME/.pasture/, so a suite pointing SEAT_KEEPER_LOG at a throwaway dir still
  # wrote into the live install — and thereby suppressed the real fleet's
  # daemon-unreachable alert for an hour. Caught by this gate doing exactly that.
  # Production is unchanged: LOG defaults to ~/.pasture/keeper.log, so the stamp
  # still lands in ~/.pasture.
  log_rl "$(dirname "$LOG")/.keeper-daemon-unreachable" \
    "DAEMON UNREACHABLE at $DAEMON — no seat can be woken. The fleet is unattended until this clears."
  exit 0
fi

# --- probe one session: busy | idle | unknown:<reason> ----------------------
probe_session() {
  local sid="$1" body
  body=$(curl -sf -m 4 "$DAEMON/v1/agent/sessions/$sid" 2>/dev/null) || { echo "unknown:http-fail"; return; }
  [ -z "$body" ] && { echo "unknown:empty-body"; return; }
  printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown:unparseable"); raise SystemExit(0)
s = d.get("session")
if not isinstance(s, dict):
    print("unknown:no-session-object"); raise SystemExit(0)
print("busy" if s.get("active_turn") else "idle")
' 2>/dev/null || echo "unknown:probe-crashed"
}

# --- pending mention for a seat: <ordinal> | "" | unknown:<reason> ----------
# ASK THE SAME ORACLE THE WATCHER ASKS. watch.sh fires on
# `stitchpad wake <name> --peek` — an UNANSWERED mention, i.e. an @name newer
# than that seat's last @-reply, resolved against seen.<name>. That is the
# fleet's real engagement gate.
#
# v1 instead read count.<seat>, which is written ONCE at watcher startup
# (watch.sh:45) and never maintained in the react loop. It is vestigial. Keying
# wake decisions off a field nothing maintains is how codex and glm came to be
# woken every 10 minutes for two days over a counter frozen since Aug 3.
#
# `--peek-ordinal` is used rather than `--peek` because it is the STABLE IDENTITY
# of the pending mention, which is what lets the effect check below distinguish
# "the same mention is still unanswered" (a wasted wake) from "a new mention
# arrived" (progress). Neither peek form advances any cursor — verified.
seat_pending() {
  local repo="$1" name="$2" out rc

  # A name that is not on the roster peeks EMPTY with rc=0 — the same answer as
  # "nothing is pending". A seat bound to an Ocean session but missing from the
  # roster would therefore read as permanently idle and never be woken again:
  # silent starvation, the exact failure this watchdog exists to prevent, wearing
  # the healthy answer's clothes. It is a bound seat, so its absence is a fault.
  if ! (cd "$repo" 2>/dev/null && "$SP" roster 2>/dev/null) | cut -d'|' -f1 | grep -qxF "$name"; then
    echo "unknown:not-in-roster"; return
  fi

  out=$(cd "$repo" 2>/dev/null && "$SP" wake "$name" --peek-ordinal 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && { echo "unknown:peek-rc-$rc"; return; }
  out="$(printf '%s' "$out" | head -1 | tr -cd '0-9')"
  echo "$out"
}

# --- open pad tasks assigned to a seat --------------------------------------
seat_tasks() {
  local pad="$1" who="$2"
  [ -f "$pad" ] || { echo 0; return; }
  awk -v who="$who" '
    /^```task/ {in_t=1; st=""; as=""; next}
    in_t && /^status:/   {st=$2}
    in_t && /^assignee:/ {as=$2}
    in_t && /^```/ {in_t=0; if ((st=="todo" || st=="in_progress") && as==who) n++}
    END {print n+0}' "$pad" 2>/dev/null || echo 0
}

[ "$REPORT" -eq 1 ] && printf '%-12s %-8s %-20s %-8s %s\n' SEAT STATE PENDING STRIKES DECISION

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  case "$repo" in \#*) continue ;; esac
  ST="$repo/.stitchpad/.state"
  PADFILE="$repo/.stitchpad/stitchpad.md"
  [ -d "$ST" ] || continue

  for f in "$ST"/ocean-session.*; do
    [ -f "$f" ] || continue
    name="${f##*/ocean-session.}"
    sid="$(cat "$f" 2>/dev/null)"
    [ -z "$sid" ] && continue
    model="$(cat "$ST/seat-model.$name" 2>/dev/null || echo '')"

    STRIKE="$ST/keeper-strike.$name"
    OBS="$ST/keeper-obs.$name"
    LASTF="$ST/keeper-last.$name"

    state="$(probe_session "$sid")"
    pending="$(seat_pending "$repo" "$name")"
    strikes="$(cat "$STRIKE" 2>/dev/null || echo 0)"
    case "$strikes" in ''|*[!0-9]*) strikes=0 ;; esac

    decision=""

    case "$state" in
      busy)
        # Working. Never needs the keeper, and progress clears its record.
        rm -f "$OBS" "$STRIKE" 2>/dev/null
        strikes=0
        decision="busy — no action"
        ;;
      unknown:*)
        # crux's `unknown`: nothing moves, and it is said out loud.
        log_rl "$ST/.keeper-unknown.$name" \
          "UNKNOWN state for $name ($repo): ${state#unknown:} — cannot tell whether it is alive; not waking."
        decision="unknown (${state#unknown:}) — not waking"
        ;;
      idle)
        now=$(date +%s)
        last=$(cat "$LASTF" 2>/dev/null || echo 0)
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        since=$(( now - last ))

        # EFFECT CHECK — evaluated only when a repeat wake is actually DUE.
        # Counting once per keeper pass instead counts COOLDOWN passes as
        # failures: at a 2-minute cron against a 10-minute drain interval that
        # quarantines a seat in ~6 minutes, before the first repeat wake has even
        # been sent. A strike must mean "I woke it again about the SAME mention
        # and nothing moved".
        # Once QUARANTINED, stop counting. A quarantined seat is never woken, so it
        # never refreshes keeper-last, so "since" stays over the threshold and every
        # subsequent pass would increment again — reporting "23 repeat wakes" when
        # there were 3 wakes and 20 idle passes. A number in an alert that is not the
        # thing it names is worse than no number.
        if [ "$since" -ge "$DRAIN_MIN_S" ] && [ "$strikes" -lt "$MAX_STRIKES" ]; then
          if [ -f "$OBS" ] && [ -n "$pending" ] && [ "$(cat "$OBS" 2>/dev/null)" = "$pending" ]; then
            strikes=$(( strikes + 1 )); echo "$strikes" > "$STRIKE" 2>/dev/null
          elif [ -f "$OBS" ]; then
            strikes=0; rm -f "$OBS" "$STRIKE" 2>/dev/null
          fi
        fi

        if [ "$strikes" -ge "$MAX_STRIKES" ]; then
          log_rl "$ST/.keeper-quarantine.$name" \
            "QUARANTINED $name ($repo): $strikes repeat wakes left mention #$pending unanswered — the wake is not landing. Not waking again until someone looks. Clear with: rm $STRIKE"
          decision="QUARANTINED after $strikes repeat wakes"
        else

          reason=""; prompt=""
          case "$pending" in
            unknown:not-in-roster)
              # Bound to a session but absent from the roster: it can never be
              # mentioned, so it can never be woken. Naming the remedy matters —
              # this one is fixed on the pad, not in the daemon.
              log_rl "$ST/.keeper-peek-unknown.$name" \
                "SEAT NOT ON ROSTER: $name ($repo) is bound to an Ocean session but has no roster line, so no mention can ever reach it and it will never be woken. Add it to the pad's \`\`\`roster block (name | adapter | wake | target), or remove .state/ocean-session.$name if the seat is retired."
              ;;
            unknown:*)
              # The oracle could not answer. Nothing moves, and it is said.
              log_rl "$ST/.keeper-peek-unknown.$name" \
                "MENTION ORACLE UNAVAILABLE for $name ($repo): ${pending#unknown:} — mention wakes are disabled for this seat until \`stitchpad wake $name --peek-ordinal\` answers again."
              ;;
            '') ;;   # nothing unanswered — the overwhelmingly common case
            *)
              if [ "$since" -ge "$DRAIN_MIN_S" ]; then
                reason="unanswered mention #$pending"
                prompt="stitchpad keeper: you have an unanswered @${name} mention. cd $repo && ~/.stitchpad/bin/pasture read -n 30, handle it per the loop prompt, then continue your task queue."
              fi
              ;;
          esac

          if [ -z "$reason" ] && [ "$since" -ge "$QUEUE_MIN_S" ]; then
            open=$(seat_tasks "$PADFILE" "$name")
            if [ "${open:-0}" -gt 0 ]; then
              reason="idle with $open open pad task(s)"
              prompt="stitchpad keeper: you are idle but have $open open task(s) assigned on the pad. cd $repo && ~/.stitchpad/bin/pasture read -n 30 to refresh context, then continue your task queue per the loop prompt. Post .status when resumed."
            fi
          fi

          if [ -z "$reason" ]; then
            decision="idle, nothing due"
          elif [ "$DRY" -eq 1 ]; then
            decision="WOULD WAKE — $reason"
          else
            out=$("$HB" wake --session-id "$sid" --cwd "$repo" --client-type stitchpad \
              ${model:+--model "$model"} --no-wait --prompt "$prompt" 2>&1)
            if echo "$out" | grep -q '"ok": *true'; then
              # RESOLVED-MODEL TELEMETRY (ported from the task-parser keeper this
              # replaced): ask the daemon what the session actually resolved to and
              # record it against the requested pin, so a silent provider swap is
              # visible instead of being discovered days later. Best-effort — an
              # unreachable daemon leaves the previous resolved record untouched,
              # and nothing here can change the wake outcome.
              if command -v sp_model_pin_record_resolved >/dev/null 2>&1; then
                _cfg="$(curl -sf -m 3 "$DAEMON/v1/agent/sessions/$sid/config" 2>/dev/null || true)"
                if [ -n "$_cfg" ]; then
                  _rm="$(printf '%s' "$_cfg" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("model") or "")
except Exception: print("")' 2>/dev/null)"
                  _rp="$(printf '%s' "$_cfg" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("provider") or "")
except Exception: print("")' 2>/dev/null)"
                  if [ -n "$_rm" ]; then
                    sp_model_pin_record_resolved "$ST" "$name" "$_rm" "$_rp" \
                      "keeper-wake-config-rpc" "$sid" || true
                    sp_model_pin_check "$ST" "$name" || true
                  fi
                fi
              fi
              date +%s > "$LASTF"
              # Remember WHICH mention we woke it about, so the next pass can tell
              # whether the wake accomplished anything.
              echo "$pending" > "$OBS" 2>/dev/null
              log "woke $name ($repo): $reason"
              decision="woke — $reason"
            else
              log "WAKE FAILED for $name ($repo): $reason — $(echo "$out" | tail -1)"
              decision="WAKE FAILED — $reason"
            fi
          fi
        fi
        ;;
    esac

    [ "$REPORT" -eq 1 ] && printf '%-12s %-8s %-20s %-8s %s\n' \
      "$name" "${state%%:*}" "${pending:-none}" "$strikes" "$decision"
  done
done < "$CONF"

exit 0
