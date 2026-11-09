# making a shiny theme

a theme is a folder with two files:

```
~/.config/shiny/themes/<name>/     (yours — stock ones live in themes/)
  palette.sh      ten colour roles + a few settings
  wallpaper.jpg
```

that's all. blur, opacity, layout, fonts and icon-tint strength are shared by every theme (`templates/style.sh`), so a theme only ever chooses colours. you never touch the app configs: `templates/` turns the ten roles into ghostty, borders, alfred, helium, beeper, cider, fastmail, sketchybar and macos settings.

## the process

1. **pick a wallpaper.** dark images work best (the templates are tuned for dark themes). 5k+ images get scaled down to 5120px.
2. **generate.** either
   - `shiny` → `n` (the theme builder in the TUI): drop the image in, look at the options side by side — **from the image** (every colour built from the wallpaper) first, then the 8 best-fitting existing schemes — choose one, choose the two accents, name it, save. or
   - `shiny theme new -i ~/Pictures/wall.jpg [-n name]` (the same pipeline, picking the top suggestion; `--scheme`, `--accent`, `--accent2` override it, `shiny theme rank -i img` shows the ranking).
3. **check.** `shiny theme check <name>` (runs automatically after `new` and `edit`). errors stop the theme applying; warnings are taste (low contrast and similar).
4. **apply.** `shiny theme set <name>`, or Enter in the TUI. `shiny theme set` with no name gives a picker.
5. **tweak** (optional). `shiny theme edit <name>` opens the palette in `$EDITOR` and re-applies when you save. if only one app looks off, `shiny theme reload <target>` re-applies just that app (`ghostty`, `borders`, `alfred`, `helium`, `beeper`, `cider`, `fastmail`, `sketchybar`, `macos`, `wallpaper`) without the loading screen.

to make a **stock** theme (ships with shiny): `shiny theme new -i img -n name --stock`, run `shiny theme check name`, add a row to the table in the README, commit `themes/<name>/`.

## two ways to get colours

- **an existing scheme** (default for `theme new`): the eight base roles and the terminal's 16 colours come from a well-known scheme (tokyo night, catppuccin, rosé pine…); only the accents come from the image. safest readability, but the closest scheme can still be a step away from the image.
- **from the image** (`--scheme image`, first option in the TUI): every colour is made from the wallpaper. backgrounds and text are greys tinted with the image's overall colour, at the same lightness steps as the curated schemes (so contrast matches them); accents are the image's colour families lifted to a readable lightness; the terminal's 16 colours keep their meaning (red is still red) but lean towards the image's nearest colours. these themes ship a `ghostty-theme` file next to `palette.sh`.

## how generation works

`libexec/palette.py`, stdlib python, no network:

1. the image is shrunk to 96px and clustered (k-means in Lab) into ~10 colours.
2. every scheme in `libexec/schemes.json` is scored against them: how close the scheme's background is to the image's dark tones, and how close its accents are to the image's most striking colours. lowest score wins.
3. that scheme supplies the eight base roles (BG … FG_DIM). its accents are matched to the image by hue: ACCENT is the image's main colour, ACCENT2 its next distinct one.
4. SELECTION is swapped for a dark wash of ACCENT if the scheme's own selection clashes with it.
5. the macOS accent preset is the nearest of macOS's 8 colours to ACCENT.

all colours come from real, well-known schemes (tokyo night, catppuccin, rosé pine…), so text stays readable whatever the image.

**improving the picks:** `tests/eval-palette.py` scores the generator against every stock theme *and every theme of yours* built on a scheme — each one you make is another labelled example. run it after changing `palette.py`.

**adding a scheme:** copy its Ghostty theme file into `libexec/ghostty-themes/` (or use one of Ghostty's built-ins: `ghostty +list-themes`), then add an entry to `schemes.json`: `id`, `name`, `ghostty` (the theme file name), optionally `roles` to pin UI roles the 16 ANSI colours don't cover (BG_DARK, SURFACE, SELECTION, MUTED, COMMENT, FG_DIM — take them from the scheme's own spec), and `extra_accents` for its non-ANSI accent colours.

## palette.sh

```sh
THEME_BASE="Tokyo Night (Night)"  # shown in lists
GHOSTTY_THEME="TokyoNight Night"  # ghostty's own theme gives the 16 terminal colours
ACCENT_PRESET=4                   # macOS accent: -1 graphite 0 red 1 orange 2 yellow 3 green 4 blue 5 purple 6 pink
WALLPAPER="wallpaper.jpg"

BG="#1A1B26"         # window background
BG_DARK="#16161E"    # frames, omnibox
SURFACE="#292E42"    # borders, dividers, inactive window border, the bar
SELECTION="#283457"  # selected rows, text selection
MUTED="#414868"      # shortcuts, scrollbar
COMMENT="#565F89"    # subtext, inactive tabs
FG="#C0CAF5"         # primary text
FG_DIM="#A9B1D6"     # secondary text
ACCENT="#7AA2F7"     # focus border, icons, links, text highlight, icon tint
ACCENT2="#FF9E64"    # cursor, shortcuts, search selection
```

`GHOSTTY_THEME` can also be a file next to `palette.sh` (themes built from the image use `ghostty-theme`).

optional: `ICON_TINT="#RRGGBB"` (icon tint other than ACCENT), and any `templates/style.sh` setting (e.g. `OPACITY=0.8`) to override it for this theme only.

## what `check` looks at

| | error below | warning below |
|---|---|---|
| FG on BG | 4.5:1 | 7:1 |
| FG_DIM on BG | 3:1 | 4.5:1 |
| COMMENT on BG | 1.8:1 | 2.3:1 |
| ACCENT, ACCENT2 on BG | 2:1 | 3:1 |
| FG on SELECTION | 3:1 | 4.5:1 |
| BG on ACCENT (bar pill text) | 2:1 | 3:1 |

plus: every role is `#RRGGBB`, the ghostty theme exists, the wallpaper exists, ACCENT_PRESET is -1…6, BG_DARK is darker than BG, SURFACE is visibly different from BG, light backgrounds get a warning.

## templates (for changing how *every* theme looks)

`templates/*` are the app configs with `{{PLACEHOLDERS}}`: any role (`{{ACCENT}}` → `#7AA2F7`), `{{ROLE_RGB}}` (`122, 162, 247`), `{{ROLE_ARGB}}` (`0xff7aa2f7`), plus `THEME`, `GHOSTTY_THEME`, `OPACITY`, `BLUR`, `ALFRED_BLUR`, `ALPHA_HEX`, `ALFRED_ALPHA_HEX`, `MATERIAL_ALPHA_HEX`, `CIDER_ALPHA_HEX`, `ACCENT_HUE`, `VERSION`. an unknown placeholder stops the apply. `libexec/shiny-apply --render <name> <dir>` renders everything into a folder without touching any app — use it to diff a template change across themes.

to theme a new app: add a template, an `apply_<app>` function in `libexec/shiny-apply`, and the app's name to `TARGETS` there.
