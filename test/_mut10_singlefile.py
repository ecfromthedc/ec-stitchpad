"""Apply MUT10: make parse_tasks_merged single-source (ignore tasks_str)."""
import sys

src = sys.argv[1]

with open(src) as f:
    content = f.read()

old = 'for s in [pad_str, tasks_str] {'
new = 'for s in [pad_str] { // MUT10: tasks.md IGNORED'

if old in content:
    content = content.replace(old, new, 1)
    with open(src, 'w') as f:
        f.write(content)
    print('MUT10: parse_tasks_merged now ignores tasks_str')
elif 'for s in [pad_str' in content:
    print('MUT10: already mutated (pad_str only)')
else:
    # Debug: show what's around the expected location
    marker = 'parse_tasks_merged'
    pos = content.find(marker)
    if pos > 0:
        snippet = content[pos:pos+500]
        print(f'MUT10: parse_tasks_merged found but pattern mismatch. Context:')
        for i, line in enumerate(snippet.split('\n')[:15], 1):
            print(f'  {i}: {line}')
    else:
        print('MUT10: parse_tasks_merged not found in source')
