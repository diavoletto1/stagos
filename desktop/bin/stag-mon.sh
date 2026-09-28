#!/bin/bash
# StagOS: toggle monitor mode on the dedicated capture card. Never touches the
# built-in card: only STAGOS_CAPTURE_IFACE (env or config/stagos.conf) is used.
# Meant to run in a terminal (sudo prompt). STAGOS_MOCK_WIFI=1 prints instead of running.
conf="${STAGOS_CONF:-$HOME/stagos/config/stagos.conf}"
if [ -z "${STAGOS_CAPTURE_IFACE:-}" ] && [ -r "$conf" ]; then
  # shellcheck source=/dev/null
  . "$conf"
fi
iface="${STAGOS_CAPTURE_IFACE:-}"
pause() { if [ -t 0 ]; then read -rp "press enter to close " _; fi; }
run() { if [ -n "${STAGOS_MOCK_WIFI:-}" ]; then echo "[mock] $*"; else "$@"; fi; }

if [ -z "$iface" ]; then
  echo "no capture card configured (set STAGOS_CAPTURE_IFACE in config/stagos.conf)"
  pause; exit 1
fi
if [ ! -d "/sys/class/net/$iface/wireless" ] && [ -z "${STAGOS_MOCK_WIFI:-}" ]; then
  echo "$iface not present - is the capture card plugged in?"
  pause; exit 1
fi
cur=$(iw dev "$iface" info 2>/dev/null | awk '/type/{print $2}')
if [ "$cur" = monitor ]; then want=managed; else want=monitor; fi
echo "$iface: ${cur:-unknown} -> $want"
if run sudo ip link set "$iface" down &&
   run sudo iw dev "$iface" set type "$want" &&
   run sudo ip link set "$iface" up; then
  echo "done: $iface is $want"
else
  echo "failed"; pause; exit 1
fi
pause
