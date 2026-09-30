#!/usr/bin/env bash
# Power: TLP (already this repo's choice, see 50-user-env), lid close = suspend, swayidle + swaylock,
# low-battery notifications, fwupd.
# TLP over power-profiles-daemon: they conflict (only one may own the CPU/radio/USB knobs), TLP is
# already enabled here, and on a 2014 ThinkPad it gives real battery wins (runtime PM, USB/PCIe/SATA
# tuning) that PPD's three profiles do not. PPD would add a GNOME-style toggle, which the bar does not use.
stagos_dm_power() {
  dm_pkgs tlp tlp-rdw swayidle swaylock wlopm fwupd upower libnotify
  if pacman -Q power-profiles-daemon >/dev/null 2>&1; then
    warn "power-profiles-daemon is installed and conflicts with TLP: sudo pacman -Rns power-profiles-daemon"
  fi
  dm_install "$HERE/desktop/tlp/50-stagos.conf" /etc/tlp.d/50-stagos.conf 644 sudo
  dm_install "$HERE/desktop/systemd/logind-lid.conf" /etc/systemd/logind.conf.d/50-stagos-lid.conf 644 sudo
  dm_install "$HERE/desktop/pam/swaylock" /etc/pam.d/swaylock 644 sudo
  dm_bins stag-lock stag-battery
  dm_config labwc
  # tlp wants systemd-rfkill masked so it alone handles radio state
  if dm_have_systemd || dm_dry; then
    run sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket
  else
    dm_note "mask systemd-rfkill.service/.socket for TLP"
  fi
  dm_enable_system tlp.service fwupd-refresh.timer
  dm_note "power: close the lid (suspends, locks first), check 'tlp-stat -s', 'fwupdmgr get-updates'"
  ok "power configured"
}
