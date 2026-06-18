# Brewfile — fresh machine provision
# Usage:
#   1. Install Homebrew
#   2. Sign into the App Store app (required before mas lines work)
#   3. brew bundle --file=~/Brewfile
# Idempotent; re-run anytime to correct drift.

# --- CLI ---
brew "mas"                      # required for the App Store installs below
cask "tailscale"                # GUI app, swap to brew "tailscale" for CLIo

# --- Casks (direct download) ---
cask "affinity"                 # Unified, v3
cask "alfred"                   # Alfred 5
cask "alt-tab"
cask "bitwarden"
cask "blender"
cask "claude"
cask "claude-code"              # CC CLI - no auto-update
cask "figma"
cask "github"
cask "iterm2"
cask "jordanbaird-ice"          # "Ice" menu-bar manager
cask "notion"
cask "signal"
cask "telegram"
cask "the-unarchiver"
cask "transmission"
cask "visual-studio-code"
cask "zed"
cask "hammerspoon"

# --- Mac App Store only ---
# Confirm IDs post-signin with `mas search "<name>"` if any line fails.
mas "Amphetamine", id: 937984704
mas "Magnet", id: 441258766
mas "ColorSlurp", id: 1287239339
mas "Apple Configurator", id: 1037126344
mas "Things 3", id: 904280696      # verify: mas search "Things"
mas "StepTwo", id: 1448916662      # verify: mas search "StepTwo"
