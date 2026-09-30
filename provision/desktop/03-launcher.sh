#!/usr/bin/env bash
# Launcher: fuzzel (Super+Space) as Spotlight, plus stag-spotlight for files (plocate) and math (qalc).
stagos_dm_launcher() {
  dm_pkgs fuzzel plocate libqalculate wl-clipboard libnotify xdg-utils
  dm_config fuzzel
  dm_bins stag-spotlight
  dm_enable_system plocate-updatedb.timer
  # first index so file search works today, not tomorrow
  if ! dm_have_systemd && ! dm_dry; then dm_note "sudo updatedb (first plocate index)"; else run sudo updatedb || true; fi
  ok "launcher ready: Super+Space apps, Super+Shift+Space spotlight (= calc, / files)"
}
