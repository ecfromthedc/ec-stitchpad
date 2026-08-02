#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_HOME="$ROOT/tool"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

tmp="$(mktemp -d /tmp/stitchpad-pad-safety.XXXXXX)"
cleanup() {
  if [ -d "$tmp/.stitchpad" ]; then
    STITCHPAD_PAD_DIR="$tmp/.stitchpad" "$SP" daemon stop >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
cd "$tmp"
git init -q
git config user.name test
git config user.email test@example.invalid
printf '# fixture\n' > README.md
: > .gitignore
git add README.md .gitignore
git commit -qm init

"$SP" init --name safety >/dev/null
"$SP" daemon stop >/dev/null 2>&1 || true

# The outer repository must ignore the whole runtime directory. Otherwise
# `git stash -u` removes stitchpad.md while live bridge writers keep running.
git check-ignore -q .stitchpad/stitchpad.md || fail 'outer repo does not ignore stitchpad.md'
git stash -u -q
[ -f .stitchpad/stitchpad.md ] || fail 'git stash -u removed the live pad'
git stash pop -q 2>/dev/null || true

# Bridge recovery must preserve the body and stay idempotent under repeated
# repair attempts (the original raw write raced and duplicated the roster).
cp .stitchpad/stitchpad.md "$tmp/good.md"
sed -n '/^```roster[[:space:]]*$/,/^```[[:space:]]*$/p' "$tmp/good.md" > .stitchpad/.state/roster.backup
printf '\n## @tester · 00:00\n\nbody survives repair\n' > .stitchpad/stitchpad.md
"$SP" restore-roster .stitchpad/.state/roster.backup >/dev/null
"$SP" restore-roster .stitchpad/.state/roster.backup >/dev/null
[ "$(grep -c '^```roster' .stitchpad/stitchpad.md)" -eq 1 ] || fail 'roster recovery duplicated the header'
grep -qF 'body survives repair' .stitchpad/stitchpad.md || fail 'roster recovery lost the existing body'

# A missing/headerless pad must fail closed instead of being recreated by say.
cp "$tmp/good.md" .stitchpad/stitchpad.md
rm .stitchpad/stitchpad.md
if STITCHPAD_NAME=tester "$SP" say '@all must not land' >/dev/null 2>&1; then
  fail 'say accepted a missing pad file'
fi
[ ! -e .stitchpad/stitchpad.md ] || fail 'say recreated a missing headerless pad'
printf '\n## @tester · 00:00\n\n@all must not land\n' > .stitchpad/stitchpad.md
if STITCHPAD_NAME=tester "$SP" say '@all still must not land' >/dev/null 2>&1; then
  fail 'say accepted a pad with no roster block'
fi
cmp -s .stitchpad/stitchpad.md <(printf '\n## @tester · 00:00\n\n@all must not land\n') || fail 'failed say mutated headerless pad'

# A file resurrected after an older staged deletion must be committed again.
cp "$tmp/good.md" .stitchpad/stitchpad.md
git --git-dir=.stitchpad/stitchpad-git --work-tree=.stitchpad add -A -- stitchpad.md
git --git-dir=.stitchpad/stitchpad-git --work-tree=.stitchpad commit -qm 'restore fixture' || true
rm .stitchpad/stitchpad.md
git --git-dir=.stitchpad/stitchpad-git --work-tree=.stitchpad add -A -- stitchpad.md
git --git-dir=.stitchpad/stitchpad-git --work-tree=.stitchpad commit -qm 'simulate transient deletion'
cp "$tmp/good.md" .stitchpad/stitchpad.md
(
  BIN_DIR="$ROOT/tool/bin"
  source "$ROOT/tool/bin/lib.sh"
  sp_init_paths "$tmp" >/dev/null
  sp_commit 'repair resurrected pad'
)
git --git-dir=.stitchpad/stitchpad-git show HEAD:stitchpad.md >/dev/null 2>&1 || fail 'sp_commit ignored resurrected pad'
[ "$(git --git-dir=.stitchpad/stitchpad-git log -1 --format=%s)" = 'repair resurrected pad' ] || fail 'resurrected pad was not committed'

printf 'PASS: pad runtime survives outer stash and fails closed without a roster\n'
