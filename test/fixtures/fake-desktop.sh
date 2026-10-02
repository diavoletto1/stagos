#!/bin/bash
# fixture helpers (sourced): a sandbox for stag-ctl / stag-status with fake tools and a fake /sys + /proc.
#   fake_desktop_setup DIR     PATH gets DIR/bin (fake-desktop under every tool name) + the repo's stag-* shims,
#                              STAGOS_SYS/STAGOS_PROC point at a stagpad-like tree, HOME is DIR/home
#   fake_state KEY VALUE       set fake-desktop state (wifi on|off, bt yes|no, vol 0-100, player none|spotify ...)
#   fake_sys_iface NAME TYPE [wireless]   add /sys/class/net/NAME (TYPE 1 = managed/ethernet, 803 = monitor)
# shellcheck disable=SC2034
FAKE_TOOLS="nmcli bluetoothctl busctl wpctl brightnessctl playerctl qdbus6 curl kreadconfig6 kwriteconfig6 tailscale gpspipe
  pgrep pkill rfkill setsid foot konsole gtk-launch chromium wl-copy xdg-open loginctl systemctl kismet"

FAKE_SYS_PATH="${FAKE_SYS_PATH:-$PATH}"
fake_desktop_setup() {
  local d="$1" root t f
  PATH="$FAKE_SYS_PATH"
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  rm -rf "$d"; mkdir -p "$d/bin" "$d/fake" "$d/home" "$d/sys" "$d/proc"
  for t in $FAKE_TOOLS; do ln -s "$root/test/fixtures/bin/fake-desktop" "$d/bin/$t"; done
  for f in "$root"/desktop/bin/stag-{lib,ctl,status}.sh; do ln -s "$f" "$d/bin/$(basename "$f" .sh)"; done
  export FAKE_DIR="$d/fake" FAKE_LOG="$d/fake/log" HOME="$d/home" STAGOS_SYS="$d/sys" STAGOS_PROC="$d/proc"
  export STAGOS_CACHE="$d/home/.cache/stagos" STAGOS_QDBUS=qdbus6 FAKE_BL="$d/sys/class/backlight/intel_backlight"
  export STAGOS_CONF="$d/home/stagos/config/stagos.conf"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_CURRENT_DESKTOP STAGOS_CAPTURE_IFACE \
    STAGOS_DESKTOP_CONF STAGOS_PLASMA_DATA STAGOS_STAG_LIST STAGOS_CACHE_SYNC
  : > "$FAKE_LOG"
  # only the fakes plus plain coreutils-level tools: a real nmcli/pgrep/qdbus6 on the host never leaks in
  mkdir -p "$d/sysbin"
  for t in bash sh cat grep awk sed mkdir mktemp rm mv cp cut head tail date df sleep timeout flock touch ln tr wc \
    basename dirname env sort uniq readlink stat python3 jq; do
    f="$(PATH="$FAKE_SYS_PATH" command -v "$t" 2>/dev/null)" && ln -sf "$f" "$d/sysbin/$t"
  done
  PATH="$d/bin:$d/sysbin"
  mkdir -p "$HOME/.config/stagos"
  cp "$root/desktop/plasma/desktop.conf.default" "$HOME/.config/stagos/desktop.conf"

  # /proc
  local p="$STAGOS_PROC"
  mkdir -p "$p/sys/kernel" "$p/net"
  echo "cpu  1000 0 1000 8000 0 0 0 0 0 0" > "$p/stat"
  echo "0.42 0.30 0.20 1/300 1234" > "$p/loadavg"
  printf 'MemTotal:        7800000 kB\nMemFree:         1000000 kB\nMemAvailable:    3900000 kB\n' > "$p/meminfo"
  echo stagpad > "$p/sys/kernel/hostname"; echo 6.10.0-arch1-1 > "$p/sys/kernel/osrelease"
  echo "93784.12 100.00" > "$p/uptime"
  printf 'processor\t: 0\nmodel name\t: Intel(R) Core(TM) i5-5300U CPU @ 2.30GHz\n' > "$p/cpuinfo"
  printf 'Inter-| sta-|   Quality        |   Discarded packets\n face | tus | link level noise |  nwid\n wlan0: 0000   56.  -54.  -256        0      0\n' > "$p/net/wireless"

  # /sys
  local s="$STAGOS_SYS"
  mkdir -p "$s/class/thermal/thermal_zone0" "$s/class/thermal/thermal_zone1" "$s/class/power_supply/BAT0" \
    "$s/class/backlight/intel_backlight" "$s/class/bluetooth/hci0" "$s/class/rfkill/rfkill0" "$s/class/rfkill/rfkill1" "$s/class/net"
  echo acpitz > "$s/class/thermal/thermal_zone0/type"; echo 40000 > "$s/class/thermal/thermal_zone0/temp"
  echo x86_pkg_temp > "$s/class/thermal/thermal_zone1/type"; echo 52000 > "$s/class/thermal/thermal_zone1/temp"
  echo 81 > "$s/class/power_supply/BAT0/capacity"; echo Discharging > "$s/class/power_supply/BAT0/status"
  echo 7500000 > "$s/class/power_supply/BAT0/power_now"; echo 37000000 > "$s/class/power_supply/BAT0/energy_full"
  echo 46000000 > "$s/class/power_supply/BAT0/energy_full_design"; echo 312 > "$s/class/power_supply/BAT0/cycle_count"
  echo 1000 > "$s/class/backlight/intel_backlight/max_brightness"; echo 500 > "$s/class/backlight/intel_backlight/brightness"
  echo wlan > "$s/class/rfkill/rfkill0/type"; echo 0 > "$s/class/rfkill/rfkill0/soft"; echo 0 > "$s/class/rfkill/rfkill0/hard"
  echo bluetooth > "$s/class/rfkill/rfkill1/type"; echo 0 > "$s/class/rfkill/rfkill1/soft"; echo 0 > "$s/class/rfkill/rfkill1/hard"
  fake_sys_iface lo 772
  fake_sys_iface wlan0 1 wireless
}
fake_state() { mkdir -p "$FAKE_DIR/state"; printf '%s' "$2" > "$FAKE_DIR/state/$1"; }
fake_sys_iface() {
  local d="$STAGOS_SYS/class/net/$1"
  mkdir -p "$d"; echo "$2" > "$d/type"; echo up > "$d/operstate"
  [ "${3:-}" = wireless ] && mkdir -p "$d/wireless"
  return 0
}
