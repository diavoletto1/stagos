#!/bin/bash
# StagOS power menu (fuzzel dmenu). Bound to Super+Escape and the bar's power button.
# All actions work as the logged-in user via logind/polkit, no sudo.
choice=$(printf 'Lock\nSleep\nLog out\nRestart\nShut down' \
  | fuzzel --dmenu --prompt 'power> ' --lines 5 --width 14)
case "$choice" in
  Lock)        stag-lock ;;
  Sleep)       systemctl suspend ;;
  "Log out")   pkill -x labwc ;;
  Restart)     systemctl reboot ;;
  "Shut down") systemctl poweroff ;;
esac
