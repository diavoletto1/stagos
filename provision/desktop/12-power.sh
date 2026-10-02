#!/usr/bin/env bash
# Power: TLP (already this repo's choice, see 50-user-env), logind lid close = suspend, fwupd. Idle dimming,
# screen lock (kscreenlocker) and low-battery handling are Plasma's (powerdevil, keys in desktop/plasma/base.kconf).
# TLP over power-profiles-daemon: they conflict (only one may own the CPU/radio/USB knobs), TLP is
# already enabled here, and on a 2014 ThinkPad it gives real battery wins (runtime PM, USB/PCIe/SATA
# tuning) that PPD's three profiles do not. Plasma's battery applet works without PPD (no profile switch).
stagos_dm_power() {
  dm_pkgs tlp tlp-rdw fwupd upower python polkit
  if pacman -Q power-profiles-daemon >/dev/null 2>&1; then
    warn "power-profiles-daemon is installed and conflicts with TLP: sudo pacman -Rns power-profiles-daemon"
  fi
  dm_install "$HERE/desktop/tlp/50-stagos.conf" /etc/tlp.d/50-stagos.conf 644 sudo
  dm_write /etc/tlp.d/51-stagos-battery.conf 644 sudo < <(stagos_dm_battery_conf)
  dm_bins stag-battery
  stagos_dm_charge
  dm_install "$HERE/desktop/systemd/logind-lid.conf" /etc/systemd/logind.conf.d/50-stagos-lid.conf 644 sudo
  # tlp wants systemd-rfkill masked so it alone handles radio state
  if dm_have_systemd || dm_dry; then
    run sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket
  else
    dm_note "mask systemd-rfkill.service/.socket for TLP"
  fi
  dm_enable_system tlp.service fwupd-refresh.timer
  dm_note "battery: sudo tlp setcharge (applies the thresholds now), then stag-battery status (learned schedule)"
  dm_note "power: close the lid (suspends, Plasma locks on resume), check 'tlp-stat -s', 'fwupdmgr get-updates'"
  ok "power configured"
}

# TLP charge thresholds for BAT0 (TLP thinkpad plugin, kernel natacpi: charge_control_{start,end}_threshold).
# Ranges per TLP's vendor docs: start 0..99, stop 1..100, start below stop; factory 96/100 = thresholds off.
# STAGOS_BAT_FULL=1 writes the factory values: the controller keeps old thresholds across reboots, so
# leaving the keys out would not turn them off.
stagos_dm_battery_vals() { # prints "START STOP"
  local start="${STAGOS_BAT_START:-75}" stop="${STAGOS_BAT_STOP:-80}"
  if [[ "${STAGOS_BAT_FULL:-0}" == 1 ]]; then
    start=96; stop=100
  elif ! [[ "$start" =~ ^[0-9]+$ && "$stop" =~ ^[0-9]+$ ]] || (( start > 99 || stop < 1 || stop > 100 || start >= stop )); then
    warn "battery thresholds $start/$stop out of range (start 0..99 < stop 1..100): using 75/80"
    start=75; stop=80
  fi
  echo "$start $stop"
}
stagos_dm_battery_conf() {
  local start stop
  read -r start stop < <(stagos_dm_battery_vals)
  cat <<EOF
# StagOS battery care, generated from config/stagos.conf (STAGOS_BAT_START/STOP/FULL). Edit there, then
# ./stagos-desktop power && sudo tlp setcharge. For a trip: stag-battery full (100% until the next unplug).
# With STAGOS_BAT_OPTIMIZED=1, stag-charge (stagos-charge.timer) raises these for a short top-off before
# the usual unplug; these are the hold values it comes back to.
START_CHARGE_THRESH_BAT0=$start
STOP_CHARGE_THRESH_BAT0=$stop
EOF
}

# Optimized charging (macOS style): stag-charge, a root oneshot run by a 5 min timer, by udev on an AC
# change and after resume, learns the unplug times and tops off to 100% shortly before the usual one
# (see desktop/bin/stag-charge.py). It owns the thresholds through sysfs; stag-battery full|hold start
# two oneshot units that a narrow polkit rule lets a local wheel user start without a password.
# STAGOS_BAT_OPTIMIZED=0 (or STAGOS_BAT_FULL=1): the units stay, but stag-charge only puts the plain
# thresholds back once and keeps recording unplugs, so turning it on later starts with a history.
stagos_dm_battery_env() {
  local start stop opt="${STAGOS_BAT_OPTIMIZED:-1}" lead="${STAGOS_BAT_TOPOFF_LEAD:-90}" wake="${STAGOS_BAT_WAKE:-1}"
  read -r start stop < <(stagos_dm_battery_vals 2>/dev/null)
  [[ "$opt" == 1 && "${STAGOS_BAT_FULL:-0}" != 1 ]] || opt=0
  [[ "$wake" == 1 ]] || wake=0
  if ! [[ "$lead" =~ ^[0-9]+$ ]] || (( lead < 15 || lead > 480 )); then
    warn "STAGOS_BAT_TOPOFF_LEAD=$lead out of range (15..480 minutes): using 90"
    lead=90
  fi
  cat <<EOF
# StagOS optimized charging, generated from config/stagos.conf by stagos-desktop power (read by stag-charge).
OPTIMIZED=$opt
START=$start
STOP=$stop
LEAD_MIN=$lead
WAKE=$wake
EOF
}
stagos_dm_charge() {
  local before="$DM_CHANGED" u
  dm_write /etc/stagos/battery.conf 644 sudo < <(stagos_dm_battery_env)
  dm_install "$HERE/desktop/bin/stag-charge.py" /usr/local/bin/stag-charge 755 sudo
  for u in stagos-charge.service stagos-charge.timer stagos-charge-full.service stagos-charge-hold.service; do
    dm_install "$HERE/desktop/charge/$u" "/etc/systemd/system/$u" 644 sudo
  done
  dm_install "$HERE/desktop/charge/90-stagos-charge.rules" /etc/udev/rules.d/90-stagos-charge.rules 644 sudo
  # rules.d is root:polkitd 750, so dm_install (comparing as the user) would rewrite the rule on every run
  local pk=/etc/polkit-1/rules.d/50-stagos-charge.rules
  if dm_dry || ! sudo cmp -s "$HERE/desktop/charge/50-stagos-charge.rules" "$pk" 2>/dev/null \
     || [[ "$(sudo stat -c %a "$pk" 2>/dev/null)" != 644 ]]; then
    dm_install "$HERE/desktop/charge/50-stagos-charge.rules" "$pk" 644 sudo
  fi
  if (( DM_CHANGED > before )) && dm_have_systemd; then
    run sudo systemctl daemon-reload
    run sudo udevadm control --reload
  fi
  # enabled whatever STAGOS_BAT_OPTIMIZED says: with 0, stag-charge restores the plain thresholds once
  dm_enable_system stagos-charge.timer stagos-charge.service
}
