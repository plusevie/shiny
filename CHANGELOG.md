# changelog

## v1.0.0 — 2026-11-09

first tagged release. everything below is what shiny does as of now.

**setup** (`shiny setup`)
- apps from the Brewfile, macOS defaults, Dock contents, hostname, hosts blocklist
- patched jankyborders (macOS 27 Mission Control fix) as a launch agent
- Fastmail theming agent (single-instance), Rectangle layout, Helium set to restore tabs

**theming** (`shiny theme …`)
- one wallpaper + ten colour roles theme Ghostty, borders, Alfred, Helium, Beeper, Cider, Fastmail, SketchyBar and macOS accent / highlight / icon tint
- glass matched across apps against a checkerboard; Beeper and Fastmail floating surfaces get a solid blurred tint
- applying is parallel and cached: macOS first, then every app at once; `SHINY_TIMINGS=1` shows where the time goes
- Helium only restarts when it will restore your tabs
- even 10pt spacing between windows, screen edges and the bar (`WINDOW_GAP`)

**making themes** (see THEMES.md)
- `shiny theme new` fits the best existing scheme to an image and picks accents from it; `--scheme image` builds every colour from the image instead
- `shiny theme check` lints contrast and roles; `tests/eval-palette.py` scores the generator against the stock themes and yours
- 11 stock themes, including trail

**TUI** (`shiny`)
- SHINY banner, theme browser with wallpaper thumbnails and live previews, theme builder that compares the image-built palette with the closest schemes

**bar**
- spaces, front app, now playing (Apple Music / Cider), next calendar event, Things today count, wifi, battery, clock
