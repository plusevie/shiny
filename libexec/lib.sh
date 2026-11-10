# lib.sh — shared helpers for bin/shiny and libexec/shiny-apply (sourced, bash 3.2-safe).
#
# Expects SHINY_HOME to be set to the shiny checkout.

STATE_DIR="${HOME}/.config/shiny"
USER_THEMES="${SHINY_USER_THEMES:-${STATE_DIR}/themes}"
STOCK_THEMES="${SHINY_HOME}/themes"
CACHE_DIR="${HOME}/Library/Caches/shiny"
SUPPORT_DIR="${HOME}/Library/Application Support/shiny"

# The ten colour roles every palette.sh defines (see THEMES.md).
COLOR_ROLES=(BG BG_DARK SURFACE SELECTION MUTED COMMENT FG FG_DIM ACCENT ACCENT2)

if [[ -t 1 ]]; then B=$'\033[1m'; D=$'\033[2m'; C=$'\033[34m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B= D= C= Y= R= N=; fi
info() { printf '%s==>%s %s\n' "$C$B" "$N" "$*"; }
warn() { printf '%s==> WARNING:%s %s\n' "$Y$B" "$N" "$*" >&2; }
die()  { printf '%s==> ERROR:%s %s\n' "$R$B" "$N" "$*" >&2; exit 1; }

theme_dir() { # theme_dir <name> → path (your themes win over stock)
  local d
  for d in "$USER_THEMES" "$STOCK_THEMES"; do
    [[ -f "${d}/$1/palette.sh" ]] && { printf '%s/%s' "$d" "$1"; return 0; }
  done
  return 1
}

all_themes() { # name<TAB>dir, yours first, no duplicates
  local d n seen=" "
  for d in "$USER_THEMES" "$STOCK_THEMES"; do
    [[ -d "$d" ]] || continue
    for n in "$d"/*/palette.sh; do
      [[ -f "$n" ]] || continue
      n="$(basename "$(dirname "$n")")"
      [[ "$seen" == *" $n "* ]] && continue
      seen+="$n "; printf '%s\t%s/%s\n' "$n" "$d" "$n"
    done
  done
}

current_theme() { [[ -f "${STATE_DIR}/current" ]] && cat "${STATE_DIR}/current" || true; }
is_user_theme() { [[ -f "${USER_THEMES}/$1/palette.sh" ]]; }
palette_get() { grep -E "^$2=" "$1/palette.sh" | head -1 | cut -d'"' -f2; }   # palette_get <dir> <KEY>

# `open -Ra` first: asked about an app that isn't installed, osascript blocks
# ~2 min (or pops a "Where is X?" chooser and waits forever).
app_running() { open -Ra "$1" 2>/dev/null && [[ "$(osascript -e "application \"$1\" is running" 2>/dev/null)" == true ]]; }

now_ms() { local t; t="$(date +%s%N 2>/dev/null)"; [[ "$t" == *N ]] && echo $(( $(date +%s) * 1000 )) || echo $(( t / 1000000 )); }

native_tool() { # native_tool <name> [framework…] — builds libexec/<name>.{m,swift} once, prints its path
  local name="$1"; shift
  local src="${SHINY_HOME}/libexec/${name}.m" bin="${SUPPORT_DIR}/bin/${name}" f fw=()
  [[ -f "$src" ]] || src="${SHINY_HOME}/libexec/${name}.swift"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    mkdir -p "$(dirname "$bin")"
    if [[ "$src" == *.swift ]]; then
      command -v swiftc >/dev/null 2>&1 || return 1
      # libexec/<name>.plist, if any, is embedded as the tool's Info.plist (privacy prompts need it).
      local plist="${SHINY_HOME}/libexec/${name}.plist" pl=()
      [[ -f "$plist" ]] && pl=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist")
      swiftc -O ${pl[@]+"${pl[@]}"} "$src" -o "$bin" 2>/dev/null || return 1
    else
      command -v clang >/dev/null 2>&1 || return 1
      for f in "$@"; do fw+=(-framework "$f"); done
      clang -fobjc-arc -O2 ${fw[@]+"${fw[@]}"} "$src" -o "$bin" 2>/dev/null || return 1
    fi
  fi
  printf '%s' "$bin"
}

alfred_prefs_dir() {
  local sync
  sync="$(defaults read com.runningwithcrayons.Alfred-Preferences syncfolder 2>/dev/null || true)"
  sync="${sync/#\~/$HOME}"
  [[ -n "$sync" ]] || sync="${HOME}/Library/Application Support/Alfred"
  printf '%s/Alfred.alfredpreferences' "$sync"
}

ALFRED_EVIE_UID="theme.custom.alfred-evie"
install_alfred_evie() { # install_alfred_evie — Alfred Evie (Alfred Dark 2's shape, Alfred Dark's colours) into Alfred's themes
  local prefs; prefs="$(alfred_prefs_dir)"
  [[ -d "$prefs" ]] || return 1
  mkdir -p "${prefs}/themes/${ALFRED_EVIE_UID}"
  cp -f "${SHINY_HOME}/alfred/alfred-evie.json" "${prefs}/themes/${ALFRED_EVIE_UID}/theme.json"
}

# ── curtain ──────────────────────────────────────────────────────────────────
# Black loading screen over every display while apps restart/relaunch, so the
# flashing happens out of sight (libexec/curtain.m). SHINY_CURTAIN=0 turns it off.
CURTAIN_PID=""
CURTAIN_STATUS="${TMPDIR:-/tmp}/shiny-curtain-status.$$"
curtain_say() { [[ -n "$CURTAIN_PID" ]] && printf '%s\n' "$*" > "$CURTAIN_STATUS" 2>/dev/null || true; }
curtain_up() { # curtain_up <message>
  [[ "${SHINY_CURTAIN:-1}" != 0 ]] || return 0
  local tool ready i
  tool="$(native_tool curtain AppKit QuartzCore)" || return 0
  ready="${TMPDIR:-/tmp}/shiny-curtain.$$"; rm -f "$ready"
  printf '%s\n' "$1" > "$CURTAIN_STATUS"
  "$tool" --ready "$ready" --status "$CURTAIN_STATUS" >/dev/null 2>&1 &
  CURTAIN_PID=$!
  # Wait until it's fully black before touching anything (gives up after 3s).
  for i in {1..30}; do [[ -f "$ready" ]] && break; sleep 0.1; done
  rm -f "$ready"
}
curtain_down() { # curtain_down [settle secs] — let relaunched apps draw, then fade out
  [[ -n "$CURTAIN_PID" ]] || return 0
  [[ -n "${1:-}" ]] && sleep "$1"
  kill -TERM "$CURTAIN_PID" 2>/dev/null || true
  CURTAIN_PID=""
  ( sleep 1; rm -f "$CURTAIN_STATUS" ) >/dev/null 2>&1 &
}
banner() { # banner — SHINY in block letters, shaded from the current theme's ACCENT to ACCENT2
  local lines=(
    '███████╗██╗  ██╗██╗███╗   ██╗██╗   ██╗'
    '██╔════╝██║  ██║██║████╗  ██║╚██╗ ██╔╝'
    '███████╗███████║██║██╔██╗ ██║ ╚████╔╝ '
    '╚════██║██╔══██║██║██║╚██╗██║  ╚██╔╝  '
    '███████║██║  ██║██║██║ ╚████║   ██║   '
    '╚══════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝   ╚═╝   ')
  local a="#7AA2F7" z="#FF9E64" d cur i r g b n=${#lines[@]}
  cur="$(current_theme)"; [[ -n "$cur" ]] && d="$(theme_dir "$cur")" \
    && { a="$(palette_get "$d" ACCENT)"; z="$(palette_get "$d" ACCENT2)"; }
  [[ -t 1 ]] || { printf '%s\n' "${lines[@]}"; return; }
  a="${a#\#}"; z="${z#\#}"
  for ((i = 0; i < n; i++)); do
    r=$(( 16#${a:0:2} + (16#${z:0:2} - 16#${a:0:2}) * i / (n - 1) ))
    g=$(( 16#${a:2:2} + (16#${z:2:2} - 16#${a:2:2}) * i / (n - 1) ))
    b=$(( 16#${a:4:2} + (16#${z:4:2} - 16#${a:4:2}) * i / (n - 1) ))
    printf '  \033[38;2;%d;%d;%dm%s\033[0m\n' "$r" "$g" "$b" "${lines[$i]}"
  done
}
