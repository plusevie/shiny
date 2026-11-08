#!/bin/bash
# Next calendar event: "now · Standup", "in 25m · Standup", "14:30 · Standup".
# Hidden when nothing's coming up in the next 12 hours (or no calendar access).
tool="$HOME/Library/Application Support/shiny/bin/next-event"
[ -x "$tool" ] || { sketchybar --set "$NAME" drawing=off; exit 0; }
line="$("$tool" --hours 12 2>/dev/null)"
[ -z "$line" ] && { sketchybar --set "$NAME" drawing=off; exit 0; }
IFS=$'\t' read -r start end title <<<"$line"
now=$(date +%s)
if [ "$start" -le "$now" ]; then when="now"
elif [ $((start - now)) -lt 3600 ]; then when="in $(( (start - now + 59) / 60 ))m"
else when="$(date -r "$start" +%H:%M)"; fi
sketchybar --set "$NAME" drawing=on label="$when · $title"
