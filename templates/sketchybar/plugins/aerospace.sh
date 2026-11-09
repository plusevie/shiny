#!/bin/bash
# One AeroSpace workspace pill (arg: its name). Shown when it's focused or has
# windows; the focused one is filled with the accent colour.
source "$HOME/.config/sketchybar/colors.sh"
ws="$1"
focused="${FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused 2>/dev/null)}"
if [ "$ws" = "$focused" ]; then
  sketchybar --set "$NAME" drawing=on background.color="$PILL_ACTIVE" icon.color="$ON_ACCENT"
elif [ -n "$(aerospace list-windows --workspace "$ws" 2>/dev/null)" ]; then
  sketchybar --set "$NAME" drawing=on background.color="$PILL" icon.color="$FG_DIM"
else
  sketchybar --set "$NAME" drawing=off
fi
