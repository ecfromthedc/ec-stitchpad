"""M6: Remove _git resolution from recover — relies on global (unset when standalone)."""
import sys

src = sys.argv[1]
with open(src) as f:
    content = f.read()

# Remove the _git resolution block from journal_recover
old_block = '''  # Resolve git dir from PAD_DIR (always, not cached — PAD_DIR can change
  # across test sections or caller contexts; using a local avoids leaking
  # one pad's resolved dir into another pad's recovery).
  local _git=""
  [ -n "${PAD_DIR:-}" ] && [ -d "$PAD_DIR/pasture-git" ] && _git="$PAD_DIR/pasture-git"
  [ -z "$_git" ] && [ -n "${PAD_DIR:-}" ] && [ -d "$PAD_DIR/stitchpad-git" ] && _git="$PAD_DIR/stitchpad-git"
'''

if old_block in content:
    content = content.replace(old_block, '', 1)
    # Replace $_git refs with a global that is never set (standalone)
    content = content.replace('"$_git"', '"${_sp_journal_git:-}"')
    content = content.replace('"$_git', '"${_sp_journal_git:-}"')
    # Also fix any remaining placeholder
    print('M6: removed _git block from recover; refs use unset global _sp_journal_git')
else:
    print('M6: pattern not found in source')

with open(src, 'w') as f:
    f.write(content)
