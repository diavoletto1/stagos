#!/bin/bash
# StagOS battery care (TLP charge thresholds, see /etc/tlp.d/51-stagos-battery.conf from config/stagos.conf).
#   stag-battery            same as status
#   stag-battery status     charge, health and the thresholds the battery is using now
#   stag-battery full       charge to 100% once (trips): sudo tlp fullcharge; the configured thresholds come
#                           back at the next boot or with `stag-battery normal`
#   stag-battery normal     put the configured thresholds back now (sudo tlp setcharge)
set -uo pipefail
SYS="${STAGOS_SYS:-/sys}"
BAT="${STAGOS_BAT:-BAT0}"
B="$SYS/class/power_supply/$BAT"
rd() { cat "$1" 2>/dev/null; }

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
}

case "${1:-status}" in
  status) status ;;
  full)
    sudo tlp fullcharge "$BAT" || exit
    echo "charging to 100% this once; thresholds return at the next boot or with: stag-battery normal" ;;
  normal)
    sudo tlp setcharge "$BAT" || exit
    status ;;
  -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "stag-battery: unknown command $1 (see --help)" >&2; exit 2 ;;
esac
