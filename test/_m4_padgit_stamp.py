"""M4: In journal_begin .base-sha stamp (3rd occurrence), replace _git with PAD_GIT.
PAD_GIT is unset on pasture-only pads → empty .base-sha stamp."""
import sys
src = sys.argv[1]
with open(src) as f:
    content = f.read()
old = 'git --git-dir="$_git" rev-parse HEAD'
new = 'git --git-dir="${PAD_GIT:-}" rev-parse HEAD'
positions = []
pos = -1
while True:
    pos = content.find(old, pos + 1)
    if pos < 0: break
    positions.append(pos)
if len(positions) >= 3:
    target = positions[2]
    content = content[:target] + new + content[target + len(old):]
    print(f'M4: replaced 3rd occurrence (pos={target}, journal_begin line 976)')
else:
    print(f'M4: only {len(positions)} occurrences, need 3')
with open(src, 'w') as f:
    f.write(content)
