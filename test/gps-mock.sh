#!/usr/bin/env bash
# Mock GPS: gpsfake replays a synthetic 3D-fix NMEA log on :2948 (real gpsd on
# :2947 untouched), then checks the top bar's source (stag-ctl recon status) reports a 3D fix.
# Run on stagpad: ./test/gps-mock.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v gpsfake >/dev/null || { echo "gpsfake missing (gpsd pkg)"; exit 1; }
nmea=$(mktemp --suffix=.nmea)
shim=$(mktemp -d)   # stag-ctl sources stag-lib from PATH; its own cache dir so a stale reading never answers
ln -s "$PWD/desktop/bin/stag-lib.sh" "$shim/stag-lib"; ln -s "$PWD/desktop/bin/stag-ctl.sh" "$shim/stag-ctl"
trap 'rm -rf "$nmea" "$shim"; kill "${gf:-0}" 2>/dev/null || true' EXIT
python3 - "$nmea" <<'PY'
import sys
def ck(s):
    c = 0
    for ch in s: c ^= ord(ch)
    return "$%s*%02X" % (s, c)
out = []
for i in range(60):
    t = "1200%02d.00" % i
    out.append(ck("GPGGA,%s,2811.0000,N,08221.0000,W,1,08,0.9,20.0,M,-30.0,M,," % t))
    out.append(ck("GPGSA,A,3,01,02,03,04,05,06,07,08,,,,,1.5,0.9,1.2"))
    out.append(ck("GPRMC,%s,A,2811.0000,N,08221.0000,W,0.0,0.0,270926,,," % t))
open(sys.argv[1], "w").write("\r\n".join(out) + "\r\n")
PY
gpsfake -q -c 0.2 -P 2948 "$nmea" >/dev/null 2>&1 & gf=$!
sleep 3
got=$(PATH="$shim:$PATH" STAGOS_CACHE="$shim/cache" STAGOS_GPSD=localhost:2948 stag-ctl recon status)
echo "$got"
if grep -q '"gps":{"installed":true,"mode":3}' <<<"$got"; then echo "gps mock: PASS"; else echo "gps mock: FAIL"; exit 1; fi
