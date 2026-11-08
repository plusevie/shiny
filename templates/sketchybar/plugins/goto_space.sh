#!/bin/bash
# Switch to desktop N by sending Ctrl+N (needs Accessibility for SketchyBar).
codes=(0 18 19 20 21 23 22 26 28 25)
osascript -e "tell application \"System Events\" to key code ${codes[$1]} using control down"
