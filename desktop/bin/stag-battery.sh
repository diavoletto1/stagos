#!/bin/bash
# StagOS battery care (TLP charge thresholds from config/stagos.conf, optimized charging by stag-charge).
#   stag-battery            same as status
#   stag-battery status     charge, health, the thresholds in use now, the learned unplug schedule and the
#                           next planned top-off (optimized charging)
#   stag-battery full       charge to 100% now (trips), until the next unplug
#   stag-battery hold       back to the hold threshold (80%) now, also ends a top-off in progress
#   stag-battery normal     same as hold
# Optimized (STAGOS_BAT_OPTIMIZED=1): full/hold start stagos-charge-full/-hold.service, no password for a
# local wheel user (polkit rule). Off: sudo tlp fullcharge / sudo tlp setcharge.
set -uo pipefail
SYS="${STAGOS_SYS:-/sys}"
BAT="${STAGOS_BAT:-BAT0}"
B="$SYS/class/power_supply/$BAT"
CONF="${STAGOS_CHARGE_CONF:-/etc/stagos/battery.conf}"
rd() { cat "$1" 2>/dev/null; }
optimized() { grep -qx 'OPTIMIZED=1' "$CONF" 2>/dev/null && command -v stag-charge >/dev/null; }

status() {
  local cap st s e full design
  [ -d "$B" ] || { echo "no battery $BAT"; return 1; }
  cap="$(rd "$B/capacity")"; st="$(rd "$B/status")"
  s="$(rd "$B/charge_control_start_threshold")"; e="$(rd "$B/charge_control_end_threshold")"
  full="$(rd "$B/energy_full")"; design="$(rd "$B/energy_full_design")"
  echo "battery:    ${cap:-?}% ${st,,}"
  if [[ "$full" =~ ^[0-9]+$ && "$design" =~ ^[0-9]+$ && "$design" -gt 0 ]]; then echo "health:     $((full * 100 / design))% of design"; fi
  if [ -n "$e" ]; then
    if [ "$e" -ge 100 ]; then echo "thresholds: off (charges to 100%)"
    else echo "thresholds: charge starts below ${s:-?}%, stops at $e%"; fi
  else
    echo "thresholds: not exposed by the kernel (thinkpad_acpi natacpi)"
  fi
  if command -v stag-charge >/dev/null && [ -r "$CONF" ]; then stag-charge status; fi
}

case "${1:-status}" in
  status) status ;;
  full)
    if optimized; then
      systemctl start stagos-charge-full.service || exit
      echo "charging to 100% now; back to the hold threshold after the next unplug or with: stag-battery hold"
    else
      sudo tlp fullcharge "$BAT" || exit
      echo "charging to 100% this once; thresholds return at the next boot or with: stag-battery hold"
    fi ;;
  hold|normal)
    if optimized; then systemctl start stagos-charge-hold.service || exit
    else sudo tlp setcharge "$BAT" || exit; fi
    status ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "stag-battery: unknown command $1 (see --help)" >&2; exit 2 ;;
esac
