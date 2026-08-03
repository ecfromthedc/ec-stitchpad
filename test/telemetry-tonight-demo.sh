#!/usr/bin/env bash
# telemetry-tonight-demo.sh — acceptance evidence for TASK-7: the bounded
# summary must REPRODUCE tonight's story from data.
#
# Seeds .state/telemetry with records matching the 2026-08-02 ocean-arena
# night (per flash-scorecard-evidence-20260802.md + the re-attack lane) and
# asserts `stitchpad telemetry --json` aggregates them to the same numbers.
# Per-model, not per-seat: flash + flash2 both label deepseek-v4-flash, so
# their reliability/cost-value rows merge under one model — that merge is the
# point of the card.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_STEAL=1 STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID \
      STITCHPAD_MODEL CODEX_MODEL CLAUDE_MODEL ANTHROPIC_MODEL STITCHPAD_PROVIDER 2>/dev/null || true

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass=0; failn=0
ok()  { printf '  PASS %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; failn=$((failn + 1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/sp-tel-tonight.XXXXXX")"
trap 'rm -rf "$W"' EXIT
P="$W/.stitchpad"
export STITCHPAD_PAD_DIR="$P" HOME="$W/home"
mkdir -p "$HOME" "$P/.state/sessions" "$P/.state/claims"
printf '```roster\nflash  | ocean | pull | -\nflash2 | ocean | pull | -\nkimi   | ocean | pull | -\ndeepseek | ocean | pull | -\nglm    | ocean | pull | -\n```\n' > "$P/stitchpad.md"
mkdir -p "$P/stitchpad-git"
git --git-dir="$P/stitchpad-git" --work-tree="$P" init -q
git --git-dir="$P/stitchpad-git" --work-tree="$P" config user.email tel@test
git --git-dir="$P/stitchpad-git" --work-tree="$P" config user.name Telemetry
git --git-dir="$P/stitchpad-git" --work-tree="$P" add stitchpad.md
git --git-dir="$P/stitchpad-git" --work-tree="$P" commit -q -m initial
touch "$P/.state/session-registry.jsonl"

# seed tonight's story — helpers sourced from the real library
export PAD_DIR="$P" PAD_MD="$P/stitchpad.md" PAD_STATE="$P/.state" PAD_GIT="$P/stitchpad-git"
# shellcheck disable=SC1091
source "$ROOT/tool/bin/lib.sh"

# flash (deepseek-v4-flash): re-attack lane — 3 seals, R1-R4 confirmed,
# E1-E3 held, 1 false terminal (the empty re-attack turn), wake mix.
for a in flash-cross-phaseb-524bea3 flash-reattack-phaseb-88ce8ca flash-scorecard-evidence-20260802; do
  sp_telemetry_record seal seat=flash artifact="$a.md" sha=0000000000000000000000000000000000000000 model=deepseek-v4-flash || true
done
for cand in R1 R2 R3 R4; do
  sp_telemetry_record verdict seat=flash verdict=confirmed candidate="$cand" model=deepseek-v4-flash || true
done
for cand in E1 E2 E3; do
  sp_telemetry_record verdict seat=flash verdict=held candidate="$cand" model=deepseek-v4-flash || true
done
sp_telemetry_record false_terminal seat=flash count=1 detail="empty re-attack turn" model=deepseek-v4-flash || true
for i in 1 2 3 4 5; do sp_telemetry_record wake seat=flash outcome=delivered dur_ms=420 model=deepseek-v4-flash || true; done
for i in 1 2 3; do sp_telemetry_record wake seat=flash outcome=zero_run dur_ms=90 model=deepseek-v4-flash || true; done
sp_telemetry_record wake seat=flash outcome=deferred dur_ms=310 model=deepseek-v4-flash || true
for i in 1 2 3 4 5 6 7; do sp_telemetry_record say seat=flash outcome=posted dur_ms=1500 model=deepseek-v4-flash || true; done

# flash2 (deepseek-v4-flash): wakefix lane — 1 seal, 6 delivered, 2 zero_run
sp_telemetry_record seal seat=flash2 artifact="flash2-wakefix.md" sha=1111111111111111111111111111111111111111 model=deepseek-v4-flash || true
for i in 1 2 3 4 5 6; do sp_telemetry_record wake seat=flash2 outcome=delivered dur_ms=380 model=deepseek-v4-flash || true; done
for i in 1 2; do sp_telemetry_record wake seat=flash2 outcome=zero_run dur_ms=75 model=deepseek-v4-flash || true; done
for i in 1 2 3 4; do sp_telemetry_record say seat=flash2 outcome=posted dur_ms=1300 model=deepseek-v4-flash || true; done

# kimi (k3): gate series — 5 seals, 4 confirmed + 1 held (gate9 HOLD)
for g in gate8 gate9 gate10 gate12 gate13; do
  sp_telemetry_record seal seat=kimi artifact="kimi-coordination-$g.md" sha=2222222222222222222222222222222222222222 model=k3 || true
done
for c in gate8 gate10 gate12 gate13; do sp_telemetry_record verdict seat=kimi verdict=confirmed candidate="$c" model=k3 || true; done
sp_telemetry_record verdict seat=kimi verdict=held candidate=gate9 detail="self-actor refusal missing" model=k3 || true
for i in 1 2; do sp_telemetry_record wake seat=kimi outcome=delivered dur_ms=500 model=k3 || true; done
for i in 1 2 3 4; do sp_telemetry_record wake seat=kimi outcome=zero_run dur_ms=80 model=k3 || true; done

# deepseek (v4-pro): 2 seals, 2 confirmed, stood down for zero-artifact turns → 2 false terminals
for g in gate5 sliceA; do
  sp_telemetry_record seal seat=deepseek artifact="deepseek-coordination-$g.md" sha=3333333333333333333333333333333333333333 model=v4-pro || true
done
sp_telemetry_record verdict seat=deepseek verdict=confirmed candidate=gate5 model=v4-pro || true
sp_telemetry_record verdict seat=deepseek verdict=confirmed candidate=sliceA model=v4-pro || true
sp_telemetry_record false_terminal seat=deepseek count=2 detail="zero-artifact turns, stood down" model=v4-pro || true
sp_telemetry_record wake seat=deepseek outcome=delivered dur_ms=600 model=v4-pro || true
for i in 1 2 3 4 5 6; do sp_telemetry_record wake seat=deepseek outcome=zero_run dur_ms=85 model=v4-pro || true; done

# glm (5.2): 3 seals, 3 confirmed
for g in gate13v phaseb h2; do
  sp_telemetry_record seal seat=glm artifact="glm-$g.md" sha=4444444444444444444444444444444444444444 model=5.2 || true
done
for c in gate13v phaseb h2; do sp_telemetry_record verdict seat=glm verdict=confirmed candidate="$c" model=5.2 || true; done
for i in 1 2 3; do sp_telemetry_record wake seat=glm outcome=delivered dur_ms=450 model=5.2 || true; done
for i in 1 2; do sp_telemetry_record wake seat=glm outcome=zero_run dur_ms=70 model=5.2 || true; done

unset PAD_DIR PAD_MD PAD_STATE PAD_GIT

echo "=== telemetry tonight-demo (summary reproduces 2026-08-02 story) ==="

J="$("$SP" telemetry --json)"
echo "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
by={m["model"]:m for m in d["models"]}
assert d["drops"]==0, d["drops"]

# deepseek-v4-flash = flash + flash2 merged
f=by["deepseek-v4-flash"]
assert f["seats"]==["flash","flash2"], f["seats"]
assert f["seals"]==4, ("flash seals",f["seals"])            # 3 + 1
assert f["verdicts"]["confirmed"]==4, f["verdicts"]          # R1-R4
assert f["verdicts"]["held"]==3, f["verdicts"]               # E1-E3
assert f["verdicts"]["rejected"]==0, f["verdicts"]
assert f["false_terminals"]==1, f["false_terminals"]         # empty re-attack turn
assert f["wake_outcomes"]["delivered"]==11, f["wake_outcomes"]  # 5 + 6
assert f["wake_outcomes"]["zero_run"]==5, f["wake_outcomes"]    # 3 + 2
assert f["wake_outcomes"]["deferred"]==1, f["wake_outcomes"]
assert f["say"]["posted"]==11, f["say"]                        # 7 + 4

# kimi k3: 5 seals, 4 confirmed + 1 held (gate9)
k=by["k3"]
assert k["seals"]==5, k["seals"]
assert k["verdicts"]["confirmed"]==4 and k["verdicts"]["held"]==1, k["verdicts"]
assert k["wake_outcomes"]["delivered"]==2 and k["wake_outcomes"]["zero_run"]==4, k["wake_outcomes"]

# deepseek v4-pro: stood down, 2 false terminals
v=by["v4-pro"]
assert v["seals"]==2, v["seals"]
assert v["verdicts"]["confirmed"]==2, v["verdicts"]
assert v["false_terminals"]==2, v["false_terminals"]
assert v["wake_outcomes"]["zero_run"]==6, v["wake_outcomes"]

# glm 5.2: 3 seals, 3 confirmed, healthy delivery
g=by["5.2"]
assert g["seals"]==3, g["seals"]
assert g["verdicts"]["confirmed"]==3, g["verdicts"]
assert g["wake_outcomes"]["delivered"]==3, g["wake_outcomes"]
' && ok "summary reproduces tonight story from data (per-model merge + counts)" \
  || bad "summary did not reproduce tonight story"

# text table honesty: verdict column rendered per model
T="$("$SP" telemetry)"
echo "$T" | grep -q "deepseek-v4-flash" && ok "text: flash model row present" || bad "text: flash row missing"
echo "$T" | grep -q "v4-pro" && ok "text: v4-pro row present" || bad "text: v4-pro row missing"
echo "$T" | grep -q "n/a" && ok "text: unknown tokens/cost render n/a" || bad "text: no n/a"

echo ""
if [ "$failn" -eq 0 ]; then
  printf 'telemetry tonight-demo: %s passed, 0 failed\n' "$pass"
  exit 0
else
  printf 'telemetry tonight-demo: %s passed, %s failed\n' "$pass" "$failn"
  exit 1
fi
