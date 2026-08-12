#!/usr/bin/env bash
# Regression test for stitchpad-await (the orchestrator-staleness fix):
#   1. fires when a crew seat posts; prints the message; exits 0
#   2. ignores the awaiting seat's own posts
#   3. --authors filters to the named seats only
#   4. survives a pad SHRINK (archive/trim) without firing — hash-keyed,
#      where a line-number key goes permanently deaf (the recorded failure)
#   5. a byte-identical rewrite does not fire
#
#   bash test/orchestrator-await.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWAIT="$HERE/../tool/bin/stitchpad-await"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-await.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

PADDIR="$WORK/repo"; PAD="$PADDIR/.stitchpad/stitchpad.md"
mkdir -p "$PADDIR/.stitchpad"

post() { printf '## @%s · 12:00 · #m-%s\n\n%s\n\n' "$1" "$2" "$3" >> "$PAD"; }

reset_pad() {
  : > "$PAD"
  post fable  aaa001 "orchestrator note"
  post kimi   aaa002 "old kimi message"
}

# Launch an await and wait (bounded) for it to exit; echoes its exit disposition.
# $1 = seconds to allow; remaining args = await flags.
run_await() {
  local allow="$1"; shift
  STITCHPAD_NAME=fable "$AWAIT" --pad "$PADDIR" --interval 1 "$@" > "$WORK/out" 2>&1 &
  AWPID=$!
}
await_done() { # $1 = seconds budget → "exited" | "running"
  local n=0
  while kill -0 "$AWPID" 2>/dev/null; do
    n=$(( n + 1 )); [ "$n" -ge $(( $1 * 10 )) ] && { echo running; return; }
    sleep 0.1
  done
  echo exited
}

echo "1) fires on a crew post, prints it, exits 0"
reset_pad; run_await 5
sleep 1.5; post deepseek bbb001 "TASK-9 VERDICT: SHIP"
check "await exited on new post"        "$(await_done 5)" "exited"
wait "$AWPID"; check "exit code 0"      "$?" "0"
grep -q 'deepseek' "$WORK/out" && ok "output names the author" || bad "output names the author"
grep -q 'VERDICT: SHIP' "$WORK/out" && ok "output carries the body" || bad "output carries the body"

echo "2) ignores own posts"
reset_pad; run_await 3
sleep 1.5; post fable ccc001 "talking to myself"
check "still armed after own post"      "$(await_done 3)" "running"
kill "$AWPID" 2>/dev/null; wait "$AWPID" 2>/dev/null || true

echo "3) --authors filter"
reset_pad; run_await 3 --authors 'kimi|deepseek'
sleep 1.5; post codex ddd001 "not a watched author"
check "unwatched author does not fire"  "$(await_done 3)" "running"
post kimi ddd002 "watched author"
check "watched author fires"            "$(await_done 5)" "exited"

echo "4) pad shrink (archive) does not fire; the NEXT real post does"
reset_pad
post kimi eee001 "will survive the trim"
run_await 3
sleep 1.5
# Trim: drop history but keep the newest kimi message — like stitchpad archive.
{ printf '## @kimi · 12:00 · #m-eee001\n\nwill survive the trim\n\n'; } > "$PAD"
check "shrink alone does not fire"      "$(await_done 3)" "running"
post deepseek eee002 "post-archive message"
check "post after shrink fires"         "$(await_done 5)" "exited"

echo "5) byte-identical rewrite does not fire"
reset_pad; run_await 3
sleep 1.5; cp "$PAD" "$WORK/copy"; cat "$WORK/copy" > "$PAD"
check "identical rewrite does not fire" "$(await_done 3)" "running"
kill "$AWPID" 2>/dev/null; wait "$AWPID" 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
