#!/usr/bin/env bash
# Control Center + notifications: swaync (DND, toggles for wifi/bluetooth/night light, history)
# and SwayOSD for volume/brightness/caps lock OSD.
stagos_dm_notify() {
  dm_pkgs swaync swayosd libnotify network-manager-applet bluez-utils
  dm_config swaync swayosd
  dm_bins stag-toggle stag-nightlight
  # caps lock OSD reads libinput as root through this backend
  dm_enable_system swayosd-libinput-backend.service
  ok "swaync + swayosd configured (mako stays installed but is no longer started when swaync exists)"
}
