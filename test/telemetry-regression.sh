#!/usr/bin/env bash
# telemetry-regression.sh — TASK-7 per-model reliability + cost-value telemetry.
#
# Covers:
#   1. say/wake capture points emit append-only jsonl under .state/telemetry/<model>/
#   2. model resolution: env (STITCHPAD_MODEL) wins over .state/model.<seat> meta
#   3. wake outcomes delivered/deferred/zero_run recorded correctly
#   4. bounded summary reader renders per-model rows; --json exposes exact counters
#   5. unknown values render honestly (n/a / null), never silently zeroed
#   6. telemetry write failure NEVER fails a primary operation (silent skip)
#   7. verdicts/seals/false_terminals events feed the summary columns
#   8. reader respects --days mtime bound
#
# Env-robust: unset ambient identity/model vars, isolated HOME, no watcher.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_STEAL=1
export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID 2>/dev/null || true

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  PASS %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; failn=$((failn + 1)); }
pass=0; failn=0

W="$(mktemp -d "${TMPDIR:-/tmp}/sp-tel.XXXXXX")"
trap 'rm -rf "$W"' EXIT
P="$W/.stitchpad"
export STITCHPAD_PAD_DIR="$P" HOME="$W/home"
# Hermetic: the runner's ambient session/model must never leak into assertions.
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID \
      STITCHPAD_MODEL CODEX_MODEL CLAUDE_MODEL ANTHROPIC_MODEL \
      STITCHPAD_PROVIDER STITCHPAD_TEST_MODE STITCHPAD_TEST_COMMIT_FAIL 2>/dev/null || true
mkdir -p "$HOME" "$P/.state/sessions" "$P/.state/claims"
printf '```roster\nalice | claude | pull | -\nbob   | ocean  | push | target\n```\n' > "$P/stitchpad.md"
mkdir -p "$P/stitchpad-git"
git --git-dir="$P/stitchpad-git" --work-tree="$P" init -q
git --git-dir="$P/stitchpad-git" --work-tree="$P" config user.email tel@test
git --git-dir="$P/stitchpad-git" --work-tree="$P" config user.name Telemetry
git --git-dir="$P/stitchpad-git" --work-tree="$P" add stitchpad.md
git --git-dir="$P/stitchpad-git" --work-tree="$P" commit -q -m initial
touch "$P/.state/session-registry.jsonl"

echo "=== telemetry regression ==="

# ── 1. say + wake emit append-only jsonl, model via env ──
STITCHPAD_NAME=alice STITCHPAD_MODEL=deepseek-v4-flash "$SP" say "hello all" >/dev/null 2>&1 \
  || fail "say should succeed"
STITCHPAD_NAME=bob STITCHPAD_MODEL=kimi-k3 "$SP" wake bob >/dev/null 2>&1   # zero_run
STITCHPAD_NAME=bob STITCHPAD_MODEL=kimi-k3 "$SP" say "@alice for you" >/dev/null 2>&1
STITCHPAD_NAME=alice STITCHPAD_MODEL=deepseek-v4-flash "$SP" wake alice >/dev/null 2>&1   # delivered
STITCHPAD_NAME=alice "$SP" dnd on >/dev/null 2>&1
STITCHPAD_NAME=bob STITCHPAD_MODEL=kimi-k3 "$SP" say "@alice again" >/dev/null 2>&1
STITCHPAD_NAME=alice STITCHPAD_MODEL=deepseek-v4-flash "$SP" wake alice >/dev/null 2>&1   # deferred
STITCHPAD_NAME=alice "$SP" dnd off >/dev/null 2>&1

[ -f "$P/.state/telemetry/deepseek-v4-flash/$(date -u +%F).jsonl" ] \
  && ok "1a: deepseek jsonl exists" || bad "1a: deepseek jsonl missing"
[ -f "$P/.state/telemetry/kimi-k3/$(date -u +%F).jsonl" ] \
  && ok "1b: kimi jsonl exists" || bad "1b: kimi jsonl missing"
[ ! -f "$P/.state/telemetry/.drops" ] && ok "1c: zero telemetry drops" \
  || bad "1c: unexpected drops ($(wc -l < "$P/.state/telemetry/.drops" 2>/dev/null))"

# ── 2. model resolution: meta file used when env absent ──
STITCHPAD_NAME=bob "$SP" meta set bob model kimi-k3-latest >/dev/null 2>&1
STITCHPAD_NAME=bob "$SP" say "no env model" >/dev/null 2>&1 || fail "say w/ meta model"
[ -f "$P/.state/telemetry/kimi-k3-latest/$(date -u +%F).jsonl" ] \
  && ok "2a: meta-file model resolved (kimi-k3-latest)" \
  || bad "2a: meta-file model not resolved"

# ── 3. summary text: per-model rows + honest n/a ──
SUM="$("$SP" telemetry)"
echo "$SUM" | grep -q "deepseek-v4-flash" && ok "3a: deepseek row present" || bad "3a: no deepseek row"
echo "$SUM" | grep -q "kimi-k3" && ok "3b: kimi row present" || bad "3b: no kimi row"
echo "$SUM" | grep -q "n/a" && ok "3c: unknown values render n/a" || bad "3c: no n/a rendered"

# ── 4. --json exact counters ──
J="$("$SP" telemetry --json)"
echo "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
by={m["model"]:m for m in d["models"]}
assert d["drops"]==0, d["drops"]
ds=by["deepseek-v4-flash"]
assert ds["wake_outcomes"]["delivered"]==1, ds
assert ds["wake_outcomes"]["deferred"]==1, ds
assert ds["say"]["posted"]==1, ds          # "hello all" only (env model)
ks=by["kimi-k3"]
assert ks["wake_outcomes"]["zero_run"]==1, ks
assert ks["say"]["posted"]==2, ks          # "for you" + "again"
assert ds["tokens_in"] is None, ds         # honest unknown, not 0
assert ds["cost_usd"] is None, ds
assert ds["avg_turn_ms"] is not None, ds
' && ok "4a: --json counters exact" || bad "4a: --json counters mismatch"

# ── 5. verdicts / seals / false_terminals feed summary columns ──
export PAD_DIR="$P" PAD_MD="$P/stitchpad.md" PAD_STATE="$P/.state" PAD_GIT="$P/stitchpad-git"
# shellcheck disable=SC1091
source "$ROOT/tool/bin/lib.sh"
sp_telemetry_record verdict seat=alice verdict=confirmed model=deepseek-v4-flash \
  candidate=abc123 detail="probe repro" || true
sp_telemetry_record verdict seat=alice verdict=rejected model=deepseek-v4-flash \
  candidate=def456 detail="not a defect" || true
sp_telemetry_record verdict seat=alice verdict=held model=deepseek-v4-flash \
  candidate=ghi789 detail="race held" || true
sp_telemetry_record seal seat=alice artifact=report.md sha=abcd1234 model=deepseek-v4-flash || true
sp_telemetry_record false_terminal seat=alice count=2 detail="no artifacts" model=deepseek-v4-flash || true
sp_telemetry_record wake seat=alice outcome=delivered dur_ms=99 tokens_in=1500 tokens_out=220 \
  cost_usd=0.0123 model=deepseek-v4-flash || true
unset PAD_DIR PAD_MD PAD_STATE PAD_GIT
J2="$("$SP" telemetry --json)"
echo "$J2" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ds=[m for m in d["models"] if m["model"]=="deepseek-v4-flash"][0]
assert ds["verdicts"]=={"confirmed":1,"rejected":1,"held":1}, ds["verdicts"]
assert ds["seals"]==1, ds["seals"]
assert ds["false_terminals"]==2, ds["false_terminals"]
assert ds["tokens_in"]==1500 and ds["tokens_out"]==220, (ds["tokens_in"],ds["tokens_out"])
assert abs(ds["cost_usd"]-0.0123) < 1e-6, ds["cost_usd"]
' && ok "5a: verdict/seal/false_terminal/cost columns fed" || bad "5a: summary columns wrong"
SUM2="$("$SP" telemetry)"
echo "$SUM2" | grep -q "1/1/1" && ok "5b: V(c/r/h) column shows 1/1/1" || bad "5b: verdict column wrong"

# ── 6. telemetry write failure never fails the primary op ──
chmod 555 "$P/.state/telemetry" "$P/.state/telemetry/deepseek-v4-flash" 2>/dev/null || true
RC=0
OUT="$(STITCHPAD_NAME=alice STITCHPAD_MODEL=deepseek-v4-flash "$SP" say "post during telemetry outage" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "6a: say succeeds when telemetry dir is read-only" \
  || bad "6a: say failed (rc=$RC): $(printf '%s' "$OUT" | tail -1)"
grep -q "post during telemetry outage" "$P/stitchpad.md" \
  && ok "6b: message posted during telemetry outage" || bad "6b: message missing"
git --git-dir="$P/stitchpad-git" --work-tree="$P" show HEAD:stitchpad.md | grep -q "post during telemetry outage" \
  && ok "6c: message committed during telemetry outage" || bad "6c: message not committed"
chmod 755 "$P/.state/telemetry" "$P/.state/telemetry/deepseek-v4-flash" 2>/dev/null || true
# Recovery: next say records again
STITCHPAD_NAME=alice STITCHPAD_MODEL=deepseek-v4-flash "$SP" say "back online" >/dev/null 2>&1
grep -q '"e":"say"' "$P/.state/telemetry/deepseek-v4-flash/$(date -u +%F).jsonl" \
  && ok "6d: recording resumes after permission restore" || bad "6d: recording did not resume"

# ── 7. --days bound excludes stale files ──
OLD="$P/.state/telemetry/deepseek-v4-flash/2020-01-01.jsonl"
printf '{"e":"wake","seat":"alice","model":"deepseek-v4-flash","outcome":"delivered","t":"2020-01-01T00:00:00Z"}\n' > "$OLD"
touch -t 202001010000 "$OLD"
J3="$("$SP" telemetry --days 1 --json)"
echo "$J3" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["days"]==1, d["days"]
' && ok "7a: --days honored in json header" || bad "7a: --days not honored"
"$SP" telemetry --days 1 | grep -q "2020-01-01" && bad "7b: stale file leaked into 1-day window" \
  || ok "7b: stale file excluded by mtime bound"

# ── 8. ambient junk env cannot corrupt records ──
STITCHPAD_SESSION="junk-session-999" CLAUDE_CODE_SESSION_ID="junk-ambient" \
  STITCHPAD_NAME=alice STITCHPAD_MODEL="weird model name!!!" \
  "$SP" say "env robustness" >/dev/null 2>&1
[ -f "$P/.state/telemetry/weirdmodelname/$(date -u +%F).jsonl" ] \
  && ok "8a: model sanitized (weirdmodelname)" \
  || bad "8a: model sanitize failed (ls: $(ls "$P/.state/telemetry" | tr '\n' ' '))"

echo ""
if [ "$failn" -eq 0 ]; then
  printf 'telemetry regression: %s passed, 0 failed\n' "$pass"
  exit 0
else
  printf 'telemetry regression: %s passed, %s failed\n' "$pass" "$failn"
  exit 1
fi
