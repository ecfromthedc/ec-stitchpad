#!/usr/bin/env bash
# roster-duplicate-gate.sh — deepseek F6: a repeated roster row must not make
# two parts of the system disagree about one seat.
#
# THE PAIN: the roster is hand-editable and bridge-writable. With rows
#   dale | cli | pull | -
#   dale | cli | push | sess-999
# sp_wake_mode_for took the FIRST row and answered "pull", while the watcher's
# react() iterated ALL rows and delivered on the push one — so every consumer
# reasoned about a seat that was not the one being delivered to. `join` already
# refuses a duplicate (case-insensitively, and rejects the unicode homoglyphs
# that used to slip past), so a duplicate only ever arrives by hand edit, bridge
# write or merge — and until now nothing could repair one: heal-roster answered
# "nothing to heal" on exactly the roster that needed healing.
#
# ONE HALF OF F6 DOES NOT REPRODUCE and is recorded here rather than quietly
# dropped: it predicted that a duplicate makes react() dispatch the same mention
# twice. It does not — delivery_enqueue is idempotent per (ordinal, message_id).
# G8 asserts that property and G10's mutant breaks the identity check to prove
# G8 is measuring something real.
#
#   G1  sp_wake_mode_for fails CLOSED — any push row makes the seat push
#   G2  a single-row seat is unaffected (the fail-closed rule is not a blanket)
#   G3  heal-roster REPAIRS duplicates instead of declaring victory
#   G4  ... keeping the push row, and losing nobody
#   G5  ... and the repair is committed, not just written
#   G6  a healthy roster still reports "nothing to heal"
#   G7  join still refuses to mint a duplicate at the producer
#   G8  one mention → one delivery generation, even with two push rows
#   G11 the watcher SAYS the roster is duplicated, once an hour, not silently
#   G9  MUTANT: first-row-wins → G1 goes RED
#   G10 MUTANT: enqueue identity broken → G8 goes RED
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
SP="$TOP/tool/bin/stitchpad"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-dupe.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT   # nothing here spawns a daemon (P9)
export HOME="$TMP/home"; mkdir -p "$HOME"
export STITCHPAD_HEARTBEAT_AUTOSTART=0 STITCHPAD_WATCH_START_GRACE=0

sp() {  # $1 = pad dir, $2 = identity, $3 = terminal namespace, rest = args
  ( cd "$1" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID -u STITCHPAD_SESSION \
      STITCHPAD_NAME="$2" STITCHPAD_TERMINAL_NAMESPACE="$3" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
      "$SP" "${@:4}" ) 2>&1
}
# Each seat needs its OWN terminal namespace: one terminal holds one identity,
# so joining two seats from one namespace silently leaves a one-member roster
# and every assertion below would pass while measuring nothing.
mkpad() {  # $1 = tag → pad dir with larry (pull) and dale (pull)
  local d="$TMP/$1"; mkdir -p "$d"
  sp "$d" larry "$1-a" init --name "$1" >/dev/null 2>&1
  sp "$d" larry "$1-a" join larry cli pull - >/dev/null 2>&1
  sp "$d" dale  "$1-b" join dale  cli pull - >/dev/null 2>&1
  printf '%s' "$d"
}
add_dupe_row() {  # $1 = pad dir — append a second, PUSH row for dale
  python3 - "$1/.stitchpad/stitchpad.md" <<'PY'
import sys
p = sys.argv[1]; out = []
for l in open(p, encoding='utf-8').read().split('\n'):
    out.append(l)
    if l.strip().startswith('dale |'):
        out.append('dale | cli | push | sess-999')
open(p, 'w', encoding='utf-8').write('\n'.join(out))
PY
}
rows_for() { sp "$1" larry "$2" roster 2>/dev/null | grep -c "^$3|" || true; }

echo "=== deepseek F6: one seat, one answer ==="
echo ""

P="$(mkpad d1)"
if [ "$(rows_for "$P" d1-a dale)" = "1" ] && [ "$(rows_for "$P" d1-a larry)" = "1" ]; then
  add_dupe_row "$P"
else
  bad "INVALID FIXTURE — the two-seat roster did not build; nothing below measures anything"
fi
_n="$(rows_for "$P" d1-a dale)"
if [ "$_n" != "2" ]; then
  bad "INVALID FIXTURE — expected 2 dale rows, got $_n"
fi

# G1/G2 — read the mode through the CLI's own refusal wording, which is what an
# operator actually sees, rather than poking the helper in isolation.
_out="$(sp "$P" larry d1-a wake dale)"
case "$_out" in
  *"the watcher dispatches it"*) ok "G1 a name with any push row is treated as PUSH (fails closed)" ;;
  *"PULL seat"*) bad "G1 the duplicated seat still reads PULL — first-row-wins is back" ;;
  *) bad "G1 unexpected refusal text: $(printf '%s' "$_out" | head -2)" ;;
esac
_out="$(sp "$P" dale d1-b wake larry)"
case "$_out" in
  *"PULL seat"*) ok "G2 a single-row pull seat still reads PULL — the rule is not a blanket" ;;
  *) bad "G2 an ordinary pull seat changed meaning: $(printf '%s' "$_out" | head -2)" ;;
esac

# G3/G4/G5 — the repair
_before_commits="$(git --git-dir="$P/.stitchpad/stitchpad-git" rev-list --count HEAD 2>/dev/null || echo 0)"
_out="$(sp "$P" larry d1-a heal-roster)"; _rc=$?
_n="$(rows_for "$P" d1-a dale)"
if [ "$_rc" -eq 0 ] && [ "$_n" = "1" ]; then
  ok "G3 heal-roster collapsed the duplicate rows (dale rows 2 → 1)"
else
  bad "G3 heal-roster left $_n dale rows, rc=$_rc: $(printf '%s' "$_out" | head -2)"
fi
if sp "$P" larry d1-a roster 2>/dev/null | grep -q '^dale|cli|push|sess-999$'; then
  ok "G4 the surviving row is the PUSH one — the deliverable seat was kept"
else
  bad "G4 the push row was discarded: $(sp "$P" larry d1-a roster | tr '\n' ' ')"
fi
sp "$P" larry d1-a roster 2>/dev/null | grep -q '^larry|' \
  && ok "G4b nobody else was lost in the repair" \
  || bad "G4b the repair dropped an unrelated seat"
_after_commits="$(git --git-dir="$P/.stitchpad/stitchpad-git" rev-list --count HEAD 2>/dev/null || echo 0)"
if [ "$_after_commits" -gt "$_before_commits" ]; then
  ok "G5 the repair is committed ($_before_commits → $_after_commits), not just written to the working tree"
else
  bad "G5 the repair never reached a commit ($_before_commits → $_after_commits) — it will be lost"
fi

# G6 — a healthy roster is left alone
_out="$(sp "$P" larry d1-a heal-roster)"
case "$_out" in
  *"nothing to heal"*) ok "G6 a healthy roster still reports nothing to heal" ;;
  *) bad "G6 heal-roster now churns a healthy roster: $(printf '%s' "$_out" | head -1)" ;;
esac

# G7 — the producer still refuses
P2="$(mkpad d2)"
sp "$P2" dale d2-b join dale cli push sess-777 >/dev/null 2>&1
if [ "$(rows_for "$P2" d2-a dale)" = "1" ]; then
  ok "G7 re-joining an existing name updates its row instead of adding a second"
else
  bad "G7 join minted a duplicate row — the producer gate is gone"
fi

# G8 — the watcher dispatches a duplicated name once, and picks the push row
P3="$TMP/d3"; mkdir -p "$P3/.stitchpad/.state"
{ printf '# dupe fixture\n\n```roster\n'
  printf 'dale | mock | pull | -\n'
  printf 'dale | mock | push | sess-999\n'
  printf '```\n'
  printf '\n## @operator · 00:00\n\n@dale one message\n'
} > "$P3/.stitchpad/stitchpad.md"
TEST_TOOL="$TMP/tool"; mkdir -p "$TEST_TOOL/adapters"; ln -s "$TOP/tool/bin" "$TEST_TOOL/bin"
cat > "$TEST_TOOL/adapters/mock.sh" <<'MOCK'
#!/usr/bin/env bash
set -u
printf '%s|%s\n' "$2" "${SP_TARGET:-}" >> "$SP_PAD_DIR/.state/mock.calls"
exit 0
MOCK
chmod +x "$TEST_TOOL/adapters/mock.sh"
(
  export STITCHPAD_HOME="$TEST_TOOL"
  BIN_DIR="$TOP/tool/bin"
  # shellcheck disable=SC1090
  source "$TOP/tool/bin/lib.sh"
  unset PAD_DIR PAD_MD PAD_GIT PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
  sp_init_paths "$P3/.stitchpad" >/dev/null
  STITCHPAD_WATCH_LIB_ONLY=1
  # shellcheck disable=SC1090
  source "$TOP/tool/bin/watch.sh"
  unset STITCHPAD_WATCH_LIB_ONLY
  react >/dev/null 2>&1 || true
) >/dev/null 2>&1 || true
_pend="$(cut -d'|' -f8 "$P3/.stitchpad/.state/delivery.dale.pending" 2>/dev/null || true)"
if [ -z "${_pend:-}" ]; then
  bad "G8b INVALID PROBE — react() enqueued nothing, so nothing here measures the dedupe"
elif [ "${_pend:-}" = "sess-999" ]; then
  ok "G8b the dispatch used the PUSH row's target — a stray pull row cannot silence the seat"
else
  bad "G8b the dispatch used target '${_pend:-none}' (want sess-999) — the pull row won and the seat goes undelivered"
fi

# Two PUSH rows is where the double-dispatch actually bites: react() iterates
# rows, so without a per-name guard it enqueues twice in one cycle and the second
# supersedes the first — one mention, two generations, two wakes.
react_cycle() {  # $1 = pad dir
  (
    export STITCHPAD_HOME="$TEST_TOOL"
    BIN_DIR="$TOP/tool/bin"
    # shellcheck disable=SC1090
    source "$TOP/tool/bin/lib.sh"
    unset PAD_DIR PAD_MD PAD_GIT PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
    sp_init_paths "$1/.stitchpad" >/dev/null
    STITCHPAD_WATCH_LIB_ONLY=1
    # shellcheck disable=SC1090
    source "${2:-$TOP/tool}/bin/watch.sh"
    unset STITCHPAD_WATCH_LIB_ONLY
    react >/dev/null 2>&1 || true
  ) >/dev/null 2>&1 || true
}
twopush_pad() {  # $1 = dir
  mkdir -p "$1/.stitchpad/.state"
  { printf '# dupe fixture\n\n```roster\n'
    printf 'dale | mock | push | sess-111\n'
    printf 'dale | mock | push | sess-999\n'
    printf '```\n'
    printf '\n## @operator · 00:00\n\n@dale one message\n'
  } > "$1/.stitchpad/stitchpad.md"
}
P5="$TMP/d5"; twopush_pad "$P5"
react_cycle "$P5"
_gen="$(cat "$P5/.stitchpad/.state/delivery.dale.generation" 2>/dev/null || echo 0)"
if [ "${_gen:-0}" = "1" ]; then
  ok "G8 two push rows, one cycle → ONE generation — the mention was dispatched once"
elif [ "${_gen:-0}" = "0" ]; then
  bad "G8 INVALID PROBE — nothing was enqueued at all"
else
  bad "G8 one mention produced generation $_gen — the duplicate row double-dispatched"
fi

# ── G9 MUTANT: first row wins again ───────────────────────────────────────
echo "  -- mutant: sp_wake_mode_for takes the first row --"
MUT="$TMP/mutant"; mkdir -p "$MUT"; cp -R "$TOP/tool/." "$MUT/"
python3 - "$MUT/bin/lib.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='if (tolower($1) == tolower(n)) { if ($3 == "push") { print "push"; hit=1; exit } if (first == "") first = $3 } }'
new='if (tolower($1) == tolower(n)) { print $3; hit=1; exit } }'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "G9 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  P4="$TMP/d4"; mkdir -p "$P4"
  ( cd "$P4" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE=d4-a STITCHPAD_HEARTBEAT_AUTOSTART=0 "$MUT/bin/stitchpad" init --name d4 >/dev/null 2>&1
    cd "$P4" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE=d4-a STITCHPAD_HEARTBEAT_AUTOSTART=0 "$MUT/bin/stitchpad" join larry cli pull - >/dev/null 2>&1
    cd "$P4" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=dale \
      STITCHPAD_TERMINAL_NAMESPACE=d4-b STITCHPAD_HEARTBEAT_AUTOSTART=0 "$MUT/bin/stitchpad" join dale cli pull - >/dev/null 2>&1 ) || true
  add_dupe_row "$P4"
  _mout="$( cd "$P4" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME=larry \
      STITCHPAD_TERMINAL_NAMESPACE=d4-a STITCHPAD_HEARTBEAT_AUTOSTART=0 "$MUT/bin/stitchpad" wake dale 2>&1 )"
  case "$_mout" in
    *"PULL seat"*) ok "G9 with first-row-wins the duplicated seat reads PULL again — G1 detects it" ;;
    *) bad "G9 mutant applied but the mode did not change: $(printf '%s' "$_mout" | head -2)" ;;
  esac
fi


# G11 — the watcher is the only component that sees the whole roster every
# cycle, so it is the one that tells the operator the roster is corrupt.
P7="$TMP/d7"; twopush_pad "$P7"
_wout="$(
  export STITCHPAD_HOME="$TEST_TOOL"
  BIN_DIR="$TOP/tool/bin"
  # shellcheck disable=SC1090
  source "$TOP/tool/bin/lib.sh"
  unset PAD_DIR PAD_MD PAD_GIT PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
  sp_init_paths "$P7/.stitchpad" >/dev/null
  STITCHPAD_WATCH_LIB_ONLY=1
  # shellcheck disable=SC1090
  source "$TOP/tool/bin/watch.sh"
  unset STITCHPAD_WATCH_LIB_ONLY
  react 2>&1 || true
)"
case "$_wout" in
  *"MORE THAN ONE roster row"*)
    ok "G11 the watcher names the duplicate and points at heal-roster" ;;
  *) bad "G11 the watcher delivered on a corrupt roster in silence" ;;
esac
_wout2="$(
  export STITCHPAD_HOME="$TEST_TOOL"
  BIN_DIR="$TOP/tool/bin"
  # shellcheck disable=SC1090
  source "$TOP/tool/bin/lib.sh"
  unset PAD_DIR PAD_MD PAD_GIT PAD_STATE PAD_TASKS PAD_ARCHIVE_DIR
  sp_init_paths "$P7/.stitchpad" >/dev/null
  STITCHPAD_WATCH_LIB_ONLY=1
  # shellcheck disable=SC1090
  source "$TOP/tool/bin/watch.sh"
  unset STITCHPAD_WATCH_LIB_ONLY
  react 2>&1 || true
)"
case "$_wout2" in
  *"MORE THAN ONE roster row"*)
    bad "G11b the warning repeats every cycle — a watcher runs constantly, this is a log flood" ;;
  *) ok "G11b the warning is rate-limited: the second cycle is quiet" ;;
esac

# ── G10 MUTANT: prove G8 is testing something real ────────────────────────
# deepseek F6 predicted that a duplicated row makes react() double-dispatch. It
# does NOT, and this mutant records WHY rather than leaving G8 looking like a
# property nothing enforces: delivery_enqueue is idempotent per
# (ordinal, message_id), so the second row's enqueue is a no-op. Break that
# identity check and the double-dispatch F6 described appears immediately.
echo "  -- mutant: enqueue is no longer idempotent per message --"
python3 - "$MUT/bin/watch.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='if [ "$old_ordinal" = "$ordinal" ] && [ "$old_message" = "$message_id" ]; then'
new='if false; then'
if s.count(old)!=1:
    sys.stderr.write("MUTANT DID NOT APPLY: anchor not found exactly once\n"); sys.exit(9)
open(p,'w',encoding='utf-8').write(s.replace(old,new))
PY
if [ $? -eq 9 ]; then
  bad "G10 MUTANT DID NOT APPLY — INCONCLUSIVE, not a pass"
else
  P6="$TMP/d6"; twopush_pad "$P6"
  react_cycle "$P6" "$MUT"
  _mgen="$(cat "$P6/.stitchpad/.state/delivery.dale.generation" 2>/dev/null || echo 0)"
  if [ "${_mgen:-0}" -gt 1 ]; then
    ok "G10 with enqueue identity broken the duplicate DOES double-dispatch (generation $_mgen) — G8 detects it"
  else
    bad "G10 mutant applied but generation stayed ${_mgen:-0} — G8 may be testing nothing"
  fi
fi

echo ""
echo "  passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "F6 GREEN — a duplicated roster row is visible, repairable, and reads the same everywhere"
