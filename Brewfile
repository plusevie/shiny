# Brewfile — fresh machine provision
# Usage:
#   1. Install Homebrew
#   2. Sign into the App Store app (required before mas lines work)
#   3. brew bundle --file=~/Brewfile
# Idempotent; re-run anytime to correct drift.

# --- CLI ---
brew "mas"                      # required for the App Store installs below
brew "wallpaper"                # sindresorhus/macos-wallpaper CLI - osascript/System Events wallpaper setting is unreliable on Golden Gate
brew "felixkratz/formulae/borders"  # JankyBorders - focused-window borders
brew "felixkratz/formulae/sketchybar"  # bottom bar: desktops, clock, battery (themed by shiny)
cask "font-sf-pro"              # SF Pro + SF Symbols glyphs for SketchyBar
cask "tailscale-app"            # GUI app (cask renamed from "tailscale"), swap to brew "tailscale" for CLI

# --- Casks (direct download) ---
cask "affinity"                 # Unified, v3
cask "alfred"                   # Alfred 5
cask "bitwarden"
cask "claude"
cask "claude-code"              # CC CLI - no auto-update
cask "figma"
cask "thaw"
cask "nikitabobko/tap/aerospace"  # i3-style tiling window manager (Option key; config from shiny)
cask "notion"
cask "helium-browser"
cask "ghostty"
cask "beeper"
cask "fastmail"
cask "swiftcord"
cask "qlab"
cask "displaperture"
cask "macs-fan-control"
cask "openlogi"
# Manual installs (no cask): DxO PhotoLab 9, LUMIX Tether, onetwo (own build)

# --- Mac App Store only ---
# Confirm IDs post-signin with `mas search "<name>"` if any line fails.
mas "Amphetamine", id: 937984704
mas "ColorSlurp", id: 1287239339
mas "Apple Configurator", id: 1037126344
mas "Things 3", id: 904280696      # verify: mas search "Things"
mas "StepTwo", id: 1448916662      # verify: mas search "StepTwo"
mas "Mononote", id: 6788222857
mas "Developer", id: 640199958
mas "Keynote", id: 361285480
mas "Numbers", id: 361304891
mas "Pages", id: 361309726
mas "Xcode", id: 497799835         # large download
