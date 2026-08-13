#!/usr/bin/env bash
# Regression test: a headless spawn must never park silently.
#
# The failure it exists for (2026-08-12): `codex exec` spawned from an
# orchestration pipeline blocked on "Reading additional input from stdin..."
# for 2h21m — 0% CPU, no session file, not one API call — while `ps` showed it
# alive and the task tracker showed "running". The lane it was building sat
# untouched and nothing anywhere reported a problem.
#
# Two properties are pinned here, because either one alone still fails quiet:
#   1. stdin is closed, so a child that reads stdin cannot hang.
#   2. a child that produces NOTHING is killed and reported, not left to look
#      alive forever. A process that exists is not a process that is working.
#
#   bash test/headless-spawn-stdin.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXEC="$HERE/../tool/bin/stitchpad-exec"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-spawn.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }

[ -x "$EXEC" ] || chmod +x "$EXEC" 2>/dev/null

echo "headless spawn — stdin and start-verification"

# ---------------------------------------------------------------- 1. the wedge
# A child that reads stdin the way a headless agent does. Spawned with an open
# pipe it hangs forever; through stitchpad-exec it must EOF and finish.
cat > "$WORK/reads-stdin.sh" <<'EOF'
#!/usr/bin/env bash
echo "Reading additional input from stdin..."
cat > /dev/null
echo "STARTED_AND_FINISHED"
EOF
chmod +x "$WORK/reads-stdin.sh"

# Prove the wedge is real first, so this test fails loudly if the premise dies.
( : | { sleep 4; } & keeper=$!;
  "$WORK/reads-stdin.sh" < <(sleep 6) > "$WORK/wedge.log" 2>&1 &
  victim=$!
  sleep 2
  if kill -0 "$victim" 2>/dev/null; then echo WEDGED > "$WORK/premise"; fi
  kill "$victim" 2>/dev/null; kill "$keeper" 2>/dev/null ) >/dev/null 2>&1
if [ "$(cat "$WORK/premise" 2>/dev/null)" = "WEDGED" ]; then
  ok "premise holds: a stdin-reading child hangs on an unclosed pipe"
else
  bad "premise broken: the child no longer blocks on stdin (test is now blind)"
fi

out="$("$EXEC" --deadline 15 --log "$WORK/a.log" -- "$WORK/reads-stdin.sh" 2>&1)"
rc=$?
if [ $rc -eq 0 ] && grep -q STARTED_AND_FINISHED "$WORK/a.log"; then
  ok "stdin is closed: the same child runs to completion"
else
  bad "stdin-reading child did not complete (rc=$rc): $out"
fi

# ------------------------------------------------- 2. silence is not "running"
# The heart of it: a child that produces nothing must be killed and REPORTED,
# not left parked looking healthy.
cat > "$WORK/silent.sh" <<'EOF'
#!/usr/bin/env bash
sleep 300
EOF
chmod +x "$WORK/silent.sh"

start=$(date +%s)
out="$("$EXEC" --deadline 3 --log "$WORK/b.log" -- "$WORK/silent.sh" 2>&1)"
rc=$?
elapsed=$(( $(date +%s) - start ))

if [ $rc -eq 78 ]; then
  ok "a spawn that produced nothing exits 78 (wedged), not 0"
else
  bad "silent spawn returned $rc — a wedge was reported as success"
fi
if printf '%s' "$out" | grep -qi 'WEDGED SPAWN'; then
  ok "the wedge announces itself in words"
else
  bad "wedge was not reported: $out"
fi
if [ "$elapsed" -lt 30 ]; then
  ok "it gave up at the deadline (${elapsed}s) instead of waiting forever"
else
  bad "deadline not honoured — took ${elapsed}s"
fi
if pgrep -f "$WORK/silent.sh" >/dev/null 2>&1; then
  bad "the wedged child was left running after being reported dead"
  pkill -f "$WORK/silent.sh" 2>/dev/null
else
  ok "the wedged child was actually killed, not just reported"
fi

# ------------------------------------------------------- 3. real work is clean
cat > "$WORK/works.sh" <<'EOF'
#!/usr/bin/env bash
echo "banner"
exit 0
EOF
chmod +x "$WORK/works.sh"
"$EXEC" --deadline 10 --log "$WORK/c.log" -- "$WORK/works.sh" >/dev/null 2>&1
[ $? -eq 0 ] && ok "a healthy spawn still exits 0" || bad "healthy spawn misreported"

# A failing child must surface ITS status, not a laundered 0.
cat > "$WORK/fails.sh" <<'EOF'
#!/usr/bin/env bash
echo "starting"
exit 9
EOF
chmod +x "$WORK/fails.sh"
"$EXEC" --deadline 10 --log "$WORK/d.log" -- "$WORK/fails.sh" >/dev/null 2>&1
[ $? -eq 9 ] && ok "a failing child's exit status is propagated, not swallowed" \
             || bad "child failure was laundered into a different status"

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
