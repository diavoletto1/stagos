#!/bin/bash
# StagOS clipboard history (cliphist). Super+Shift+V.
#   stag-clip pick    fuzzel list, selected entry goes back on the clipboard
#   stag-clip clear   wipe the history
case "${1:-pick}" in
  pick)  cliphist list | fuzzel --dmenu --prompt 'clip> ' --width 60 | cliphist decode | wl-copy ;;
  clear) cliphist wipe && notify-send "Clipboard history cleared" ;;
  *)     echo "usage: stag-clip pick|clear" >&2; exit 2 ;;
esac
