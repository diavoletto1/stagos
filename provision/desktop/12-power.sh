#!/usr/bin/env bash
# Power: TLP (already this repo's choice, see 50-user-env), logind lid close = suspend, fwupd. Idle dimming,
# screen lock (kscreenlocker) and low-battery handling are Plasma's (powerdevil, keys in desktop/plasma/base.kconf).
# TLP over power-profiles-daemon: they conflict (only one may own the CPU/radio/USB knobs), TLP is
# already enabled here, and on a 2014 ThinkPad it gives real battery wins (runtime PM, USB/PCIe/SATA
# tuning) that PPD's three profiles do not. Plasma's battery applet works without PPD (no profile switch).
stagos_dm_power() {
  dm_pkgs tlp tlp-rdw fwupd upower
  if pacman -Q power-profiles-daemon >/dev/null 2>&1; then
    warn "power-profiles-daemon is installed and conflicts with TLP: sudo pacman -Rns power-profiles-daemon"
  fi
  dm_install "$HERE/desktop/tlp/50-stagos.conf" /etc/tlp.d/50-stagos.conf 644 sudo
  dm_install "$HERE/desktop/systemd/logind-lid.conf" /etc/systemd/logind.conf.d/50-stagos-lid.conf 644 sudo
  # tlp wants systemd-rfkill masked so it alone handles radio state
  if dm_have_systemd || dm_dry; then
    run sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket
  else
    dm_note "mask systemd-rfkill.service/.socket for TLP"
  fi
  dm_enable_system tlp.service fwupd-refresh.timer
  dm_note "power: close the lid (suspends, Plasma locks on resume), check 'tlp-stat -s', 'fwupdmgr get-updates'"
  ok "power configured"
}
