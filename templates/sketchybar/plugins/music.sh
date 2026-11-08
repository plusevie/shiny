#!/bin/bash
# Now playing: Apple Music, then Cider. Only asks apps that are already running
# (never launches them). Cider is read through its local API with the
# playback-only token shiny registers (~/.config/shiny/cider-token).
TOKEN_FILE="$HOME/.config/shiny/cider-token"
CIDER_API="http://127.0.0.1:10767/api/v1/playback"
running() { [ "$(osascript -e "application \"$1\" is running" 2>/dev/null)" = "true" ]; }

source_app=""; info=""
if running Music; then
  info=$(osascript -e 'tell application "Music"
    if player state is playing then return (name of current track) & " — " & (artist of current track)
    return ""
  end tell' 2>/dev/null)
  [ -n "$info" ] && source_app=music
fi
if [ -z "$info" ] && running Cider && [ -s "$TOKEN_FILE" ]; then
  tok=$(cat "$TOKEN_FILE")
  if curl -s -m 1 -H "apptoken: $tok" "$CIDER_API/is-playing" | grep -q '"is_playing":true'; then
    np=$(curl -s -m 1 -H "apptoken: $tok" "$CIDER_API/now-playing")
    name=$(plutil -extract info.name raw -o - - <<<"$np" 2>/dev/null)
    artist=$(plutil -extract info.artistName raw -o - - <<<"$np" 2>/dev/null)
    [ -n "$name" ] && { info="$name — $artist"; source_app=cider; }
  fi
fi

if [ "$SENDER" = "mouse.clicked" ]; then   # click: play/pause whichever app is showing
  case "$(cat /tmp/shiny-np-source 2>/dev/null)" in
    music) osascript -e 'tell application "Music" to playpause' ;;
    cider) curl -s -m 1 -X POST -H "apptoken: $(cat "$TOKEN_FILE")" "$CIDER_API/playpause" >/dev/null ;;
  esac
  exit 0
fi

if [ -n "$info" ]; then
  echo "$source_app" > /tmp/shiny-np-source
  sketchybar --set "$NAME" drawing=on label="$info"
else
  sketchybar --set "$NAME" drawing=off
fi
