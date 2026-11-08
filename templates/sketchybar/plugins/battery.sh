#!/bin/bash
info="$(pmset -g batt)"
pct="$(grep -Eo '[0-9]+%' <<<"$info" | head -1 | tr -d %)"
[ -z "$pct" ] && { sketchybar --set "$NAME" drawing=off; exit 0; }
if   [ "$pct" -ge 90 ]; then icon=􀛨
elif [ "$pct" -ge 60 ]; then icon=􀺸
elif [ "$pct" -ge 35 ]; then icon=􀺶
elif [ "$pct" -ge 10 ]; then icon=􀛩
else icon=􀛪; fi
grep -q "AC Power" <<<"$info" && icon=􀢋
sketchybar --set "$NAME" icon="$icon"   # icon only: no percentage
