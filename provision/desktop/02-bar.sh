#!/usr/bin/env bash
# App bar + dock: waybar top bar (workspaces, taskbar, clock, status, tray, power) and
# nwg-dock at the bottom with pinned apps. HUD themed.
stagos_dm_bar() {
  dm_pkgs waybar nwg-dock brightnessctl papirus-icon-theme ttf-jetbrains-mono inter-font wlr-randr
  dm_config waybar waybar-dock nwg-dock
  dm_bins stag-dock stag-power stag-lock
  # pinned apps: only seeded when absent, so pins you make in the dock survive reruns
  local pins="$HOME/.cache/nwg-dock-pinned"
  if [[ ! -s "$pins" ]]; then
    dm_write "$pins" 644 <<'PINS'
foot
chromium
thunar
obsidian
code
spotify-launcher
claude
PINS
  fi
  ok "bar and dock configured"
}
