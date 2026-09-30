#!/bin/bash
# StagOS screenshots -> ~/Pictures/Screenshots, also on the clipboard, with a notification.
#   stag-screenshot full     whole screen            (Super+Shift+3)
#   stag-screenshot region   drag a region           (Super+Shift+4, Print)
#   stag-screenshot edit     drag a region, annotate in swappy   (Super+Shift+6)
dir="${STAGOS_SHOT_DIR:-$HOME/Pictures/Screenshots}"
mkdir -p "$dir"
file="$dir/$(date +%F_%H-%M-%S).png"
case "${1:-region}" in
  full)   grim "$file" || exit 1 ;;
  region) geom=$(slurp) || exit 0; grim -g "$geom" "$file" || exit 1 ;;
  edit)   geom=$(slurp) || exit 0
          grim -g "$geom" - | swappy -f - -o "$file" || exit 1
          [ -s "$file" ] || exit 0 ;;
  *)      echo "usage: stag-screenshot full|region|edit" >&2; exit 2 ;;
esac
wl-copy < "$file"
notify-send -i "$file" "Screenshot saved" "$file"
