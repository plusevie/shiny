#!/bin/bash
# Highlight the current desktop's pill in the accent colour.
source "$HOME/.config/sketchybar/colors.sh"
if [ "$SELECTED" = "true" ]; then
  sketchybar --set "$NAME" background.color="$PILL_ACTIVE" icon.color="$ON_ACCENT"
else
  sketchybar --set "$NAME" background.color="$PILL" icon.color="$FG_DIM"
fi
