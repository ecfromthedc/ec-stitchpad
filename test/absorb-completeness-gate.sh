#!/usr/bin/env bash
# absorb-completeness-gate.sh — GAP 2: every card marked done/in_review must
# have its declared production commit actually present in the candidate tree.
#
# Builds a synthetic repo with controlled commits, a board with known-verdict
# cards, and runs the gate.  Mutant-proven: flip a PRESENT card to test-only
# and the gate must go RED.
#
# Verdicts:
#   PRESENT      commit-sha is ancestor of candidate AND touches production paths
#   TESTS-ONLY   commit-sha is ancestor but changed files are ALL test/docs/md
#   MISSING      no commit-sha: line in card body
#   STALE-CLAIM  commit-sha exists in repo but is NOT an ancestor of candidate
#   UNTRACKED    commit-sha not found in repo at all
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0; FAILED=0
ok()  { PASSED=$((PASSED+1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  \033[0;31mFAIL\033[0m %s: %s\n' "$1" "${2:-}" >&2; }

cleanup() { rm -rf "$TMP"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/absorb-gate.XXXXXX")"
trap cleanup EXIT

# ===========================================================================
# EMBEDDED GATE ENGINE — repo-agnostic, self-contained
#
# absorb_completeness_gate <board_path> <candidate_sha> <repo_path>
#   stdout: pipe-delimited verdicts (VERDICT|TASK-ID|status|title|detail)
#   stderr: summary table
#   exit: 0 = all PRESENT, non-zero = issue count
# ===========================================================================
absorb_completeness_gate() {
  local _board="$1" _candidate="$2" _repo="$3"
  local _tmp
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/absorb-gate-fn.XXXXXX")"
  local _parse_script="$_tmp/parse.py" _verdict_script="$_tmp/verdict.py" _cards_json="$_tmp/cards.json"

  # --- parser script (reads board, writes JSON of done/in_review cards) ---
  cat > "$_parse_script" << 'PARSEOF'
import sys, re, json
with open(sys.argv[1]) as f:
    text = f.read()
cards = []
for m in re.finditer(r'^```task\s+(\S+)\s*\n(.*?)```$', text, re.MULTILINE | re.DOTALL):
    bid = m.group(1); block = m.group(2)
    fields = {}; body = ""; in_body = False
    for line in block.split('\n'):
        if not in_body and line.strip() == '---':
            in_body = True; continue
        if in_body: body += line + '\n'
        elif ':' in line:
            k, _, v = line.partition(':'); k = k.strip(); v = v.strip()
            if k in ('title','status','priority','assignee','labels','created','estimate'):
                fields[k] = v
    if fields.get('status') not in ('done','in_review'): continue
    sha = (re.search(r'^commit-sha:\s*(\S+)', body, re.MULTILINE) or [None,''])[1] or ''
    cards.append({'id':bid,'title':fields.get('title',''),'status':fields['status'],'commit_sha':sha})
print(json.dumps(cards))
PARSEOF

  # --- verdict script (reads JSON from file, writes pipe-delimited verdicts) ---
  cat > "$_verdict_script" << 'VERDEOF'
import sys, json, subprocess, re
candidate = sys.argv[1]
repo = sys.argv[2]
with open(sys.argv[3]) as f:
    cards = json.loads(f.read())
NON_PROD_RE = re.compile(r'^(test/|docs/|spec/|examples/|.*[.]md$)')
results = []
for c in cards:
    vid, sha, status, title = c['id'], c['commit_sha'], c['status'], c['title']
    if not sha:
        results.append(('MISSING',vid,status,title,'no commit-sha declared'))
        continue
    r = subprocess.run(['git','-C',repo,'cat-file','-e',sha], capture_output=True)
    if r.returncode != 0:
        results.append(('UNTRACKED',vid,status,title,sha[:12]+'… not in repo'))
        continue
    r = subprocess.run(['git','-C',repo,'merge-base','--is-ancestor',sha,candidate], capture_output=True)
    if r.returncode != 0:
        results.append(('STALE-CLAIM',vid,status,title,sha[:12]+'… not ancestor of '+candidate[:12]+'…'))
        continue
    r = subprocess.run(['git','-C',repo,'diff-tree','--no-commit-id','--name-only','-r',sha],
                       capture_output=True, text=True)
    changed = [f for f in r.stdout.strip().split('\n') if f]
    if not changed:
        r2 = subprocess.run(['git','-C',repo,'log','-1','--name-only','--format=',sha],
                            capture_output=True, text=True)
        changed = [f for f in r2.stdout.strip().split('\n') if f]
    if not changed:
        results.append(('PRESENT',vid,status,title,sha[:12]+'… ancestor (empty — merge)'))
        continue
    if all(NON_PROD_RE.match(f) for f in changed):
        results.append(('TESTS-ONLY',vid,status,title,sha[:12]+'… '+str(len(changed))+' non-prod files'))
    else:
        results.append(('PRESENT',vid,status,title,sha[:12]+'… ancestor, '+str(len(changed))+' prod files'))
for r in results:
    print('|'.join(r))
VERDEOF

  # --- execute parser ---
  python3 "$_parse_script" "$_board" > "$_cards_json" 2>/dev/null

  # --- execute verdict engine ---
  local _verdicts
  _verdicts="$(python3 "$_verdict_script" "$_candidate" "$_repo" "$_cards_json" 2>/dev/null)"

  # --- report to stderr ---
  local _p _i _t
  # Trim whitespace; empty verdicts = zero cards
  _verdicts="$(echo "$_verdicts" | sed '/^[[:space:]]*$/d')"
  if [ -z "$_verdicts" ]; then
    {
      printf '\n========== ABSORB-COMPLETENESS GATE ==========\n'
      printf 'Candidate: %s\n' "$_candidate"
      printf 'Board:     %s\n' "$_board"
      printf 'Cards:     0 done/in_review — nothing to check\n'
      printf 'GATE: PASSED (no cards)\n'
      printf '================================================\n'
    } >&2
    rm -rf "$_tmp"
    return 0
  fi
  _p="$(echo "$_verdicts" | awk -F'|' '$1=="PRESENT"{c++} END{print c+0}')"
  _i="$(echo "$_verdicts" | awk -F'|' '$1!="PRESENT"{c++} END{print c+0}')"
  _t="$(echo "$_verdicts" | wc -l | tr -d ' ')"

  {
    printf '\n========== ABSORB-COMPLETENESS GATE ==========\n'
    printf 'Candidate: %s\n' "$_candidate"
    printf 'Board:     %s\n' "$_board"
    printf 'Cards:     %s done/in_review\n\n' "$_t"
    printf '%-6s %-12s %-9s %s\n' 'CARD' 'VERDICT' 'STATUS' 'DETAIL'
    printf '%-6s %-12s %-9s %s\n' '------' '------------' '---------' '-------------------------'
    echo "$_verdicts" | sort -t'|' -k1,1 | while IFS='|' read -r _v _id _status _title _detail; do
      printf '%-6s %-12s %-9s %s\n' "$_id" "$_v" "$_status" "$_detail"
    done
    printf '\nRESULT: %s PRESENT, %s ISSUES (%s total)\n' "$_p" "$_i" "$_t"
    if [ "$_i" -eq 0 ]; then
      printf 'GATE: PASSED — every committed card is present and non-test-only.\n'
    else
      printf 'GATE: FAILED — %s card(s) TESTS-ONLY / MISSING / STALE-CLAIM.\n' "$_i"
    fi
    printf '================================================\n'
  } >&2

  rm -rf "$_tmp"
  return "$_i"
}

# ===========================================================================
# FIXTURE: build a controlled git repo with known commits
# ===========================================================================
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.name "absorb-test"
git -C "$REPO" config user.email "t@absorb"

mkdir -p "$REPO/src" "$REPO/test" "$REPO/tool/bin" "$REPO/docs"

# C1: production — src/main.sh
echo "#!/usr/bin/env bash" > "$REPO/src/main.sh"
echo "main() { echo hi; }" >> "$REPO/src/main.sh"
git -C "$REPO" add src/main.sh && git -C "$REPO" commit -q -m "feat: main"
PROD_1="$(git -C "$REPO" rev-parse HEAD)"

# C2: production — src/lib.sh + test/test_lib.sh
echo "lib() { return 0; }" > "$REPO/src/lib.sh"
echo "#!/usr/bin/env bash" > "$REPO/test/test_lib.sh"
echo ". ../src/lib.sh" >> "$REPO/test/test_lib.sh"
git -C "$REPO" add src/lib.sh test/test_lib.sh && git -C "$REPO" commit -q -m "feat: lib + tests"
PROD_2="$(git -C "$REPO" rev-parse HEAD)"

# C3: TESTS-ONLY — test/test_extra.sh only
echo "echo xtra" > "$REPO/test/test_extra.sh"
git -C "$REPO" add test/test_extra.sh && git -C "$REPO" commit -q -m "test: extra"
TEST_ONLY_1="$(git -C "$REPO" rev-parse HEAD)"

# C4: production — tool/bin/cli.sh
echo "#!/usr/bin/env bash" > "$REPO/tool/bin/cli.sh"
echo 'echo "$@"' >> "$REPO/tool/bin/cli.sh"
git -C "$REPO" add tool/bin/cli.sh && git -C "$REPO" commit -q -m "feat: cli"
PROD_3="$(git -C "$REPO" rev-parse HEAD)"

# C5: production — src/config.sh
echo "CONFIG=default" > "$REPO/src/config.sh"
git -C "$REPO" add src/config.sh && git -C "$REPO" commit -q -m "feat: config"
PROD_4="$(git -C "$REPO" rev-parse HEAD)"

# C6: production — src/auth.sh
echo "auth() { true; }" > "$REPO/src/auth.sh"
git -C "$REPO" add src/auth.sh && git -C "$REPO" commit -q -m "feat: auth"
PROD_5="$(git -C "$REPO" rev-parse HEAD)"

# C7: TESTS-ONLY — docs/README.md
echo "# docs" > "$REPO/docs/README.md"
git -C "$REPO" add docs/README.md && git -C "$REPO" commit -q -m "docs: readme"
TEST_ONLY_2="$(git -C "$REPO" rev-parse HEAD)"

CANDIDATE="$(git -C "$REPO" rev-parse HEAD)"

# Side branch: SHA exists but NOT ancestor of CANDIDATE
git -C "$REPO" checkout -q -b side HEAD~3
echo "side" > "$REPO/side-file.txt"
git -C "$REPO" add side-file.txt && git -C "$REPO" commit -q -m "side: branch"
NOT_ANCESTOR="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main 2>/dev/null || git -C "$REPO" checkout -q master 2>/dev/null || true

FAKE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

echo "REPO=$REPO"
echo "CANDIDATE=$(git -C "$REPO" rev-parse --short HEAD)"

# ===========================================================================
# BUILD BOARD with known-truth cards
# ===========================================================================
BOARD="$TMP/tasks.md"
python3 - "$BOARD" \
    "$PROD_1" "$PROD_2" "$TEST_ONLY_1" "$PROD_3" "$PROD_4" "$PROD_5" \
    "$NOT_ANCESTOR" << 'PYEOF'
import sys
bp, p1,p2,to1,p3,p4,p5,nota = sys.argv[1:]
txt = f"""# Test Board — absorb-completeness seed fixtures

```task TASK-1
title: Pin and verify the resolved model for every seat
status: done
priority: high
assignee: kimi2
labels: orchestration
created: 08-03 02:37
---
commit-sha: {p1}
suite: test_lib.sh
```

```task TASK-2
title: Make provider availability live, bounded, and truthful
status: done
priority: high
assignee: pro3
labels: orchestration
created: 08-03 02:37
---
commit-sha: {p2}
suite: test_lib.sh
```

```task TASK-4
title: Bound recovery, rotation, and idempotent reassignment
status: done
priority: high
assignee: pro3
labels: delivery
created: 08-03 02:37
---
commit-sha: {p3}
```

```task TASK-6
title: Label verification evidence by environment and immutable candidate
status: done
priority: medium
assignee: flash2
labels: testing
created: 08-03 02:37
---
commit-sha: {p4}
```

```task TASK-7
title: Capture per-model reliability and cost-value telemetry
status: done
priority: medium
assignee: flash
labels: telemetry
created: 08-03 02:37
---
commit-sha: {p5}
```

```task TASK-9
title: Roster must survive concurrent writes (clobber guard) — TESTS-ONLY
status: done
priority: high
assignee: km3
labels: durability
created: 08-03 14:56
---
commit-sha: {to1}
This card is TESTS-ONLY — commit only touched test/ files.
```

```task TASK-12
title: Worker identity must not leak between concurrent agents — MISSING
status: in_review
priority: high
assignee: pro5
labels: coordination
created: 08-03 14:56
---
This card has NO commit-sha: line — it is MISSING.
```

```task TASK-17
title: SECURITY — journal-replay RCE + containment (flash H/C series)
status: done
priority: high
assignee: flash
labels: security
created: 08-03 15:54
---
commit-sha: {p1}
```

```task TASK-20
title: DOCS — 8 doc-vs-behavior drifts (rc4) — STALE-CLAIM
status: in_review
priority: medium
assignee: km1
labels: docs
created: 08-03 15:54
---
commit-sha: {nota}
This SHA is on a side branch — STALE-CLAIM.
```

```task TASK-21
title: AUTHORITY MODEL — gate must not be self-declarable
status: done
priority: high
assignee: kimi2
labels: security
created: 08-03 15:54
---
commit-sha: {p3}
```

```task TASK-25
title: Still doing — IGNORED by gate
status: doing
priority: medium
assignee: someone
labels: misc
created: 08-03 16:00
---
commit-sha: {p2}
```
"""
with open(bp, 'w') as f: f.write(txt)
PYEOF

# ===========================================================================
# G1: KNOWN VERDICTS — 7 PRESENT, 3 ISSUES
# ===========================================================================
echo ""
echo "=== G1: known-verdict board ==="
echo ""

GATE_RC=0
GATE_OUT="$(absorb_completeness_gate "$BOARD" "$CANDIDATE" "$REPO" 2>&1)" || GATE_RC=$?
echo "$GATE_OUT"

# G1a: non-zero exit
if [ "$GATE_RC" -ne 0 ]; then
  ok "G1a: gate exits non-zero with issues (rc=$GATE_RC)"
else
  bad "G1a: gate exited 0 despite known issues" "rc=$GATE_RC"
fi

# G1b: TASK-9 → TESTS-ONLY
if echo "$GATE_OUT" | awk '$1=="TASK-9" && $2=="TESTS-ONLY"{f=1} END{exit !f}'; then
  ok "G1b: TASK-9 flagged TESTS-ONLY"
else
  bad "G1b: TASK-9 NOT flagged TESTS-ONLY" "$(echo "$GATE_OUT" | grep 'TASK-9' || echo '<no TASK-9>')"
fi

# G1c: TASK-12 → MISSING
if echo "$GATE_OUT" | awk '$1=="TASK-12" && $2=="MISSING"{f=1} END{exit !f}'; then
  ok "G1c: TASK-12 flagged MISSING"
else
  bad "G1c: TASK-12 NOT flagged MISSING" "$(echo "$GATE_OUT" | grep 'TASK-12' || echo '<no TASK-12>')"
fi

# G1d: TASK-20 → STALE-CLAIM
if echo "$GATE_OUT" | awk '$1=="TASK-20" && $2=="STALE-CLAIM"{f=1} END{exit !f}'; then
  ok "G1d: TASK-20 flagged STALE-CLAIM"
else
  bad "G1d: TASK-20 NOT flagged STALE-CLAIM" "$(echo "$GATE_OUT" | grep 'TASK-20' || echo '<no TASK-20>')"
fi

# G1e–k: PRESENT cards
for _tid in TASK-1 TASK-2 TASK-4 TASK-6 TASK-7 TASK-17 TASK-21; do
  if echo "$GATE_OUT" | awk -v t="$_tid" '$1==t && $2=="PRESENT"{f=1} END{exit !f}'; then
    ok "G1: $_tid → PRESENT"
  else
    bad "G1: $_tid NOT PRESENT" "$(echo "$GATE_OUT" | grep "$_tid" || echo '<none>')"
  fi
done

# G1l: exactly 3 issues
_ic="$(echo "$GATE_OUT" | awk '$2=="TESTS-ONLY" || $2=="MISSING" || $2=="STALE-CLAIM" || $2=="UNTRACKED"{c++} END{print c+0}')"
if [ "$_ic" -eq 3 ]; then
  ok "G1l: exactly 3 issues (TESTS-ONLY + MISSING + STALE-CLAIM)"
else
  bad "G1l: expected 3 issues, got $_ic"
fi

# G1m: TASK-25 (doing) ignored
if ! echo "$GATE_OUT" | grep -q 'TASK-25'; then
  ok "G1m: TASK-25 (doing) correctly ignored"
else
  bad "G1m: TASK-25 should be ignored"
fi

# ===========================================================================
# G2: MUTANT PROOF — fix all 3 issues, gate goes GREEN
# ===========================================================================
echo ""
echo "=== G2: mutant — fix all issues, gate goes GREEN ==="
echo ""

FIXED_BOARD="$TMP/tasks-fixed.md"
python3 - "$BOARD" "$FIXED_BOARD" "$PROD_5" "$PROD_2" "$PROD_1" << 'PYEOF'
import sys, re
src, dst, p5, p2, p1 = sys.argv[1:]
with open(src) as f: content = f.read()
content = re.sub(r'(```task TASK-9\n.*?---\n)commit-sha:\s*\S+', r'\1commit-sha: ' + p5, content, flags=re.DOTALL)
content = re.sub(r'(```task TASK-12\n.*?---\n)', r'\1commit-sha: ' + p2 + '\n', content, flags=re.DOTALL)
content = re.sub(r'(```task TASK-20\n.*?---\n)commit-sha:\s*\S+', r'\1commit-sha: ' + p1, content, flags=re.DOTALL)
with open(dst, 'w') as f: f.write(content)
PYEOF

GATE2_RC=0
GATE2_OUT="$(absorb_completeness_gate "$FIXED_BOARD" "$CANDIDATE" "$REPO" 2>&1)" || GATE2_RC=$?
echo "$GATE2_OUT"

if [ "$GATE2_RC" -eq 0 ]; then
  ok "G2a: all issues fixed — gate exits 0 (all PRESENT)"
else
  bad "G2a: gate failed after fixing all issues" "rc=$GATE2_RC"
fi

# ===========================================================================
# G3: MUTANT PROOF — flip TASK-1 to UNTRACKED fake SHA → RED
# ===========================================================================
echo ""
echo "=== G3: mutant — TASK-1 → fake SHA (UNTRACKED) ==="
echo ""

MUT1="$TMP/tasks-mutant1.md"
python3 - "$FIXED_BOARD" "$MUT1" "$FAKE_SHA" << 'PYEOF'
import sys, re
src, dst, fake = sys.argv[1:]
with open(src) as f: content = f.read()
content = re.sub(r'(```task TASK-1\n.*?---\n)commit-sha:\s*\S+', r'\1commit-sha: ' + fake, content, flags=re.DOTALL)
with open(dst, 'w') as f: f.write(content)
PYEOF

GATE3_RC=0
GATE3_OUT="$(absorb_completeness_gate "$MUT1" "$CANDIDATE" "$REPO" 2>&1)" || GATE3_RC=$?
echo "$GATE3_OUT"

if [ "$GATE3_RC" -ne 0 ]; then
  ok "G3a: UNTRACKED mutant exits non-zero (rc=$GATE3_RC)"
else
  bad "G3a: UNTRACKED mutant should have failed" "rc=$GATE3_RC"
fi

if echo "$GATE3_OUT" | awk '$1=="TASK-1" && $2=="UNTRACKED"{f=1} END{exit !f}'; then
  ok "G3b: mutant TASK-1 correctly flagged UNTRACKED"
else
  bad "G3b: mutant TASK-1 not flagged UNTRACKED" "$(echo "$GATE3_OUT" | grep 'TASK-1' || echo '<none>')"
fi

# ===========================================================================
# G4: MUTANT PROOF — flip TASK-2 to test-only SHA → RED
# ===========================================================================
echo ""
echo "=== G4: mutant — TASK-2 → test-only SHA (TESTS-ONLY) ==="
echo ""

MUT2="$TMP/tasks-mutant2.md"
python3 - "$FIXED_BOARD" "$MUT2" "$TEST_ONLY_2" << 'PYEOF'
import sys, re
src, dst, to2 = sys.argv[1:]
with open(src) as f: content = f.read()
content = re.sub(r'(```task TASK-2\n.*?---\n)commit-sha:\s*\S+', r'\1commit-sha: ' + to2, content, flags=re.DOTALL)
with open(dst, 'w') as f: f.write(content)
PYEOF

GATE4_RC=0
GATE4_OUT="$(absorb_completeness_gate "$MUT2" "$CANDIDATE" "$REPO" 2>&1)" || GATE4_RC=$?
echo "$GATE4_OUT"

if [ "$GATE4_RC" -ne 0 ]; then
  ok "G4a: TESTS-ONLY mutant exits non-zero (rc=$GATE4_RC)"
else
  bad "G4a: TESTS-ONLY mutant should have failed" "rc=$GATE4_RC"
fi

if echo "$GATE4_OUT" | awk '$1=="TASK-2" && $2=="TESTS-ONLY"{f=1} END{exit !f}'; then
  ok "G4b: mutant TASK-2 correctly flagged TESTS-ONLY"
else
  bad "G4b: mutant TASK-2 not flagged TESTS-ONLY" "$(echo "$GATE4_OUT" | grep 'TASK-2' || echo '<none>')"
fi

# ===========================================================================
# G5: empty board (only doing cards) exits 0
# ===========================================================================
echo ""
echo "=== G5: empty board (only doing cards) exits 0 ==="
echo ""

EMPTY="$TMP/tasks-empty.md"
cat > "$EMPTY" << 'EOF'
# Empty board

```task TASK-99
title: still working
status: doing
priority: low
assignee: x
labels: y
created: 01-01
---
commit-sha: abcdef01
```
EOF

GATE5_RC=0
GATE5_OUT="$(absorb_completeness_gate "$EMPTY" "$CANDIDATE" "$REPO" 2>&1)" || GATE5_RC=$?

if [ "$GATE5_RC" -eq 0 ]; then
  ok "G5a: empty board (only doing) exits 0"
else
  bad "G5a: empty board should exit 0" "rc=$GATE5_RC"
fi

# ===========================================================================
# G6: TREE-LEVEL MUTANT — remove PROD_3 from candidate ancestry
#     Create a new branch from before PROD_3; use that as candidate.
#     TASK-4 and TASK-3 (if pointing at PROD_3) become STALE-CLAIM.
# ===========================================================================
echo ""
echo "=== G6: tree-level mutant — remove PROD_3 from candidate ancestry ==="
echo ""

# PROD_3 is the cli commit. Create a branch from the commit BEFORE it.
PROD_3_PARENT="$(git -C "$REPO" rev-parse "${PROD_3}~1" 2>/dev/null)"
git -C "$REPO" checkout -q -b mutated-candidate "$PROD_3_PARENT" 2>/dev/null
MUTATED_CANDIDATE="$(git -C "$REPO" rev-parse HEAD)"
echo "CANDIDATE (normal): $(echo "$CANDIDATE" | cut -c1-12)..."
echo "CANDIDATE (mutated): $(echo "$MUTATED_CANDIDATE" | cut -c1-12)..."
echo ""
echo "--- MUTATION: candidate moved to before PROD_3 ---"
echo "git checkout -b mutated-candidate PROD_3~1"
echo "PROD_3 ($(echo "$PROD_3" | cut -c1-12)...) is NO LONGER an ancestor."
echo ""
echo "Board cards pointing at PROD_3, PROD_4, PROD_5 should now be STALE-CLAIM."
echo ""

GATE6_RC=0
GATE6_OUT="$(absorb_completeness_gate "$FIXED_BOARD" "$MUTATED_CANDIDATE" "$REPO" 2>&1)" || GATE6_RC=$?
echo "$GATE6_OUT"

# Gate must exit non-zero
if [ "$GATE6_RC" -ne 0 ]; then
  ok "G6a: tree-level mutant exits non-zero (rc=$GATE6_RC)"
else
  bad "G6a: tree-level mutant should have failed" "rc=$GATE6_RC"
fi

# At least one card that was PRESENT must now be STALE-CLAIM
if echo "$GATE6_OUT" | awk '$2=="STALE-CLAIM"{f=1} END{exit !f}'; then
  ok "G6b: at least one card now STALE-CLAIM after tree mutation"
else
  bad "G6b: no card flagged STALE-CLAIM after tree mutation" \
    "$(echo "$GATE6_OUT" | grep -E 'TASK-[0-9]' | head -5)"
fi

# Switch back to main
git -C "$REPO" checkout -q main 2>/dev/null || true

# ===========================================================================
echo ""
cd "$ROOT"

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll absorb-completeness gates PASSED.\n'; exit 0; }
printf '\nSome absorb-completeness gates FAILED.\n'; exit 1
