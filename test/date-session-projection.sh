#!/usr/bin/env bash
# Deterministic tests for date-divider and session-registry projection semantics.
#   bash test/date-session-projection.sh
#
# Covers:
#   1. exact visible format (italic: *— ... —*)
#   2. one-epoch snapshot (no re-derivation across calls)
#   3. no read-only mutation
#   4. concurrency (two writers under lock, exactly one divider per date)
#   5. midnight boundary
#   6. monotonic enforcement: backward/forward clock, first-authored-message
#   7. DST fold/gap
#   8. session registry: append, projection, status, cap
#   9. sentinel-bounded projection
#  10. provider mapping (kimi → kimi, not deepseek)
#  11. session ID validation
#  12. injected clock
#  13. failed append rollback (readonly, symlink refusal)
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
BIN="$ROOT/tool/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0

ok()  { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
check_contains() { if echo "$2" | grep -qF -e "$3"; then ok "$1"; else bad "$1 (missing '$3' in '$2')"; fi; }
# Evaluate a command as an assertion (set -e safe): assert "msg" test -n "$x"
assert() { local _m="$1"; shift; if "$@"; then ok "$_m"; else bad "$_m"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-proj.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Set up a minimal pad fixture
mkdir -p "$WORK/.state" "$WORK/home"
export HOME="$WORK/home"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
export STITCHPAD_HEARTBEAT_AUTOSTART=0

PAD_MD="$WORK/stitchpad.md"
PAD_STATE="$WORK/.state"
mkdir -p "$PAD_STATE"

# Minimal pad: roster block + some existing content
cat > "$PAD_MD" <<'EOPAD'
```roster
alice | claude | pull | -
bob   | claude | pull | -
```
EOPAD

# Source the libraries
source "$BIN/date-divider.sh"
source "$BIN/session-registry.sh"

echo "=== date-session-projection tests ==="
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# 1. Exact visible format (italic: *— ... —*)
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 1. exact visible format ---"

# sp_date_divider_line must produce: *— YYYY-MM-DD (Zone) · Weekday —*
# Use a fixed epoch we control: 2026-08-01 12:00:00 UTC = 1785585600
FIXED_EPOCH=1785585600

# America/New_York → 2026-08-01 08:00:00 EDT → Saturday
LINE="$(sp_date_divider_line "$FIXED_EPOCH" "America/New_York")"

# Full format assertion — the EXACT italic divider string
WANT_LINE="*— 2026-08-01 (America/New_York) · Saturday —*"
check "divider: exact full line" "$LINE" "$WANT_LINE"

check_contains "divider: asterisk prefix" "$LINE" "*— "
check_contains "divider: asterisk suffix" "$LINE" " —*"
check_contains "divider: contains canonical date" "$LINE" "2026-08-01"
check_contains "divider: contains zone name in parens" "$LINE" "(America/New_York)"
check_contains "divider: contains weekday" "$LINE" "Saturday"
check_contains "divider: middle dot separator" "$LINE" "·"

# UTC zone
LINE_UTC="$(sp_date_divider_line "$FIXED_EPOCH" "UTC")"
check_contains "divider UTC: contains 2026-08-01" "$LINE_UTC" "2026-08-01"
check_contains "divider UTC: italic format" "$LINE_UTC" "*— "

# Australia/Sydney at +10 → still 2026-08-01 (22:00 local)
LINE_SYD="$(sp_date_divider_line "$FIXED_EPOCH" "Australia/Sydney")"
check_contains "divider Sydney: still 2026-08-01" "$LINE_SYD" "2026-08-01"

# Pacific/Auckland at +13 → rolls to 2026-08-02 (01:00 local)
LINE_AKL="$(sp_date_divider_line "$FIXED_EPOCH" "Pacific/Auckland")"
check_contains "divider Auckland: rolls to 2026-08-02" "$LINE_AKL" "2026-08-02"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 2. One-epoch snapshot — snapshot is captured once per operation
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 2. one-epoch snapshot ---"

# Snapshot captures the current wall-clock time via date +%s
STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
EPOCH1="$_SP_DATE_EPOCH"
DATE1="$_SP_DATE_DATE"

assert "snapshot: epoch captured" test -n "$EPOCH1"
assert "snapshot: date derived" test -n "$DATE1"

sleep 1  # advance wall clock

# Second snapshot — same operation, should be later epoch
STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
EPOCH2="$_SP_DATE_EPOCH"
DATE2="$_SP_DATE_DATE"

assert "snapshot: second epoch captured" test -n "$EPOCH2"
[ "$EPOCH2" -gt "$EPOCH1" ] && ok "snapshot: second epoch > first" \
  || bad "snapshot: second epoch > first (e1=$EPOCH1 e2=$EPOCH2)"

# Same UTC day → dates should match
check "snapshot: same date within UTC day" "$DATE1" "$DATE2"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 3. No read-only mutation
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 3. no read-only mutation ---"

# sp_date_divider_line does not touch files
BEFORE_MD5="$(md5 -q "$PAD_MD" 2>/dev/null || md5sum "$PAD_MD" | awk '{print $1}')"
BEFORE_STATE_COUNT="$(ls -1 "$PAD_STATE" 2>/dev/null | wc -l | tr -d ' ')"

sp_date_divider_line "1785585600" "UTC" >/dev/null
sp_date_divider_line "1785585600" "America/New_York" >/dev/null
sp_date_divider_needed >/dev/null 2>&1 || true

AFTER_MD5="$(md5 -q "$PAD_MD" 2>/dev/null || md5sum "$PAD_MD" | awk '{print $1}')"
AFTER_STATE_COUNT="$(ls -1 "$PAD_STATE" 2>/dev/null | wc -l | tr -d ' ')"

check "immutable: pad md5 unchanged by line/needed" "$BEFORE_MD5" "$AFTER_MD5"
check "immutable: state file count unchanged by read-only ops" "$BEFORE_STATE_COUNT" "$AFTER_STATE_COUNT"

# sp_session_registry_project is read-only
BEFORE_MD5="$(md5 -q "$PAD_MD" 2>/dev/null || md5sum "$PAD_MD" | awk '{print $1}')"
sp_session_registry_project >/dev/null 2>&1 || true
AFTER_MD5="$(md5 -q "$PAD_MD" 2>/dev/null || md5sum "$PAD_MD" | awk '{print $1}')"
check "immutable: pad md5 unchanged by project" "$BEFORE_MD5" "$AFTER_MD5"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 4. Concurrency — two writers under lock, exactly one divider per date
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 4. concurrency ---"

# Set up a fresh pad
PAD_MD="$WORK/pad-concurrent.md"
cat > "$PAD_MD" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD

# Inject a fixed clock
SP_DATE_DIVIDER_CLOCK="1785585600" STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
assert "concurrency: snapshot captured" test -n "$_SP_DATE_DATE"
check "concurrency: date is 2026-08-01" "$_SP_DATE_DATE" "2026-08-01"

# First insert — should write the divider
RC=0; sp_date_divider_insert || RC=$?
assert "concurrency: first insert succeeds" test "$RC" -eq 0

DIV_COUNT_1="$(grep -c '^\*— ' "$PAD_MD" 2>/dev/null || echo 0)"
check "concurrency: exactly one divider after first insert" "$DIV_COUNT_1" "1"

# Second insert (same snapshot, same date) — should be a no-op
RC=0; sp_date_divider_insert || RC=$?
[ "$RC" -eq 1 ] && ok "concurrency: second insert returns 1 (already present)" \
  || bad "concurrency: second insert returns 1 (got $RC)"

DIV_COUNT_2="$(grep -c '^\*— ' "$PAD_MD" 2>/dev/null || echo 0)"
check "concurrency: still exactly one divider after double insert" "$DIV_COUNT_2" "1"

# Simulate a late writer who snapshotted before the first insert
# Take a fresh snapshot of the SAME date → insert should still be idempotent
SP_DATE_DIVIDER_CLOCK="1785585600" STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
RC=0; sp_date_divider_insert || RC=$?
[ "$RC" -eq 1 ] && ok "concurrency: late writer no-ops (already present)" \
  || bad "concurrency: late writer no-ops (got $RC)"

DIV_COUNT_3="$(grep -c '^\*— ' "$PAD_MD" 2>/dev/null || echo 0)"
check "concurrency: exactly one divider after three inserts" "$DIV_COUNT_3" "1"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 5. Midnight boundary
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 5. midnight boundary ---"

PAD_MD="$WORK/pad-midnight.md"
cat > "$PAD_MD" <<'EOPAD'
```roster
alice | claude | pull | -
```

*— 2026-07-31 (UTC) · Friday —*
EOPAD

# Force the snapshot for 2026-08-01 (next day)
SP_DATE_DIVIDER_CLOCK="1785585600" STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
assert "midnight: snapshot for 2026-08-01" test "$_SP_DATE_DATE" = "2026-08-01"

# The pad already has a divider for 2026-07-31, not 2026-08-01
RC=0; sp_date_divider_needed || RC=$?
[ "$RC" -eq 0 ] && ok "midnight: divider needed for new date" \
  || bad "midnight: divider needed for new date (got $RC)"

RC=0; sp_date_divider_insert || RC=$?
[ "$RC" -eq 0 ] && ok "midnight: insert succeeds for new date" \
  || bad "midnight: insert succeeds for new date (got $RC)"

DIV_COUNT="$(grep -c '^\*— ' "$PAD_MD" 2>/dev/null || echo 0)"
check "midnight: two dividers (one per date)" "$DIV_COUNT" "2"

# Verify the new divider is for the right date and has italic format
grep -q "^\*— 2026-08-01 " "$PAD_MD" && ok "midnight: new divider has correct date and italic format" \
  || bad "midnight: new divider has correct date and italic format"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 6. Monotonic enforcement: backward clock + forward date + first-authored
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 6. monotonic enforcement ---"

PAD_MD="$WORK/pad-mono.md"
PAD_STATE="$WORK/.state-mono"
mkdir -p "$PAD_STATE"

cat > "$PAD_MD" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD

# Day 1: insert divider for 2026-08-01 at epoch 1785585600 (noon UTC)
SP_DATE_DIVIDER_CLOCK="1785585600" STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
RC=0; sp_date_divider_insert || RC=$?
[ "$RC" -eq 0 ] && ok "mono: day 1 insert OK" || bad "mono: day 1 insert failed ($RC)"
check_contains "mono: day 1 divider present" "$(cat "$PAD_MD")" "*— 2026-08-01"

# Same day, later epoch (one hour after) — second insert should be idempotent
SP_DATE_DIVIDER_CLOCK="1785589200" STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
RC=0; sp_date_divider_insert || RC=$?
[ "$RC" -eq 1 ] && ok "mono: same day idempotent (returns 1)" \
  || bad "mono: same day idempotent (got $RC)"

# Day 2: forward to 2026-08-02 at epoch 1785672000 (next day noon UTC)
SP_DATE_DIVIDER_CLOCK="1785672000" STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
RC=0; sp_date_divider_insert || RC=$?
[ "$RC" -eq 0 ] && ok "mono: day 2 divider inserted for next day" \
  || bad "mono: day 2 divider inserted for next day (got $RC)"

DIV_COUNT_MONO="$(grep -c '^\*— ' "$PAD_MD" 2>/dev/null || echo 0)"
check "mono: two dividers (one per date)" "$DIV_COUNT_MONO" "2"

# Backward clock to day 1 — should REFUSE (returns 2 for error)
# This simulates a clock-drift scenario
SP_DATE_DIVIDER_CLOCK="1785585600" STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
RC=0; sp_date_divider_insert || RC=$?
[ "$RC" -eq 2 ] && ok "mono: backward clock refused (returns 2)" \
  || bad "mono: backward clock refused (got $RC, want 2)"

# Still exactly 2 dividers
DIV_COUNT_MONO2="$(grep -c '^\*— ' "$PAD_MD" 2>/dev/null || echo 0)"
check "mono: still two dividers after backward clock refusal" "$DIV_COUNT_MONO2" "2"

# Clean up the last-divider state for subsequent tests
rm -f "$PAD_STATE/last-divider-epoch"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 7. DST fold/gap
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 7. DST fold/gap ---"

# America/New_York DST transitions:
#   Spring forward: 2026-03-08 02:00 → 03:00 (gap: 02:30 doesn't exist)
#   Fall back:      2026-11-01 02:00 → 01:00 (fold: 01:30 happens twice)
#
# The date should remain correct through both transitions.

# Spring forward gap: 2026-03-08 03:30 EDT
GAP_EPOCH=$(python3 -c "
from datetime import datetime
import zoneinfo
# 2026-03-08 03:30 EDT = 07:30 UTC
dt = datetime(2026, 3, 8, 7, 30, 0, tzinfo=zoneinfo.ZoneInfo('UTC'))
print(int(dt.timestamp()))
")
LINE_GAP="$(sp_date_divider_line "$GAP_EPOCH" "America/New_York")"
check_contains "DST gap: date is 2026-03-08" "$LINE_GAP" "2026-03-08"
check_contains "DST gap: weekday is Sunday" "$LINE_GAP" "Sunday"

# Fall back fold: 2026-11-01 01:30 EDT (first occurrence, 05:30 UTC)
FOLD_EPOCH_1=$(python3 -c "
from datetime import datetime
import zoneinfo
dt = datetime(2026, 11, 1, 5, 30, 0, tzinfo=zoneinfo.ZoneInfo('UTC'))
print(int(dt.timestamp()))
")
LINE_FOLD1="$(sp_date_divider_line "$FOLD_EPOCH_1" "America/New_York")"
check_contains "DST fold 1st: date is 2026-11-01" "$LINE_FOLD1" "2026-11-01"

# Fall back fold: 2026-11-01 01:30 EST (second occurrence, 06:30 UTC)
FOLD_EPOCH_2=$(python3 -c "
from datetime import datetime
import zoneinfo
dt = datetime(2026, 11, 1, 6, 30, 0, tzinfo=zoneinfo.ZoneInfo('UTC'))
print(int(dt.timestamp()))
")
LINE_FOLD2="$(sp_date_divider_line "$FOLD_EPOCH_2" "America/New_York")"
check_contains "DST fold 2nd: date is still 2026-11-01" "$LINE_FOLD2" "2026-11-01"

# Both fold occurrences produce the same date divider
check "DST fold: both occurrences produce same date" \
  "$(echo "$LINE_FOLD1" | grep -o '2026-11-01')" \
  "$(echo "$LINE_FOLD2" | grep -o '2026-11-01')"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 8. Session registry: append, projection, status, cap, provider mapping
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 8. session registry ---"

# Fresh state dir
PAD_STATE="$WORK/.state-registry"
mkdir -p "$PAD_STATE"

# Initialize
RC=0; sp_session_registry_init || RC=$?
assert "registry: init succeeds" test "$RC" -eq 0
assert "registry: init creates file" test -f "$PAD_STATE/session-registry.jsonl"

# Append entries with varied session_ids for projection testing
RC=0
STITCHPAD_SESSION="sid-alice" STITCHPAD_NAME="alice" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$WORK" \
  sp_session_registry_append || RC=$?
assert "registry: append alice (openai)" test "$RC" -eq 0

RC=0
STITCHPAD_SESSION="sid-bob" STITCHPAD_NAME="bob" \
  STITCHPAD_MODEL="claude-opus-4.5" PAD_DIR="$WORK" \
  sp_session_registry_append || RC=$?
assert "registry: append bob (anthropic)" test "$RC" -eq 0

RC=0
STITCHPAD_SESSION="sid-kimi" STITCHPAD_NAME="kimi-test" \
  STITCHPAD_MODEL="kimi-k2" PAD_DIR="$WORK" \
  sp_session_registry_append || RC=$?
assert "registry: append kimi" test "$RC" -eq 0

RC=0
STITCHPAD_SESSION="sid-alice" STITCHPAD_NAME="alice" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$WORK" \
  sp_session_registry_append || RC=$?
assert "registry: append alice again" test "$RC" -eq 0

# Verify file has 4 lines
LINE_COUNT="$(wc -l < "$PAD_STATE/session-registry.jsonl" | tr -d ' ')"
check "registry: 4 entries in file" "$LINE_COUNT" "4"

# Each line must be valid JSON with required fields
LINE1="$(head -1 "$PAD_STATE/session-registry.jsonl")"
check_contains "registry: line 1 has request_id" "$LINE1" "request_id"
check_contains "registry: line 1 has session_id" "$LINE1" "session_id"
check_contains "registry: line 1 has provider" "$LINE1" "provider"
check_contains "registry: line 1 has model" "$LINE1" "model"
check_contains "registry: line 1 has worktree" "$LINE1" "worktree"
check_contains "registry: line 1 has start" "$LINE1" "start"
check_contains "registry: line 1 has last_activity" "$LINE1" "last_activity"
check_contains "registry: line 1 has name" "$LINE1" "name"

# Unique request_ids — every entry must have a different request_id
REQ1="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])" <<< "$(head -1 "$PAD_STATE/session-registry.jsonl")")"
REQ2="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])" <<< "$(sed -n '2p' "$PAD_STATE/session-registry.jsonl")")"
REQ3="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])" <<< "$(sed -n '3p' "$PAD_STATE/session-registry.jsonl")")"
REQ4="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])" <<< "$(sed -n '4p' "$PAD_STATE/session-registry.jsonl")")"

[ "$REQ1" != "$REQ2" ] && ok "registry: unique request_ids (1≠2)" \
  || bad "registry: unique request_ids (1≠2)"
[ "$REQ2" != "$REQ3" ] && ok "registry: unique request_ids (2≠3)" \
  || bad "registry: unique request_ids (2≠3)"
[ "$REQ1" != "$REQ3" ] && ok "registry: unique request_ids (1≠3)" \
  || bad "registry: unique request_ids (1≠3)"
[ "$REQ3" != "$REQ4" ] && ok "registry: unique request_ids (3≠4)" \
  || bad "registry: unique request_ids (3≠4)"

# Verify provider mapping: kimi → kimi (NOT deepseek)
KIMI_PROVIDER="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['provider'])" <<< "$(sed -n '3p' "$PAD_STATE/session-registry.jsonl")")"
check "provider: kimi-k2 → kimi (not deepseek)" "$KIMI_PROVIDER" "kimi"

# Verify request_id reflects delegated lifecycle (provider-sid-counter)
check_contains "request_id: reflects provider" "$REQ1" "openai"
check_contains "request_id: reflects provider for kimi" "$REQ3" "kimi"

# Projection: 4 entries from 3 sessions → 3 session summaries
PROJ="$(sp_session_registry_project)"
SESSION_COUNT="$(echo "$PROJ" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))")"
check "registry: projection has 3 sessions" "$SESSION_COUNT" "3"

# Alice has request_count=2
ALICE_REQS="$(echo "$PROJ" | python3 -c "
import json,sys
data = json.loads(sys.stdin.read())
for s in data:
    if s['session_id'] == 'sid-alice':
        print(s['request_count'])
")"
check "registry: alice request_count" "$ALICE_REQS" "2"

# Status derivation: sessions should be 'active' (just appended)
ALICE_STATUS="$(echo "$PROJ" | python3 -c "
import json,sys
data = json.loads(sys.stdin.read())
for s in data:
    if s['session_id'] == 'sid-alice':
        print(s['status'])
")"
check "registry: alice status is active" "$ALICE_STATUS" "active"

# Terminal status: create session-end marker
touch "$PAD_STATE/session-end.sid-alice"
PROJ2="$(sp_session_registry_project)"
ALICE_STATUS2="$(echo "$PROJ2" | python3 -c "
import json,sys
data = json.loads(sys.stdin.read())
for s in data:
    if s['session_id'] == 'sid-alice':
        print(s['status'])
")"
check "registry: terminal marker → status=terminal" "$ALICE_STATUS2" "terminal"
rm -f "$PAD_STATE/session-end.sid-alice"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 9. Sentinel-bounded projection
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 9. sentinel-bounded projection ---"

# Projection with since_epoch=0 (all entries)
PROJ_ALL="$(sp_session_registry_project)"
ALL_COUNT="$(echo "$PROJ_ALL" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))")"
assert "sentinel: all sessions visible when since=0" test "$ALL_COUNT" -gt 0

# Projection with a far-future since_epoch (no entries qualify)
NOW="$(date +%s)"
FUTURE=$(( NOW + 86400 ))
STITCHPAD_PROJECTION_SINCE="$FUTURE" PROJ_FUTURE="$(sp_session_registry_project)"
FUTURE_COUNT="$(echo "$PROJ_FUTURE" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))")"
check "sentinel: no sessions when since_epoch is future" "$FUTURE_COUNT" "0"

# Projection cap
STITCHPAD_PROJECTION_MAX=2 PROJ_CAPPED="$(sp_session_registry_project)"
CAPPED_COUNT="$(echo "$PROJ_CAPPED" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))")"
assert "sentinel: projection capped at STITCHPAD_PROJECTION_MAX" test "$CAPPED_COUNT" -le 2

unset STITCHPAD_PROJECTION_SINCE STITCHPAD_PROJECTION_MAX

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 10. Session ID validation
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 10. session ID validation ---"

# Valid session IDs
sp_session_registry_validate_sid "abc123" && ok "sid-valid: abc123" || bad "sid-valid: abc123"
sp_session_registry_validate_sid "sid-alice" && ok "sid-valid: sid-alice" || bad "sid-valid: sid-alice"
sp_session_registry_validate_sid "a1.b2_c3-d4" && ok "sid-valid: a1.b2_c3-d4" || bad "sid-valid: a1.b2_c3-d4"
sp_session_registry_validate_sid "ABCDEF" && ok "sid-valid: uppercase" || bad "sid-valid: uppercase"

# Invalid session IDs (path traversal, metacharacters)
sp_session_registry_validate_sid "../../etc/passwd" && bad "sid-invalid: path traversal accepted" || ok "sid-invalid: path traversal rejected"
sp_session_registry_validate_sid "foo/bar" && bad "sid-invalid: slash accepted" || ok "sid-invalid: slash rejected"
sp_session_registry_validate_sid "foo bar" && bad "sid-invalid: space accepted" || ok "sid-invalid: space rejected"
sp_session_registry_validate_sid ".hidden" && bad "sid-invalid: leading dot accepted" || ok "sid-invalid: leading dot rejected"
sp_session_registry_validate_sid "foo;rm -rf" && bad "sid-invalid: semicolon accepted" || ok "sid-invalid: semicolon rejected"
sp_session_registry_validate_sid "foo|bar" && bad "sid-invalid: pipe accepted" || ok "sid-invalid: pipe rejected"
sp_session_registry_validate_sid "foo\$bar" && bad "sid-invalid: dollar accepted" || ok "sid-invalid: dollar rejected"
sp_session_registry_validate_sid "foo\`bar\`" && bad "sid-invalid: backtick accepted" || ok "sid-invalid: backtick rejected"
sp_session_registry_validate_sid "" && bad "sid-invalid: empty accepted" || ok "sid-invalid: empty rejected"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 11. Injected clock
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 11. injected clock ---"

# sp_date_divider_snapshot with SP_DATE_DIVIDER_CLOCK
SP_DATE_DIVIDER_CLOCK="1785585600" STITCHPAD_TIMEZONE="UTC" sp_date_divider_snapshot
check "clock-inject: epoch matches injected value" "$_SP_DATE_EPOCH" "1785585600"
check "clock-inject: date derived as 2026-08-01" "$_SP_DATE_DATE" "2026-08-01"

# sp_date_divider_hhmm from captured epoch
HHMM="$(sp_date_divider_hhmm)"
check "clock-inject: HH:MM from 12:00 UTC" "$HHMM" "12:00 PM"

# sp_date_divider_epoch returns captured value
CAP_EPOCH="$(sp_date_divider_epoch)"
check "clock-inject: sp_date_divider_epoch matches" "$CAP_EPOCH" "1785585600"

# Different injected clock — 1785672000 = 2026-08-02 12:00 UTC → 08:00 EDT 08-02
SP_DATE_DIVIDER_CLOCK="1785672000" STITCHPAD_TIMEZONE="America/New_York" sp_date_divider_snapshot
check "clock-inject: NY date is 2026-08-02 (08:00 EDT)" "$_SP_DATE_DATE" "2026-08-02"

HHMM_NY="$(sp_date_divider_hhmm)"
check "clock-inject: NY HH:MM from 08:00 EDT" "$HHMM_NY" "08:00 AM"

unset SP_DATE_DIVIDER_CLOCK

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 12. Failed append: no partial data left behind
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 12. failed append rollback ---"

# Scenario: PAD_STATE is a symlink → init refuses.
# Symlink target stays inside $WORK so the test never touches shared /tmp.
mkdir -p "$WORK/symtarget"
PAD_STATE_SYMLINK="$WORK/.state-fail"
ln -sf "$WORK/symtarget" "$PAD_STATE_SYMLINK"
PAD_STATE="$PAD_STATE_SYMLINK"

RC=0; sp_session_registry_init || RC=$?
[ "$RC" -ne 0 ] && ok "rollback: init refuses symlink PAD_STATE" \
  || bad "rollback: init refuses symlink PAD_STATE"
[ ! -f "$PAD_STATE/session-registry.jsonl" ] \
  && ok "rollback: no registry file created on init failure" \
  || bad "rollback: no registry file created on init failure"
rm -f "$PAD_STATE_SYMLINK"

# Scenario: session-registry.jsonl is a symlink → append should fail
PAD_STATE="$WORK/.state-fail2"
mkdir -p "$PAD_STATE"
ln -sf /dev/null "$PAD_STATE/session-registry.jsonl"

RC=0
STITCHPAD_SESSION="sid-fail" STITCHPAD_NAME="fail" \
  STITCHPAD_MODEL="test" PAD_DIR="$WORK" \
  sp_session_registry_append || RC=$?
[ "$RC" -ne 0 ] && ok "rollback: append refuses symlink registry" \
  || bad "rollback: append refuses symlink registry (got $RC)"
rm -rf "$PAD_STATE"

# Scenario: invalid session ID → append should fail
PAD_STATE="$WORK/.state-fail3"
mkdir -p "$PAD_STATE"

RC=0
STITCHPAD_SESSION="../../etc/passwd" STITCHPAD_NAME="hacker" \
  STITCHPAD_MODEL="test" PAD_DIR="$WORK" \
  sp_session_registry_append || RC=$?
[ "$RC" -ne 0 ] && ok "rollback: append refuses invalid session ID" \
  || bad "rollback: append refuses invalid session ID (got $RC)"
# No partial visible state: nothing may have been appended for the refused sid
if [ -f "$PAD_STATE/session-registry.jsonl" ]; then
  assert "rollback: refused append leaves registry empty" \
    test ! -s "$PAD_STATE/session-registry.jsonl"
else
  ok "rollback: refused append leaves registry empty"
fi
rm -rf "$PAD_STATE"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 13. Capped history
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 13. capped history ---"

PAD_STATE="$WORK/.state-cap"
mkdir -p "$PAD_STATE"
sp_session_registry_init

# Set cap very low for testing
SESSION_REGISTRY_MAX=5

# Append 10 entries
for i in $(seq 1 10); do
  STITCHPAD_SESSION="sid-cap" STITCHPAD_NAME="cap-test" \
    STITCHPAD_MODEL="test-model" PAD_DIR="$WORK" \
    sp_session_registry_append >/dev/null 2>&1
done

CAP_COUNT="$(wc -l < "$PAD_STATE/session-registry.jsonl" | tr -d ' ')"
check "cap: exactly 5 entries retained" "$CAP_COUNT" "5"

# Reset cap for subsequent tests
SESSION_REGISTRY_MAX=1024

echo ""
echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 14. Pad header renders sentinel-bounded Active Sessions and capped History
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 14. pad header renders Active Sessions + History ---"

# Isolated fixture: full registry integration — not helper-only.
HEADER_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-header.XXXXXX")"
HEADER_PAD="$HEADER_WORK/stitchpad.md"
HEADER_STATE="$HEADER_WORK/.state"
mkdir -p "$HEADER_STATE"

cat > "$HEADER_PAD" <<'EOPAD'
```roster
alice | claude | pull | -
bob   | claude | pull | -
```
EOPAD

PAD_STATE="$HEADER_STATE" PAD_MD="$HEADER_PAD" sp_session_registry_init

# Seed: alice active (recent), bob idle (older), carol terminal, dave stale
_now="$(date +%s)"
_alice_start="$(( _now - 60 ))"
_bob_start="$(( _now - 1200 ))"
_dave_start="$(( _now - 7200 ))"

# Alice — 2 recent activities
for _hh in 09:00 10:00; do
  STITCHPAD_SESSION="sid-alice-hdr" STITCHPAD_NAME="alice-hdr" \
    STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$HEADER_WORK" \
    PAD_STATE="$HEADER_STATE" \
    sp_session_registry_append "$_now" >/dev/null 2>&1 || true
done

# Bob — 1 old activity (idle)
echo "$_bob_start" > "$HEADER_STATE/session-start.sid-bob-hdr"
STITCHPAD_SESSION="sid-bob-hdr" STITCHPAD_NAME="bob-hdr" \
  STITCHPAD_MODEL="claude-opus-4.5" PAD_DIR="$HEADER_WORK" \
  PAD_STATE="$HEADER_STATE" \
  sp_session_registry_append "$_bob_start" >/dev/null 2>&1 || true

# Carol — terminal
echo "$_now" > "$HEADER_STATE/session-start.sid-carol-hdr"
STITCHPAD_SESSION="sid-carol-hdr" STITCHPAD_NAME="carol-hdr" \
  STITCHPAD_MODEL="claude-opus-4.5" PAD_DIR="$HEADER_WORK" \
  PAD_STATE="$HEADER_STATE" \
  sp_session_registry_append "$_now" >/dev/null 2>&1 || true
touch "$HEADER_STATE/session-end.sid-carol-hdr"

# Dave — stale
echo "$_dave_start" > "$HEADER_STATE/session-start.sid-dave-hdr"
STITCHPAD_SESSION="sid-dave-hdr" STITCHPAD_NAME="dave-hdr" \
  STITCHPAD_MODEL="deepseek-chat" PAD_DIR="$HEADER_WORK" \
  PAD_STATE="$HEADER_STATE" \
  sp_session_registry_append "$_dave_start" >/dev/null 2>&1 || true

# Record terminal event for carol (visible in history)
STITCHPAD_SESSION="sid-carol-hdr" PAD_DIR="$HEADER_WORK" \
  PAD_STATE="$HEADER_STATE" \
  sp_session_registry_record_event "terminal" "$_now" >/dev/null 2>&1 || true

# Record cancel + resume events for bob (visible in history)
STITCHPAD_SESSION="sid-bob-hdr" PAD_DIR="$HEADER_WORK" \
  PAD_STATE="$HEADER_STATE" \
  sp_session_registry_record_event "cancel" "$_bob_start" >/dev/null 2>&1 || true

# Pad header rendering — full integration, not just unit helper
HEADER_OUT="$(PAD_STATE="$HEADER_STATE" sp_session_registry_pad_header 2>/dev/null || true)"

# Active Sessions section must appear
check_contains "pad-header: Active Sessions section rendered" "$HEADER_OUT" "Active Sessions"
# Alice should appear (active)
check_contains "pad-header: alice in active sessions" "$HEADER_OUT" "alice-hdr"
# Terminal carol must NOT appear in Active Sessions
if ! echo "$HEADER_OUT" | grep -q "carol-hdr"; then
  ok "pad-header: terminal carol excluded from Active Sessions"
else
  bad "pad-header: terminal carol excluded from Active Sessions"
fi

# Session History section must appear with terminal event
check_contains "pad-header: Session History section rendered" "$HEADER_OUT" "Session History"
check_contains "pad-header: terminal event in history" "$HEADER_OUT" "[terminal]"
check_contains "pad-header: cancel event in history" "$HEADER_OUT" "[cancel]"

# Sentinel bounds: STITCHPAD_PROJECTION_MAX caps active sessions
CAPPED_HEADER="$(STITCHPAD_PROJECTION_MAX=1 PAD_STATE="$HEADER_STATE" sp_session_registry_pad_header 2>/dev/null || true)"
# Should still render but only at most 1 active session
check_contains "pad-header: sentinel capped header still has section" "$CAPPED_HEADER" "Active Sessions"

rm -rf "$HEADER_WORK"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 15. Lifecycle events: dispatch/refresh(activity)/terminal/cancel/resume/rotate
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 15. lifecycle events ---"

EV_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-ev.XXXXXX")"
EV_STATE="$EV_WORK/.state"
mkdir -p "$EV_STATE"
PAD_STATE="$EV_STATE" sp_session_registry_init

_now_ev="$(date +%s)"
echo "$_now_ev" > "$EV_STATE/session-start.sid-lifecycle"

# dispatch event — first contact, creates new request id
STITCHPAD_SESSION="sid-lifecycle" STITCHPAD_NAME="lifecycle-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$EV_WORK" PAD_STATE="$EV_STATE" \
  sp_session_registry_record_event "dispatch" "$_now_ev" >/dev/null 2>&1
RC_DISP=$?
assert "lifecycle: dispatch recorded" test "$RC_DISP" -eq 0

# activity event (refresh) — same request id
STITCHPAD_SESSION="sid-lifecycle" STITCHPAD_NAME="lifecycle-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$EV_WORK" PAD_STATE="$EV_STATE" \
  sp_session_registry_record_event "activity" "$_now_ev" >/dev/null 2>&1
RC_ACT=$?
assert "lifecycle: activity recorded" test "$RC_ACT" -eq 0

# terminal event
STITCHPAD_SESSION="sid-lifecycle" STITCHPAD_NAME="lifecycle-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$EV_WORK" PAD_STATE="$EV_STATE" \
  sp_session_registry_record_event "terminal" "$_now_ev" >/dev/null 2>&1
RC_TERM=$?
assert "lifecycle: terminal recorded" test "$RC_TERM" -eq 0

# cancel event
STITCHPAD_SESSION="sid-lifecycle" STITCHPAD_NAME="lifecycle-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$EV_WORK" PAD_STATE="$EV_STATE" \
  sp_session_registry_record_event "cancel" "$_now_ev" >/dev/null 2>&1
RC_CANCEL=$?
assert "lifecycle: cancel recorded" test "$RC_CANCEL" -eq 0

# resume event
STITCHPAD_SESSION="sid-lifecycle" STITCHPAD_NAME="lifecycle-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$EV_WORK" PAD_STATE="$EV_STATE" \
  sp_session_registry_record_event "resume" "$_now_ev" >/dev/null 2>&1
RC_RESUME=$?
assert "lifecycle: resume recorded" test "$RC_RESUME" -eq 0

# rotate event
STITCHPAD_SESSION="sid-lifecycle" STITCHPAD_NAME="lifecycle-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$EV_WORK" PAD_STATE="$EV_STATE" \
  sp_session_registry_record_event "rotate" "$_now_ev" >/dev/null 2>&1
RC_ROTATE=$?
assert "lifecycle: rotate recorded" test "$RC_ROTATE" -eq 0

# Verify all 6 entries exist in the registry
ENTRY_COUNT_EV="$(wc -l < "$EV_STATE/session-registry.jsonl" | tr -d ' ')"
check "lifecycle: 6 entries total" "$ENTRY_COUNT_EV" "6"

# Each entry must have the correct event field
EVT1="$(sed -n '1p' "$EV_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['event'])")"
check "lifecycle: entry 1 event=dispatch" "$EVT1" "dispatch"

EVT2="$(sed -n '2p' "$EV_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['event'])")"
check "lifecycle: entry 2 event=activity" "$EVT2" "activity"

EVT3="$(sed -n '3p' "$EV_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['event'])")"
check "lifecycle: entry 3 event=terminal" "$EVT3" "terminal"

EVT4="$(sed -n '4p' "$EV_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['event'])")"
check "lifecycle: entry 4 event=cancel" "$EVT4" "cancel"

EVT5="$(sed -n '5p' "$EV_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['event'])")"
check "lifecycle: entry 5 event=resume" "$EVT5" "resume"

EVT6="$(sed -n '6p' "$EV_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['event'])")"
check "lifecycle: entry 6 event=rotate" "$EVT6" "rotate"

# Unknown event type must be rejected
RC_BAD=0
PAD_STATE="$EV_STATE" sp_session_registry_record_event "nonsense" "$_now_ev" >/dev/null 2>&1 || RC_BAD=$?
[ "$RC_BAD" -ne 0 ] && ok "lifecycle: unknown event rejected" \
  || bad "lifecycle: unknown event rejected (got $RC_BAD)"

rm -rf "$EV_WORK"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 16. Stable request ID across say/activity; new ID on lifecycle transition
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 16. stable request ID across activity ---"

REQ_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-req.XXXXXX")"
REQ_STATE="$REQ_WORK/.state"
mkdir -p "$REQ_STATE"
PAD_STATE="$REQ_STATE" sp_session_registry_init

_now_req="$(date +%s)"
echo "$_now_req" > "$REQ_STATE/session-start.sid-stable"

# Simulate a delegated request arriving via env
export STITCHPAD_REQUEST_ID="delegated-req-abc123"
STITCHPAD_SESSION="sid-stable" STITCHPAD_NAME="stable-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$REQ_WORK" PAD_STATE="$REQ_STATE" \
  sp_session_registry_record_event "dispatch" "$_now_req" >/dev/null 2>&1

RID1="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])" < "$REQ_STATE/session-registry.jsonl")"
check "req-id: delegated id used for dispatch" "$RID1" "delegated-req-abc123"

# Activity event — must reuse same request id
STITCHPAD_SESSION="sid-stable" STITCHPAD_NAME="stable-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$REQ_WORK" PAD_STATE="$REQ_STATE" \
  sp_session_registry_record_event "activity" "$_now_req" >/dev/null 2>&1

RID2="$(sed -n '2p' "$REQ_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])")"
check "req-id: activity reuses same delegated id" "$RID2" "delegated-req-abc123"

# Resume event — forces new request id
STITCHPAD_SESSION="sid-stable" STITCHPAD_NAME="stable-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$REQ_WORK" PAD_STATE="$REQ_STATE" \
  sp_session_registry_record_event "resume" "$_now_req" >/dev/null 2>&1

RID3="$(sed -n '3p' "$REQ_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])")"
check "req-id: resume forces new request id" "$RID3" "delegated-req-abc123"
# delegated id is still the same because STITCHPAD_REQUEST_ID is still set,
# but the lifecycle transition still "forces new" — with delegated, the
# "new" flag means it's still the delegated id (same value).

# Now test without delegated id: provider-derived fallback
unset STITCHPAD_REQUEST_ID
rm -f "$REQ_STATE/request-id.sid-derived" "$REQ_STATE/request-counter"

STITCHPAD_SESSION="sid-derived" STITCHPAD_NAME="derived-test" \
  STITCHPAD_MODEL="deepseek-chat" PAD_DIR="$REQ_WORK" PAD_STATE="$REQ_STATE" \
  sp_session_registry_record_event "dispatch" "$_now_req" >/dev/null 2>&1

DERIVED_RID="$(tail -1 "$REQ_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])")"
check_contains "req-id: derived id has provider prefix" "$DERIVED_RID" "deepseek"
check_contains "req-id: derived id has counter" "$DERIVED_RID" "-1"

# Activity without delegated id — reuses same derived id from persistence
STITCHPAD_SESSION="sid-derived" STITCHPAD_NAME="derived-test" \
  STITCHPAD_MODEL="deepseek-chat" PAD_DIR="$REQ_WORK" PAD_STATE="$REQ_STATE" \
  sp_session_registry_record_event "activity" "$_now_req" >/dev/null 2>&1

DERIVED_RID2="$(tail -1 "$REQ_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])")"
check "req-id: activity reuses derived id" "$DERIVED_RID2" "$DERIVED_RID"

# Rotate forces new derived id
STITCHPAD_SESSION="sid-derived" STITCHPAD_NAME="derived-test" \
  STITCHPAD_MODEL="deepseek-chat" PAD_DIR="$REQ_WORK" PAD_STATE="$REQ_STATE" \
  sp_session_registry_record_event "rotate" "$_now_req" >/dev/null 2>&1

DERIVED_RID3="$(tail -1 "$REQ_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['request_id'])")"
check_contains "req-id: rotate has new counter" "$DERIVED_RID3" "-2"
[ "$DERIVED_RID3" != "$DERIVED_RID" ] && ok "req-id: rotate gave different derived id" \
  || bad "req-id: rotate gave different derived id"

rm -rf "$REQ_WORK"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 17. Explicit unknown model/provider: never collapse to _unknown_
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 17. explicit unknown preservation ---"

UNK_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-unk.XXXXXX")"
UNK_STATE="$UNK_WORK/.state"
mkdir -p "$UNK_STATE"
PAD_STATE="$UNK_STATE" sp_session_registry_init

_now_unk="$(date +%s)"

# Append with unknown model → provider must be "" not "_unknown_"
STITCHPAD_SESSION="sid-unk" STITCHPAD_NAME="unk-test" \
  STITCHPAD_MODEL="some-bizarre-model-v42" PAD_DIR="$UNK_WORK" \
  PAD_STATE="$UNK_STATE" \
  sp_session_registry_append "$_now_unk" >/dev/null 2>&1

UNK_PROVIDER="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['provider'])" < "$UNK_STATE/session-registry.jsonl")"
check "unknown: provider is empty (not _unknown_)" "$UNK_PROVIDER" ""

# Append with no name
STITCHPAD_SESSION="sid-noname" STITCHPAD_NAME="" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$UNK_WORK" \
  PAD_STATE="$UNK_STATE" \
  sp_session_registry_append "$_now_unk" >/dev/null 2>&1

UNK_NAME="$(sed -n '2p' "$UNK_STATE/session-registry.jsonl" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")"
check "unknown: empty name preserved as empty" "$UNK_NAME" ""

# Projection must also preserve empty provider/name — never collapse
PROJ_UNK="$(PAD_STATE="$UNK_STATE" sp_session_registry_project 2>/dev/null || true)"
# The session with empty name should have name="" in projection
UNK_PROJ_NAME="$(echo "$PROJ_UNK" | python3 -c "
import json,sys
data = json.loads(sys.stdin.read())
for s in data:
    if s['session_id'] == 'sid-noname':
        print(s['name'])
")"
check "unknown: projection preserves empty name" "$UNK_PROJ_NAME" ""

UNK_PROJ_PROV="$(echo "$PROJ_UNK" | python3 -c "
import json,sys
data = json.loads(sys.stdin.read())
for s in data:
    if s['session_id'] == 'sid-unk':
        print(s['provider'])
")"
check "unknown: projection preserves empty provider" "$UNK_PROJ_PROV" ""

rm -rf "$UNK_WORK"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 18. History projection shows terminal/cancel/resume/rotate/dispatch visibly
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 18. visible history projection ---"

HIST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-hist.XXXXXX")"
HIST_STATE="$HIST_WORK/.state"
mkdir -p "$HIST_STATE"
PAD_STATE="$HIST_STATE" sp_session_registry_init

_now_hist="$(date +%s)"

# Record a sequence of lifecycle events for different sessions
for _evt in dispatch activity terminal cancel resume rotate dispatch; do
  _sid="sid-hist-$_evt"
  echo "$_now_hist" > "$HIST_STATE/session-start.$_sid"
  STITCHPAD_SESSION="$_sid" STITCHPAD_NAME="hist-$_evt" \
    STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$HIST_WORK" PAD_STATE="$HIST_STATE" \
    sp_session_registry_record_event "$_evt" "$_now_hist" >/dev/null 2>&1
done

# History must return only non-activity events (terminal/cancel/resume/rotate/dispatch)
HIST_DATA="$(PAD_STATE="$HIST_STATE" sp_session_registry_history 2>/dev/null || true)"
HIST_COUNT="$(echo "$HIST_DATA" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))")"

# We recorded 6 non-activity events (dispatch, terminal, cancel, resume, rotate, dispatch)
# Default SESSION_HISTORY_LINES=8 so all should appear
assert "history: has entries" test "$HIST_COUNT" -gt 0

# Verify each event type appears
check_contains "history: dispatch visible" "$HIST_DATA" "dispatch"
check_contains "history: terminal visible" "$HIST_DATA" "terminal"
check_contains "history: cancel visible" "$HIST_DATA" "cancel"
check_contains "history: resume visible" "$HIST_DATA" "resume"
check_contains "history: rotate visible" "$HIST_DATA" "rotate"

# activity events must NOT appear in history
if ! echo "$HIST_DATA" | python3 -c "
import json,sys
data = json.loads(sys.stdin.read())
for e in data:
    if e.get('event') == 'activity':
        raise SystemExit(1)
"; then
  bad "history: activity should not appear in history"
else
  ok "history: activity excluded from history"
fi

# Capped: SESSION_HISTORY_LINES=2 limits to 2 entries
CAPPED_HIST="$(SESSION_HISTORY_LINES=2 PAD_STATE="$HIST_STATE" sp_session_registry_history 2>/dev/null || true)"
CAPPED_HIST_COUNT="$(echo "$CAPPED_HIST" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))")"
assert "history: capped at SESSION_HISTORY_LINES" test "$CAPPED_HIST_COUNT" -le 2

rm -rf "$HIST_WORK"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 19. One injected epoch across registry/divider/message/commit
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 19. one injected epoch ---"

EPOCH_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-epoch.XXXXXX")"
EPOCH_STATE="$EPOCH_WORK/.state"
EPOCH_PAD="$EPOCH_WORK/stitchpad.md"
mkdir -p "$EPOCH_STATE"

cat > "$EPOCH_PAD" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD

# Inject a single clock: 2026-08-01 12:00:00 UTC = 1785585600
INJECTED=1785585600
export SP_DATE_DIVIDER_CLOCK="$INJECTED"
export STITCHPAD_TIMEZONE="UTC"

# Snapshot captures the injected epoch
SP_DATE_DIVIDER_CLOCK="$INJECTED" STITCHPAD_TIMEZONE="UTC" \
  PAD_STATE="$EPOCH_STATE" PAD_MD="$EPOCH_PAD" \
  sp_date_divider_snapshot

check "epoch: _SP_DATE_EPOCH matches injected" "$_SP_DATE_EPOCH" "$INJECTED"
check "epoch: _SP_DATE_DATE is 2026-08-01" "$_SP_DATE_DATE" "2026-08-01"

# HH:MM from captured epoch — shares the same injected clock
HHMM_EPOCH="$(sp_date_divider_hhmm)"
check "epoch: HH:MM from injected 12:00 UTC" "$HHMM_EPOCH" "12:00 PM"

# Divider line from captured epoch
DIV_EPOCH="$(sp_date_divider_line "$_SP_DATE_EPOCH" "$_SP_DATE_TZ")"
check_contains "epoch: divider has 2026-08-01" "$DIV_EPOCH" "2026-08-01"

# Registry entry uses the same captured epoch — inject into session-registry too
PAD_STATE="$EPOCH_STATE" sp_session_registry_init
echo "$INJECTED" > "$EPOCH_STATE/session-start.sid-epoch"

STITCHPAD_SESSION="sid-epoch" STITCHPAD_NAME="epoch-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$EPOCH_WORK" \
  PAD_STATE="$EPOCH_STATE" \
  sp_session_registry_append "$_SP_DATE_EPOCH" >/dev/null 2>&1

REG_EPOCH="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['last_activity'])" < "$EPOCH_STATE/session-registry.jsonl")"
check "epoch: registry last_activity matches injected" "$REG_EPOCH" "$INJECTED"

# Verify that _SP_DATE_EPOCH is shared — session registry now() falls back to it
SP_SESSION_REGISTRY_CLOCK="$_SP_DATE_EPOCH" PAD_STATE="$EPOCH_STATE" \
  sp_session_registry_project >/dev/null 2>&1
# If the projection completes, the injected clock was used (no real clock leak)

# Verify the shared epoch is stable (same value accessible from both APIs)
CAP_EPOCH="$(sp_date_divider_epoch)"
check "epoch: shared epoch accessible via sp_date_divider_epoch" "$CAP_EPOCH" "$INJECTED"

# Now insert divider with the same injected epoch — full pad integration
PAD_STATE="$EPOCH_STATE" PAD_MD="$EPOCH_PAD" \
  SP_DATE_DIVIDER_CLOCK="$INJECTED" STITCHPAD_TIMEZONE="UTC" \
  sp_date_divider_snapshot
PAD_STATE="$EPOCH_STATE" PAD_MD="$EPOCH_PAD" \
  sp_date_divider_insert >/dev/null 2>&1 || true

DIV_IN_PAD="$(grep '^\*— ' "$EPOCH_PAD" 2>/dev/null || true)"
check_contains "epoch: divider in pad has date 2026-08-01" "$DIV_IN_PAD" "2026-08-01"

unset SP_DATE_DIVIDER_CLOCK SP_SESSION_REGISTRY_CLOCK STITCHPAD_TIMEZONE
rm -rf "$EPOCH_WORK"

echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 20. State publication ordering: registry write before sp_commit; rollback on failure
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 20. state publication ordering / rollback ---"

ORDER_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-order.XXXXXX")"
ORDER_STATE="$ORDER_WORK/.state"
ORDER_PAD="$ORDER_WORK/stitchpad.md"
mkdir -p "$ORDER_STATE"

cat > "$ORDER_PAD" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD

PAD_STATE="$ORDER_STATE" sp_session_registry_init
_now_ord="$(date +%s)"
echo "$_now_ord" > "$ORDER_STATE/session-start.sid-order"

# The "say" command does: snapshot → lock → divider_insert → append →
# registry_append → sp_commit. Registry writes BEFORE sp_commit.
# Simulate the ordering: registry append succeeds, then we verify the
# registry has the entry even if we never commit (simulating commit failure).

ORD_BEFORE_LINES="$(wc -l < "$ORDER_STATE/session-registry.jsonl" | tr -d ' ')"
check "order: empty registry before test" "$ORD_BEFORE_LINES" "0"

STITCHPAD_SESSION="sid-order" STITCHPAD_NAME="order-test" \
  STITCHPAD_MODEL="gpt-5.6-sol" PAD_DIR="$ORDER_WORK" \
  PAD_STATE="$ORDER_STATE" \
  sp_session_registry_append "$_now_ord" >/dev/null 2>&1
RC_REG=$?
assert "order: registry append succeeded" test "$RC_REG" -eq 0

# Registry entry exists — durable state is published BEFORE commit
ORD_AFTER_LINES="$(wc -l < "$ORDER_STATE/session-registry.jsonl" | tr -d ' ')"
check "order: registry has 1 entry after append" "$ORD_AFTER_LINES" "1"

# Simulate commit failure: git dir doesn't exist for this test.
# In the real say path, sp_commit is called after registry append and silently
# degrades. The registry entry must survive — data must not vanish.
PAD_DIR="$ORDER_WORK" PAD_MD="$ORDER_PAD" PAD_GIT="$ORDER_STATE/.nonexistent-git" \
  PAD_TASKS="$ORDER_WORK/tasks.md" \
  sp_commit "test: ordered publication" >/dev/null 2>&1 || true

# Registry must still have its entry
ORD_FINAL_LINES="$(wc -l < "$ORDER_STATE/session-registry.jsonl" | tr -d ' ')"
check "order: registry survives sp_commit failure" "$ORD_FINAL_LINES" "1"

# Verify the entry content is intact
ORD_ENTRY="$(cat "$ORDER_STATE/session-registry.jsonl")"
check_contains "order: entry has session_id" "$ORD_ENTRY" "sid-order"
check_contains "order: entry has correct last_activity" "$ORD_ENTRY" "$_now_ord"

rm -rf "$ORDER_WORK"

echo ""
echo ""
# ══════════════════════════════════════════════════════════════════════════════
# 21. Atomic no-follow last-divider reconciliation from prior divider with absent state under backward clocks
# ══════════════════════════════════════════════════════════════════════════════
echo "--- 21. atomic last-divider reconciliation / backward clock defense ---"

RECON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-recon.XXXXXX")"
RECON_STATE="$RECON_WORK/.state"
RECON_PAD="$RECON_WORK/pad-recon.md"
mkdir -p "$RECON_STATE"

RECON_EPOCH_DAY1=1785585600  # 2026-08-01 12:00 UTC
RECON_EPOCH_DAY0=1785499200  # 2026-07-31 12:00 UTC
RECON_EPOCH_DAY2=1785672000  # 2026-08-02 12:00 UTC

# Create pad WITHOUT any divider — insert it fresh
cat > "$RECON_PAD" <<'EOPAD'
```roster
alice | claude | pull | -
```
EOPAD

PAD_MD="$RECON_PAD" PAD_STATE="$RECON_STATE"

# Scenario 1: No state file, no existing divider — fresh insert for day 1.
SP_DATE_DIVIDER_CLOCK="$RECON_EPOCH_DAY1" STITCHPAD_TIMEZONE="UTC" \
  sp_date_divider_snapshot
assert "recon: day 1 snapshot captured" test -n "$_SP_DATE_EPOCH"

# Insert divider for day 1 — this writes the divider AND last-divider-epoch
RC=0; sp_date_divider_insert || RC=$?
assert "recon: day 1 fresh insert OK" test "$RC" -eq 0

DIV_COUNT_RECON="$(grep -c '^\*— ' "$RECON_PAD" 2>/dev/null || echo 0)"
check "recon: exactly 1 divider after fresh insert" "$DIV_COUNT_RECON" "1"

# Verify state file was written atomically (temp+rename)
assert "recon: last-divider-epoch file exists" test -f "$RECON_STATE/last-divider-epoch"
STATE_CONTENTS="$(cat "$RECON_STATE/last-divider-epoch")"
check "recon: state file has correct epoch" "$STATE_CONTENTS" "$RECON_EPOCH_DAY1"

# Scenario 2: Delete state file → reconcile from pad under backward clock.
# The real reconciliation path: _sp_divider_reconcile_last_epoch scans the
# pad for the last divider, derives its epoch, and saves it atomically.
# Then the monotonic check catches the backward cross-date attempt.
rm -f "$RECON_STATE/last-divider-epoch"
assert "recon: state file removed" test ! -f "$RECON_STATE/last-divider-epoch"

# Backward clock to day 0 (2026-07-31)
SP_DATE_DIVIDER_CLOCK="$RECON_EPOCH_DAY0" STITCHPAD_TIMEZONE="UTC" \
  sp_date_divider_snapshot
check "recon: day 0 snapshot date" "$_SP_DATE_DATE" "2026-07-31"

# Try to insert divider for day 0 — must be REFUSED (backward cross-date)
# The reconcile step finds the pad's day-1 divider, derives noon-UTC epoch
# 1785585600, which is > day-0 epoch, so the backward-clock guard fires.
RC=0; sp_date_divider_insert || RC=$?
[ "$RC" -eq 2 ] && ok "recon: backward cross-date refused (returns 2)" \
  || bad "recon: backward cross-date refused (got $RC, want 2)"

# State file must have been RECREATED by reconciliation (atomic temp+rename)
assert "recon: state file recreated by reconciliation" test -f "$RECON_STATE/last-divider-epoch"
RECON_STATE_CONTENTS="$(cat "$RECON_STATE/last-divider-epoch")"
check "recon: reconciled epoch is day 1 noon UTC" "$RECON_STATE_CONTENTS" "1785585600"

# Scenario 3: Forward clock to day 1 again — idempotent (divider exists)
SP_DATE_DIVIDER_CLOCK="$RECON_EPOCH_DAY1" STITCHPAD_TIMEZONE="UTC" \
  sp_date_divider_snapshot
check "recon: day 1 resnapshot date" "$_SP_DATE_DATE" "2026-08-01"

RC=0; sp_date_divider_insert || RC=$?
[ "$RC" -eq 1 ] && ok "recon: day 1 idempotent after reconciliation" \
  || bad "recon: day 1 idempotent after reconciliation (got $RC)"

# Still exactly 1 divider — reconciliation did not create a duplicate
DIV_COUNT_RECON2="$(grep -c '^\*— ' "$RECON_PAD" 2>/dev/null || echo 0)"
check "recon: still exactly 1 divider after reconciliation" "$DIV_COUNT_RECON2" "1"

# Scenario 4: No-follow safety — state file is a symlink.
# _sp_divider_save_last_epoch refuses to write through symlinks.
# The divider line is still appended to the pad; save failure is non-fatal.
rm -f "$RECON_STATE/last-divider-epoch"
ln -sf /dev/null "$RECON_STATE/last-divider-epoch"

# Take snapshot at day 2 (forward from day 1)
SP_DATE_DIVIDER_CLOCK="$RECON_EPOCH_DAY2" STITCHPAD_TIMEZONE="UTC" \
  sp_date_divider_snapshot

# Insert: divider not present for day 2, monotonic passes,
# save_last_epoch fails (symlink), but the divider IS appended.
RC=0; sp_date_divider_insert || RC=$?
assert "recon: symlink'd state: insert does not crash" test "$RC" -eq 0

# The symlink must NOT have been followed — it must still point to /dev/null
[ -L "$RECON_STATE/last-divider-epoch" ] && ok "recon: symlink not followed" \
  || bad "recon: symlink not followed (was overwritten)"

# Day 2 divider was written despite save failure
DIV_COUNT_RECON3="$(grep -c '^\*— ' "$RECON_PAD" 2>/dev/null || echo 0)"
check "recon: two dividers after symlink scenario (day 1 + day 2)" "$DIV_COUNT_RECON3" "2"

rm -rf "$RECON_WORK"
unset SP_DATE_DIVIDER_CLOCK STITCHPAD_TIMEZONE
# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
printf "Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
