"""M7: In journal_recover line 856, replace _git with PAD_DIR/stitchpad-git.
On a pasture-git-only pad, $PAD_DIR/stitchpad-git doesn't exist,
so git rev-parse fails → _recovery_head_sha="" → R3 guard skipped
→ unconditional rollback clobbers committed content."""
import sys
src = sys.argv[1]
with open(src) as f:
    content = f.read()

# Target the FIRST occurrence of git --git-dir="$_git" rev-parse HEAD
# (line 856 in journal_recover — the _recovery_head_sha line)
old = 'git --git-dir="$_git" rev-parse HEAD'
# This string appears 3 times. The FIRST is line 856 (_recovery_head_sha).
# We need to find the exact context to be sure we're targeting the right one.

# Find the FIRST occurrence (the _recovery_head_sha one)
first = content.find(old)
if first < 0:
    print('M7: pattern not found')
    raise SystemExit(1)

# Verify this is the recovery_head_sha line by checking context
ctx_start = max(0, first - 60)
ctx = content[ctx_start:first + len(old) + 30]
if '_recovery_head_sha' in ctx:
    new = 'git --git-dir="$PAD_DIR/stitchpad-git" rev-parse HEAD'
    content = content[:first] + new + content[first + len(old):]
    with open(src, 'w') as f:
        f.write(content)
    print('M7: replaced line 856 _git with $PAD_DIR/stitchpad-git (breaks on pasture-only pads)')
else:
    print(f'M7: first occurrence is not _recovery_head_sha line. Context: {ctx[:200]}')
    # Fallback: try to find specifically the recovery_head_sha line
    marker = '_recovery_head_sha="$(git --git-dir="$_git"'
    pos = content.find(marker)
    if pos > 0:
        new_marker = '_recovery_head_sha="$(git --git-dir="$PAD_DIR/stitchpad-git"'
        content = content[:pos] + new_marker + content[pos + len(marker):]
        with open(src, 'w') as f:
            f.write(content)
        print('M7: fallback — replaced _recovery_head_sha git dir with stitchpad-git')
    else:
        print('M7: could not find _recovery_head_sha line')
