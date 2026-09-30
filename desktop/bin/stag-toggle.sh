#!/bin/bash
# StagOS quick toggles for the Control Center (swaync buttons-grid).
#   stag-toggle wifi|bluetooth|night toggle     flip it
#   stag-toggle wifi|bluetooth|night status     print true/false (drives the button state)
what="${1:-}"; act="${2:-status}"
case "$what:$act" in
  wifi:status)      [ "$(nmcli radio wifi 2>/dev/null)" = enabled ] && echo true || echo false ;;
  wifi:toggle)      if [ "$(nmcli radio wifi)" = enabled ]; then nmcli radio wifi off; else nmcli radio wifi on; fi ;;
  bluetooth:status) bluetoothctl show 2>/dev/null | grep -q 'Powered: yes' && echo true || echo false ;;
  bluetooth:toggle) if bluetoothctl show | grep -q 'Powered: yes'; then bluetoothctl power off; else rfkill unblock bluetooth; bluetoothctl power on; fi ;;
  night:status)     stag-nightlight status ;;
  night:toggle)     stag-nightlight toggle ;;
  *) echo "usage: stag-toggle wifi|bluetooth|night toggle|status" >&2; exit 2 ;;
esac
