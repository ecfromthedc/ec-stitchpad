"""M1: Swap pasture-git and stitchpad-git resolution order in both functions."""
import sys

src = sys.argv[1]
with open(src) as f:
    lines = f.readlines()

# Find and swap within the _git resolution blocks
i = 0
swapped = 0
while i < len(lines) - 1:
    li = lines[i]
    # Match first resolution line with pasture-git
    if ('pasture-git' in li and '$PAD_DIR/pasture-git' in li
            and '_git=' in li and 'stitchpad-git' not in li):
        lj = lines[i + 1]
        if ('stitchpad-git' in lj and '$PAD_DIR/stitchpad-git' in lj
                and '_git=' in lj):
            # Swap: change pasture→stitchpad and stitchpad→pasture
            def swap_line(line):
                return (line.replace('stitchpad-git', 'TMPGIT___')
                           .replace('pasture-git', 'stitchpad-git')
                           .replace('TMPGIT___', 'pasture-git'))
            lines[i] = swap_line(lj)
            lines[i + 1] = swap_line(li)
            swapped += 1
            i += 1
    i += 1

with open(src, 'w') as f:
    f.writelines(lines)

print(f'M1: swapped {swapped} resolution pairs')
