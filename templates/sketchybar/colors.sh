# managed by shiny-theme — colours for SketchyBar (0xAARRGGBB). Theme: {{THEME}}
hex() { printf '0x%s%s' "$2" "${1#\#}"; }
# SURFACE (one step up from BG) at Ghostty's opacity: the bar is too thin for the
# blur to average much, so plain BG reads darker than Ghostty. Checkerboard-matched.
BAR_COLOR=$(hex "{{SURFACE}}" {{ALPHA_HEX}})
BAR_BORDER=$(hex "{{MUTED}}" 90)
PILL=$(hex "{{MUTED}}" 70)
PILL_ACTIVE=$(hex "{{ACCENT}}" ff)
FG=$(hex "{{FG}}" ff)
FG_DIM=$(hex "{{FG_DIM}}" ff)
MUTED=$(hex "{{COMMENT}}" ff)
ACCENT=$(hex "{{ACCENT}}" ff)
ACCENT2=$(hex "{{ACCENT2}}" ff)
ON_ACCENT=$(hex "{{BG}}" ff)
BLUR={{BLUR}}
