#!/bin/bash
# Wi-Fi: connected / disconnected (SSIDs are hidden from scripts on recent macOS).
source "$HOME/.config/sketchybar/colors.sh"
if [ -n "$(ipconfig getifaddr en0 2>/dev/null)" ]; then
  sketchybar --set "$NAME" icon=􀙇 icon.color="$FG_DIM"
else
  sketchybar --set "$NAME" icon=􀙈 icon.color="$MUTED"
fi
