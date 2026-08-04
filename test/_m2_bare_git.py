"""M2: Replace one git --git-dir="$_git" rev-parse HEAD with bare git rev-parse HEAD."""
import sys
src = sys.argv[1]
with open(src) as f:
    content = f.read()
old = 'git --git-dir="$_git" rev-parse HEAD'
new = 'git rev-parse HEAD'
count = content.count(old)
content = content.replace(old, new, 1)
with open(src, 'w') as f:
    f.write(content)
print(f'M2: replaced 1 of {count} occurrences with bare git call')
