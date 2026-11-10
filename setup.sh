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

# Failsafes: per-entry limits for Homebrew/App Store installs (seconds), and
# stalled git transfers (brew update, the borders build) give up instead of
# hanging forever.
BREW_TIMEOUT="${SHINY_BREW_TIMEOUT:-1200}"
MAS_TIMEOUT="${SHINY_MAS_TIMEOUT:-3600}"     # Xcode is ~10 GB
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60 HOMEBREW_CURL_RETRIES=3

# Everything is logged too, so a failed run can be read back afterwards.
LOG_DIR="${HOME}/Library/Logs/shiny"; mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
NOTES="$(mktemp "${TMPDIR:-/tmp}/shiny-setup.XXXXXX")"   # what didn't install, across step subshells

echo; banner; echo

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ -f "$BREWFILE" ]] || die "No Brewfile found next to this script at: $BREWFILE"

trap 'kill "${SUDO_KEEPALIVE_PID:-}" 2>/dev/null || true; rm -f "$NOTES"' EXIT

note() { printf '%s\n' "$*" >> "$NOTES"; }   # note <line> — listed in the summary

with_timeout() { # with_timeout <secs> <label> <cmd…> — gives up after secs (SIGKILL 30s later)
  local secs="$1" label="$2" rc=0; shift 2
  timeout -k 30 "$secs" "$@" || rc=$?
  ((rc == 124 || rc == 137)) && warn "${label}: gave up after ${secs}s."
  return "$rc"
}

load_brew_env() { # put brew on PATH in this shell (Apple Silicon, then Intel)
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$b" ]] && { BREW_BIN="$b"; eval "$("$b" shellenv)"; return 0; }
  done
  return 1
}
load_brew_env || true

# ─────────────────────────────────────────────────────────────────────────────
# 1. XCLT
# ─────────────────────────────────────────────────────────────────────────────
install_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    info "Xcode CLT already present."
    return
  fi
  info "Installing Xcode Command Line Tools…"
  xcode-select --install 2>/dev/null || true   # usually already opened by the preflight
  info "Waiting for CLT install to finish — complete the dialog if prompted…"
  local waited=0
  until xcode-select -p >/dev/null 2>&1; do
    sleep 5; waited=$((waited + 5))
    ((waited < 1800)) || die "Still no Command Line Tools after 30 min — cancelled? Run again once they're in."
  done
  info "Xcode CLT installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Homebrew + Brewfile
# ─────────────────────────────────────────────────────────────────────────────
install_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    info "Installing Homebrew…"
    local script
    script="$(curl -fsSL --max-time 60 --retry 2 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || die "Couldn't download the Homebrew installer — check your connection."
    NONINTERACTIVE=1 with_timeout 1800 "Homebrew install" /bin/bash -c "$script" \
      || die "Homebrew's installer failed (see above)."
  fi

  # Load brew into this shell (the main shell reloads it after this step), and
  # persist for future logins.
  load_brew_env || die "Homebrew installed but brew binary not found."
  if ! grep -q 'brew shellenv' "${HOME}/.zprofile" 2>/dev/null; then
    echo "eval \"\$(${BREW_BIN} shellenv)\"" >> "${HOME}/.zprofile"
  fi
  info "Homebrew ready ($("$BREW_BIN" --version | head -1))."
}

run_bundle() {
  command -v brew >/dev/null 2>&1 || die "Homebrew isn't installed (run the Homebrew step)."
  # Newer Homebrew refuses third-party taps until trusted: every tap the
  # Brewfile names (user/tap/name entries).
  local tap
  for tap in $(brewfile_entries | awk -F'|' '{ n = split($2, p, "/"); if (n == 3) print p[1] "/" p[2] }' | sort -u); do
    brew trust --tap "$tap" >/dev/null 2>&1 || true
  done
  info "Updating Homebrew…"
  with_timeout 300 "brew update" brew update --quiet </dev/null \
    || warn "brew update failed — installing from the formulae already here."
  export HOMEBREW_NO_AUTO_UPDATE=1   # once is enough, not before every entry

  # One entry at a time instead of `brew bundle`: it has no timeout, doesn't
  # say which entry is stuck, and upgrades everything already installed (slow
  # for the big App Store apps). Installed entries are skipped — `brew upgrade`
  # / `mas upgrade` when you want updates.
  local formulae casks mas_ids kind name id n=0 total
  formulae=" $(brew list --formula -1 | tr '\n' ' ') "
  casks=" $(brew list --cask -1 | tr '\n' ' ') "
  mas_ids=" $(mas list 2>/dev/null | awk '{ print $1 }' | tr '\n' ' ') "
  total="$(brewfile_entries | wc -l | tr -d ' ')"
  info "Installing from ${BREWFILE} (${BREW_TIMEOUT}s limit per app, ${MAS_TIMEOUT}s per App Store app)…"
  while IFS='|' read -r -u 3 kind name id; do
    n=$((n + 1))
    case "$kind" in
      brew)
        [[ "$formulae" == *" ${name##*/} "* ]] && continue
        info "[${n}/${total}] ${name}"
        with_timeout "$BREW_TIMEOUT" "$name" brew install "$name" </dev/null || note "brew ${name}" ;;
      cask)
        [[ "$casks" == *" ${name##*/} "* ]] && continue
        info "[${n}/${total}] ${name} (cask)"
        # --adopt takes over an app that's already in /Applications (installed by hand).
        with_timeout "$BREW_TIMEOUT" "$name" brew install --cask --adopt "$name" </dev/null || note "cask ${name}" ;;
      mas)
        [[ "$mas_ids" == *" ${id} "* ]] && continue
        info "[${n}/${total}] ${name} (App Store)"
        # mas 7 installs through sudo, kept warm above.
        with_timeout "$MAS_TIMEOUT" "$name" mas install "$id" </dev/null || note "mas ${name} (${id})" ;;
    esac
  done 3< <(brewfile_entries)

  # dockutil (dock step) and wallpaper (theme step) are needed regardless of the Brewfile.
  command -v dockutil >/dev/null 2>&1 || with_timeout "$BREW_TIMEOUT" dockutil brew install dockutil </dev/null || note "brew dockutil"
  command -v wallpaper >/dev/null 2>&1 || with_timeout "$BREW_TIMEOUT" wallpaper brew install wallpaper </dev/null || note "brew wallpaper"
  return 0
}

brewfile_entries() { # → kind|name|id per Brewfile line (id only for mas)
  sed -nE -e 's/^[[:space:]]*(brew|cask)[[:space:]]+"([^"]+)".*/\1|\2|/p' \
          -e 's/^[[:space:]]*mas[[:space:]]+"([^"]+)",[[:space:]]*id:[[:space:]]*([0-9]+).*/mas|\1|\2/p' "$BREWFILE"
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

  # AeroSpace tiles windows (config is rendered by the theme step). Group
  # windows by app in Mission Control: AeroSpace hides windows off-screen
  # and ungrouped they show up tiny.
  defaults write com.apple.dock expose-group-apps -bool true

  # Dark mode, not Auto: every theme is built on it. The theme step switches
  # it live; this alone needs a logout.
  defaults write -g AppleInterfaceStyle -string Dark
  defaults delete -g AppleInterfaceStyleSwitchesAutomatically 2>/dev/null || true

  # ⌘Space is Alfred's (the theme step sets it there): Spotlight moves off it.
  defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 \
    "<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1048576</integer></array><key>type</key><string>standard</string></dict></dict>"

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
  defaults write com.apple.dock orientation -string left
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
  name="${NEW_HOSTNAME:-}"   # asked in the preflight
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
  curl -fsSL --max-time 180 --retry 2 https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-social/hosts -o "$tmp" \
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
  command -v sketchybar >/dev/null 2>&1 && timeout 60 brew services start sketchybar >/dev/null 2>&1 || true
  # Alfred Evie: the plain theme `shiny off` switches Alfred to.
  install_alfred_evie && info "Alfred: Alfred Evie theme installed." || warn "Alfred: open it once, then re-run for the Alfred Evie theme."
  with_timeout 600 "Theme" "${SCRIPT_DIR}/libexec/shiny-apply" "$THEME" \
    || { warn "Theme '${THEME}' didn't fully apply — see above."; return 1; }
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
# run_step <label> <cmd…> — each step runs in its own subshell with errexit, so
# a failure stops that step only; it's reported in the summary and the rest run.
STEP_RESULTS=()
FAILED=0
run_step() {
  local label="$1" rc=0 t0=$SECONDS why; shift
  echo; info "${B}${label}${N}"
  set +e; ( set -e; "$@" ); rc=$?; set -e
  if ((rc == 0)); then
    STEP_RESULTS+=("ok      ${label} ($((SECONDS - t0))s)")
  else
    why="exit ${rc}"; ((rc != 124)) || why="timed out"
    STEP_RESULTS+=("FAILED  ${label} (${why})"); FAILED=1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight — everything that needs you happens here, then the rest runs on its
# own. (macOS still shows its own permission dialogs as apps first start, at the
# end: Accessibility for AeroSpace, "Terminal wants to control …".)
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
  # The Command Line Tools dialog first: it downloads while you answer the rest.
  if step_enabled clt && ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install 2>/dev/null || true
    info "Click Install in the Command Line Tools dialog (it carries on in the background)."
  fi
  if ! ((YES)) && [[ -t 0 ]]; then
    if step_enabled hostname; then
      local current; current="$(scutil --get ComputerName 2>/dev/null || true)"
      read -r -p "Hostname for this machine [${current}]: " NEW_HOSTNAME
    fi
    # mas can't sign in (Apple removed CLI sign-in) or tell whether you are.
    if step_enabled brew && grep -qE '^[[:space:]]*mas ' "$BREWFILE"; then
      open -a "App Store" 2>/dev/null || true
      info "Sign in to the App Store (it just opened) if you aren't already — App Store apps need it."
      read -r -p "Press Enter when you're signed in (or to skip App Store apps)… " _
    fi
  fi
  # Your password once; kept warm for the whole run.
  info "Your password, for Homebrew, the hostname, the hosts file and a few system settings:"
  sudo -v
  while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
  echo; info "${B}That's everything — the rest runs on its own.${N}"
}

choose_recipe
NEW_HOSTNAME=""
preflight

step_enabled clt      && run_step "Xcode Command Line Tools" install_clt
step_enabled brew     && { run_step "Homebrew" install_brew; load_brew_env || true; run_step "Brewfile apps" run_bundle; }
step_enabled defaults && run_step "System defaults" set_defaults
step_enabled dock     && run_step "Dock contents" set_dock
step_enabled hostname && run_step "Hostname" set_hostname
step_enabled hosts    && run_step "Hosts blocklist" write_hosts
step_enabled borders  && run_step "Patched JankyBorders (Homebrew borders still works if this fails)" \
                           with_timeout 900 "Borders build" "${SCRIPT_DIR}/libexec/install-borders"
step_enabled fastmail && run_step "Fastmail theming (Fastmail itself is untouched if this fails)" \
                           with_timeout 300 "Fastmail theming" "${SCRIPT_DIR}/libexec/install-fastmail"
step_enabled theme    && run_step "Theme: ${THEME}" set_theme

# Apply: restart the affected UI services. Key-repeat/appearance still want a logout.
killall Finder Dock SystemUIServer 2>/dev/null || true

echo; info "Summary:"
printf '  %s\n' "${STEP_RESULTS[@]+"${STEP_RESULTS[@]}"}"
if [[ -s "$NOTES" ]]; then
  FAILED=1
  warn "Didn't install (re-run \`shiny setup\` to retry just these):"
  sed 's/^/  /' "$NOTES"
fi

# Approvals macOS only asks for once an app has started: open the pane for them.
TODO=()
if [[ -d /Applications/AeroSpace.app ]] && ! timeout 5 aerospace list-workspaces --focused >/dev/null 2>&1; then
  TODO+=("Allow ${BOLD}AeroSpace${RESET} in Privacy & Security → Accessibility (just opened) so it can tile.")
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
fi
if [[ -d "/Applications/Alfred 5.app" ]] && ! compgen -G "${HOME}/Library/Application Support/Alfred/powerpack.*.dat" >/dev/null; then
  TODO+=("Alfred: enter your Powerpack licence (Alfred → Powerpack) — the \`theme\` workflow needs it.")
fi
if [[ -s "$NOTES" ]] && grep -q '^mas ' "$NOTES"; then
  TODO+=("App Store apps were skipped: sign in to the App Store, then run \`shiny setup\` again.")
fi

cat <<EOF

${BOLD}Done.${RESET}  Full log: ${LOG}
$( ((${#TODO[@]})) && printf '\n  • %s' "${TODO[@]}" )

  • Log out and back in for keyboard repeat + accent colour to fully apply.
  • ${BOLD}Don't forget to log in to Tailscale${RESET} — run:  tailscale up
  • Sanity check what didn't install:  brew bundle check --file="$BREWFILE"

EOF
exit "$FAILED"
