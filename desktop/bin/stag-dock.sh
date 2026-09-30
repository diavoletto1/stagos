#!/bin/bash
# StagOS dock: a second waybar at the bottom center with HUD text tiles
# (~/.config/waybar-dock). nwg-dock is not used: it needs sway/hyprland IPC
# ($SWAYSOCK) and exits immediately under labwc.
#   stag-dock start    start it if it is not running (autostart)
#   stag-dock          toggle (Super+Shift+D, DOCK on the top bar)
# shellcheck source=/dev/null
[ -r "$HOME/.config/stagos/desktop.env" ] && . "$HOME/.config/stagos/desktop.env"

cfg="$HOME/.config/waybar-dock/config.jsonc"
css="$HOME/.config/waybar-dock/style.css"
# match the dock's own command line only (anchored), never this script or a shell
pids() { pgrep -f "^waybar -c $cfg"; }
launch() { setsid -f waybar -c "$cfg" -s "$css" >/dev/null 2>&1; }

case "${1:-toggle}" in
  start)  pids >/dev/null || launch ;;
  toggle) if pids >/dev/null; then pids | xargs kill; else launch; fi ;;
  *)      echo "usage: stag-dock [start]" >&2; exit 2 ;;
esac
