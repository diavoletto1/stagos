#!/bin/bash
# StagOS: toggle the app dock (Super+A / APPS button). Closed = not running.
if pkill -f 'waybar-doc[k]/config'; then exit 0; fi
exec waybar -c "$HOME/.config/waybar-dock/config.jsonc" \
            -s "$HOME/.config/waybar-dock/style.css" >/dev/null 2>&1
