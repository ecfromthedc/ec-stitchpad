#!/usr/bin/env bash
# Regression test for stitchpad-watchdog's pending-work matching — the awk
# that is easy to get wrong, driven through the --check-task debug flag:
#   1. todo and in_progress tasks assigned to the seat count as pending
#   2. in_review does NOT count (the seat is waiting on the OTHER seat's
#      verdict; counting it over-wakes the author every cooldown — the
#      recorded failure)
#   3. done/canceled don't count; other seats' tasks don't count
#   4. a seat name that PREFIXES another (kim vs kimi) must not cross-match
#
#   bash test/watchdog-task-matching.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$HERE/../tool/bin/stitchpad-watchdog"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sp-wd.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }
expect(){ # $1 label, $2 seat, $3 want-exit (0 pending / 1 not)
  if "$WD" --pad "$WORK/repo" --check-task "$2" >/dev/null 2>&1; then got=0; else got=1; fi
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 (want exit $3, got $got)"; fi
}

mkdir -p "$WORK/repo/.stitchpad/.state"
card(){ printf 'TASK-%s\ntitle: %s\nassignee: %s\nstatus: %s\n\n' "$1" "$2" "$3" "$4" >> "$WORK/repo/.stitchpad/tasks.md"; }

card 1 "kimi builds a thing"     kimi     todo
card 2 "kimi reviews something"  kimi     in_review
card 3 "deepseek mid-build"      deepseek in_progress
card 4 "codex finished"          codex    done
card 5 "kim is a different seat" kim      todo

expect "todo counts as pending (kimi)"            kimi     0
expect "in_progress counts as pending (deepseek)" deepseek 0
expect "done does not count (codex)"              codex    1
expect "prefix name does not cross-match (kim)"   kim      0
expect "unknown seat has nothing (glm)"           glm      1

# Flip kimi's only open task to in_review — pending must go away.
sed -i '' 's/^status: todo$/status: in_review/' "$WORK/repo/.stitchpad/tasks.md" 2>/dev/null \
  || sed -i 's/^status: todo$/status: in_review/' "$WORK/repo/.stitchpad/tasks.md"
expect "in_review alone is NOT pending (kimi)"    kimi     1
expect "in_review alone is NOT pending (kim)"     kim      1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
