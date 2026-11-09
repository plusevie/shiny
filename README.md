# shiny

opinionated post-install script + theming engine for my macos machines. targets golden gate (macOS 27) on apple silicon, installs some software, sets some defaults, and themes everything from one wallpaper. gets me most of the way there to a machine set up how i like it.

mainly storing it here for my own use, but it's public if you want to build upon it. i have a weird workflow so its kinda weird and opinionated. lol.

provided as-is with no warranty. project contains ai code so no copyright whatsoever 'cause that'd be a bit hypocritical.

## install

```sh
curl -fsSL https://raw.githubusercontent.com/plusevie/shiny/main/install.sh | bash
```

clones shiny to `~/.local/share/shiny` and puts a `shiny` command on your PATH. run it again to update (or `shiny update`).

## use

```sh
shiny                       # the TUI: browse/apply themes, build new ones from an image
shiny setup                 # apps (Brewfile), defaults, Dock, patched borders, theme — safe to re-run
shiny setup --yes           # same, no prompts

shiny theme list            # * = current
shiny theme set [name]      # apply (no name: pick from a list)
shiny theme new -i ~/Pictures/wall.jpg [-n name] [--set]
shiny theme show [name]     # print a theme's colours
shiny theme edit [name]     # open its palette in $EDITOR, re-applies if current
shiny theme remove [name]   # delete one of your themes
shiny theme check [name|all]  # lint a palette (contrast, missing roles)
shiny theme reload [target] # re-apply the current theme, or one app of it
shiny theme rank -i img     # which colour schemes fit an image
shiny theme schemes         # schemes themes can be based on
```

## themes

a theme is a wallpaper + a palette of ten colour roles. everything else (blur, opacity, layout, icon tint strength) is shared in `templates/style.sh`, so every theme looks like part of the same system.

full guide to making and tuning themes: [THEMES.md](THEMES.md).

`shiny theme new` (or `n` in the TUI, which lets you compare the best-fitting schemes and pick accents) builds a theme from any image: it picks the existing colour scheme that fits the image best (tokyo night, catppuccin, rosé pine, kanagawa, everforest, gruvbox, nord, dracula… see `libexec/schemes.json`), then that scheme's accents that match the image — or, with `--scheme image`, builds every colour from the image itself. override with `--scheme`, `--accent`, `--accent2`, or just `shiny theme edit` after.

| theme | based on |
|---|---|
| solarflare | tokyo night (night) |
| city | nord |
| fire | kanagawa wave |
| forest | everforest dark (medium) |
| gradient | catppuccin macchiato |
| meteor | gruvbox dark |
| mountain | rosé pine |
| creation | catppuccin mocha |
| hansel | nightfox |
| snowfall | iceberg dark |
| trail | kanagawa dragon |

stock themes live in `themes/`, yours in `~/.config/shiny/themes/` (yours win if names clash).

**what a theme touches:** ghostty, jankyborders, alfred, helium, beeper, macos accent / text highlight / icon tint, wallpaper.

- **alfred:** `open ~/.local/share/shiny/alfred/shiny-theme.alfredworkflow` once, then type `theme` to switch.
- **helium:** one-time *Load unpacked* of `~/Library/Application Support/shiny/helium-theme` in `chrome://extensions` (developer mode). chromium only reads a theme at launch, so shiny relaunches helium on a switch — but only when *On startup → Continue where you left off* is on (`shiny setup` turns it on while helium is closed), so you never lose tabs. otherwise restart it yourself (`SHINY_RESTART_HELIUM=1` forces it).
- **macos text highlight:** apps pick it up when they next launch; shiny relaunches finder for you.
- **beeper:** themed through its `custom.css`, live.
- **speed:** everything except the macOS recolour runs in parallel; `SHINY_TIMINGS=1 shiny theme set <name>` prints how long each app took.
- **loading screen:** while a theme applies, the screen dips to black so the dock/finder/widget restarts and app relaunches happen out of sight. click to dismiss early; `SHINY_CURTAIN=0 shiny theme <name>` to skip it.
- **blur:** ghostty + alfred use macOS's window blur (maxes out around 90); beeper uses macOS vibrancy. measured against a checkerboard so they match as closely as they can.

## windows

[AeroSpace](https://github.com/nikitabobko/AeroSpace) tiles windows (no SIP changes needed), with its [default shortcuts](https://nikitabobko.github.io/AeroSpace/guide#default-config) on Option: `opt+h/j/k/l` focus, `opt+shift+h/j/k/l` move, `opt+1…9` / `opt+a…z` workspace, `opt+shift+…` send a window there, `opt+/` and `opt+,` layout, `opt+shift+;` service mode (`r` reset layout, `f` float, `opt+shift+h/j/k/l` join into a stack). from the old Rectangle setup: `ctrl+opt+←/→/↑` move a window to that side, `ctrl+opt+return` fullscreen. the bar shows workspaces that have windows. gaps match the bar (`WINDOW_GAP` in `templates/style.sh`); the config is `templates/aerospace.toml`.

## notes

- `shiny setup` installs a patched jankyborders (1.9.0 + the macOS 27 mission control fix, upstream issues #147/#209) as a launch agent. undo: `~/.local/share/shiny/libexec/install-borders --uninstall`.
- don't forget to log in to tailscale: `tailscale up`.
