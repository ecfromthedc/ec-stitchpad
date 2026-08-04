"""M3: Add guard — refuse journal_begin when git dir is unresolvable."""
import sys

src = sys.argv[1]
with open(src) as f:
    content = f.read()

# The pattern to insert after: second _git resolution block in journal_begin,
# right before "# C1: recover stale journals..."
old = '''  local _git=""
  [ -n "${PAD_DIR:-}" ] && [ -d "$PAD_DIR/pasture-git" ] && _git="$PAD_DIR/pasture-git"
  [ -z "$_git" ] && [ -n "${PAD_DIR:-}" ] && [ -d "$PAD_DIR/stitchpad-git" ] && _git="$PAD_DIR/stitchpad-git"
  # C1: recover stale journals from a prior crash BEFORE any new journal.'''

new = '''  local _git=""
  [ -n "${PAD_DIR:-}" ] && [ -d "$PAD_DIR/pasture-git" ] && _git="$PAD_DIR/pasture-git"
  [ -z "$_git" ] && [ -n "${PAD_DIR:-}" ] && [ -d "$PAD_DIR/stitchpad-git" ] && _git="$PAD_DIR/stitchpad-git"
  # Gate M3: refuse to journal without a resolvable git dir — silently
  # skipping the .base-sha stamp is the stale-path bug. Without it,
  # recovery cannot detect HEAD advancement and would clobber committed
  # content. Try PWD as last-resort fallback; refuse if still empty.
  if [ -z "$_git" ] && [ -n "${PWD:-}" ]; then
    [ -d "$PWD/pasture-git" ] && _git="$PWD/pasture-git"
    [ -z "$_git" ] && [ -d "$PWD/stitchpad-git" ] && _git="$PWD/stitchpad-git"
  fi
  if [ -z "$_git" ]; then
    echo "stitchpad: cannot resolve pad git dir — refusing to journal without base-sha stamp" >&2
    return 1
  fi
  # C1: recover stale journals from a prior crash BEFORE any new journal.'''

content = content.replace(old, new, 1)
with open(src, 'w') as f:
    f.write(content)

print('M3: added git-dir refusal guard to journal_begin')
