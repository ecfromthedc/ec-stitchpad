#!/usr/bin/env bash
# seat-keeper — anti-starvation watchdog for pasture/stitchpad Ocean seats.
#
# THE PROBLEM: wakes are mention-driven. A seat with no NEW @mentions but
# unfinished work idles forever once ad-hoc monitors die. This watchdog is the
# standing guarantee that a bound seat with work waiting always gets woken.
#
# THE TRAP IT WAS FALLING INTO: an earlier revision woke on `count.<seat> > 0`.
# `count.*` is not a backlog. It is the CUMULATIVE count of pad lines addressing
# @seat or @all (lib.sh sp_count_to), written ONCE at watcher startup
# (watch.sh) and never maintained by the react loop — vestigial. So `> 0` only
# ever meant "has been mentioned at some point in this pad's life". Observed
# consequence on a live 3-seat fleet: two seats woken every 10 minutes for two
# days (~570 paid model turns) against a pad that mentioned neither, while the
# third — the seat the watchdog was written to save — starved untouched at
# count=0, because with no pad task blocks neither wake branch could fire. Three
# of the counters were also mode 444, so the watcher's seed write failed
# silently and froze them at values from two days prior.
#
# Three properties are borrowed from Daniel Coulbourne's crux (MIT,
# github.com/DanielCoulbourne/crux-cli), which solves this same class of problem:
#
#   1. FAIL CLOSED WITH A VOICE (crux lib/failover.js). A probe has three
#      outcomes, not two: up, down, and unknown. Collapsing unknown into "skip"
#      means an unreachable or reshaped daemon silently stops the entire watchdog
#      with no log line at all. Here unknown never moves a seat AND never passes
#      in silence.
#
#   2. A CURSOR BELONGS TO THE CONSUMER (crux lib/cursor.js). Position is read
#      relative to what THIS seat has consumed, never as a shared level.
#
#   3. A SUPERVISOR THAT CANNOT SEE ITS WORKER SAYS SO (crux 0.5.1). A wake that
#      leaves the SAME mention unanswered is a strike; MAX_STRIKES consecutive
#      no-ops quarantine the seat and log loudly instead of retrying forever.
#
# Pads watched: one repo path per line in ~/.pasture/keeper.conf
# Kill switch:  touch ~/.pasture/keeper.off
# Log:          ~/.pasture/keeper.log
# Un-quarantine: rm <pad>/.state/keeper-strike.<seat>
#
# Flags: --dry-run  decide and log, wake nothing
#        --report   dry-run plus a per-seat decision table
set -uo pipefail

# Install home: ~/.pasture on migrated machines, ~/.stitchpad on legacy ones.
SP_HOME="${STITCHPAD_HOME:-}"
if [ -z "$SP_HOME" ]; then
  if [ -d "$HOME/.pasture" ]; then SP_HOME="$HOME/.pasture"; else SP_HOME="$HOME/.stitchpad"; fi
fi

# Overridable so the wake path can be exercised against a throwaway pad without
# touching the live fleet's conf. A refusal you cannot test is a refusal that
# rots, and that applies to the wake path just as much as to the refusals.
CONF="${SEAT_KEEPER_CONF:-$SP_HOME/keeper.conf}"
LOG="${SEAT_KEEPER_LOG:-$SP_HOME/keeper.log}"
HB="${OCEAN_HEARTBEAT:-$HOME/dev/ocean-os/target/release/ocean-heartbeat}"
SP="$SP_HOME/bin/stitchpad"           # the mention oracle {@see seat_pending}
DAEMON="${OCEAN_DAEMON:-http://127.0.0.1:4780}"
DRAIN_MIN_S=600       # min seconds between keeper wakes per seat (mentions)
QUEUE_MIN_S=900       # min seconds between keeper wakes per seat (task queue)
MAX_STRIKES=3         # consecutive no-effect wakes before quarantine
RELOG_S=3600          # re-log a quarantined/unknown seat at most this often

DRY=0; REPORT=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --report)  DRY=1; REPORT=1 ;;
    *) echo "seat-keeper: unknown flag $a" >&2; exit 2 ;;
  esac
done

[ -f "$SP_HOME/keeper.off" ] && exit 0
[ -f "$CONF" ] || exit 0
[ -x "$HB" ] || { echo "seat-keeper: no heartbeat binary at $HB" >&2; exit 0; }
[ -x "$SP" ] || { echo "seat-keeper: no stitchpad CLI at $SP" >&2; exit 0; }

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

# --- pad layout: .pasture wins, .stitchpad accepted {@see lib.sh sp_find_pad} --
pad_dir() {
  [ -d "$1/.pasture" ]   && { echo "$1/.pasture"; return; }
  [ -d "$1/.stitchpad" ] && { echo "$1/.stitchpad"; return; }
  return 1
}
pad_md() {
  [ -f "$1/pasture.md" ] && { echo "$1/pasture.md"; return; }
  echo "$1/stitchpad.md"
}

# --- daemon reachability, answered ONCE per run -----------------------------
# Probing per seat and silently skipping every seat on failure produces a
# watchdog that has stopped watching and says nothing. Being unable to reach the
# daemon is the single most important thing this script can report.
if ! curl -sf -m 3 "$DAEMON/health" >/dev/null 2>&1; then
  log_rl "$SP_HOME/.keeper-daemon-unreachable" \
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
# than that seat's last addressed reply, resolved against its own seen.<name>.
# That is the fleet's real engagement gate; anything else is a re-derivation
# that can drift from it, and the count.* trap above is what drift looks like.
#
# `--peek-ordinal` rather than `--peek` because the ordinal is the STABLE
# IDENTITY of the pending mention, which is what lets the effect check below
# tell "the same mention is still unanswered" (a wasted wake) from "a new
# mention arrived" (progress). Neither peek form advances any cursor.
seat_pending() {
  local repo="$1" name="$2" out rc

  # A name that is not on the roster peeks EMPTY with rc=0 — the same answer as
  # "nothing is pending". A seat bound to an Ocean session but missing from the
  # roster would therefore read as permanently idle and never be woken again:
  # silent starvation, the exact failure this watchdog exists to prevent,
  # wearing the healthy answer's clothes. It is a bound seat, so this is a fault.
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

[ "$REPORT" -eq 1 ] && printf '%-12s %-8s %-22s %-8s %s\n' SEAT STATE PENDING STRIKES DECISION

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  case "$repo" in \#*) continue ;; esac
  PAD="$(pad_dir "$repo")" || continue
  ST="$PAD/.state"
  PADFILE="$(pad_md "$PAD")"
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
        log_rl "$ST/.keeper-state-unknown.$name" \
          "UNKNOWN state for $name ($repo): ${state#unknown:} — cannot tell whether it is alive; not waking."
        decision="unknown (${state#unknown:}) — not waking"
        ;;
      idle)
        # Effect check: we woke it about mention #N last pass. If #N is STILL the
        # unanswered one, that wake did nothing. Count it rather than repeating
        # it forever. A different ordinal, or none, is progress.
        if [ -f "$OBS" ] && [ -n "$pending" ] && [ "$(cat "$OBS" 2>/dev/null)" = "$pending" ]; then
          strikes=$(( strikes + 1 ))
          echo "$strikes" > "$STRIKE" 2>/dev/null
        elif [ -f "$OBS" ]; then
          strikes=0; rm -f "$OBS" "$STRIKE" 2>/dev/null
        fi

        if [ "$strikes" -ge "$MAX_STRIKES" ]; then
          log_rl "$ST/.keeper-quarantine.$name" \
            "QUARANTINED $name ($repo): $strikes consecutive wakes left mention #$pending unanswered — the wake is not landing. Not waking again until someone looks. Clear with: rm $STRIKE"
          decision="QUARANTINED after $strikes no-op wakes"
        else
          now=$(date +%s)
          last=$(cat "$LASTF" 2>/dev/null || echo 0)
          case "$last" in ''|*[!0-9]*) last=0 ;; esac
          since=$(( now - last ))

          reason=""; prompt=""
          case "$pending" in
            unknown:not-in-roster)
              # Bound to a session but absent from the roster: it can never be
              # mentioned, so it can never be woken. Name the remedy — this one
              # is fixed on the pad, not in the daemon.
              log_rl "$ST/.keeper-peek-unknown.$name" \
                "SEAT NOT ON ROSTER: $name ($repo) is bound to an Ocean session but has no roster line, so no mention can ever reach it and it will never be woken. Add it to the pad's roster block (name | adapter | wake | target), or remove .state/ocean-session.$name if the seat is retired."
              ;;
            unknown:*)
              log_rl "$ST/.keeper-peek-unknown.$name" \
                "MENTION ORACLE UNAVAILABLE for $name ($repo): ${pending#unknown:} — mention wakes are disabled for this seat until \`stitchpad wake $name --peek-ordinal\` answers again."
              ;;
            '') ;;   # nothing unanswered — the overwhelmingly common case
            *)
              if [ "$since" -ge "$DRAIN_MIN_S" ]; then
                reason="unanswered mention #$pending"
                prompt="pasture keeper: you have an unanswered @${name} mention. cd $repo && $SP_HOME/bin/pasture read -n 30, handle it per the loop prompt, then continue your task queue."
              fi
              ;;
          esac

          if [ -z "$reason" ] && [ "$since" -ge "$QUEUE_MIN_S" ]; then
            open=$(seat_tasks "$PADFILE" "$name")
            if [ "${open:-0}" -gt 0 ]; then
              reason="idle with $open open pad task(s)"
              prompt="pasture keeper: you are idle but have $open open task(s) assigned on the pad. cd $repo && $SP_HOME/bin/pasture read -n 30 to refresh context, then continue your task queue per the loop prompt. Post .status when resumed."
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
              date +%s > "$LASTF"
              # Remember WHICH mention we woke it about, so the next pass can
              # tell whether the wake accomplished anything.
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

    [ "$REPORT" -eq 1 ] && printf '%-12s %-8s %-22s %-8s %s\n' \
      "$name" "${state%%:*}" "${pending:-none}" "$strikes" "$decision"
  done
done < "$CONF"

exit 0
