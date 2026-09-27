#!/bin/bash
# waybar: GPS fix from gpsd. Shows sat count / fix mode when a dongle is attached.
if ! command -v gpspipe >/dev/null; then
  printf '{"text":"GPS n/a","class":"off"}\n'; exit 0
fi
# one TPV/SKY sample, non-blocking-ish
j=$(timeout 2 gpspipe -w -n 8 2>/dev/null | grep -m1 '"class":"TPV"')
mode=$(printf '%s' "$j" | grep -oE '"mode":[0-9]' | grep -oE '[0-9]$')
case "${mode:-0}" in
  3) printf '{"text":"GPS 3D","class":"ok"}\n' ;;
  2) printf '{"text":"GPS 2D","class":"ok"}\n' ;;
  *) printf '{"text":"GPS --","class":"off"}\n' ;;
esac
