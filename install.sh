#!/usr/bin/env bash
#
# shiny installer — the theming engine + stock themes.
#
#   curl -fsSL https://raw.githubusercontent.com/plusevie/shiny/main/install.sh | bash
#
# Clones shiny to ~/.local/share/shiny (override with SHINY_HOME) and puts a
# `shiny` command on your PATH. Re-running it updates. Then:
#   shiny setup          apps, defaults, Dock, theme
#   shiny theme set      pick a theme

set -euo pipefail

SHINY_HOME="${SHINY_HOME:-${HOME}/.local/share/shiny}"
REPO="${SHINY_REPO:-https://github.com/plusevie/shiny.git}"
BRANCH="${SHINY_BRANCH:-main}"

if [[ -t 1 ]]; then B=$'\033[1m'; C=$'\033[34m'; R=$'\033[31m'; N=$'\033[0m'; else B= C= R= N=; fi
info() { printf '%s==>%s %s\n' "$C$B" "$N" "$*"; }
die()  { printf '%s==> ERROR:%s %s\n' "$R$B" "$N" "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "shiny is macOS only."

# git comes with the Xcode Command Line Tools.
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install 2>/dev/null || true
  die "Install the Command Line Tools from the dialog that just opened, then run this again."
fi

if [[ -d "${SHINY_HOME}/.git" ]]; then
  info "Updating ${SHINY_HOME}…"
  git -C "$SHINY_HOME" pull -q --ff-only
else
  info "Installing shiny to ${SHINY_HOME}…"
  mkdir -p "$(dirname "$SHINY_HOME")"
  git clone -q --depth 1 -b "$BRANCH" "$REPO" "$SHINY_HOME"
fi

"${SHINY_HOME}/bin/shiny" install-cli

cat <<MSG

${B}shiny is installed.${N}  ($(command -v shiny || echo "${SHINY_HOME}/bin/shiny"))

  shiny setup        install apps, defaults, Dock and a theme (safe to re-run)
  shiny theme set    pick a theme · shiny theme list · shiny theme new -i <image>
  shiny help

MSG
