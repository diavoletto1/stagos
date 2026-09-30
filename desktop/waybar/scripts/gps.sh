#!/bin/bash
# waybar: GPS fix from gpsd. Shows fix mode when a dongle is attached. Probe: stag-lib (shared with stag-status).
# STAGOS_GPSD=host:port overrides (tests/gpsfake).
# shellcheck source=desktop/bin/stag-lib.sh
. stag-lib 2>/dev/null || { printf '{"text":"GPS ?","class":"off"}\n'; exit 0; }
case "$(stag_gps)" in
  na) printf '{"text":"GPS n/a","class":"off"}\n' ;;
  3)  printf '{"text":"GPS 3D","class":"ok"}\n' ;;
  2)  printf '{"text":"GPS 2D","class":"ok"}\n' ;;
  *)  printf '{"text":"GPS --","class":"off"}\n' ;;
esac
