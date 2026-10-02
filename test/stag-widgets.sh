#!/usr/bin/env bash
# Unit tests for stag-ctl, stag-status and stag-lib (the shell side of the org.stagos.* Plasma widgets),
# plus static checks of the plasmoid packages. No display, no Plasma: every tool is a stateful fake
# (test/fixtures/bin/fake-desktop) and /sys + /proc are a fake tree (test/fixtures/fake-desktop.sh).
# Run: ./test/stag-widgets.sh
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ORIG_PATH="$PATH"
# shellcheck source=test/fixtures/fake-desktop.sh
. "$ROOT/test/fixtures/fake-desktop.sh"
pass=0; fail=0
check() { # check "name" command...
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi
}
jq_ok() { command -v jq >/dev/null 2>&1; }
# jcheck NAME JSON JQ-FILTER: the filter must print "true" (skipped cleanly without jq: plain JSON syntax check)
jcheck() {
  if jq_ok; then check "$1" test "$(printf '%s' "$2" | jq -r "$3" 2>/dev/null)" = true
  else check "$1 (json parses)" python3 -c 'import json,sys; json.loads(sys.argv[1])' "$2"; fi
}
rc() { "$@" >/dev/null 2>&1; echo $?; }
new() { fake_desktop_setup "$T/sb"; }

# ---- stag-status ----
new
fake_state bt yes
J="$(stag-status --json)"
jcheck "status: valid JSON, v1" "$J" '.v == 1'
jcheck "status: default bar has every field in order" "$J" '[.fields[].id] == ["ts","gps","mon","cpu","ram","temp","net","bt","vol","bat","clock"]'
jcheck "status: fields carry text, state and tooltip" "$J" 'all(.fields[]; (.text|length) > 0 and (.state|IN("ok","off","hot")) and has("tooltip"))'
jcheck "status: ram from /proc/meminfo" "$J" '(.fields[] | select(.id=="ram") | .text) == "RAM 50"'
jcheck "status: temp prefers x86_pkg_temp" "$J" '(.fields[] | select(.id=="temp") | .text) == "52C"'
jcheck "status: wifi quality from /proc/net/wireless" "$J" '(.fields[] | select(.id=="net") | .text) == "WIFI 80"'
jcheck "status: bt powered via busctl" "$J" '(.fields[] | select(.id=="bt") | .state) == "ok"'
jcheck "status: vol from wpctl" "$J" '(.fields[] | select(.id=="vol") | .text) == "VOL 40"'
jcheck "status: battery text + watts" "$J" '(.fields[] | select(.id=="bat") | (.text == "BAT 81" and (.tooltip|test("7.5 W"))))'
jcheck "status: clock format from [bar]" "$J" '.clock_format == "ddd d MMM  HH:mm"'
jcheck "status: bar layout flags" "$J" '.bar.stag_menu == true and .bar.appmenu == true'
# cpu: the second call uses the delta against the first sample
echo "cpu  1500 0 1500 8000 0 0 0 0 0 0" > "$STAGOS_PROC/stat"
jcheck "status: cpu is the delta since the last poll" "$(stag-status --json)" '(.fields[] | select(.id=="cpu") | .text) == "CPU 100"'
# live toggles: [bar] is read on every call
sed -i 's/^cpu=true/cpu=false/; s/^recon=true/recon=false/; s/^clock=true/clock=false/' "$HOME/.config/stagos/desktop.conf"
jcheck "status: [bar] toggles drop fields at once" "$(stag-status --json)" '[.fields[].id] == ["ram","temp","net","bt","vol","bat"]'
printf '[bar]\nram=false\n# comment\n  vol = false  \n' > "$HOME/.config/stagos/desktop.conf"
mkdir -p "$HOME/.local/share/stagos/plasma"; cp "$ROOT/desktop/plasma/desktop.conf.default" "$HOME/.local/share/stagos/plasma/"
jcheck "status: missing keys fall back to desktop.conf.default" "$(stag-status --json)" '[.fields[].id] == ["ts","gps","mon","cpu","temp","net","bt","bat","clock"]'
rm "$HOME/.config/stagos/desktop.conf" "$HOME/.local/share/stagos/plasma/desktop.conf.default"
jcheck "status: no desktop.conf at all = everything on" "$(stag-status --json)" '(.fields|length) == 11'
# states
fake_state muted 1; fake_state bt no
J="$(stag-status --json)"
jcheck "status: muted shows MUTE" "$J" '(.fields[] | select(.id=="vol") | .text) == "MUTE"'
jcheck "status: bt off" "$J" '(.fields[] | select(.id=="bt") | .state) == "off"'
echo 9 > "$STAGOS_SYS/class/power_supply/BAT0/capacity"
jcheck "status: low battery is hot" "$(stag-status --json)" '(.fields[] | select(.id=="bat") | .state) == "hot"'
echo Charging > "$STAGOS_SYS/class/power_supply/BAT0/status"
jcheck "status: charging shows +" "$(stag-status --json)" '(.fields[] | select(.id=="bat") | .text) == "BAT 9+"'
# BAK: off unless [bar] bak=true; age and state from stag-backup's backup.state
jcheck "status: bak is off by default" "$(stag-status --json)" '[.fields[].id] | index("bak") == null'
printf '[bar]\nbak=true\n' > "$HOME/.config/stagos/desktop.conf"
jcheck "status: bak on, no backup yet" "$(stag-status --json)" '(.fields[] | select(.id=="bak") | (.text == "BAK --" and .state == "off"))'
jcheck "status: bak sits before bat" "$(stag-status --json)" '[.fields[].id] | (index("bak") + 1 == index("bat"))'
mkdir -p "$HOME/.local/state/stagos"; BS="$HOME/.local/state/stagos/backup.state"
printf 'last_ok=%s\nlast_rc=0\n' "$(( $(date +%s) - 5 * 3600 ))" > "$BS"
jcheck "status: bak 5h ok" "$(stag-status --json)" '(.fields[] | select(.id=="bak") | (.text == "BAK 5h" and .state == "ok"))'
printf 'last_ok=%s\nlast_rc=0\n' "$(( $(date +%s) - 4 * 86400 ))" > "$BS"
jcheck "status: bak older than 3 days is hot" "$(stag-status --json)" '(.fields[] | select(.id=="bak") | (.text == "BAK 4d" and .state == "hot"))'
printf 'last_ok=%s\nlast_rc=1\n' "$(( $(date +%s) - 3600 ))" > "$BS"
jcheck "status: bak hot after a failed run" "$(stag-status --json)" '(.fields[] | select(.id=="bak") | .state == "hot" and (.tooltip|test("failed")))'
rm -f "$HOME/.config/stagos/desktop.conf" "$BS"
echo down > "$STAGOS_SYS/class/net/wlan0/operstate"; echo 1 > "$STAGOS_SYS/class/rfkill/rfkill0/soft"
jcheck "status: wifi radio off" "$(stag-status --json)" '(.fields[] | select(.id=="net") | .text) == "WIFI off"'
fake_sys_iface enp0s25 1
jcheck "status: ethernet wins" "$(stag-status --json)" '(.fields[] | select(.id=="net") | .text) == "ETH"'
# recon: capture card in monitor mode is hot, slow probes come from the cache
fake_sys_iface wlan1 803 wireless
STAGOS_CACHE_SYNC=1 stag-status --json >/dev/null
J="$(stag-status --json)"
jcheck "status: MON <iface> hot when a card is in monitor mode" "$J" '(.fields[] | select(.id=="mon") | (.text == "MON wlan1" and .state == "hot"))'
jcheck "status: TS from the cache" "$J" '(.fields[] | select(.id=="ts") | .state) == "ok"'
jcheck "status: GPS 3D from the cache" "$J" '(.fields[] | select(.id=="gps") | .text) == "GPS 3D"'
fake_state ts down; fake_state gps 0; rm -f "$STAGOS_CACHE/ts" "$STAGOS_CACHE/gps"
J="$(STAGOS_CACHE_SYNC=1 stag-status --json)"
jcheck "status: tailnet down" "$J" '(.fields[] | select(.id=="ts") | .state) == "off"'
jcheck "status: no gps fix" "$J" '(.fields[] | select(.id=="gps") | .text) == "GPS --"'
# JSON escaping of hostile strings (SSID with quotes, backslash, tab)
fake_state ssid $'Caf\\e "5G"\tx'; rm -f "$STAGOS_SYS/class/net/enp0s25" -r; echo up > "$STAGOS_SYS/class/net/wlan0/operstate"
STAGOS_CACHE_SYNC=1 stag-status --json >/dev/null; rm -f "$STAGOS_CACHE/ssid"
J="$(STAGOS_CACHE_SYNC=1 stag-status --json)"
jcheck "status: hostile SSID stays valid JSON" "$J" '(.fields[] | select(.id=="net") | .tooltip) | startswith("Caf\\e \"5G\"")'
# stagbot readout from stag-ctl's cache
printf 'control|https://stag.example/control/\nmaps|https://stag.example/maps/\n' > "$HOME/.config/stagos/stag-services"
printf 'https://stag.example/maps/ 502\n' > "$FAKE_DIR/curl.codes"
stag-ctl stagbot status >/dev/null
J="$(stag-status --json)"
jcheck "status: stagbot hot with the down service named" "$J" '(.fields[] | select(.id=="stagbot") | (.state == "hot" and (.tooltip|test("1/2 up, down: maps"))))'
sed -i 's/^stag_menu=.*/stag_menu=false/' "$HOME/.config/stagos/desktop.conf" 2>/dev/null || printf '[bar]\nstag_menu=false\n' > "$HOME/.config/stagos/desktop.conf"
check "status --layout: the STAG menu flag, live" test "$(stag-status --layout)" = '{"stag_menu":false,"appmenu":true}'
check "status: text mode prints id<TAB>text" bash -c "stag-status | grep -qP '^ram\tRAM '"
check "status: bad option is a usage error" test "$(rc stag-status --bogus)" = 2
# speed: the whole readout, cached probes, must stay well under 100 ms (allow slack for a busy box)
start=$(date +%s%N); for _ in 1 2 3 4 5; do stag-status --json >/dev/null; done; ms=$(( ($(date +%s%N) - start) / 5000000 ))
echo "     stag-status: ${ms} ms per call (fakes)"
check "status: under 200 ms per call with bash fakes (real tools: ~60 ms on stagmini)" test "$ms" -lt 200

# ---- stag-ctl: toggles ----
new
jcheck "wifi status" "$(stag-ctl wifi status)" '.on == true and .ssid == "HomeNet" and .signal == 72'
jcheck "wifi toggle -> off" "$(stag-ctl wifi toggle)" '.on == false and .connected == false'
check "wifi off went through nmcli" grep -q '^nmcli radio wifi off' "$FAKE_LOG"
jcheck "wifi on" "$(stag-ctl wifi on)" '.on == true'
check "wifi junk arg -> 2" test "$(rc stag-ctl wifi sideways)" = 2
jcheck "bt status off" "$(stag-ctl bt status)" '.on == false and .available == true'
: > "$FAKE_LOG"
jcheck "bt on unblocks rfkill + powers on" "$(stag-ctl bt on)" '.on == true'
check "bt on: rfkill unblock before power on" bash -c "grep -n . '$FAKE_LOG' | grep -q 'rfkill unblock bluetooth' && grep -q 'bluetoothctl power on' '$FAKE_LOG'"
fake_state bt_conn 1
jcheck "bt connected count" "$(stag-ctl bt status)" '.connected == 1'
jcheck "bt toggle -> off" "$(stag-ctl bt toggle)" '.on == false'
fake_state bt_adapter no
jcheck "bt: no adapter = unavailable" "$(stag-ctl bt status)" '.available == false'
rm "$T/sb/bin/nmcli"
check "wifi without nmcli -> 3" test "$(rc stag-ctl wifi status)" = 3

# DND: Plasma's plasmanotifyrc [DoNotDisturb] Until
new
jcheck "dnd off by default" "$(stag-ctl dnd status)" '.on == false'
jcheck "dnd on" "$(stag-ctl dnd on)" '.on == true'
check "dnd on writes Until a year ahead, with --notify" bash -c "grep -q -- '--group DoNotDisturb --key Until --notify $(( $(date +%Y) + 1 )),' '$FAKE_LOG'"
jcheck "dnd toggle -> off deletes Until" "$(stag-ctl dnd toggle)" '.on == false'
check "dnd off: --delete --notify" grep -q -- '--key Until --notify --delete' "$FAKE_LOG"
echo "DoNotDisturb|Until=2001,1,1,0,0,0" > "$FAKE_DIR/kconfig/plasmanotifyrc"
jcheck "dnd: an Until in the past is off" "$(stag-ctl dnd status)" '.on == false'
echo "DoNotDisturb|Until=2999,12,31,23,59,1.5" > "$FAKE_DIR/kconfig/plasmanotifyrc"
jcheck "dnd: fractional seconds parse" "$(stag-ctl dnd status)" '.on == true'

# Night light: KWin (kwinrc [NightColor] Active + org.kde.KWin.NightLight)
new
fake_state plasma yes
jcheck "night off" "$(stag-ctl night status)" '.on == false and .running == false'
fake_state night_now no   # daytime: a sunset schedule would not warm the screen yet
jcheck "night on via kwinrc, warm right away (daytime)" "$(stag-ctl night on)" '.on == true and .running == true and .temp == 4500'
check "night on: Mode=Constant (Mac style, not the schedule)" grep -q -- 'kwriteconfig6 --file kwinrc --group NightColor --key Mode --notify Constant' "$FAKE_LOG"
check "night: KWin state read as D-Bus properties (Properties.Get)" grep -q -- 'org.freedesktop.DBus.Properties.Get org.kde.KWin.NightLight running' "$FAKE_LOG"
check "night on: bool with --notify" grep -q -- 'kwriteconfig6 --file kwinrc --group NightColor --key Active --type bool --notify true' "$FAKE_LOG"
jcheck "night toggle -> off" "$(stag-ctl night toggle)" '.on == false'
fake_state plasma no
check "night outside Plasma -> 3 (not available)" test "$(rc stag-ctl night on)" = 3

# ---- volume, brightness, media ----
new
jcheck "vol get" "$(stag-ctl vol get)" '.volume == 40 and .muted == false'
jcheck "vol set 65" "$(stag-ctl vol set 65)" '.volume == 65'
check "vol set caps at 100% (-l 1.0)" grep -q 'wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 65%' "$FAKE_LOG"
jcheck "vol set 150 clamps" "$(stag-ctl vol set 150)" '.volume == 100'
jcheck "vol mute toggles" "$(stag-ctl vol mute)" '.muted == true'
jcheck "vol mute off" "$(stag-ctl vol mute off)" '.muted == false'
check "vol set junk -> 2" test "$(rc stag-ctl vol set loud)" = 2
check "vol set -5 -> 2" test "$(rc stag-ctl vol set -5)" = 2
fake_state sink no
check "vol: no sink -> 3" test "$(rc stag-ctl vol get)" = 3
jcheck "bright get from sysfs" "$(stag-ctl bright get)" '.available == true and .percent == 50'
jcheck "bright set via brightnessctl without powerdevil" "$(stag-ctl bright set 30)" '.percent == 30'
check "bright: brightnessctl used" grep -q 'brightnessctl -q set 30%' "$FAKE_LOG"
fake_state powerdevil yes; : > "$FAKE_LOG"
jcheck "bright set via powerdevil when it runs" "$(stag-ctl bright set 80)" '.percent == 80'
check "bright: powerdevil displays and max read as D-Bus properties" bash -c "grep -q 'Properties.Get org.kde.ScreenBrightness DisplaysDBusNames' '$FAKE_LOG' && grep -q 'Properties.Get org.kde.ScreenBrightness.Display MaxBrightness' '$FAKE_LOG'"
check "bright: powerdevil SetBrightness raw value, no OSD" bash -c "grep -q 'Display.SetBrightness 800 1' '$FAKE_LOG' && ! grep -q brightnessctl '$FAKE_LOG'"
jcheck "bright set 0 keeps the screen on (1%)" "$(stag-ctl bright set 0)" '.percent == 1'
rm -rf "$STAGOS_SYS/class/backlight/intel_backlight"
check "bright: no backlight -> 3" test "$(rc stag-ctl bright get)" = 3
jcheck "media: no player" "$(stag-ctl media status)" '.available == false'
fake_state player spotify
jcheck "media status" "$(stag-ctl media status)" '.available == true and .status == "Playing" and .title == "Track 1" and .artist == "The Band"'
jcheck "media play-pause" "$(stag-ctl media play-pause)" '.status == "Paused"'
jcheck "media next" "$(stag-ctl media next)" '.title == "Track 2"'
jcheck "media prev" "$(stag-ctl media prev)" '.title == "Track 1"'
fake_state title $'Song "quoted" \\ back'
jcheck "media: quotes in titles stay valid JSON" "$(stag-ctl media status)" '.title == "Song \"quoted\" \\ back"'

# ---- recon ----
new
jcheck "recon: no capture card configured" "$(stag-ctl recon status)" '.capture.mode == "unset" and .ts.up == true and .gps.mode == 3 and .kismet.running == false'
check "recon mon on without a card -> 3" test "$(rc stag-ctl recon mon on)" = 3
sed -i 's/^capture_iface=.*/capture_iface=wlan1/' "$HOME/.config/stagos/desktop.conf"
check "recon mon on with the card absent -> 3" test "$(rc stag-ctl recon mon on)" = 3
fake_sys_iface wlan1 1 wireless
jcheck "recon: card managed" "$(stag-ctl recon status)" '.capture.iface == "wlan1" and .capture.mode == "managed"'
: > "$FAKE_LOG"; stag-ctl recon mon on >/dev/null
check "recon mon on: stag-mon in a terminal, like the dock tile" grep -q '^foot -T stag-mon -e stag-mon' "$FAKE_LOG"
echo 803 > "$STAGOS_SYS/class/net/wlan1/type"; : > "$FAKE_LOG"
jcheck "recon: card in monitor mode" "$(stag-ctl recon mon on)" '.capture.mode == "monitor" and .capture.monitor == "wlan1"'
check "recon mon on when already on: no terminal" bash -c "! grep -q '^foot' '$FAKE_LOG'"
rm "$T/sb/bin/foot"; : > "$FAKE_LOG"; stag-ctl recon mon off >/dev/null
check "recon mon off falls back to konsole" grep -q '^konsole -p tabtitle=stag-mon -e stag-mon' "$FAKE_LOG"
# the capture card from config/stagos.conf (literal value; shell expressions are ignored)
sed -i 's/^capture_iface=.*/capture_iface=/' "$HOME/.config/stagos/desktop.conf"
mkdir -p "$HOME/stagos/config"
# shellcheck disable=SC2016  # the literal shell expression config/stagos.conf ships
printf 'STAGOS_CAPTURE_IFACE="${STAGOS_CAPTURE_IFACE:-}"   # comment\n' > "$HOME/stagos/config/stagos.conf"
jcheck "recon: stagos.conf default expression = unset" "$(stag-ctl recon status)" '.capture.mode == "unset"'
printf 'STAGOS_CAPTURE_IFACE="wlan1"\n' > "$HOME/stagos/config/local.conf"
jcheck "recon: capture card from config/local.conf" "$(stag-ctl recon status)" '.capture.iface == "wlan1"'
jcheck "recon kismet start" "$(stag-ctl recon kismet start)" '.kismet.running == true'
check "kismet started detached in ~/.kismet/logs" bash -c "grep -q '^setsid -f kismet --no-ncurses' '$FAKE_LOG' && test -d '$HOME/.kismet/logs'"
jcheck "recon kismet stop" "$(stag-ctl recon kismet stop)" '.kismet.running == false'
check "recon junk -> 2" test "$(rc stag-ctl recon kismet explode)" = 2

# ---- stagbot ----
new
check "stagbot: no services file -> 3" test "$(rc stag-ctl stagbot status)" = 3
printf 'control|https://stag.example/control/\nmaps|https://stag.example/maps/\ntasks|https://stag.example/tasks/\n' > "$HOME/.config/stagos/stag-services"
printf 'https://stag.example/maps/ 000\nhttps://stag.example/tasks/ 401\n' > "$FAKE_DIR/curl.codes"
export FAKE_CURL_SLEEP=1
start=$(date +%s%N); J="$(stag-ctl stagbot status)"; ms=$(( ($(date +%s%N) - start) / 1000000 ))
unset FAKE_CURL_SLEEP
jcheck "stagbot: per-service up/down (401 = up, no answer = down)" "$J" '.total == 3 and .up == 2 and ([.services[] | select(.up == false) | .name] == ["maps"])'
check "stagbot: HEAD requests run in parallel (${ms} ms for 3 x 1 s)" test "$ms" -lt 2500
check "stagbot: HEAD with a 3 s timeout" grep -q 'curl -sS -o /dev/null -I --max-time 3' "$FAKE_LOG"
: > "$FAKE_LOG"; stag-ctl stagbot status >/dev/null
check "stagbot: second call within 30 s is served from the cache" bash -c "! grep -q '^curl' '$FAKE_LOG'"
stag-ctl stagbot status --refresh >/dev/null
check "stagbot: --refresh probes again" grep -q '^curl' "$FAKE_LOG"
: > "$FAKE_LOG"
jcheck "stagbot open with text copies it (no prefill in stag-control)" "$(stag-ctl stagbot open 'what is up with "maps"?')" '.opened == true and .copied == true and .prefill == false'
check "stagbot open: exact text on the clipboard" test "$(cat "$FAKE_DIR/clipboard")" = 'what is up with "maps"?'
check "stagbot open: chromium --app on the control url" grep -q '^chromium --app=https://stag.example/control/' "$FAKE_LOG"
mkdir -p "$HOME/.local/share/applications"; touch "$HOME/.local/share/applications/stag-control.desktop"; : > "$FAKE_LOG"
jcheck "stagbot open without text" "$(stag-ctl stagbot open)" '.copied == false'
check "stagbot open prefers the stag-control.desktop launcher" grep -q '^gtk-launch stag-control' "$FAKE_LOG"
printf 'maps|https://stag.example/maps/\n' > "$HOME/.config/stagos/stag-services"
check "stagbot open without a control entry -> 3" test "$(rc stag-ctl stagbot open)" = 3

# ---- apps, about, session ----
new
jcheck "apps: empty without a services file" "$(stag-ctl apps)" '.apps == []'
printf 'control|https://stag.example/control/\nmaps|https://stag.example/maps/\n' > "$HOME/.config/stagos/stag-services"
J="$(stag-ctl apps)"
jcheck "apps: names and titles, no urls" "$J" '[.apps[].title] == ["Stag Control","Stag Maps"] and (tostring | test("example") | not)'
: > "$FAKE_LOG"; stag-ctl app open maps >/dev/null
check "app open falls back to chromium --app" grep -q '^chromium --app=https://stag.example/maps/' "$FAKE_LOG"
check "app open unknown -> 3" test "$(rc stag-ctl app open nope)" = 3
J="$(stag-ctl about)"
jcheck "about: host, kernel, uptime, cpu" "$J" '.host == "stagpad" and .kernel == "6.10.0-arch1-1" and .uptime == "1d 2h 3m" and (.cpu|test("i5-5300U"))'
jcheck "about: ram and battery health" "$J" '.ram_total_mb == 7617 and .ram_used_mb == 3808 and .battery.health == 80 and .battery.cycles == 312'
jcheck "about: stag-settings missing -> settings false" "$J" '.settings == false'
ln -s "$ROOT/test/fixtures/bin/fake-desktop" "$T/sb/bin/stag-settings"
jcheck "about: stag-settings present -> settings true" "$(stag-ctl about)" '.settings == true'
: > "$FAKE_LOG"; fake_state plasma yes
stag-ctl session reboot >/dev/null
check "session reboot through Plasma's logout (org.kde.Shutdown)" grep -q 'qdbus6 org.kde.Shutdown /Shutdown org.kde.Shutdown.logoutAndReboot' "$FAKE_LOG"
fake_state plasma no; : > "$FAKE_LOG"
stag-ctl session poweroff >/dev/null
check "session poweroff without Plasma: systemctl" grep -q '^systemctl poweroff' "$FAKE_LOG"
check "session labwc is gone -> 2" test "$(rc stag-ctl session labwc)" = 2
check "session junk -> 2" test "$(rc stag-ctl session dance)" = 2
J="$(stag-ctl control)"
jcheck "control: one JSON with every section" "$J" 'has("wifi") and has("bt") and has("dnd") and has("night") and .vol.volume == 40 and .bright.percent == 50 and has("media") and .recon.gps.mode == 3'
check "unknown command -> 2" test "$(rc stag-ctl frobnicate)" = 2
check "no arguments -> 2" test "$(rc stag-ctl)" = 2
check "stag-lib refuses to run directly" test "$(rc bash "$ROOT/desktop/bin/stag-lib.sh")" = 2
PATH="$ORIG_PATH"

# ---- stag-lib recon helpers as the top bar sees them (tailnet ip, gps fix, a card already in monitor mode) ----
new
fake_sys_iface wlan1 803 wireless
jcheck "recon via stag-lib: tailnet ip, 3D fix, monitor-mode card" "$(stag-ctl recon status)" '.ts.ip == "100.64.0.7" and .gps.mode == 3 and .capture.monitor == "wlan1"'
PATH="$ORIG_PATH"

# ---- plasmoid packages (static; kpackagetool6 + qmllint run in the container test) ----
P="$ROOT/desktop/plasma/plasmoids"
for id in org.stagos.menu org.stagos.status; do
  check "$id: metadata.json parses, Id matches, Plasma/Applet" python3 - "$P/$id/metadata.json" "$id" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["KPlugin"]["Id"] == sys.argv[2], m["KPlugin"]["Id"]
assert m["KPackageStructure"] == "Plasma/Applet"
assert m["X-Plasma-API-Minimum-Version"].startswith("6")
PY
  check "$id: has contents/ui/main.qml with a PlasmoidItem" grep -q 'PlasmoidItem' "$P/$id/contents/ui/main.qml"
done
check "plasmoids: no external urls, no eval" bash -c "! grep -rnE 'https?://|eval\\(|new Function' '$P' --include=*.qml --include=*.js"
check "plasmoids: user text is shell quoted before it reaches a command" grep -q 'function shq' "$P/org.stagos.status/contents/ui/Exec.qml"
L="$ROOT/desktop/plasma/layout.js"
check "layout.js: slots keep their markers" bash -c "for w in menu status control; do grep -qx \"// STAGOS_WIDGET \$w\" '$L' && grep -qx \"// END_STAGOS_WIDGET \$w\" '$L' || exit 1; done"
check "layout.js: org.stagos.menu and org.stagos.status in the bar" bash -c "grep -q 'addWidget(\"org.stagos.menu\")' '$L' && grep -q 'addWidget(\"org.stagos.status\")' '$L'"
check "layout.js: stand-ins gone (kickoff, digital clock)" bash -c "! grep -qE 'org.kde.plasma.(kickoff|digitalclock)' '$L'"
check "layout.js: systray keeps notifications, drops the applets the readouts replace" bash -c "grep -q 'org.kde.plasma.notifications' '$L' && grep -q 'org.kde.plasma.networkmanagement' '$L'"
CC="$ROOT/desktop/plasma/plasmoids/org.stagos.status/contents/ui/ControlCenter.qml"
check "Control Center: a disabled Monitor button says why" bash -c "grep -q 'Monitor: no card' '$CC' && grep -q 'Monitor: unplugged' '$CC'"

echo; echo "stag-widgets: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
