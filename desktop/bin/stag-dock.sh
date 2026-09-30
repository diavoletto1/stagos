#!/bin/bash
# StagOS dock. nwg-dock (bottom, pinned apps from ~/.cache/nwg-dock-pinned).
#   stag-dock start    start it if it is not running (autostart)
#   stag-dock          toggle (Super+Shift+D, DOCK button on the bar)
# Falls back to the old text-tile waybar dock when nwg-dock is not installed.
# shellcheck source=/dev/null
[ -r "$HOME/.config/stagos/desktop.env" ] && . "$HOME/.config/stagos/desktop.env"

if ! command -v nwg-dock >/dev/null 2>&1; then
  [ "$1" = start ] && exit 0
  if pkill -f 'waybar-doc[k]/config'; then exit 0; fi
  exec waybar -c "$HOME/.config/waybar-dock/config.jsonc" \
              -s "$HOME/.config/waybar-dock/style.css" >/dev/null 2>&1
fi

running() { pgrep -x nwg-dock >/dev/null; }
launch() {
  args=(-p bottom -i 44 -mb 10 -nows -c fuzzel -s "$HOME/.config/nwg-dock/style.css")
  if [ "${STAGOS_DOCK_AUTOHIDE:-1}" = 1 ]; then args+=(-d); else args+=(-l top -x); fi
  setsid -f nwg-dock "${args[@]}" >/dev/null 2>&1
}
case "${1:-toggle}" in
  start)  running || launch ;;
  toggle) if running; then pkill -x nwg-dock; else launch; fi ;;
  *)      echo "usage: stag-dock [start]" >&2; exit 2 ;;
esac
