"""M5: Replace recover's _git block with nothing — just use ${PAD_GIT:-} directly.
On pasture-only pads, PAD_GIT is unset → ${PAD_GIT:-} is empty → all git ops fail
→ R3 guard skipped → unconditional rollback clobbers committed content."""
import sys

src = sys.argv[1]
with open(src) as f:
    content = f.read()

# The block to remove (current _git resolution in recover):
old_block = '''  # Resolve git dir from PAD_DIR (always, not cached — PAD_DIR can change
  # across test sections or caller contexts; using a local avoids leaking
  # one pad's resolved dir into another pad's recovery).
  local _git=""
  [ -n "${PAD_DIR:-}" ] && [ -d "$PAD_DIR/pasture-git" ] && _git="$PAD_DIR/pasture-git"
  [ -z "$_git" ] && [ -n "${PAD_DIR:-}" ] && [ -d "$PAD_DIR/stitchpad-git" ] && _git="$PAD_DIR/stitchpad-git"
'''

if old_block in content:
    # Remove the block entirely — recover will have no local _git
    content = content.replace(old_block, '', 1)

    # Replace ALL $_git references in the recover function with ${PAD_GIT:-}
    # Find the recover function boundaries
    marker = 'sp_session_registry_journal_recover()'
    end_marker = 'sp_session_registry_journal_rollback()'
    rstart = content.find(marker)
    rend = content.find(end_marker, rstart) if rstart >= 0 else -1
    if rstart >= 0 and rend >= 0:
        before = content[:rend]
        after = content[rend:]
        recover_body = before[rstart:]
        recover_body = recover_body.replace('"$_git"', '"${PAD_GIT:-}"')
        recover_body = recover_body.replace('"$_git', '"${PAD_GIT:-}"')
        content = before[:rstart] + recover_body + after

    with open(src, 'w') as f:
        f.write(content)
    print('M5: removed _git block from recover; all refs use ${PAD_GIT:-} (empty on pasture pads)')
else:
    print('M5: old_block not found in source')
