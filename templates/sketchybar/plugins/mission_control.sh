#!/bin/bash
# Hide the bar while Mission Control is open (events from shiny's patched borders).
case "$SENDER" in
  mc_enter) sketchybar --bar hidden=on ;;
  mc_exit)  sketchybar --bar hidden=off ;;
esac
