#!/bin/bash
# waybar: tailscale state. Short label, the address goes in the tooltip. Probe: stag-lib (shared with stag-status).
# shellcheck source=desktop/bin/stag-lib.sh
. stag-lib 2>/dev/null || { printf '{"text":"TS","class":"off","tooltip":"stag-lib missing (stagos-desktop bar)"}\n'; exit 0; }
ts="$(stag_ts)"
case "$ts" in
  none) printf '{"text":"TS","class":"off","tooltip":"tailscale not installed"}\n' ;;
  up\ *) printf '{"text":"TS","class":"ok","tooltip":"tailnet up  %s"}\n' "${ts#up }" ;;
  *)    printf '{"text":"TS","class":"off","tooltip":"tailnet down"}\n' ;;
esac
