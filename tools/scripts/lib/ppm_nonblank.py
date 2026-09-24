#!/usr/bin/env python3
# Non-blank oracle for a P6 PPM: more than one distinct colour AND a
# meaningful per-channel spread. A solid clear / black / empty frame fails.
# Shared by render-smoke.sh (GLFW + sceneviewer-script captures) and
# render-oracle.sh (sceneviewer-script capture) -- one assertion, not two
# copies to keep in sync.
import sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()
if data[:2] != b"P6":
    print("not a P6 PPM"); sys.exit(1)
i = 2
def read_token(i):
    while i < len(data) and data[i:i+1].isspace():
        i += 1
    s = i
    while i < len(data) and not data[i:i+1].isspace():
        i += 1
    return data[s:i], i
wtok, i = read_token(i)
htok, i = read_token(i)
mtok, i = read_token(i)
i += 1
w, h, mx = int(wtok), int(htok), int(mtok)
pix = data[i:]
n = len(pix) // 3
if n == 0 or len(pix) < w * h * 3:
    print(f"truncated PPM: {w}x{h} maxval={mx} got {len(pix)} bytes, need {w*h*3}")
    sys.exit(1)
colors = set()
mins = [255, 255, 255]; maxs = [0, 0, 0]; sums = [0, 0, 0]
for p in range(0, n * 3, 3):
    r, g, b = pix[p], pix[p+1], pix[p+2]
    colors.add((r, g, b))
    for c, v in ((0, r), (1, g), (2, b)):
        sums[c] += v
        if v < mins[c]: mins[c] = v
        if v > maxs[c]: maxs[c] = v
means = [round(s / n, 1) for s in sums]
range_sum = sum(maxs[c] - mins[c] for c in range(3))
print(f"  {w}x{h}  distinct_colors={len(colors)}  mean={means}  "
      f"min={mins}  max={maxs}  range_sum={range_sum}")
if len(colors) <= 1 or range_sum <= 3:
    print("  -> BLANK"); sys.exit(1)
print("  -> NON-BLANK"); sys.exit(0)
