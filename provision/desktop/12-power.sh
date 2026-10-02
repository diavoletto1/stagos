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
  dm_write /etc/tlp.d/51-stagos-battery.conf 644 sudo < <(stagos_dm_battery_conf)
  dm_bins stag-battery
  dm_install "$HERE/desktop/systemd/logind-lid.conf" /etc/systemd/logind.conf.d/50-stagos-lid.conf 644 sudo
  # tlp wants systemd-rfkill masked so it alone handles radio state
  if dm_have_systemd || dm_dry; then
    run sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket
  else
    dm_note "mask systemd-rfkill.service/.socket for TLP"
  fi
  dm_enable_system tlp.service fwupd-refresh.timer
  dm_note "battery: sudo tlp setcharge (applies the thresholds now), then stag-battery status"
  dm_note "power: close the lid (suspends, Plasma locks on resume), check 'tlp-stat -s', 'fwupdmgr get-updates'"
  ok "power configured"
}

# TLP charge thresholds for BAT0 (TLP thinkpad plugin, kernel natacpi: charge_control_{start,end}_threshold).
# Ranges per TLP's vendor docs: start 0..99, stop 1..100, start below stop; factory 96/100 = thresholds off.
# STAGOS_BAT_FULL=1 writes the factory values: the controller keeps old thresholds across reboots, so
# leaving the keys out would not turn them off.
stagos_dm_battery_conf() {
  local start="${STAGOS_BAT_START:-75}" stop="${STAGOS_BAT_STOP:-80}"
  if [[ "${STAGOS_BAT_FULL:-0}" == 1 ]]; then
    start=96; stop=100
  elif ! [[ "$start" =~ ^[0-9]+$ && "$stop" =~ ^[0-9]+$ ]] || (( start > 99 || stop < 1 || stop > 100 || start >= stop )); then
    warn "battery thresholds $start/$stop out of range (start 0..99 < stop 1..100): using 75/80"
    start=75; stop=80
  fi
  cat <<EOF
# StagOS battery care, generated from config/stagos.conf (STAGOS_BAT_START/STOP/FULL). Edit there, then
# ./stagos-desktop power && sudo tlp setcharge. For a trip: stag-battery full (100% once, until reboot).
START_CHARGE_THRESH_BAT0=$start
STOP_CHARGE_THRESH_BAT0=$stop
EOF
}
