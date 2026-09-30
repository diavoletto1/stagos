#!/usr/bin/env bash
# Trackpad: tap to click, natural scroll, palm rejection (labwc rc.xml <libinput>, synced with the
# labwc config) and libinput-gestures 3-finger swipe for workspaces (types Ctrl+Alt+Left/Right via wtype).
stagos_dm_trackpad() {
  dm_pkgs libinput wtype
  dm_config labwc
  dm_aur libinput-gestures
  dm_add_group input
  dm_sync_dir "$HERE/desktop/libinput-gestures" "$(dm_cfg)"
  ok "trackpad configured"
}
