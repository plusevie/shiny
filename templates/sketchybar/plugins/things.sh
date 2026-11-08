#!/bin/bash
# Things: how many to-dos are in Today. Only asks Things when it's running.
running=$(osascript -e 'application "Things3" is running' 2>/dev/null)
if [ "$running" != "true" ]; then sketchybar --set "$NAME" drawing=off; exit 0; fi
n=$(osascript -e 'tell application "Things3" to count to dos of list "Today"' 2>/dev/null)
[ -n "$n" ] && sketchybar --set "$NAME" drawing=on label="$n" || sketchybar --set "$NAME" drawing=off
