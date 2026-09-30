#!/bin/bash
# StagOS night light (wlsunset, sunrise/sunset from STAGOS_LAT/LON, Tampa by default).
#   stag-nightlight start|stop|toggle|status
# shellcheck source=/dev/null
[ -r "$HOME/.config/stagos/desktop.env" ] && . "$HOME/.config/stagos/desktop.env"
running() { pgrep -x wlsunset >/dev/null; }
case "${1:-toggle}" in
  start)  running || setsid -f wlsunset -l "${STAGOS_LAT:-27.95}" -L "${STAGOS_LON:--82.46}" -t "${STAGOS_NIGHT_TEMP:-3500}" -T 6500 >/dev/null 2>&1 ;;
  stop)   running && pkill -x wlsunset ;;
  toggle) if running; then pkill -x wlsunset; else "$0" start; fi ;;
  status) running && echo true || echo false ;;
  *)      echo "usage: stag-nightlight start|stop|toggle|status" >&2; exit 2 ;;
esac
