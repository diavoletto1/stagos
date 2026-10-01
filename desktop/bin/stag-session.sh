#!/bin/bash
# StagOS: pick and start the graphical session on tty1 (called from the ~/.zprofile block).
#   stag-session start          start [session] default from ~/.config/stagos/desktop.conf
#   stag-session plasma|labwc   make that the default (also clears a crash fallback)
#   stag-session --status       print default=, next= (what start would run, and why), fails=
#   stag-session notify-daemon  D-Bus activation of org.freedesktop.Notifications (see below)
# Plasma = plasma-dbus-run-session-if-needed startplasma-wayland; labwc when Plasma is not installed.
# If Plasma exits non-zero within 30 s twice in a row, start labwc instead and log it to
# ~/.cache/stagos/session.log. The fallback sticks until `stag-session plasma` or until desktop.conf is
# saved again (StagOS Settings, a hand edit).
set -uo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
CONF="${STAGOS_DESKTOP_CONF:-$CFG/stagos/desktop.conf}"
DEFAULTS="${STAGOS_PLASMA_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/stagos/plasma}/desktop.conf.default"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/stagos"
LOG="$CACHE/session.log"
FAILS="$CACHE/session-plasma-fails"
STARTPLASMA="${STAGOS_STARTPLASMA:-/usr/bin/startplasma-wayland}"
DBUS_WRAP="${STAGOS_PLASMA_DBUS_WRAPPER:-/usr/lib/plasma-dbus-run-session-if-needed}"
LABWC="${STAGOS_LABWC:-labwc}"
FAST="${STAGOS_SESSION_FAST_SECS:-30}"
MAX_FAILS=2

log() { mkdir -p "$CACHE"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

ini_get() { # file section key
  awk -v s="$2" -v k="$3" '
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ { sec = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec); next }
    sec == s && index($0, "=") {
      key = substr($0, 1, index($0, "=") - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == k) { v = substr($0, index($0, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; found = 1; exit }
    }
    END { exit !found }' "$1" 2>/dev/null
}

# ini_set file section key value: edit in place, keeping comments and other sections
ini_set() {
  local f="$1" tmp
  mkdir -p "$(dirname "$f")"; [ -f "$f" ] || : > "$f"
  tmp="$(mktemp "$f.XXXXXX")"
  awk -v s="$2" -v k="$3" -v v="$4" '
    function emit() { if (!done) { print k "=" v; done = 1 } }
    /^[[:space:]]*\[/ { if (sec == s) emit(); sec = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec); if (sec == s) seen = 1; print; next }
    sec == s && !/^[[:space:]]*[#;]/ && index($0, "=") {
      key = substr($0, 1, index($0, "=") - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == k) { emit(); next }
    }
    { print }
    END { if (sec == s) emit(); else if (!seen) { print ""; print "[" s "]"; print k "=" v } }' "$f" > "$tmp" && mv "$tmp" "$f"
}

default_session() {
  local d
  d="$(ini_get "$CONF" session default || ini_get "$DEFAULTS" session default || echo plasma)"
  case "$d" in plasma|labwc) echo "$d" ;; *) echo plasma ;; esac
}
plasma_installed() { [ -x "$STARTPLASMA" ]; }
fails() { # a desktop.conf saved after the last failure counts as "try Plasma again"
  local n
  if [ -f "$CONF" ] && [ "$CONF" -nt "$FAILS" ]; then echo 0; return; fi
  n="$(cat "$FAILS" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# next: what `start` would run now, plus the reason
next_session() {
  local d; d="$(default_session)"
  if [ "$d" = labwc ]; then echo "labwc (default)"; return; fi
  if ! plasma_installed; then echo "labwc (plasma not installed)"; return; fi
  if [ "$(fails)" -ge "$MAX_FAILS" ]; then echo "labwc (plasma failed $(fails)x within ${FAST}s; run: stag-session plasma)"; return; fi
  echo "plasma (default)"
}

run_labwc() {
  log "start labwc: $1"
  # Plasma-only env must not leak into labwc; labwc reads ~/.config/labwc/environment itself
  exec env -u XDG_CURRENT_DESKTOP -u XDG_SESSION_DESKTOP -u KDE_FULL_SESSION "$LABWC"
}

run_plasma() {
  local t0 rc dur n tries=0 cmd=()
  [ -x "$DBUS_WRAP" ] && cmd+=("$DBUS_WRAP")
  cmd+=("$STARTPLASMA")
  while :; do
    log "start plasma (fails so far: $(fails))"
    t0="$(date +%s)"
    # labwc-only settings (qt6ct platform theme, GTK_THEME, wlroots desktop name) stay out of Plasma
    env -u QT_QPA_PLATFORMTHEME -u GTK_THEME -u XDG_CURRENT_DESKTOP -u XDG_SESSION_DESKTOP "${cmd[@]}"
    rc=$?; dur=$(( $(date +%s) - t0 ))
    if [ "$rc" -eq 0 ] || [ "$dur" -ge "$FAST" ]; then
      echo 0 > "$FAILS"
      log "plasma exited rc=$rc after ${dur}s"
      exit "$rc"
    fi
    n=$(( $(fails) + 1 )); echo "$n" > "$FAILS"; tries=$((tries + 1))
    log "plasma failed fast: rc=$rc after ${dur}s ($n/$MAX_FAILS)"
    # tries: never loop on Plasma even when the counter file cannot be written
    if [ "$n" -ge "$MAX_FAILS" ] || [ "$tries" -ge "$MAX_FAILS" ]; then
      log "FALLBACK: plasma failed $n times in a row within ${FAST}s; starting labwc (stag-session plasma to retry)"
      run_labwc "fallback"
    fi
  done
}

notify_daemon() {
  # One user-level D-Bus service file (~/.local/share/dbus-1/services, installed by the plasma module)
  # points org.freedesktop.Notifications here, so mako, swaync and Plasma never race for the name.
  case ":${XDG_CURRENT_DESKTOP:-}:" in
    *:KDE:*) exec "${STAGOS_PLASMA_WAITFORNAME:-/usr/bin/plasma_waitforname}" org.freedesktop.Notifications ;;
  esac
  if command -v swaync >/dev/null 2>&1; then exec swaync; fi
  exec mako
}

mkdir -p "$CACHE"
case "${1:-}" in
  start)
    case "$(next_session)" in
      plasma*) run_plasma ;;
      *) run_labwc "$(next_session)" ;;
    esac ;;
  plasma|labwc)
    ini_set "$CONF" session default "$1"
    echo 0 > "$FAILS"
    log "default set to $1"
    echo "default session: $1 (next tty1 login; log out to switch now)"
    [ "$1" = plasma ] && ! plasma_installed && echo "note: Plasma is not installed, labwc will start (stagos-desktop plasma)"
    exit 0 ;;
  --status|status)
    echo "default=$(default_session)"
    echo "next=$(next_session)"
    echo "fails=$(fails)"
    exit 0 ;;
  notify-daemon) notify_daemon ;;
  -h|--help|'') sed -n '2,9p' "$0" | sed 's/^# \?//'; [ -n "${1:-}" ] ;;
  *) echo "stag-session: unknown command $1 (see --help)" >&2; exit 2 ;;
esac
