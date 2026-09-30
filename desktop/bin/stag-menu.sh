#!/bin/bash
# StagOS "Stag" menu: pick a stag-* service and open it as a chromium app window.
# Services come from ~/.config/stagos/stag-services ("name|url" lines), written by the
# `stag` module from the untracked config/local.conf. No URLs are stored in the repo.
list="${STAGOS_STAG_LIST:-$HOME/.config/stagos/stag-services}"
if [ ! -s "$list" ]; then
  notify-send "Stag" "No services configured. Fill config/local.conf and run: stagos-desktop stag"
  exit 1
fi
name=$(cut -d'|' -f1 "$list" | fuzzel --dmenu --prompt 'stag> ' --lines 6 --width 20) || exit 0
url=$(awk -F'|' -v n="$name" '$1==n{print $2; exit}' "$list")
[ -n "$url" ] && exec chromium --app="$url"
