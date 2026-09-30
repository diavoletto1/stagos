#!/bin/bash
# StagOS control CLI: every action and status behind the Plasma widgets (org.stagos.*), usable from a shell.
# Status calls print one JSON line; actions print the new status. Exit codes:
#   0 ok   1 the action failed   2 usage error   3 not available here (tool, hardware or config missing)
#
#   stag-ctl wifi|bt|dnd|night on|off|toggle|status
#   stag-ctl vol get | vol set N | vol mute [on|off|toggle]
#   stag-ctl bright get | bright set N
#   stag-ctl media status|play-pause|next|prev
#   stag-ctl recon status | recon kismet start|stop|open | recon mon on|off
#   stag-ctl stagbot status [--refresh] | stagbot open [text]
#   stag-ctl apps | app open NAME          stag services from ~/.config/stagos/stag-services
#   stag-ctl about                          host, kernel, uptime, RAM, disk, battery health
#   stag-ctl session lock|sleep|logout|reboot|poweroff|labwc
#   stag-ctl control                        everything the Control Center shows, one JSON line
set -uo pipefail
# shellcheck source=desktop/bin/stag-lib.sh
. stag-lib || { echo '{"error":"stag-lib missing"}'; exit 3; }

QDBUS="${STAGOS_QDBUS:-qdbus6}"
usage() { sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
fail() { printf '{"error":"%s"}\n' "$(stag_json_esc "$2")"; exit "$1"; }
need() { stag_have "$1" || fail 3 "$1 is not installed"; }
detach() { setsid -f "$@" </dev/null >/dev/null 2>&1; }
plasma() { [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]] || "$QDBUS" org.kde.KWin /KWin >/dev/null 2>&1; }
prop() { # SERVICE PATH INTERFACE NAME: a D-Bus property (qdbus6 SERVICE PATH IFACE.NAME would call a method)
  "$QDBUS" "$1" "$2" org.freedesktop.DBus.Properties.Get "$3" "$4" 2>/dev/null
}
WANT="" N=0
onoff() { # current(true|false) arg -> WANT=true|false; exits 2 on junk
  case "$2" in on) WANT=true ;; off) WANT=false ;; toggle) if [ "$1" = true ]; then WANT=false; else WANT=true; fi ;; *) usage ;; esac
}
pct() { [[ "$1" =~ ^[0-9]{1,3}$ ]] || fail 2 "not a percentage: $1"; N=$((10#$1)); [ "$N" -gt 100 ] && N=100; return 0; }

# ---- wifi (NetworkManager) ----
wifi_status() {
  need nmcli
  local on=false ssid="" sig="" a s g
  [ "$(nmcli radio wifi 2>/dev/null)" = enabled ] && on=true
  if [ "$on" = true ]; then
    while IFS=: read -r a s g; do
      [ "$a" = yes ] && { ssid="$s"; sig="$g"; break; }
    done < <(nmcli -t -f ACTIVE,SSID,SIGNAL device wifi list --rescan no 2>/dev/null)
  fi
  printf '{"on":%s,"connected":%s,"ssid":"%s","signal":%s}\n' "$on" "$([ -n "$ssid" ] && echo true || echo false)" \
    "$(stag_json_esc "$ssid")" "${sig:-0}"
}
cmd_wifi() {
  local act="${1:-status}" cur want
  case "$act" in status) wifi_status; return ;; esac
  need nmcli
  cur=false; [ "$(nmcli radio wifi 2>/dev/null)" = enabled ] && cur=true
  onoff "$cur" "$act"; want="$WANT"
  nmcli radio wifi "$([ "$want" = true ] && echo on || echo off)" || fail 1 "nmcli radio wifi failed"
  wifi_status
}

# ---- bluetooth (bluez) ----
bt_powered() { bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; }
bt_status() {
  need bluetoothctl
  local on=false n=0 avail=true
  bluetoothctl show >/dev/null 2>&1 || avail=false
  bt_powered && on=true
  [ "$on" = true ] && n="$(bluetoothctl devices Connected 2>/dev/null | grep -c '^Device ')"
  printf '{"on":%s,"connected":%s,"available":%s}\n' "$on" "${n:-0}" "$avail"
}
cmd_bt() {
  local act="${1:-status}" cur=false want
  case "$act" in status) bt_status; return ;; esac
  need bluetoothctl
  bt_powered && cur=true
  onoff "$cur" "$act"; want="$WANT"
  if [ "$want" = true ]; then
    stag_have rfkill && rfkill unblock bluetooth 2>/dev/null
    bluetoothctl power on >/dev/null || fail 1 "bluetoothctl power on failed"
  else
    bluetoothctl power off >/dev/null || fail 1 "bluetoothctl power off failed"
  fi
  bt_status
}

# ---- do not disturb: Plasma's own (plasmanotifyrc [DoNotDisturb] Until, a QDateTime "y,M,d,h,m,s").
# The notifications applet and plasmashell's popups watch that file (KConfigWatcher), so --notify
# applies it live. "On" is a year from now, which is what Plasma's own DND toggle writes. ----
dnd_until() { kreadconfig6 --file plasmanotifyrc --group DoNotDisturb --key Until 2>/dev/null; }
dnd_active() { # Until later than now (local time, compared as zero padded yyyyMMddhhmmss)
  local u="$1" y mo d h mi s now
  IFS=', ' read -r y mo d h mi s _ <<< "$u"
  [[ "$y" =~ ^[0-9]+$ && "$mo" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  s="${s%%.*}"
  now="$(printf '%(%Y%m%d%H%M%S)T' -1)"
  [ "$(printf '%04d%02d%02d%02d%02d%02d' "$((10#$y))" "$((10#$mo))" "$((10#$d))" "$((10#${h:-0}))" "$((10#${mi:-0}))" "$((10#${s:-0}))")" -gt "$now" ]
}
dnd_status() {
  need kreadconfig6
  local u on=false
  u="$(dnd_until)"
  dnd_active "$u" && on=true
  printf '{"on":%s,"until":"%s"}\n' "$on" "$(stag_json_esc "$([ "$on" = true ] && echo "$u")")"
}
cmd_dnd() {
  local act="${1:-status}" cur=false want y
  case "$act" in status) dnd_status; return ;; esac
  need kwriteconfig6; need kreadconfig6
  dnd_active "$(dnd_until)" && cur=true
  onoff "$cur" "$act"; want="$WANT"
  if [ "$want" = true ]; then
    y="$(printf '%(%Y)T' -1)"
    kwriteconfig6 --file plasmanotifyrc --group DoNotDisturb --key Until --notify \
      "$((y + 1)),$(printf '%(%-m,%-d,%-H,%-M,%-S)T' -1)" || fail 1 "kwriteconfig6 failed"
  else
    kwriteconfig6 --file plasmanotifyrc --group DoNotDisturb --key Until --notify --delete || fail 1 "kwriteconfig6 failed"
  fi
  dnd_status
}

# ---- night light: KWin Night Light (kwinrc [NightColor], watched live by KWin; the state comes from
# org.kde.KWin /org/kde/KWin/NightLight). Mac style: "on" means warm now and until turned off
# (Mode=Constant), not the sunset schedule. Outside Plasma: stag-nightlight (wlsunset). ----
night_status() {
  local on="" run=false temp=0 v
  if v="$(prop org.kde.KWin /org/kde/KWin/NightLight org.kde.KWin.NightLight enabled)"; then
    on="$v"
    [ "$(prop org.kde.KWin /org/kde/KWin/NightLight org.kde.KWin.NightLight running)" = true ] && run=true
    temp="$(prop org.kde.KWin /org/kde/KWin/NightLight org.kde.KWin.NightLight currentTemperature)"
  elif stag_have kreadconfig6 && plasma; then
    on="$(kreadconfig6 --file kwinrc --group NightColor --key Active --default false 2>/dev/null)"
  elif stag_have stag-nightlight; then
    on="$(stag-nightlight status)"; run="$on"
  else
    fail 3 "no night light here"
  fi
  [ "$on" = true ] || on=false
  [[ "$temp" =~ ^[0-9]+$ ]] || temp=0
  printf '{"on":%s,"running":%s,"temp":%s}\n' "$on" "$run" "$temp"
}
cmd_night() {
  local act="${1:-status}" cur want
  case "$act" in status) night_status; return ;; esac
  cur="$(night_status | grep -o '"on":[a-z]*' | cut -d: -f2)"
  onoff "$cur" "$act"; want="$WANT"
  if stag_have kwriteconfig6 && plasma; then
    if [ "$want" = true ]; then
      kwriteconfig6 --file kwinrc --group NightColor --key Mode --notify Constant || fail 1 "kwriteconfig6 failed"
    fi
    kwriteconfig6 --file kwinrc --group NightColor --key Active --type bool --notify "$want" || fail 1 "kwriteconfig6 failed"
  elif stag_have stag-nightlight; then
    stag-nightlight "$([ "$want" = true ] && echo start || echo stop)"
  else
    fail 3 "no night light here"
  fi
  night_status
}

# ---- volume (PipeWire, wpctl) ----
vol_get() {
  need wpctl
  local out v
  out="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)" || fail 3 "no audio sink"
  v="${out#Volume: }"; v="${v%% *}"
  [[ "$v" =~ ^([0-9]+)\.([0-9]{2}) ]] && v=$((10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]})) || v=0
  printf '{"volume":%s,"muted":%s}\n' "$v" "$([[ "$out" == *MUTED* ]] && echo true || echo false)"
}
cmd_vol() {
  local act="${1:-get}"
  need wpctl
  case "$act" in
    get) ;;
    set) [ $# -ge 2 ] || usage
         pct "$2"; wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ "$N%" || fail 1 "wpctl set-volume failed" ;;
    mute) case "${2:-toggle}" in on) m=1 ;; off) m=0 ;; toggle) m=toggle ;; *) usage ;; esac
          wpctl set-mute @DEFAULT_AUDIO_SINK@ "$m" || fail 1 "wpctl set-mute failed" ;;
    *) usage ;;
  esac
  vol_get
}

# ---- brightness: read /sys; set through powerdevil (org.kde.ScreenBrightness, no root, keeps Plasma in
# sync) and fall back to brightnessctl (logind, no root either) ----
bl_dir() {
  local d first=""
  for d in "$STAG_SYS"/class/backlight/*; do
    [ -r "$d/max_brightness" ] || continue
    case "${d##*/}" in intel_backlight|amdgpu_bl*|acpi_video0) printf '%s' "$d"; return 0 ;; esac
    [ -z "$first" ] && first="$d"
  done
  [ -n "$first" ] && printf '%s' "$first"
}
bright_get() {
  local d cur max
  d="$(bl_dir)" || true
  [ -n "$d" ] || { printf '{"available":false,"percent":0}\n'; return 3; }
  cur="$(stag_read "$d/brightness")"; max="$(stag_read "$d/max_brightness")"
  [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ] || max=1
  printf '{"available":true,"percent":%s}\n' "$(( (cur * 100 + max / 2) / max ))"
}
cmd_bright() {
  local act="${1:-get}" n disp max
  case "$act" in
    get) bright_get; return ;;
    set) [ $# -ge 2 ] || usage; pct "$2"; n="$N"; [ "$n" -lt 1 ] && n=1 ;;
    *) usage ;;
  esac
  disp="$(prop org.kde.ScreenBrightness /org/kde/ScreenBrightness org.kde.ScreenBrightness DisplaysDBusNames | head -1)"
  if [ -n "$disp" ] && max="$(prop org.kde.ScreenBrightness "/org/kde/ScreenBrightness/$disp" org.kde.ScreenBrightness.Display MaxBrightness)" \
     && [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ]; then
    # flags 1 = no OSD (the slider is the feedback)
    "$QDBUS" org.kde.ScreenBrightness "/org/kde/ScreenBrightness/$disp" org.kde.ScreenBrightness.Display.SetBrightness \
      "$(( (n * max + 50) / 100 ))" 1 >/dev/null || fail 1 "powerdevil SetBrightness failed"
  elif stag_have brightnessctl; then
    brightnessctl -q set "$n%" || fail 1 "brightnessctl failed"
  else
    fail 3 "no brightness control (powerdevil or brightnessctl)"
  fi
  bright_get
}

# ---- media (MPRIS, playerctl) ----
media_status() {
  need playerctl
  local st t a p
  if ! IFS=$'\t' read -r st p t a < <(playerctl metadata --format $'{{status}}\t{{playerName}}\t{{title}}\t{{artist}}' 2>/dev/null); then
    printf '{"available":false,"status":"Stopped","player":"","title":"","artist":""}\n'; return 0
  fi
  printf '{"available":true,"status":"%s","player":"%s","title":"%s","artist":"%s"}\n' "$(stag_json_esc "$st")" \
    "$(stag_json_esc "$p")" "$(stag_json_esc "$t")" "$(stag_json_esc "$a")"
}
cmd_media() {
  case "${1:-status}" in
    status) media_status ;;
    play-pause|next|previous|prev) need playerctl
      local c="$1"; [ "$c" = prev ] && c=previous
      playerctl "$c" 2>/dev/null || fail 1 "no player"
      media_status ;;
    *) usage ;;
  esac
}

# ---- recon: tailscale, gps, capture card, kismet ----
recon_status() {
  local ts gps iface mode kis=false
  ts="$(STAGOS_CACHE_SYNC=1 stag_cached ts 10 stag_ts)"
  gps="$(STAGOS_CACHE_SYNC=1 stag_cached gps 5 stag_gps)"
  iface="$(stag_capture_iface)"
  mode="unset"; [ -n "$iface" ] && mode="$(stag_iface_mode "$iface")"
  stag_kismet_running && kis=true
  printf '{"ts":{"up":%s,"installed":%s,"ip":"%s"},"gps":{"installed":%s,"mode":%s},"capture":{"iface":"%s","mode":"%s","monitor":"%s"},"kismet":{"running":%s}}\n' \
    "$([[ "$ts" == up* ]] && echo true || echo false)" "$([ "$ts" = none ] && echo false || echo true)" \
    "$(stag_json_esc "$([[ "$ts" == up\ * ]] && echo "${ts#up }")")" \
    "$([ "$gps" = na ] && echo false || echo true)" "$([[ "$gps" =~ ^[0-9]$ ]] && echo "$gps" || echo 0)" \
    "$(stag_json_esc "$iface")" "$mode" "$(stag_json_esc "$(stag_mon_iface)")" "$kis"
}
term() { # run a command in a terminal window (stag-mon asks for sudo there)
  if stag_have foot; then detach foot -T "$1" -e "${@:2}"
  elif stag_have konsole; then detach konsole -p tabtitle="$1" -e "${@:2}"
  else return 1; fi
}
cmd_recon() {
  case "${1:-status}:${2:-}" in
    status:) recon_status ;;
    kismet:start)
      need kismet
      if ! stag_kismet_running; then
        mkdir -p "$HOME/.kismet/logs"
        (cd "$HOME/.kismet/logs" && setsid -f kismet --no-ncurses >"$HOME/.kismet/kismet.out" 2>&1 </dev/null) || fail 1 "kismet did not start"
      fi
      recon_status ;;
    kismet:stop)
      if stag_kismet_running; then pkill -x kismet || fail 1 "could not stop kismet"; fi
      local _i; for _i in 1 2 3 4 5 6 7 8 9 10; do stag_kismet_running || break; sleep 0.3; done
      recon_status ;;
    kismet:open) need xdg-open; detach xdg-open http://localhost:2501; recon_status ;;
    mon:on|mon:off)
      local iface mode want="managed"
      [ "$2" = on ] && want=monitor
      iface="$(stag_capture_iface)"
      [ -n "$iface" ] || fail 3 "no capture card configured ([recon] capture_iface in desktop.conf)"
      mode="$(stag_iface_mode "$iface")"
      [ "$mode" = absent ] && fail 3 "$iface is not present (is the capture card plugged in?)"
      if [ "$mode" != "$want" ]; then
        # the same path as the dock's MON tile: stag-mon in a terminal (it needs sudo)
        STAGOS_CAPTURE_IFACE="$iface" term stag-mon stag-mon || fail 3 "no terminal (foot or konsole) for stag-mon"
      fi
      recon_status ;;
    *) usage ;;
  esac
}

# ---- stagbot: stag services up/down (HEAD, 3 s timeout, parallel, cached 30 s) ----
stagbot_probe() {
  local list tmp n u i=0 names=() urls=() out="" up=0 code ok
  list="$(stag_services_file)"
  tmp="$(mktemp -d)"
  while IFS='|' read -r n u; do
    [ -n "$n" ] && [ -n "$u" ] || continue
    names+=("$n"); urls+=("$u")
    curl -sS -o /dev/null -I --max-time 3 -w '%{http_code}' "$u" > "$tmp/$i" 2>/dev/null &
    i=$((i + 1))
  done < "$list"
  wait
  for i in "${!names[@]}"; do
    code="$(stag_read "$tmp/$i")"; [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
    # any HTTP answer below 500 counts as up (auth walls answer 401/302)
    ok=false; [ "$code" != 000 ] && [ "$code" -lt 500 ] && ok=true && up=$((up + 1))
    [ -n "$out" ] && out+=","
    out+="{\"name\":\"$(stag_json_esc "${names[$i]}")\",\"url\":\"$(stag_json_esc "${urls[$i]}")\",\"up\":$ok,\"code\":$((10#$code))}"
  done
  rm -rf "$tmp"
  printf '{"ts":%s,"up":%s,"total":%s,"services":[%s]}\n' "$(stag_now)" "$up" "${#names[@]}" "$out"
}
cmd_stagbot() {
  local f="$STAG_CACHE/stagbot.json" j now ts re='"ts":([0-9]+)'
  case "${1:-status}" in
    status)
      [ -s "$(stag_services_file)" ] || fail 3 "no stag services configured (config/local.conf, then: stagos-desktop stag)"
      need curl
      now="$(stag_now)"
      if [ "${2:-}" != --refresh ] && j="$(stag_read "$f")" && [[ "$j" =~ $re ]] && [ $((now - BASH_REMATCH[1])) -lt 30 ]; then
        printf '%s\n' "$j"; return 0
      fi
      mkdir -p "$STAG_CACHE"
      (
        stag_have flock && { flock -w 5 9 || true; }
        # another caller may have refreshed it while we waited
        if [ "${2:-}" != --refresh ] && j="$(stag_read "$f")" && [[ "$j" =~ $re ]] && [ $(( $(stag_now) - BASH_REMATCH[1] )) -lt 30 ]; then
          printf '%s\n' "$j"; exit 0
        fi
        stagbot_probe > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
        cat "$f"
      ) 9>"$STAG_CACHE/stagbot.lock" ;;
    open)
      shift
      local url text="$*" copied=false
      url="$(stag_service_url control)" || fail 3 "no 'control' entry in $(stag_services_file)"
      # the stag-control chat has no prefill parameter: the question goes to the clipboard
      if [ -n "$text" ] && stag_have wl-copy; then printf '%s' "$text" | wl-copy 2>/dev/null && copied=true; fi
      open_url "$url" control || fail 1 "could not open the Stagbot chat"
      printf '{"opened":true,"prefill":false,"copied":%s}\n' "$copied" ;;
    *) usage ;;
  esac
}

# ---- stag apps: launch stag-<name>.desktop (module stag), else chromium --app ----
open_url() { # URL NAME
  local desk="${XDG_DATA_HOME:-$HOME/.local/share}/applications/stag-$2.desktop"
  if [ -f "$desk" ] && stag_have gtk-launch; then detach gtk-launch "stag-$2"
  elif [ -f "$desk" ] && stag_have kioclient; then detach kioclient exec "$desk"
  elif stag_have chromium; then detach chromium --app="$1"
  else return 1; fi
}
cmd_apps() {
  local n u out="" f
  f="$(stag_services_file)"
  [ -r "$f" ] || { echo '{"apps":[]}'; return 0; }
  while IFS='|' read -r n u; do
    [ -n "$n" ] && [ -n "$u" ] || continue
    [ -n "$out" ] && out+=","
    out+="{\"name\":\"$(stag_json_esc "$n")\",\"title\":\"Stag $(stag_json_esc "${n^}")\"}"
  done < "$f"
  printf '{"apps":[%s]}\n' "$out"
}
cmd_app() {
  [ "${1:-}" = open ] && [ -n "${2:-}" ] || usage
  local url
  url="$(stag_service_url "$2")" || fail 3 "no stag service named $2"
  open_url "$url" "$2" || fail 1 "could not open $2"
  printf '{"opened":"%s"}\n' "$(stag_json_esc "$2")"
}

# ---- about this computer ----
cmd_about() {
  local host kern up d h m model="" k v _u mt=0 ma=0 b health="" cyc="" cap="" bst="" full design dt du
  host="$(stag_read "$STAG_PROC/sys/kernel/hostname")"
  kern="$(stag_read "$STAG_PROC/sys/kernel/osrelease")"
  read -r up _ < "$STAG_PROC/uptime"; up="${up%.*}"
  d=$((up / 86400)); h=$((up % 86400 / 3600)); m=$((up % 3600 / 60))
  while IFS=: read -r k v; do
    [[ "$k" == "model name"* ]] && { model="${v# }"; break; }
  done < "$STAG_PROC/cpuinfo"
  while read -r k v _u; do
    case "$k" in MemTotal:) mt=$v ;; MemAvailable:) ma=$v ;; esac
  done < "$STAG_PROC/meminfo"
  for b in "$STAG_SYS"/class/power_supply/BAT*; do
    [ -r "$b/capacity" ] || continue
    cap="$(stag_read "$b/capacity")"; bst="$(stag_read "$b/status")"; cyc="$(stag_read "$b/cycle_count")"
    full="$(stag_read "$b/energy_full" || stag_read "$b/charge_full")"
    design="$(stag_read "$b/energy_full_design" || stag_read "$b/charge_full_design")"
    [[ "$full" =~ ^[0-9]+$ && "$design" =~ ^[0-9]+$ ]] && [ "$design" -gt 0 ] && health=$((full * 100 / design))
    break
  done
  read -r dt du < <(df -Pk / 2>/dev/null | awk 'NR==2 {print $2, $3}')
  [[ "$dt" =~ ^[0-9]+$ && "$du" =~ ^[0-9]+$ ]] || { dt=0; du=0; }
  printf '{"host":"%s","os":"StagOS","kernel":"%s","cpu":"%s","uptime":"%s","ram_total_mb":%s,"ram_used_mb":%s,' \
    "$(stag_json_esc "$host")" "$(stag_json_esc "$kern")" "$(stag_json_esc "$model")" \
    "$([ "$d" -gt 0 ] && printf '%dd ' "$d")${h}h ${m}m" "$((mt / 1024))" "$(((mt - ma) / 1024))"
  printf '"disk_total_gb":%s,"disk_used_gb":%s,' "$((dt / 1048576))" "$((du / 1048576))"
  printf '"battery":{"present":%s,"capacity":%s,"status":"%s","health":%s,"cycles":%s},"settings":%s,"session":"%s"}\n' \
    "$([ -n "$cap" ] && echo true || echo false)" "${cap:-0}" "$(stag_json_esc "$bst")" "${health:-0}" \
    "$([[ "$cyc" =~ ^[0-9]+$ ]] && echo "$cyc" || echo 0)" "$(stag_have stag-settings && echo true || echo false)" \
    "$(stag_json_esc "${XDG_CURRENT_DESKTOP:-}")"
}

# ---- session ----
ksm() { "$QDBUS" org.kde.Shutdown /Shutdown "org.kde.Shutdown.$1" >/dev/null 2>&1; }
cmd_session() {
  case "${1:-}" in
    lock)     loginctl lock-session || fail 1 "lock failed" ;;
    sleep)    systemctl suspend || fail 1 "suspend failed" ;;
    logout)   ksm logout || loginctl terminate-session "${XDG_SESSION_ID:-}" || fail 1 "logout failed" ;;
    reboot)   ksm logoutAndReboot || systemctl reboot || fail 1 "reboot failed" ;;
    poweroff) ksm logoutAndShutdown || systemctl poweroff || fail 1 "poweroff failed" ;;
    labwc)    need stag-session
              stag-session labwc >/dev/null || fail 1 "stag-session labwc failed"
              ksm logout || loginctl terminate-session "${XDG_SESSION_ID:-}" || fail 1 "logout failed" ;;
    *) usage ;;
  esac
  printf '{"ok":true,"action":"%s"}\n' "$1"
}

# ---- everything the Control Center shows, one call (its poll) ----
part() { local v; v="$("$@" 2>/dev/null)"; [ -n "$v" ] && printf '%s' "$v" || printf null; }
cmd_control() {
  printf '{"wifi":%s,"bt":%s,"dnd":%s,"night":%s,"vol":%s,"bright":%s,"media":%s,"recon":%s}\n' \
    "$(part cmd_wifi status)" "$(part cmd_bt status)" "$(part cmd_dnd status)" "$(part cmd_night status)" \
    "$(part cmd_vol get)" "$(part bright_get)" "$(part cmd_media status)" "$(part recon_status)"
}

[ $# -ge 1 ] || usage
what="$1"; shift
case "$what" in
  wifi) cmd_wifi "$@" ;;
  bt|bluetooth) cmd_bt "$@" ;;
  dnd) cmd_dnd "$@" ;;
  night) cmd_night "$@" ;;
  vol|volume) cmd_vol "$@" ;;
  bright|brightness) cmd_bright "$@" ;;
  media) cmd_media "$@" ;;
  recon) cmd_recon "$@" ;;
  stagbot) cmd_stagbot "$@" ;;
  apps) cmd_apps ;;
  app) cmd_app "$@" ;;
  about) cmd_about ;;
  session) cmd_session "$@" ;;
  control) cmd_control ;;
  -h|--help|help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
