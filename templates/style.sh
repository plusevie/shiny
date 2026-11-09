# Shared look for every theme — themes only change colours.
#
# Measured against a checkerboard wallpaper (Nov 2026, macOS 27):
#  - Ghostty and Alfred use the same macOS window-blur API: the same BLUR gives
#    the same blur. It tops out around 80–90 (σ ≈ 40–48 px); higher does nothing.
#  - Beeper uses macOS "sidebar" vibrancy (fixed by the app, σ ≈ 80–96 px,
#    ~20% show-through). Ghostty/Alfred can't blur that much, so BLUR sits at
#    their maximum and OPACITY matches Beeper's show-through.
#  - Helium's new tab can't blur live: it gets a pre-blurred wallpaper with the
#    same wash baked in (libexec/frost.swift).
OPACITY=0.75           # Ghostty, Alfred, Helium new tab (≈25% show-through)
BLUR=90                # Ghostty background-blur, Alfred blur, frosted images
# macOS vibrancy (Beeper, Fastmail), measured Nov 9 2026 over solid black /
# grey / white wallpapers next to Ghostty: it adds a fixed grey and shows a bit
# less of the backdrop than Ghostty. shiny-apply works out each theme's wash
# over it from these (material_wash), so dark themes match too.
VIBRANCY_GREY=33       # vibrancy over pure black (sRGB 0–255)
VIBRANCY_SHOW=0.22     # how much of the backdrop vibrancy shows
GHOSTTY_SHOW=0.212     # how much Ghostty shows (measured; ≈ 1 - OPACITY after blur)
ALFRED_OPACITY=0.86    # Alfred: small window, so SURFACE at a bit more opacity (checkerboard-matched)
CIDER_OPACITY=0.20     # Cider: same vibrancy, wash tuned on a checkerboard to Ghostty's brightness
# Re-matched Nov 9 2026 against Ghostty over a 64px checkerboard (fire):
#   Ghostty lum 0.280 · Beeper 0.280 · Cider 0.28 · Alfred 0.279 · bar 0.283
# Small windows (Alfred, the bar) blur less of what's under them, so they use
# SURFACE (a step up from BG) with more opacity to land on the same brightness.
ICON_TINT_ALPHA=0.15   # macOS icon tint strength (it renders tints dark + saturated)

# Spacing (points), shared by AeroSpace (templates/aerospace.toml) and the bar:
# windows sit WINDOW_GAP from each other and the screen edges, and the bar sits
# WINDOW_GAP from the sides, the bottom, and the windows above it, so their
# edges line up. Measured on macOS 27: SketchyBar's y_offset counts double.
WINDOW_GAP=10
BAR_HEIGHT=34
