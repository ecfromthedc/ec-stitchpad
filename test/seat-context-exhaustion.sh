#!/usr/bin/env bash
# Regression test: an exhausted seat must be visible, and rotating it must not
# silently produce an amnesiac or a no-op.
#
# The failure it exists for (2026-08-13): three ocean seats went inert at 198,
# 199 and 200 turns. None errored. Every wake was accepted, each session
# reported running then completed, and all three produced nothing — no commit,
# no push, no pad post, untouched worktrees. Three dispatches were silently
# dropped before anyone compared branch heads and noticed.
#
# Pinned here:
#   1. a seat at/over the critical threshold is reported and exits 3
#   2. rotation without a brief is REFUSED (an unbriefed fresh seat is worse
#      than an inert one — it acts confidently on nothing)
#   3. a mint that reuses the old session id is reported as a FAILED rotation,
#      not as success (KNOWN-WEDGES #2)
#   4. turn counts below the threshold read healthy and exit 0
#
#   bash test/seat-context-exhaustion.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../tool/bin/stitchpad-seat-health"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-seat.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }
[ -x "$TOOL" ] || chmod +x "$TOOL" 2>/dev/null

echo "seat context exhaustion — detection and safe rotation"

# A stub daemon: seat turn counts come from a file the test controls.
mkdir -p "$WORK/state" "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Stub: last arg is the URL; map <id> -> turns from $SEATDB.
url="${@: -1}"
sid="${url##*/}"
turns="$(grep "^$sid " "$SEATDB" 2>/dev/null | awk '{print $2}')"
[ -n "$turns" ] || turns=0
printf '{"session":{"state":"completed","turns":%s}}' "$turns"
EOF
chmod +x "$WORK/bin/curl"
export SEATDB="$WORK/seatdb"
export PATH="$WORK/bin:$PATH"

printf 'sess-hot 199\nsess-cold 12\n' > "$SEATDB"
printf 'sess-hot'  > "$WORK/state/ocean-session.tired"
printf 'sess-cold' > "$WORK/state/ocean-session.fresh"

# ------------------------------------------------- 1. exhaustion is visible
out="$("$TOOL" --state "$WORK/state" 2>&1)"; rc=$?
if [ $rc -eq 3 ]; then ok "a seat near 200 turns exits 3, not 0"
else bad "exhausted seat exited $rc — it would have been ignored"; fi
if printf '%s' "$out" | grep -q 'ROTATE NOW'; then ok "it says ROTATE NOW in words"
else bad "no rotate warning in output"; fi
if printf '%s' "$out" | grep -q 'fresh'; then ok "healthy seats are still listed"
else bad "healthy seat missing from the report"; fi
if printf '%s' "$out" | grep -qi 'artifact'; then
  ok "it reminds the operator that turns are not proof"
else bad "no artifact reminder — turns alone would be trusted"; fi

# ------------------------------------------------ 2. all-healthy exits zero
printf 'sess-hot 20\nsess-cold 12\n' > "$SEATDB"
"$TOOL" --state "$WORK/state" >/dev/null 2>&1
[ $? -eq 0 ] && ok "all-healthy exits 0" || bad "healthy roster did not exit 0"

# --------------------------------------------- 3. rotation demands a brief
out="$("$TOOL" --state "$WORK/state" --rotate tired --model m --cwd /tmp 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi 'brief'; then
  ok "rotation without a brief is refused (no amnesiac seats)"
else bad "rotated without a brief — that trades inert for amnesiac"; fi

# ------------------------------- 4. a reused session id is a FAILED rotation
echo "brief content" > "$WORK/brief.txt"
cat > "$WORK/bin/ocean-heartbeat" <<'EOF'
#!/usr/bin/env bash
# Stub mint that REUSES the old id — the KNOWN-WEDGES #2 behaviour.
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "--session-file" ]; then n=$(( i + 1 )); printf 'sess-hot' > "${!n}"; fi
done
EOF
chmod +x "$WORK/bin/ocean-heartbeat"
printf 'sess-hot' > "$WORK/state/ocean-session.tired"
out="$("$TOOL" --state "$WORK/state" --rotate tired --brief "$WORK/brief.txt" --model m --cwd /tmp 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi 'reused'; then
  ok "a mint that reused the old id is reported as a FAILED rotation"
else bad "silent no-op rotation: rc=$rc out=$out"; fi

# ------------------------------------------- 5. a real mint reports the swap
cat > "$WORK/bin/ocean-heartbeat" <<'EOF'
#!/usr/bin/env bash
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "--session-file" ]; then n=$(( i + 1 )); printf 'sess-brand-new' > "${!n}"; fi
done
EOF
chmod +x "$WORK/bin/ocean-heartbeat"
printf 'sess-hot' > "$WORK/state/ocean-session.tired"
out="$("$TOOL" --state "$WORK/state" --rotate tired --brief "$WORK/brief.txt" --model m --cwd /tmp 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$(cat "$WORK/state/ocean-session.tired")" = "sess-brand-new" ]; then
  ok "a genuine rotation swaps the id and exits 0"
else bad "genuine rotation failed: rc=$rc out=$out"; fi
if ls "$WORK/state"/ocean-session.tired.exhausted-* >/dev/null 2>&1; then
  ok "the dead session is archived, not destroyed"
else bad "old session id was lost — nothing to fall back to"; fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
