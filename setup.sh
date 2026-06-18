#!/usr/bin/env bash
#
# ==SHINY==
# A setup utility for macOS
#
# git clone <repo> && cd <repo>
#   ./setup.sh
#
# one-shot by claude and edited/cleaned up by evie
# thanks claude
#
# expects wallpaper.png in root folder, and a valid brewfile :3
#

set -euo pipefail

echo SHINY!!! :D

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────

WALLPAPER_FILE="wallpaper.png"

# Dock contents, left → right. Paths must match the installed .app bundle name
# EXACTLY, dockutil silently skips anything it can't find. Apple's own apps live
# under /System/Applications; brew/MAS apps under /Applications.
DOCK_APPS=(
  "/Applications/iTerm.app"
  "/Applications/Safari.app"
  "/System/Applications/Messages.app"
  "/System/Applications/Mail.app"
  "/Applications/Signal.app"
  "/Applications/Telegram.app"
  "/Applications/Things3.app"
  "/System/Applications/Calendar.app"
  "/System/Applications/Music.app"
  "/System/Applications/Maps.app"
  "/Applications/Affinity.app"
  "/Applications/Zed.app"
  "/Applications/Claude.app"
  "/System/Applications/System Settings.app"
)

# ─────────────────────────────────────────────────────────────────────────────
# Plumbing
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREWFILE="${SCRIPT_DIR}/Brewfile"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; BLUE=$'\033[34m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=""; BLUE=""; YELLOW=""; RED=""; RESET=""
fi
info() { printf '%s==>%s %s\n' "${BLUE}${BOLD}" "${RESET}" "$*"; }
warn() { printf '%s==> WARNING:%s %s\n' "${YELLOW}${BOLD}" "${RESET}" "$*" >&2; }
die()  { printf '%s==> ERROR:%s %s\n'   "${RED}${BOLD}"    "${RESET}" "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ -f "$BREWFILE" ]] || die "No Brewfile found next to this script at: $BREWFILE"

# Grab sudo once, keep it warm for the whole run.
info "This script needs sudo for Homebrew, hostname, and a few system settings."
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# 1. XCLT
# ─────────────────────────────────────────────────────────────────────────────
install_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    info "Xcode CLT already present."
    return
  fi
  info "Installing Xcode Command Line Tools (a GUI dialog will appear)…"
  xcode-select --install || true
  info "Waiting for CLT install to finish — complete the dialog if prompted…"
  until xcode-select -p >/dev/null 2>&1; do sleep 5; done
  info "Xcode CLT installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Homebrew + Brewfile
# ─────────────────────────────────────────────────────────────────────────────
install_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    info "Installing Homebrew…"
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  # Load brew into this shell, and persist for future logins.
  if [[ -x /opt/homebrew/bin/brew ]]; then
    BREW_BIN=/opt/homebrew/bin/brew          # Apple Silicon
  elif [[ -x /usr/local/bin/brew ]]; then
    BREW_BIN=/usr/local/bin/brew             # Intel
  else
    die "Homebrew installed but brew binary not found."
  fi
  eval "$("$BREW_BIN" shellenv)"
  if ! grep -q 'brew shellenv' "${HOME}/.zprofile" 2>/dev/null; then
    echo "eval \"\$(${BREW_BIN} shellenv)\"" >> "${HOME}/.zprofile"
  fi
  info "Homebrew ready ($("$BREW_BIN" --version | head -1))."
}

run_bundle() {
  # MAS apps in the Brewfile need an active App Store session first — mas can't
  # sign in (Apple removed CLI sign-in), so gate on it here.
  info "Open the App Store app and sign in with your Apple ID now."
  read -r -p "Press Enter once you're signed in (or to skip MAS apps)… " _

  info "Running brew bundle from ${BREWFILE}…"
  brew bundle --file="$BREWFILE" || warn "brew bundle reported errors — check output above."

  # dockutil is required by the dock step; ensure it's here regardless of Brewfile.
  command -v dockutil >/dev/null 2>&1 || brew install dockutil
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. System defaults
# ─────────────────────────────────────────────────────────────────────────────
set_defaults() {
  info "Applying system defaults…"

  # Appearance — graphite/gray accent + matching highlight.
  defaults write -g AppleAccentColor -int -1
  defaults write -g AppleHighlightColor -string "0.847059 0.847059 0.862745 Graphite"

  # Keyboard / input  (key-repeat changes need a logout to fully apply)
  defaults write -g InitialKeyRepeat -int 15
  defaults write -g KeyRepeat -int 2
  defaults write -g ApplePressAndHoldEnabled -bool false
  defaults write -g AppleKeyboardUIMode -int 3
  defaults write -g NSAutomaticCapitalizationEnabled -bool false
  defaults write -g NSAutomaticSpellingCorrectionEnabled -bool false
  defaults write com.apple.AppleMultitouchMouse MouseButtonMode -string "TwoButton"
  defaults write com.apple.driver.AppleBluetoothMultitouch.mouse MouseButtonMode -string "TwoButton"

  # Finder
  defaults write com.apple.finder AppleShowAllFiles -bool true
  defaults write -g AppleShowAllExtensions -bool true
  defaults write com.apple.finder ShowPathbar -bool true
  defaults write com.apple.finder ShowStatusBar -bool true
  defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"
  defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
  defaults write com.apple.finder _FXSortFoldersFirst -bool true
  defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true

  # Dock — autohide on, but require a 5-second edge dwell before it reveals.
  defaults write com.apple.dock autohide -bool true
  defaults write com.apple.dock autohide-delay -float 5
  defaults write com.apple.dock autohide-time-modifier -float 0.15
  defaults write com.apple.dock show-recents -bool false
  defaults write com.apple.dock tilesize -int 48
  defaults write com.apple.dock mru-spaces -bool false

  # Screenshots → ~/Screenshots, png, no window shadow
  mkdir -p "${HOME}/Screenshots"
  defaults write com.apple.screencapture location -string "${HOME}/Screenshots"
  defaults write com.apple.screencapture type -string "png"
  defaults write com.apple.screencapture disable-shadow -bool true

  # Misc quality-of-life
  defaults write -g NSDocumentSaveNewDocumentsToCloud -bool false
  defaults write -g NSWindowResizeTime -float 0.001
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Wallpaper
# ─────────────────────────────────────────────────────────────────────────────
set_wallpaper() {
  local src="${SCRIPT_DIR}/${WALLPAPER_FILE}"
  if [[ ! -f "$src" ]]; then
    warn "No ${WALLPAPER_FILE} in the repo — skipping wallpaper."
    return
  fi

  # Copy out of the repo into a stable location — macOS keeps a live reference to
  # the wallpaper path, so pointing it at the working/cloned dir is asking for it
  # to break if the folder moves. ~/Pictures is safe.
  local dest="${HOME}/Pictures/${WALLPAPER_FILE}"
  cp -f "$src" "$dest"

  # Sets the picture on the current space of every display. NOTE: wallpaper
  # scripting is the fragile bit on recent macOS; if this doesn't stick across
  # all spaces, `brew install wallpaper` and swap the line below for:
  #     wallpaper set "$dest"
  # Lock screen has no clean CLI — on Sequoia it follows the desktop wallpaper
  # unless overridden in System Settings, so this normally covers it.
  osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"$dest\"" \
    && info "Wallpaper set from ${WALLPAPER_FILE}." \
    || warn "Could not set wallpaper via osascript — see note in set_wallpaper()."
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Dock contents
# ─────────────────────────────────────────────────────────────────────────────
set_dock() {
  info "Building Dock…"
  dockutil --no-restart --remove all >/dev/null 2>&1 || true
  local app
  for app in "${DOCK_APPS[@]}"; do
    if [[ -e "$app" ]]; then
      dockutil --no-restart --add "$app" >/dev/null 2>&1 || warn "Couldn't add to Dock: $app"
    else
      warn "Not installed, skipping in Dock: $app"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Hostname
# ─────────────────────────────────────────────────────────────────────────────
set_hostname() {
  local name
  read -r -p "Desired hostname for this machine: " name
  [[ -z "$name" ]] && { warn "Empty hostname — skipping."; return; }

  # LocalHostname (Bonjour/.local) can't contain spaces or odd chars.
  local local_name
  local_name="$(echo "$name" | tr ' ' '-' | tr -cd '[:alnum:]-')"

  sudo scutil --set ComputerName  "$name"
  sudo scutil --set HostName      "$local_name"
  sudo scutil --set LocalHostName "$local_name"
  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server \
    NetBIOSName -string "$local_name" 2>/dev/null || true
  info "Hostname set to '${name}' (local: ${local_name})."
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Hosts
# ─────────────────────────────────────────────────────────────────────────────
write_hosts() {
    sudo cp /etc/hosts /etc/hosts.old # Backup old hostfile
    curl https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-social/hosts | sudo tee /etc/hosts > /dev/null # Grab porn and social blocker, tee into place
    sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder # "Restart" network stack
    sudo chflags uchg /etc/hosts # Lock the file

}

# ─────────────────────────────────────────────────────────────────────────────
# Run
# ─────────────────────────────────────────────────────────────────────────────
install_clt
install_brew
run_bundle
set_defaults
set_wallpaper
set_dock
set_hostname
write_hosts

# Apply: restart the affected UI services. Key-repeat/appearance still want a logout.
killall Finder Dock SystemUIServer 2>/dev/null || true

cat <<EOF

${BOLD}Done.${RESET}

  • Log out and back in for keyboard repeat + accent colour to fully apply.
  • ${BOLD}Don't forget to log in to Tailscale${RESET} — run:  tailscale up
  • Sanity check what didn't install:  brew bundle check --file="$BREWFILE"

EOF
