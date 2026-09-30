#!/usr/bin/env bash
# App bar + dock: waybar top bar (STAG menu, numbered workspaces, taskbar, clock,
# recon status, tray, power) and a second waybar as the bottom dock. HUD themed.
# nwg-dock was dropped: it needs sway/hyprland IPC and does not run under labwc.
stagos_dm_bar() {
  dm_pkgs waybar brightnessctl papirus-icon-theme ttf-jetbrains-mono inter-font wlr-randr
  dm_config waybar waybar-dock
  dm_bins stag-dock stag-power stag-lock
  ok "bar and dock configured"
}
