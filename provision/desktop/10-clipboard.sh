#!/usr/bin/env bash
# Clipboard history: wl-clipboard + cliphist, fuzzel picker on Super+Shift+V.
stagos_dm_clipboard() {
  dm_pkgs wl-clipboard cliphist fuzzel
  dm_bins stag-clip
  dm_config labwc
  ok "clipboard history ready (watchers start from labwc autostart)"
}
