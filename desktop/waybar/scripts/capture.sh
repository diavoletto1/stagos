#!/bin/bash
# waybar: capture-card state. Red "MON" when any wifi iface is in monitor mode. Probe: stag-lib.
# shellcheck source=desktop/bin/stag-lib.sh
. stag-lib 2>/dev/null || { printf '{"text":"MON ?","class":"off"}\n'; exit 0; }
if mon="$(stag_mon_iface)"; then
  printf '{"text":"MON %s","class":"hot","tooltip":"capturing on %s"}\n' "$mon" "$mon"
else
  printf '{"text":"MON off","class":"off"}\n'
fi
