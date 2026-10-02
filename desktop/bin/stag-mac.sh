#!/usr/bin/env bash
# stag-mac: which wifi networks use the real (hardware) MAC and which a random per-network one.
# The default for every saved wifi connection is a random MAC, stable per network (/etc/NetworkManager/conf.d/
# 20-stagos-mac.conf). A trusted network keeps the hardware MAC, so router allowlists and DHCP reservations work.
#   stag-mac list                 every saved wifi connection and its MAC mode
#   stag-mac trust "<name>"       use the hardware MAC for that connection (reconnect to apply)
#   stag-mac untrust "<name>"     back to the random per-network MAC
set -euo pipefail
PROP=802-11-wireless.cloned-mac-address
die() { echo "stag-mac: $*" >&2; exit 1; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \?//'; }

wifi_conns() { nmcli -t -f NAME,TYPE connection show | awk -F: '$NF=="802-11-wireless"{sub(/:802-11-wireless$/,""); gsub(/\\:/,":"); print}'; }
mode_of() { nmcli -g "$PROP" connection show id "$1" 2>/dev/null || true; }
need_conn() { [[ -n "${1:-}" ]] || die "name the connection (stag-mac list)"; wifi_conns | grep -qxF -- "$1" || die "no saved wifi connection called '$1'"; }

case "${1:-list}" in
  list)
    while IFS= read -r c; do
      m="$(mode_of "$c")"
      case "$m" in permanent) s="trusted (hardware MAC)" ;; ""|stable|stable-ssid) s="random per network" ;; *) s="custom: $m" ;; esac
      printf '%-30s %s\n' "$c" "$s"
    done < <(wifi_conns)
    ;;
  trust) need_conn "${2:-}"; nmcli connection modify id "$2" "$PROP" permanent; echo "trusted: $2 (reconnect to apply)" ;;
  untrust) need_conn "${2:-}"; nmcli connection modify id "$2" "$PROP" ""; echo "untrusted: $2 (reconnect to apply)" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
