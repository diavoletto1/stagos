#!/bin/bash
# StagOS low-battery watcher: notify at 20% and 10% (critical), once per discharge.
# Runs from labwc autostart. STAGOS_BAT_SYS overrides /sys/class/power_supply for tests,
# STAGOS_BAT_ONCE=1 checks once and exits.
sys="${STAGOS_BAT_SYS:-/sys/class/power_supply}"
warned=0
while :; do
  cap=""; status=""
  for b in "$sys"/BAT*; do
    [ -r "$b/capacity" ] || continue
    cap=$(cat "$b/capacity"); status=$(cat "$b/status"); break
  done
  if [ -n "$cap" ]; then
    if [ "$status" != Discharging ]; then warned=0
    elif [ "$cap" -le 10 ] && [ "$warned" -lt 2 ]; then
      notify-send -u critical "Battery critical: ${cap}%" "Plug in now."; warned=2
    elif [ "$cap" -le 20 ] && [ "$warned" -lt 1 ]; then
      notify-send -u normal "Battery low: ${cap}%" "Plug in soon."; warned=1
    fi
  fi
  [ "${STAGOS_BAT_ONCE:-0}" = 1 ] && exit 0
  sleep 60
done
