#!/bin/bash
# waybar: capture-card state. Red "MON" when any wifi iface is in monitor mode.
mon=""
for dev in /sys/class/net/*/type; do
  iface=$(basename "$(dirname "$dev")")
  [ -d "/sys/class/net/$iface/wireless" ] || continue
  t=$(iw dev "$iface" info 2>/dev/null | grep -oE 'type [a-z]+' | awk '{print $2}')
  if [ "$t" = "monitor" ]; then mon="$iface"; break; fi
done
if [ -n "$mon" ]; then
  printf '{"text":"MON %s","class":"hot","tooltip":"capturing on %s"}\n' "$mon" "$mon"
else
  printf '{"text":"MON off","class":"off"}\n'
fi
