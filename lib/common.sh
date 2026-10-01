#!/usr/bin/env bash
# common.sh - shared helpers for the StagOS build (sourced, not executed)

_c_reset=$'\e[0m'; _c_blue=$'\e[34m'; _c_green=$'\e[32m'
_c_yellow=$'\e[33m'; _c_red=$'\e[31m'

log()  { printf '%s[stagos]%s %s\n' "$_c_blue"   "$_c_reset" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n'  "$_c_green"  "$_c_reset" "$*"; }
warn() { printf '%s[warn]%s %s\n'  "$_c_yellow" "$_c_reset" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n'  "$_c_red"    "$_c_reset" "$*" >&2; exit 1; }

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root"; }
have() { command -v "$1" >/dev/null 2>&1; }

# run: execute a state-changing command, or just print it when DRY_RUN=1.
run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s[dry]%s %s\n' "$_c_yellow" "$_c_reset" "$*"
  else
    "$@"
  fi
}

confirm() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# wifi_monitor_iface: echo a monitor-capable interface name and return 0, else return 1.
# Set STAGOS_MOCK_WIFI=<iface> to force a result in VM/dry runs (no real card needed).
wifi_monitor_iface() {
  if [[ -n "${STAGOS_MOCK_WIFI:-}" ]]; then echo "$STAGOS_MOCK_WIFI"; return 0; fi
  have iw || return 1
  local phy
  while read -r phy; do
    if iw phy "$phy" info 2>/dev/null | grep -q 'monitor'; then
      iw dev | awk '/Interface/{print $2; exit}'
      return 0
    fi
  done < <(iw phy 2>/dev/null | awk '/^Wiphy/{print $2}')
  return 1
}

# stagos_tty1_block: the ~/.zprofile block that starts Plasma on tty1 only (stag-session start). When Plasma
# cannot start, stag-session execs a plain login shell with STAGOS_NO_SESSION=1, which this block respects (no
# loop). A login on tty2+ is always a plain shell (escape hatch).
stagos_tty1_block() {
  cat <<'EOF'

# StagOS: autostart Plasma on tty1 (stag-session; it falls back to a plain login shell)
if [[ -z "${WAYLAND_DISPLAY:-}${STAGOS_NO_SESSION:-}" && "$(tty)" == "/dev/tty1" ]] && command -v stag-session >/dev/null 2>&1; then
  exec stag-session start
fi
EOF
}

# stagos_zprofile_sync FILE: replace any older StagOS autostart block (whatever session it started) with
# the current one. Returns 0 when FILE changed, 1 when it was already current. Honours DRY_RUN.
stagos_zprofile_sync() {
  local zp="$1" tmp
  tmp="$(mktemp)"
  if [[ -f "$zp" ]]; then
    # drop the old block, then trailing blank lines (so reruns never pile up empty lines)
    sed '/# StagOS: autostart/,/^fi$/d' "$zp" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$tmp"
  fi
  stagos_tty1_block >> "$tmp"
  if [[ -f "$zp" ]] && cmp -s "$tmp" "$zp"; then rm -f "$tmp"; return 1; fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then log "[dry] would update the tty1 autostart block in $zp"; rm -f "$tmp"; return 0; fi
  cat "$tmp" > "$zp"; rm -f "$tmp"
  return 0
}
