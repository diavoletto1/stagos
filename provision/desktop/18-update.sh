#!/usr/bin/env bash
# Safe updates: stag-update (Arch news since the last run, a restic snapshot first, pacman -Syu, pacdiff for
# .pacnew/.pacsave, failed units, reboot hint; optional Arch Linux Archive pin). pacman-contrib brings pacdiff.
stagos_dm_update() {
  dm_pkgs pacman-contrib curl
  dm_bins stag-update
  dm_note "updates: stag-update --dry-run, then stag-update (the Arch Linux Archive pin is off: see README)"
  ok "stag-update installed"
}
