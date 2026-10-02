#!/bin/bash
# StagOS top bar readouts for the org.stagos.status plasmoid (polled every few seconds).
#   stag-status --json     one JSON line: {"v":1,"bar":{...},"clock_format":"...","fields":[...]}
#   stag-status            the same fields as "id<TAB>text" lines (for a terminal)
#   stag-status --layout   only the [bar] layout flags: {"stag_menu":true,"appmenu":true} (the STAG menu polls it)
# Reads [bar] of ~/.config/stagos/desktop.conf on every call and emits only the enabled fields, so bar
# toggles are live. Each field: id, group (recon|stats|stagbot|core), text, state (ok|off|hot), tooltip.
# Fast by design (well under 100 ms): /proc and /sys through bash builtins, wpctl and busctl only when
# their field is on, slow probes (tailscale, gpsd, stag services, SSID) come from ~/.cache/stagos and are
# refreshed in the background.
set -uo pipefail
# shellcheck source=desktop/bin/stag-lib.sh
. stag-lib || { echo '{"v":1,"error":"stag-lib missing","fields":[]}'; exit 3; }

mode=text
case "${1:-}" in
  --json) mode=json ;;
  --layout)
    printf '{"stag_menu":%s,"appmenu":%s}\n' "$(stag_conf_bool bar stag_menu && echo true || echo false)" \
      "$(stag_conf_bool bar appmenu && echo true || echo false)"
    exit 0 ;;
  ''|--text) ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "stag-status: unknown option $1 (see --help)" >&2; exit 2 ;;
esac

FIELDS=()
emit() { # id group text state tooltip
  if [ "$mode" = json ]; then
    local t tip
    stag_json_esc_v t "$3"; stag_json_esc_v tip "$5"
    FIELDS+=("{\"id\":\"$1\",\"group\":\"$2\",\"text\":\"$t\",\"state\":\"$4\",\"tooltip\":\"$tip\"}")
  else
    FIELDS+=("$1"$'\t'"$3")
  fi
}
on() { stag_conf_bool bar "$1" true; }

# ---- recon: TS / GPS / MON ----
recon() {
  local ts gps iface m
  ts="$(stag_cached ts 10 stag_ts)"
  case "$ts" in
    up\ *) emit ts recon TS ok "tailnet up  ${ts#up }" ;;
    down)  emit ts recon TS off "tailnet down" ;;
    none)  emit ts recon TS off "tailscale not installed" ;;
    *)     emit ts recon TS off "tailnet: checking" ;;
  esac
  gps="$(stag_cached gps 5 stag_gps)"
  case "$gps" in
    3|2) emit gps recon "GPS ${gps}D" ok "gpsd: ${gps}D fix" ;;
    na)  emit gps recon "GPS n/a" off "gpsd not installed" ;;
    0)   emit gps recon "GPS --" off "gpsd: no fix" ;;
    *)   emit gps recon "GPS --" off "gpsd: checking" ;;
  esac
  if m="$(stag_mon_iface)"; then
    emit mon recon "MON $m" hot "capturing on $m"
  else
    iface="$(stag_capture_iface)"
    if [ -z "$iface" ]; then emit mon recon "MON off" off "no capture card configured"
    else emit mon recon "MON off" off "$iface: $(stag_iface_mode "$iface")"; fi
  fi
}

# ---- stats ----
cpu() {
  local _c user nice sys idle iow irq sirq steal total busy pt pb pct=0 f="$STAG_CACHE/cpu.prev"
  read -r _c user nice sys idle iow irq sirq steal _ < "$STAG_PROC/stat" || return
  total=$((user + nice + sys + idle + iow + irq + sirq + steal)); busy=$((total - idle - iow))
  if [ -r "$f" ] && read -r pt pb < "$f" && [ $((total - pt)) -gt 0 ]; then
    pct=$(( (busy - pb) * 100 / (total - pt) ))
  elif [ "$total" -gt 0 ]; then
    pct=$((busy * 100 / total))
  fi
  mkdir -p "$STAG_CACHE"; echo "$total $busy" > "$f"
  [ "$pct" -lt 0 ] && pct=0
  local load; read -r load _ < "$STAG_PROC/loadavg" || load="?"
  emit cpu stats "CPU $pct" "$([ "$pct" -ge 90 ] && echo hot || echo ok)" "cpu ${pct}%  load $load"
}
ram() {
  local k v _u total=0 avail=0
  while read -r k v _u; do
    case "$k" in MemTotal:) total=$v ;; MemAvailable:) avail=$v ;; esac
  done < "$STAG_PROC/meminfo"
  [ "$total" -gt 0 ] || return
  local pct=$(( (total - avail) * 100 / total ))
  emit ram stats "RAM $pct" "$([ "$pct" -ge 90 ] && echo hot || echo ok)" \
    "ram $(( (total - avail) / 1024 )) / $(( total / 1024 )) MiB"
}
temp() {
  local z t="" name
  for z in "$STAG_SYS"/class/thermal/thermal_zone*; do
    [ "$(stag_read "$z/type")" = x86_pkg_temp ] && { t="$(stag_read "$z/temp")"; break; }
  done
  if [ -z "$t" ]; then
    for z in "$STAG_SYS"/class/hwmon/hwmon*; do
      name="$(stag_read "$z/name")"
      case "$name" in coretemp|k10temp|zenpower|cpu_thermal) t="$(stag_read "$z/temp1_input")"; break ;; esac
    done
  fi
  [ -z "$t" ] && for z in "$STAG_SYS"/class/thermal/thermal_zone*; do t="$(stag_read "$z/temp")" && break; done
  [[ "$t" =~ ^[0-9]+$ ]] || return
  t=$((t / 1000))
  emit temp stats "${t}C" "$([ "$t" -ge 85 ] && echo hot || echo ok)" "cpu package ${t} C"
}

# ---- stagbot: stag services up/down from stag-ctl's 30 s cache ----
stagbot() {
  local f="$STAG_CACHE/stagbot.json" j now ts up total
  [ -s "$(stag_services_file)" ] || return
  j="$(stag_read "$f")" || j=""
  now="$(stag_now)"
  ts="$(expr_json_num "$j" ts)"; up="$(expr_json_num "$j" up)"; total="$(expr_json_num "$j" total)"
  if [ -z "$ts" ] || [ $((now - ts)) -ge 30 ]; then
    ( stag-ctl stagbot status ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  if [ -z "$total" ]; then emit stagbot stagbot BOT off "stag services: checking"
  elif [ "$up" = "$total" ]; then emit stagbot stagbot BOT ok "stag services: $up/$total up"
  else emit stagbot stagbot BOT hot "stag services: $up/$total up$(down_names "$j")"; fi
}
expr_json_num() { # JSON KEY: top-level integer (stag-ctl writes flat, known JSON)
  local re="\"$2\":([0-9]+)"
  [[ "$1" =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
}
down_names() {
  local j="$1" out="" re='"name":"([^"]*)"[^}]*"up":false'
  while [[ "$j" =~ $re ]]; do out+=" ${BASH_REMATCH[1]}"; j="${j#*"${BASH_REMATCH[0]}"}"; done
  [ -n "$out" ] && printf ', down:%s' "$out"
}

# ---- core: net, bt, vol, bat, clock ----
ssid_probe() { nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2 ~ /wireless/ {print $1; exit}'; }
net() {
  local d i st wl="" q="" line eth=""
  for d in "$STAG_SYS"/class/net/*; do
    i="${d##*/}"
    [ "$(stag_read "$d/operstate")" = up ] || continue
    if [ -d "$d/wireless" ]; then [ -z "$wl" ] && wl="$i"
    else case "$i" in en*|eth*) eth="$i" ;; esac; fi
  done
  if [ -n "$eth" ]; then emit net core ETH ok "ethernet on $eth"; return; fi
  if [ -n "$wl" ]; then
    # /proc/net/wireless: "wlan0: 0000   54.  -56. ..." (link quality out of 70)
    while read -r line; do
      [ "${line%%:*}" = "$wl" ] || continue
      read -r _ _ q _ <<< "$line"; q="${q%.}"
    done < "$STAG_PROC/net/wireless" 2>/dev/null
    [[ "$q" =~ ^[0-9]+$ ]] && q=$((q * 100 / 70)) && [ "$q" -gt 100 ] && q=100
    st="$(stag_cached ssid 30 ssid_probe)"
    emit net core "WIFI ${q:---}" ok "${st:-wifi}  on $wl${q:+  ${q}%}"
    return
  fi
  local rf
  for rf in "$STAG_SYS"/class/rfkill/rfkill*; do
    [ "$(stag_read "$rf/type")" = wlan ] || continue
    if [ "$(stag_read "$rf/soft")" = 1 ] || [ "$(stag_read "$rf/hard")" = 1 ]; then
      emit net core "WIFI off" off "wifi is off"; return
    fi
  done
  emit net core "WIFI --" off "not connected"
}
bt() {
  local rf blocked=0 hci="" p=""
  for hci in "$STAG_SYS"/class/bluetooth/hci*; do [ -e "$hci" ] && break; hci=""; done
  [ -n "$hci" ] || { emit bt core "BT" off "no bluetooth adapter"; return; }
  for rf in "$STAG_SYS"/class/rfkill/rfkill*; do
    [ "$(stag_read "$rf/type")" = bluetooth ] || continue
    [ "$(stag_read "$rf/soft")" = 1 ] || [ "$(stag_read "$rf/hard")" = 1 ] && blocked=1
  done
  if [ "$blocked" = 0 ] && stag_have busctl; then
    p="$(busctl --system get-property org.bluez "/org/bluez/${hci##*/}" org.bluez.Adapter1 Powered 2>/dev/null)"
  fi
  if [ "$p" = "b true" ]; then emit bt core BT ok "bluetooth on"
  else emit bt core BT off "bluetooth off"; fi
}
vol() {
  stag_have wpctl || return
  local out v
  out="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)" || { emit vol core "VOL --" off "no audio sink"; return; }
  v="${out#Volume: }"; v="${v%% *}"
  [[ "$v" =~ ^([0-9]+)\.([0-9]{2}) ]] && v=$((10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]})) || v="?"
  if [[ "$out" == *MUTED* ]]; then emit vol core MUTE off "volume ${v}% (muted)"
  else emit vol core "VOL $v" ok "volume ${v}%"; fi
}
bat() {
  local b cap st pw tip
  for b in "$STAG_SYS"/class/power_supply/BAT*; do
    cap="$(stag_read "$b/capacity")" || continue
    st="$(stag_read "$b/status")"
    tip="battery ${cap}%  ${st,,}"
    pw="$(stag_read "$b/power_now")" && [[ "$pw" =~ ^[0-9]+$ ]] && [ "$pw" -gt 0 ] && tip+="  $((pw / 1000000)).$(( pw / 100000 % 10 )) W"
    case "$st" in
      Charging|Full|"Not charging") emit bat core "BAT ${cap}+" ok "$tip" ;;
      *) emit bat core "BAT $cap" "$([ "$cap" -le 15 ] && echo hot || echo ok)" "$tip" ;;
    esac
    return
  done
}
# backup age from stag-backup's state file (off by default: [bar] bak=true)
bak() {
  local f="${XDG_STATE_HOME:-$HOME/.local/state}/stagos/backup.state" k v ok="" rc="" age
  [ -r "$f" ] || { emit bak core "BAK --" off "no backup yet (stag-backup now)"; return; }
  while IFS='=' read -r k v; do case "$k" in last_ok) ok="$v" ;; last_rc) rc="$v" ;; esac; done < "$f"
  [[ "$ok" =~ ^[0-9]+$ ]] || { emit bak core "BAK --" hot "no good backup yet (stag-backup status)"; return; }
  age=$(( $(stag_now) - ok ))
  if [ "$age" -ge 86400 ]; then v="$((age / 86400))d"; else v="$((age / 3600))h"; fi
  if [ "$rc" != 0 ]; then emit bak core "BAK $v" hot "last backup run failed; last good one ${v} ago (stag-backup status)"
  elif [ "$age" -ge $((3 * 86400)) ]; then emit bak core "BAK $v" hot "last backup ${v} ago"
  else emit bak core "BAK $v" ok "last backup ${v} ago"; fi
}
clock() {
  # the plasmoid formats the clock itself (Qt format from [bar] clock_format); this is the fallback text
  emit clock core "$(printf '%(%a %-d %b  %H:%M)T' -1)" ok "$(printf '%(%A %-d %B %Y)T' -1)"
}

on recon && recon
on cpu && cpu
on ram && ram
on temp && temp
on stagbot && stagbot
on net && net
on bt && bt
on vol && vol
stag_conf_bool bar bak false && bak
on bat && bat
on clock && clock

if [ "$mode" = json ]; then
  printf '{"v":1,"bar":{"stag_menu":%s,"appmenu":%s},"clock_format":"%s","fields":[%s]}\n' \
    "$(on stag_menu && echo true || echo false)" "$(on appmenu && echo true || echo false)" \
    "$(stag_json_esc "$(stag_conf bar clock_format "ddd d MMM  HH:mm")")" \
    "$(IFS=,; echo "${FIELDS[*]}")"
else
  printf '%s\n' "${FIELDS[@]}"
fi
