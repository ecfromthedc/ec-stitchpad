#!/usr/bin/env bash
# delivery-grace-spawn-gate.sh — delivery_start_worker's ownerless-lock grace
# must never strand a fresh generation.
#
# THE BUG (NEXT-SESSION-PROMPT OPEN #3, surfaced by the busy-retry fixture):
# an ownerless worker lock younger than 5s made delivery_start_worker RETURN 0
# WITHOUT spawning — grace for a concurrent starter mid-spawn. But if that
# starter had died between mkdir and spawn, a brand-new delivery generation
# landing in the window got no worker and waited for the next enqueue. In
# production the watcher enqueues on every pad event so it usually recovers;
# with no further pad writes, the mention sat forever.
#
# The fix waits the window out: either the starter publishes a verifiable
# owner (return 0 — it wins) or the grace expires and the dead starter's lock
# is reclaimed and a worker is spawned.
#
#   D0 fixture proof: the ownerless young lock is really in place
#   D1 ONE enqueue during the window still delivers (waits, reclaims, spawns)
#   D2 the dead starter's lock was actually reclaimed (token replaced)
#   D3 a starter that DOES publish a live owner mid-grace is honored, not stomped
#   D4 a lock with a DEAD recorded owner is still reclaimed without the 5s wait
#   D5 MUTANT: restore the return-without-spawn → the strand reappears
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-grace-gate.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
export TMPDIR="$TMP"
DECOY_PID=""
cleanup() { _rc=$?; [ -n "$DECOY_PID" ] && kill "$DECOY_PID" 2>/dev/null; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT   # workers the enqueues spawn drain their queue and exit; the only long-lived pid is the decoy, killed by its captured pid (P9)

echo "=== OPEN #3: the ownerless-lock grace waits and spawns, never strands ==="
echo ""

# ── tool home with an adapter that always accepts and records calls ────────
TEST_TOOL="$TMP/tool"; mkdir -p "$TEST_TOOL/adapters"
ln -s "$ROOT/tool/bin" "$TEST_TOOL/bin"
cat > "$TEST_TOOL/adapters/okay.sh" <<'MOCK'
#!/usr/bin/env bash
set -u
name="$2"; state="$SP_PAD_DIR/.state"
printf '%s\n' "$(date +%s)" >> "$state/okay.$name.calls"
exit 0
MOCK
chmod +x "$TEST_TOOL/adapters/okay.sh"
export STITCHPAD_HOME="$TEST_TOOL"
BIN_DIR="$ROOT/tool/bin"
# shellcheck disable=SC1090
source "$ROOT/tool/bin/lib.sh"

new_case() {  # $1=label $2=roster row — fresh fixture pad, re-inits paths
  CASE_DIR="$TMP/case-$1"; CASE_PAD="$CASE_DIR/.stitchpad"
  mkdir -p "$CASE_PAD/.state"
  { printf '# grace fixture\n\n```roster\n'; printf '%s\n' "$2"; printf '```\n'; } > "$CASE_PAD/stitchpad.md"
  unset PAD_DIR PAD_MD PAD_GIT PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
  sp_init_paths "$CASE_PAD" >/dev/null
}
append_message() { printf '\n## @%s · 00:00\n\n%s\n' "$1" "$2" >> "$PAD_MD"; }
state_value() { sed -n "s/^${2}=//p" "$(delivery_state_file "$1")" 2>/dev/null | tail -1; }
calls() { [ -f "$PAD_STATE/okay.$1.calls" ] && wc -l < "$PAD_STATE/okay.$1.calls" | tr -d ' ' || echo 0; }
wait_state() {  # $1=name $2..=acceptable states; bounded
  local name="$1"; shift
  local tries=150 st
  while [ "$tries" -gt 0 ]; do
    st="$(state_value "$name" state)"
    for want in "$@"; do [ "$st" = "$want" ] && return 0; done
    tries=$(( tries - 1 )); sleep 0.1
  done
  return 1
}
plant_ownerless_lock() {  # $1=name $2=token — a starter that died between mkdir and spawn
  local lock; lock="$(delivery_worker_lock "$1")"
  mkdir -p "$lock"
  printf '%s' "$2" > "$lock/token"
  date +%s > "$lock/born"
}

new_case bootstrap 'bootstrap | okay | push | t'
STITCHPAD_WATCH_LIB_ONLY=1
# shellcheck disable=SC1090
source "$ROOT/tool/bin/watch.sh"
unset STITCHPAD_WATCH_LIB_ONLY
export SP_DELIVERY_RETRY_SECONDS=1

# ── D0–D2: one enqueue during the dead-starter window still delivers ───────
new_case strand 'stranded | okay | push | t'
plant_ownerless_lock stranded "dead-starter-token"
LOCK="$(delivery_worker_lock stranded)"
if [ -d "$LOCK" ] && [ ! -f "$LOCK/owner" ] && [ "$(cat "$LOCK/token")" = "dead-starter-token" ]; then
  ok "D0: ownerless young lock is in place — the window is real"
else
  bad "D0: fixture lock not arranged — every assertion below is vacuous"
fi
append_message operator '@stranded are you there?'
delivery_enqueue stranded okay push t
wait_state stranded completed || true
_st="$(state_value stranded state)"; _n="$(calls stranded)"
if [ "$_st" = "completed" ] && [ "${_n:-0}" -ge 1 ]; then
  ok "D1: ONE enqueue during the window delivered (state=completed, adapter called $_n time(s))"
else
  bad "D1: the mention sat — state='${_st:-<none>}', adapter calls=${_n:-0}, pending=$([ -f "$(delivery_pending_file stranded)" ] && echo yes || echo no)"
fi
_tok="$(cat "$LOCK/token" 2>/dev/null || true)"
if [ "$_tok" != "dead-starter-token" ]; then
  ok "D2: the dead starter's lock was reclaimed (token replaced or lock retired)"
else
  bad "D2: the dead starter's token is still installed — nothing ever owned the singleton"
fi

# ── D3: a starter that publishes a LIVE owner mid-grace wins ───────────────
new_case yield 'patient | okay | push | t'
_T="live-starter-token"
plant_ownerless_lock patient "$_T"
LOCK3="$(delivery_worker_lock patient)"
# A decoy worker whose ps command carries the verification substring; its
# owner record is published ~1s into the grace, exactly like a slow starter.
# The command is compound ON PURPOSE: `bash -c 'sleep 30'` execs into plain
# `sleep 30`, which loses the decoy argv the owner verification greps for.
bash -c 'sleep 30; exit 0' decoy "--delivery-worker patient $_T" &
DECOY_PID=$!
_decoy_start="$(delivery_process_start "$DECOY_PID")"
(
  sleep 1
  printf '%s|%s|%s|%s|%s\n' "$DECOY_PID" "$_decoy_start" "$_T" "$PAD_DIR" "patient" > "$LOCK3/owner"
  printf '%s' "$DECOY_PID" > "$LOCK3/pid"
) &
_pub=$!
_t0="$(date +%s)"
delivery_start_worker patient
_rc3=$?; _t1="$(date +%s)"
wait "$_pub" 2>/dev/null
_tok3="$(cat "$LOCK3/token" 2>/dev/null || true)"
_own3="$(cut -d'|' -f1 "$LOCK3/owner" 2>/dev/null || true)"
if [ "$_rc3" -eq 0 ] && [ "$_tok3" = "$_T" ] && [ "$_own3" = "$DECOY_PID" ] && kill -0 "$DECOY_PID" 2>/dev/null; then
  ok "D3: a live owner published mid-grace is honored (returned in $((_t1-_t0))s, decoy still owns the lock)"
else
  bad "D3: the mid-spawn starter was stomped (rc=$_rc3, token='$_tok3', owner pid='$_own3') — the grace no longer protects the concurrent starter"
fi
kill "$DECOY_PID" 2>/dev/null; wait "$DECOY_PID" 2>/dev/null; DECOY_PID=""

# ── D4: a DEAD recorded owner is reclaimed without serving the 5s wait ─────
new_case deadowner 'quick | okay | push | t'
LOCK4="$(delivery_worker_lock quick)"
mkdir -p "$LOCK4"
printf '%s' "dead-owner-token" > "$LOCK4/token"
date +%s > "$LOCK4/born"
# a pid that ran and exited: record its identity, then let it die
bash -c 'exit 0' & _dead=$!; wait "$_dead" 2>/dev/null
printf '%s|%s|%s|%s|%s\n' "$_dead" "gone" "dead-owner-token" "$PAD_DIR" "quick" > "$LOCK4/owner"
printf '%s' "$_dead" > "$LOCK4/pid"
append_message operator '@quick fast lane please'
_t0="$(date +%s)"
delivery_enqueue quick okay push t
_t1="$(date +%s)"
wait_state quick completed || true
if [ "$(state_value quick state)" = "completed" ] && [ $((_t1-_t0)) -le 3 ]; then
  ok "D4: dead-owner lock reclaimed immediately (enqueue took $((_t1-_t0))s) — the wait applies only to the ownerless window"
else
  bad "D4: dead-owner path regressed (state=$(state_value quick state), enqueue took $((_t1-_t0))s)"
fi

# ── D5: MUTANT — restore return-without-spawn; the strand must reappear ────
echo "  -- mutant: grace returns 0 without spawning --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$ROOT/tool/." "$MUT/"
python3 - "$MUT/bin/watch.sh" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
anchor = '''      _grace_tries=$((_grace_tries + 1))
      [ "$_grace_tries" -le 50 ] || return 0
      sleep 0.2
      continue'''
mutant = '''      return 0'''
if s.count(anchor) != 1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once (%d)\n" % s.count(anchor)); sys.exit(9)
open(p, 'w', encoding='utf-8').write(s.replace(anchor, mutant))
PY
if [ $? -ne 0 ]; then
  bad "D5 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  # Run the D1 scenario in a subshell against the mutant tree so the mutated
  # delivery_start_worker is the one that executes.
  _mut_out="$(
    /usr/bin/env bash -c '
      set -u
      ROOT="$1"; TMPD="$2"
      export STITCHPAD_HOME="$3" TMPDIR="$TMPD" SP_DELIVERY_RETRY_SECONDS=1
      BIN_DIR="$ROOT/bin"
      source "$ROOT/bin/lib.sh"
      CASE_PAD="$TMPD/mutcase/.stitchpad"; mkdir -p "$CASE_PAD/.state"
      { printf "# grace fixture\n\n\`\`\`roster\n"; printf "stranded | okay | push | t\n"; printf "\`\`\`\n"; } > "$CASE_PAD/stitchpad.md"
      sp_init_paths "$CASE_PAD" >/dev/null
      STITCHPAD_WATCH_LIB_ONLY=1; source "$ROOT/bin/watch.sh"; unset STITCHPAD_WATCH_LIB_ONLY
      lock="$(delivery_worker_lock stranded)"; mkdir -p "$lock"
      printf "%s" dead-starter-token > "$lock/token"; date +%s > "$lock/born"
      printf "\n## @operator · 00:00\n\n@stranded are you there?\n" >> "$PAD_MD"
      delivery_enqueue stranded okay push t
      perl -e "select(undef,undef,undef,7)"
      st="$(sed -n "s/^state=//p" "$(delivery_state_file stranded)" 2>/dev/null | tail -1)"
      n=0; [ -f "$PAD_STATE/okay.stranded.calls" ] && n="$(wc -l < "$PAD_STATE/okay.stranded.calls" | tr -d " ")"
      pend=no; [ -f "$(delivery_pending_file stranded)" ] && pend=yes
      echo "state=$st calls=$n pending=$pend"
    ' _ "$MUT" "$TMP" "$TEST_TOOL" 2>/dev/null
  )"
  case "$_mut_out" in
    *"calls=0 pending=yes"*)
      ok "D5: mutant strands the mention ($_mut_out) — D1 detects the regression" ;;
    *)
      bad "D5: mutant applied but delivery still proceeded ($_mut_out) — D1 may be testing nothing" ;;
  esac
fi

echo ""
echo "=== RESULTS: $pass PASS, $fail FAIL ==="
[ "$fail" -eq 0 ] || exit 1
