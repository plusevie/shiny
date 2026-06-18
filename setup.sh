#!/usr/bin/env bash
#
# ==SHINY==
# A setup utility for macOS
#
# Usually run as `shiny setup` (install: see README). Safe to re-run: every
# step checks what's already done.
#
#   shiny setup          interactive: pick steps, answer prompts
#   shiny setup --yes    run everything, skip prompts (keeps hostname etc.)
#
# one-shot by claude and edited/cleaned up by evie
# thanks claude
#
# expects a valid brewfile and themes/<THEME>/ (palette.sh + wallpaper) :3
#

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────

# Colour theme to apply (see: shiny theme list). Layout/blur
# live in templates/ and are shared; themes only change colours + wallpaper.
# Keeps whatever theme you're already on; falls back to solarflare.
THEME="$(cat "${HOME}/.config/shiny/current" 2>/dev/null || echo solarflare)"

YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Dock contents, left → right. Paths must match the installed .app bundle name
# EXACTLY, dockutil silently skips anything it can't find. Apple's own apps live
# under /System/Applications; brew/MAS apps under /Applications.
DOCK_APPS=(
  "/Applications/Ghostty.app"
  "/Applications/Helium.app"
  "/Applications/Things3.app"
  "/System/Applications/Calendar.app"
  "/System/Applications/Messages.app"
  "/Applications/Fastmail.app"
  "/Applications/Beeper Desktop.app"
  "/Applications/Claude.app"
  "/System/Applications/Music.app"
  "/System/Applications/System Settings.app"
)

# ─────────────────────────────────────────────────────────────────────────────
# Plumbing
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHINY_HOME="$SCRIPT_DIR"
BREWFILE="${SCRIPT_DIR}/Brewfile"
# shellcheck source=libexec/lib.sh
source "${SCRIPT_DIR}/libexec/lib.sh"   # info/warn/die, colours, banner
BOLD="$B"; RESET="$N"

echo; banner; echo

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
  if ((YES)); then
    info "Skipping the App Store sign-in prompt (--yes); MAS apps install if you're already signed in."
  else
    info "Open the App Store app and sign in with your Apple ID (skip if you already are)."
    read -r -p "Press Enter once you're signed in (or to skip MAS apps)… " _
  fi

  info "Running brew bundle from ${BREWFILE}…"
  # Newer Homebrew refuses third-party taps until trusted (borders, sketchybar).
  brew trust felixkratz/formulae >/dev/null 2>&1 || true
  brew bundle --file="$BREWFILE" || warn "brew bundle reported errors — check output above."

  # dockutil is required by the dock step; ensure it's here regardless of Brewfile.
  command -v dockutil >/dev/null 2>&1 || brew install dockutil
  # wallpaper (sindresorhus/macos-wallpaper) is required by the theme step; ensure it's here regardless of Brewfile.
  command -v wallpaper >/dev/null 2>&1 || brew install wallpaper
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. System defaults
# ─────────────────────────────────────────────────────────────────────────────
set_defaults() {
  info "Applying system defaults…"

  # Appearance (accent, text highlight, icon tint) is set by the theme step.

  # Keyboard / input  (key-repeat changes need a logout to fully apply)
  defaults write -g InitialKeyRepeat -int 15
  defaults write -g KeyRepeat -int 2
  defaults write -g ApplePressAndHoldEnabled -bool false
  defaults write -g AppleKeyboardUIMode -int 3
  defaults write -g NSAutomaticCapitalizationEnabled -bool false
  defaults write -g NSAutomaticSpellingCorrectionEnabled -bool false
  defaults write com.apple.AppleMultitouchMouse MouseButtonMode -string "TwoButton"
  defaults write com.apple.driver.AppleBluetoothMultitouch.mouse MouseButtonMode -string "TwoButton"

  # Helium: "On startup → Continue where you left off", so theme switches can
  # restart it without losing tabs. Chromium rewrites Preferences while it
  # runs, so only while it's closed.
  local hp="${HOME}/Library/Application Support/net.imput.helium/Default/Preferences"
  if [[ -f "$hp" ]] && ! app_running Helium; then
    /usr/bin/python3 -c 'import json, sys
p = json.load(open(sys.argv[1])); p.setdefault("session", {})["restore_on_startup"] = 1
json.dump(p, open(sys.argv[1], "w"), separators=(",", ":"))' "$hp" || warn "Couldn't set Helium's startup option."
  fi

  # Rectangle: Magnet-style shortcuts, gaps, room for the bottom bar.
  [[ -d /Applications/Rectangle.app ]] && "${SCRIPT_DIR}/libexec/rectangle-config" || true

  # Finder
  defaults write com.apple.finder AppleShowAllFiles -bool true
  defaults write -g AppleShowAllExtensions -bool true
  defaults write com.apple.finder ShowPathbar -bool true
  defaults write com.apple.finder ShowStatusBar -bool true
  defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"
  defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
  defaults write com.apple.finder _FXSortFoldersFirst -bool true
  defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true

  # Dock — hidden (huge autohide delay; it still runs Mission Control / Cmd-Tab).
  defaults write com.apple.dock autohide -bool true
  defaults write com.apple.dock autohide-delay -float 1000   # effectively hidden: SketchyBar shows spaces
  defaults write com.apple.dock no-bouncing -bool true
  defaults write com.apple.dock autohide-time-modifier -float 0.15
  defaults write com.apple.dock expose-animation-duration -float 0.1
  defaults write com.apple.dock show-recents -bool false
  # Ctrl+1…9 → Switch to Desktop N (SketchyBar's desktop pills send these).
  local n code codes=(18 19 20 21 23 22 26 28 25)
  for n in 0 1 2 3 4 5 6 7 8; do
    code=${codes[$n]}
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add $((118 + n)) \
      "<dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array><integer>65535</integer><integer>${code}</integer><integer>262144</integer></array><key>type</key><string>standard</string></dict></dict>"
  done
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || true
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
  defaults write -g NSAutomaticWindowAnimationsEnabled -bool false
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Dock contents
# ─────────────────────────────────────────────────────────────────────────────
dock_current() {
  defaults read com.apple.dock persistent-apps 2>/dev/null \
    | sed -nE 's/.*"_CFURLString" = "file:\/\/(.*)\/";/\1/p' \
    | /usr/bin/python3 -c 'import sys,urllib.parse; [print(urllib.parse.unquote(l.strip())) for l in sys.stdin]'
}

set_dock() {
  local want=() app
  for app in "${DOCK_APPS[@]}"; do [[ -e "$app" ]] && want+=("$app"); done
  if [[ "$(dock_current)" == "$(printf '%s\n' "${want[@]}")" ]]; then
    info "Dock already matches."; return
  fi
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
# 5. Hostname
# ─────────────────────────────────────────────────────────────────────────────
set_hostname() {
  local name current
  current="$(scutil --get ComputerName 2>/dev/null || true)"
  if ((YES)); then info "Keeping hostname '${current}' (--yes)."; return; fi
  read -r -p "Hostname for this machine [${current}]: " name
  [[ -z "$name" || "$name" == "$current" ]] && { info "Keeping hostname '${current}'."; return; }

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
# 6. Hosts
# ─────────────────────────────────────────────────────────────────────────────
write_hosts() {
  # StevenBlack porn + social blocklist. Idempotent: keeps the very first
  # backup, only rewrites (and flushes DNS) when the list actually changed.
  local tmp; tmp="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-social/hosts -o "$tmp" \
    || { warn "Couldn't download the hosts blocklist — skipping."; rm -f "$tmp"; return; }
  if cmp -s "$tmp" /etc/hosts; then
    info "Hosts blocklist already up to date."
  else
    [[ -f /etc/hosts.old ]] || sudo cp /etc/hosts /etc/hosts.old
    sudo chflags nouchg /etc/hosts
    sudo cp "$tmp" /etc/hosts
    sudo chflags uchg /etc/hosts   # lock it
    sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
    info "Hosts blocklist installed (original kept at /etc/hosts.old)."
  fi
  rm -f "$tmp"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Theme — colours everywhere (Ghostty, borders, Alfred, Helium, Beeper, Fastmail, macOS, wallpaper)
# ─────────────────────────────────────────────────────────────────────────────
set_theme() {
  # Theme switches only restart what's already running, so start the bar here.
  command -v sketchybar >/dev/null 2>&1 && brew services start sketchybar >/dev/null 2>&1 || true
  "${SCRIPT_DIR}/libexec/shiny-apply" "$THEME" || warn "Theme '${THEME}' didn't fully apply — see above."
}

# ─────────────────────────────────────────────────────────────────────────────
# Recipe — pick which steps to run
# ─────────────────────────────────────────────────────────────────────────────

STEP_IDS=(clt brew defaults dock hostname hosts borders fastmail theme)
STEP_LABELS=(
  "Xcode Command Line Tools"
  "Homebrew + Brewfile"
  "System defaults"
  "Dock contents"
  "Hostname"
  "Hosts (porn/social blocklist)"
  "Patched JankyBorders (macOS 27 Mission Control fix)"
  "Fastmail theming (launch agent that injects the theme CSS)"
  "Theme: ${THEME} (colours + wallpaper)"
)
STEP_ENABLED=(1 1 1 1 1 1 1 1 1)

print_recipe() {
  info "Recipe — steps that will run:"
  local i mark
  for i in "${!STEP_IDS[@]}"; do
    mark="[ ]"
    [[ "${STEP_ENABLED[$i]}" == "1" ]] && mark="[x]"
    printf '  %s %d) %s\n' "$mark" "$((i + 1))" "${STEP_LABELS[$i]}"
  done
}

choose_recipe() {
  { [[ -t 0 ]] && ! ((YES)); } || { info "Running the full recipe."; return; }
  local picks p idx
  while true; do
    print_recipe
    read -r -p "Toggle step numbers (space-separated), or Enter to run as shown above: " picks
    [[ -z "$picks" ]] && break
    for p in $picks; do
      [[ "$p" =~ ^[0-9]+$ ]] || continue
      idx=$((p - 1))
      (( idx >= 0 && idx < ${#STEP_ENABLED[@]} )) || continue
      STEP_ENABLED[$idx]=$(( 1 - STEP_ENABLED[$idx] ))
    done
  done
}

step_enabled() {
  local id="$1" i
  for i in "${!STEP_IDS[@]}"; do
    [[ "${STEP_IDS[$i]}" == "$id" ]] && [[ "${STEP_ENABLED[$i]}" == "1" ]] && return 0
  done
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Run
# ─────────────────────────────────────────────────────────────────────────────
choose_recipe

step_enabled clt      && install_clt
step_enabled brew     && { install_brew; run_bundle; }
step_enabled defaults && set_defaults
step_enabled dock     && set_dock
step_enabled hostname && set_hostname
step_enabled hosts    && write_hosts
step_enabled borders  && { "${SCRIPT_DIR}/libexec/install-borders" || warn "Patched borders failed — Homebrew borders still works."; }
step_enabled fastmail && { "${SCRIPT_DIR}/libexec/install-fastmail" || warn "Fastmail theming failed — Fastmail itself is untouched."; }
step_enabled theme    && set_theme

# Apply: restart the affected UI services. Key-repeat/appearance still want a logout.
killall Finder Dock SystemUIServer 2>/dev/null || true

cat <<EOF

${BOLD}Done.${RESET}

  • Log out and back in for keyboard repeat + accent colour to fully apply.
  • ${BOLD}Don't forget to log in to Tailscale${RESET} — run:  tailscale up
  • Sanity check what didn't install:  brew bundle check --file="$BREWFILE"

EOF
