#!/bin/bash
# OPEN #4 measurement: `say` under contention — what is the EXIT CODE when the
# rollback-shaped warning prints, and does the message land anyway?
# Classification per attempt:
#   rc=0  landed      -> OK (or wording problem if warning printed)
#   rc!=0 NOT landed  -> honest failure
#   rc!=0 landed      -> FALSE FAILURE (the expensive class: retry => duplicate)
# Usage: say-contention-rc.sh [repo-root] [attempts]
set -u
ROOT="${1:-/Users/ecfromthedc/dev/rt/rt-stitchpad-prs/wt}"
N="${2:-20}"
W="$(mktemp -d "${TMPDIR:-/tmp}/sp-sayrc.XXXXXX")"
mkdir -p "$W/home" "$W/proj"
ln -sfn "$ROOT/tool" "$W/home/.stitchpad"
export HOME="$W/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
unset STITCHPAD_NAME CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID HERDR_ENV 2>/dev/null || true
SP="$ROOT/tool/bin/stitchpad"

cd "$W/proj" || exit 2
"$SP" init --name sayrc >/dev/null 2>&1
STITCHPAD_TERMINAL_NAMESPACE=a STITCHPAD_NAME=alice "$SP" join alice cli pull - >/dev/null 2>&1
STITCHPAD_TERMINAL_NAMESPACE=b STITCHPAD_NAME=bob   "$SP" join bob   cli pull - >/dev/null 2>&1

# Contention: a watcher-shaped committer (sp_lock + sp_commit loop) plus a
# second seat saying at the same instant as the measured seat.
STITCHPAD_WATCH_LIB_ONLY=1
committer() {
  ( export STITCHPAD_HOME="$ROOT/tool"; BIN_DIR="$ROOT/tool/bin"
    source "$ROOT/tool/bin/lib.sh"
    sp_init_paths "$W/proj/.stitchpad" >/dev/null
    end=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$end" ] && [ -f "$W/keep-going" ]; do
      ( sp_lock 2>/dev/null && sp_commit "update ($(date '+%H:%M:%S'))" >/dev/null 2>&1; sp_unlock 2>/dev/null ) || true
      sleep 0.05
    done
  ) &
  echo $!
}

: > "$W/keep-going"
CPID="$(committer)"

false_failures=0; honest_failures=0; ok_clean=0; ok_warned=0; dupes=0
for i in $(seq 1 "$N"); do
  out_a="$W/a.$i.out"; out_b="$W/b.$i.out"
  marker="probe-$i-$$"
  # bob races alice with his own post in the same instant
  ( STITCHPAD_TERMINAL_NAMESPACE=b STITCHPAD_NAME=bob "$SP" say "bob noise $i" >"$out_b" 2>&1 ) &
  bpid=$!
  STITCHPAD_TERMINAL_NAMESPACE=a STITCHPAD_NAME=alice "$SP" say "@bob $marker" >"$out_a" 2>&1
  rc=$?
  wait "$bpid" 2>/dev/null
  copies="$(grep -c "$marker" "$W/proj/.stitchpad/stitchpad.md" 2>/dev/null | tr -d ' ')"
  warned=no
  grep -q "rolled back\|NOT posted\|commit failed" "$out_a" && warned=yes
  if [ "${copies:-0}" -ge 1 ] && [ "$rc" -ne 0 ]; then
    false_failures=$((false_failures+1))
    echo "attempt $i: rc=$rc copies=$copies warned=$warned  << FALSE FAILURE"
    sed 's/^/    /' "$out_a"
  elif [ "${copies:-0}" -eq 0 ] && [ "$rc" -ne 0 ]; then
    honest_failures=$((honest_failures+1))
    echo "attempt $i: rc=$rc copies=0 warned=$warned  (honest failure)"
    sed 's/^/    /' "$out_a"
  elif [ "$rc" -eq 0 ] && [ "$warned" = yes ]; then
    ok_warned=$((ok_warned+1))
    echo "attempt $i: rc=0 copies=$copies warned=yes  << WORDING PROBLEM (success rc, failure text)"
    sed 's/^/    /' "$out_a"
  else
    ok_clean=$((ok_clean+1))
  fi
  [ "${copies:-0}" -gt 1 ] && { dupes=$((dupes+1)); echo "attempt $i: DUPLICATE — $copies copies of one say"; }
done

rm -f "$W/keep-going"
wait "$CPID" 2>/dev/null

echo ""
echo "SUMMARY over $N contended attempts:"
echo "  clean ok            : $ok_clean"
echo "  ok but failure text : $ok_warned   (rc=0 wording problem)"
echo "  honest failures     : $honest_failures   (rc!=0, message absent)"
echo "  FALSE FAILURES      : $false_failures   (rc!=0, message present)"
echo "  duplicate posts     : $dupes"
rm -rf "$W"
[ "$false_failures" -eq 0 ] && [ "$ok_warned" -eq 0 ]
