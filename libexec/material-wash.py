#!/usr/bin/env python3
"""material-wash.py <BG> <OPACITY> <VIBRANCY_GREY> <VIBRANCY_SHOW> <GHOSTTY_SHOW>
→ "#RRGGBB AA AA2": the wash shiny lays over macOS vibrancy (Beeper, Fastmail)
so it matches Ghostty's glass for this theme's background. AA is the alpha for
one layer (Fastmail); AA2 the per-layer alpha when the wash is painted twice
(Beeper's html and body), giving the same result.

Model (measured over solid black / grey / white wallpapers, see style.sh):
  vibrancy      V = GREY + SHOW·W          (W: blurred wallpaper, sRGB 0–255)
  with a wash   (1-A)·V + A·C
  Ghostty       OPACITY·BG + 1 + GHOSTTY_SHOW·W
Vibrancy's own grey is lighter than a dark theme's glass, so no wash matches
at every W; this takes the wash (alpha A, colour C) with the least error over
typical wallpapers (W 0–160)."""
import math, sys

bg = [int(sys.argv[1][i:i + 2], 16) for i in (1, 3, 5)]
op, o, s, g = (float(v) for v in sys.argv[2:6])
Ws = range(0, 161, 10)
t = [op * c + 1 for c in bg]
best = None
for i in range(2, 91):
    A = i / 100
    C = [max(0.0, min(255.0, sum(tc + g * w - (1 - A) * (o + s * w) for w in Ws) / len(Ws) / A)) for tc in t]
    err = sum(((1 - A) * (o + s * w) + A * cc - tc - g * w) ** 2 for cc, tc in zip(C, t) for w in Ws)
    if best is None or err < best[0] - 1e-6:
        best = (err, A, C)
_, A, C = best
A2 = 1 - math.sqrt(1 - A)
print("#%02X%02X%02X %02X %02X" % (round(C[0]), round(C[1]), round(C[2]), round(A * 255), round(A2 * 255)))
