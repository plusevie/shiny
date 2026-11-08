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

app_running() { [[ "$(osascript -e "application \"$1\" is running" 2>/dev/null)" == true ]]; }

now_ms() { local t; t="$(date +%s%N 2>/dev/null)"; [[ "$t" == *N ]] && echo $(( $(date +%s) * 1000 )) || echo $(( t / 1000000 )); }

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
