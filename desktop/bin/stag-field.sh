#!/bin/bash
# StagOS field mode: one command to go wardriving and come back clean.
#   stag-field on       capture card -> monitor, gpsd + a brief fix wait, Kismet logging to ~/field/<date>/,
#                       randomize the built-in wifi MAC (only when it is not connected), battery power profile,
#                       and a sleep/idle inhibit held for the session. State: ~/.local/state/stagos/field.json
#   stag-field off      stop Kismet, managed mode back, release the inhibit, restore MAC/brightness/TLP, then sync
#   stag-field sync     upload finished .kismet logs to stag-maps over Tailscale (idempotent, resume-safe)
#   stag-field status   one JSON line for the bar / Control Center
# Privileged steps (iw, ip, macchanger, tlp) go through sudo, the same path stag-mon uses; nothing here adds a
# NOPASSWD rule. Run it from a terminal so that sudo can prompt. Exit codes: 0 ok, 1 failed, 2 usage, 3 not available.
# Test seams: STAGOS_SUDO (empty = run tools directly), STAGOS_FIELD_INHIBIT_CMD, STAGOS_STATE, STAGOS_SYS, and the
# stag-lib overrides. All tools are looked up on PATH so a fixture dir can shadow them.
set -uo pipefail
# shellcheck source=desktop/bin/stag-lib.sh
. stag-lib || { echo '{"error":"stag-lib missing"}'; exit 3; }

SUDO="${STAGOS_SUDO-sudo}"
FIELD_JSON="$(stag_field_file)"
LAST_SYNC_FILE="$STAG_STATE/field-last-sync"
UPLOADS_JSON="$STAG_STATE/field-uploads.json"
FIELD_ROOT="${STAGOS_FIELD_ROOT:-$HOME/field}"
INHIBIT_CMD="${STAGOS_FIELD_INHIBIT_CMD:-sleep infinity}"

say() { printf '%s\n' "$*" >&2; }
fail() { printf '{"ok":false,"error":"%s"}\n' "$(stag_json_esc "$2")"; exit "$1"; }
priv() { if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
host_name() { stag_read "$STAG_PROC/sys/kernel/hostname" 2>/dev/null || echo stagpad; }

# ---- process identity: pid + start time, so a stale or reused pid is never signalled ----
proc_start() { # PID -> start time in clock ticks (field 22 of /proc/PID/stat), empty when gone
  local st; st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  st="${st##*) }"
  # shellcheck disable=SC2086  # split the stat fields on purpose
  set -- $st
  printf '%s' "${20:-}"
}
boot_id() { stag_read "$STAG_PROC/sys/kernel/random/boot_id" 2>/dev/null; }

# ---- field.json helpers (compact single line, so stag-lib reads it with builtins) ----
fj_get() { # KEY -> value (string or number), empty when absent
  local j; j="$(stag_read "$FIELD_JSON")" || return 1
  [[ "$j" =~ \"$1\":\"([^\"]*)\" ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
  [[ "$j" =~ \"$1\":([0-9]+) ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
  return 1
}

# ---- monitor mode (the exact mechanism stag-mon uses) ----
iface_to_mode() { # IFACE MODE(monitor|managed)
  priv ip link set "$1" down &&
    priv iw dev "$1" set type "$2" &&
    priv ip link set "$1" up
}

# ---- the built-in wifi: the first wireless card that is not the capture iface ----
builtin_iface() { # empty when there is no second card
  local cap d i; cap="$(stag_capture_iface)"
  for d in "$STAG_SYS"/class/net/*; do
    [ -d "$d/wireless" ] || [ -e "$d/phy80211" ] || continue
    i="${d##*/}"; [ "$i" = "$cap" ] && continue
    printf '%s' "$i"; return 0
  done
  return 1
}
iface_connected() { # IFACE: rc 0 when NetworkManager reports it connected
  stag_have nmcli || return 1
  nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -qx "$1:connected"
}

# Every change "on" makes is recorded in field.json right after it happens, so "off" can undo a session that was
# interrupted half way (Ctrl+C at a sudo prompt, a crash). field.json carries the boot id: after a reboot the
# card is back in managed mode, the MAC is the hardware one and the inhibit is gone, so an old file is stale.
S_IFACE="" S_LOG="" S_GPS=0 S_INH=0 S_INH_START="" S_MAC="" S_MACNOTE="" S_BR="" S_BI="" S_MON=0 S_KIS=0
cmd_on() {
  stag_field_active && { say "field mode is already on (stag-field off first)"; cmd_status; return 0; }
  clear_state   # a stale file from an earlier boot
  local iface; iface="$(stag_capture_iface)"
  [ -n "$iface" ] || fail 3 "no capture card configured ([recon] capture_iface in desktop.conf, or STAGOS_CAPTURE_IFACE)"
  local mode; mode="$(stag_iface_mode "$iface")"
  [ "$mode" = absent ] && fail 3 "$iface is not present (is the capture card plugged in?)"
  S_IFACE="$iface"; S_BR="$(bright_pct)"
  save_state || fail 1 "could not write $FIELD_JSON"

  # 1. capture card -> monitor mode
  if [ "$mode" != monitor ]; then
    S_MON=1; save_state   # recorded first: a failure half way still gets the card back to managed on "off"
    iface_to_mode "$iface" monitor || { say "could not put $iface into monitor mode"; cmd_off >/dev/null; fail 1 "could not put $iface into monitor mode"; }
    say "monitor mode: $iface"
  fi

  # 2. gpsd: nudge the socket (no sudo; it is socket-activated), then wait briefly for a fix
  systemctl start gpsd.socket >/dev/null 2>&1 || true
  local gps=0 i
  for i in 1 2 3 4 5 6 7 8; do
    gps="$(stag_gps)"; [ "$gps" = na ] && break
    [[ "$gps" =~ ^[23]$ ]] && break
    sleep 1
  done
  case "$gps" in 2|3) say "gps: ${gps}D fix" ;; na) say "gps: gpspipe not installed" ;; *) say "gps: no fix yet (continuing)" ;; esac
  [[ "$gps" =~ ^[0-9]$ ]] && S_GPS="$gps"

  # 3. Kismet -> ~/field/<date>/ (user owns the logs; --log-prefix overrides kismet's log_prefix)
  local day log_dir; day="$(date +%Y-%m-%d)"; log_dir="$FIELD_ROOT/$day"
  mkdir -p "$log_dir" || { cmd_off >/dev/null; fail 1 "could not create $log_dir"; }
  if stag_kismet_running; then
    say "kismet: already running (not started by field mode): its logs stay where it writes them, not in $log_dir"
  else
    stag_have kismet || { cmd_off >/dev/null; fail 3 "kismet is not installed"; }
    ( cd "$log_dir" && setsid -f kismet --no-ncurses --log-prefix "$log_dir" -c "$iface" \
        >"$log_dir/kismet.out" 2>&1 </dev/null ) || { cmd_off >/dev/null; fail 1 "kismet did not start"; }
    S_KIS=1
    say "kismet: logging to $log_dir"
  fi
  S_LOG="$log_dir"; save_state

  # 4. randomize the built-in wifi MAC, but never drop a live connection
  local bi
  if bi="$(builtin_iface)"; then
    S_BI="$bi"
    if iface_connected "$bi"; then
      S_MACNOTE="kept: $bi is connected"
      say "mac: $S_MACNOTE"
    elif stag_have macchanger; then
      S_MAC="$(stag_read "$STAG_SYS/class/net/$bi/address")"; save_state
      if priv ip link set "$bi" down && priv macchanger -r "$bi" >/dev/null && priv ip link set "$bi" up; then
        say "mac: $bi randomized"
      else
        S_MACNOTE="randomize failed"; say "mac: randomize failed on $bi"
      fi
    else
      S_MACNOTE="macchanger not installed"
    fi
  else
    S_MACNOTE="no built-in card to randomize"
  fi
  save_state

  # 5. power: a notch dimmer, TLP battery mode
  if [ -n "$S_BR" ] && stag_have brightnessctl; then
    local target=$((S_BR - 15)); [ "$target" -lt 5 ] && target=5
    brightnessctl -q set "${target}%" >/dev/null 2>&1 || true
  fi
  if stag_have tlp; then priv tlp bat >/dev/null 2>&1 || say "tlp: could not switch to battery mode"; fi

  # 6. hold a sleep/idle inhibit for the whole session. setsid puts it in its own session, so closing the terminal
  # this ran in (SIGHUP to the foreground group) does not release it; $! is still its pid (setsid only forks when
  # it is already a group leader, which a background job of a script is not).
  if stag_have systemd-inhibit; then
    # shellcheck disable=SC2086  # INHIBIT_CMD is a test seam, word splitting is intended
    setsid systemd-inhibit --what=sleep:idle:handle-lid-switch --who=stag-field \
      --why="StagOS field mode" --mode=block $INHIBIT_CMD >/dev/null 2>&1 </dev/null &
    S_INH=$!
    disown 2>/dev/null || true
    S_INH_START="$(proc_start "$S_INH")"
  fi

  save_state
  say "field mode on"
  cmd_status
}

cmd_off() {
  [ -e "$FIELD_JSON" ] || { say "field mode is not on"; cmd_status; return 0; }
  if ! stag_field_active; then
    # left over from an earlier boot: card, MAC and inhibit were reset by the reboot; only brightness may differ
    load_state; restore_brightness; clear_state
    say "field mode: cleared a stale session from an earlier boot"
    cmd_status; return 0
  fi
  load_state

  # 1. Kismet: stop cleanly so it flushes the sqlite log (only the one field mode started)
  if [ "$S_KIS" = 1 ] && stag_kismet_running; then
    pkill -x kismet 2>/dev/null || true
    local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do stag_kismet_running || break; sleep 0.5; done
    if stag_kismet_running; then say "kismet: still running (did not stop)"; else say "kismet: stopped"; fi
  fi

  # 2. capture card back to managed (when field mode put it in monitor mode)
  if [ "$S_MON" = 1 ] && [ -n "$S_IFACE" ] && [ "$(stag_iface_mode "$S_IFACE")" = monitor ]; then
    iface_to_mode "$S_IFACE" managed || say "could not return $S_IFACE to managed mode"
  fi

  # 3. release the inhibit: its whole process group, and only if the pid is still the process we started
  if [[ "$S_INH" =~ ^[0-9]+$ ]] && [ "$S_INH" -gt 0 ] && [ -n "$S_INH_START" ] && [ "$(proc_start "$S_INH")" = "$S_INH_START" ]; then
    kill -- "-$S_INH" 2>/dev/null || kill "$S_INH" 2>/dev/null || true
  fi

  # 4. the built-in card back to its hardware MAC (only if we changed it; NetworkManager applies its own
  # per-network MAC on the next connect anyway), brightness back, power handed back to TLP auto
  if [ -n "$S_MAC" ] && [ -n "$S_BI" ] && stag_have macchanger; then
    if priv ip link set "$S_BI" down && priv macchanger -p "$S_BI" >/dev/null && priv ip link set "$S_BI" up; then
      say "mac: $S_BI back to its hardware address"
    else
      say "mac: could not restore $S_BI (sudo ip link set $S_BI down; sudo macchanger -p $S_BI; sudo ip link set $S_BI up)"
    fi
  fi
  restore_brightness
  if stag_have tlp; then priv tlp start >/dev/null 2>&1 || true; fi

  clear_state
  say "field mode off"

  # 5. sync in the background when online (the --user timer catches up otherwise)
  if is_online; then
    ( setsid "$0" sync ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    say "sync: started in the background"
  else
    say "sync: offline, left for the field-sync timer"
  fi
  cmd_status
}
restore_brightness() {
  if [[ "$S_BR" =~ ^[0-9]+$ ]] && stag_have brightnessctl; then
    brightnessctl -q set "${S_BR}%" >/dev/null 2>&1 || true
  fi
}

# ---- brightness: current percent from sysfs (same pick order as stag-ctl) ----
bright_pct() {
  local d first="" cur max
  for d in "$STAG_SYS"/class/backlight/*; do
    [ -r "$d/max_brightness" ] || continue
    case "${d##*/}" in intel_backlight|amdgpu_bl*|acpi_video0) first="$d"; break ;; esac
    [ -z "$first" ] && first="$d"
  done
  [ -n "$first" ] || return 0
  cur="$(stag_read "$first/brightness")"; max="$(stag_read "$first/max_brightness")"
  [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ] || return 0
  printf '%s' "$(( (cur * 100 + max / 2) / max ))"
}

# ---- state file (compact JSON on one line) ----
save_state() { # writes the S_* session variables
  mkdir -p "$STAG_STATE" || return 1
  local extra=""
  [ -n "$S_MAC" ] && extra+=",\"mac_original\":\"$(stag_json_esc "$S_MAC")\""
  [ -n "$S_MACNOTE" ] && extra+=",\"mac_note\":\"$(stag_json_esc "$S_MACNOTE")\""
  [ -n "$S_BR" ] && extra+=",\"brightness_original\":$S_BR"
  [ -n "$S_INH_START" ] && extra+=",\"inhibit_start\":$S_INH_START"
  printf '{"active":true,"boot_id":"%s","iface":"%s","log_dir":"%s","started":%s,"gps_fix":%s,"inhibit_pid":%s,"builtin":"%s","set_monitor":%s,"started_kismet":%s%s}\n' \
    "$(stag_json_esc "$(boot_id)")" "$(stag_json_esc "$S_IFACE")" "$(stag_json_esc "$S_LOG")" "$(stag_now)" "${S_GPS:-0}" \
    "${S_INH:-0}" "$(stag_json_esc "$S_BI")" "$S_MON" "$S_KIS" "$extra" \
    > "$FIELD_JSON.tmp.$$" && mv -f "$FIELD_JSON.tmp.$$" "$FIELD_JSON"
}
load_state() {
  S_IFACE="$(fj_get iface)"; S_LOG="$(fj_get log_dir)"; S_INH="$(fj_get inhibit_pid)"; S_INH_START="$(fj_get inhibit_start)"
  S_MAC="$(fj_get mac_original)"; S_BR="$(fj_get brightness_original)"; S_BI="$(fj_get builtin)"
  S_MON="$(fj_get set_monitor)"; S_KIS="$(fj_get started_kismet)"
  # a session file from before these keys existed: assume field mode did both
  [ -n "$S_MON" ] || S_MON=1
  [ -n "$S_KIS" ] || S_KIS=1
}
clear_state() { rm -f "$FIELD_JSON"; }

# ---- status ----
cmd_status() {
  local active=false iface mode="unset" gps kis=false started=0 log_dir last devices=null
  if stag_field_active; then active=true; fi
  iface="$(fj_get iface)"; [ -n "$iface" ] || iface="$(stag_capture_iface)"
  [ -n "$iface" ] && mode="$(stag_iface_mode "$iface")"
  gps="$(fj_get gps_fix)"; [ -n "$gps" ] || gps="$(stag_gps)"; [[ "$gps" =~ ^[0-9]$ ]] || gps=0
  stag_kismet_running && kis=true
  started="$(fj_get started)"; [[ "$started" =~ ^[0-9]+$ ]] || started=0
  log_dir="$(fj_get log_dir)"
  last="$(stag_field_last_upload)"
  printf '{"active":%s,"iface":"%s","mode":"%s","gps":%s,"kismet":%s,"started":%s,"log_dir":"%s","devices":%s,"last_upload":"%s"}\n' \
    "$active" "$(stag_json_esc "$iface")" "$mode" "$gps" "$kis" "$started" "$(stag_json_esc "$log_dir")" \
    "$devices" "$(stag_json_esc "$last")"
}

# ---- sync ----
is_online() { local ts; ts="$(stag_ts)"; [[ "$ts" == up* ]]; }
maps_base() { local u; u="$(stag_service_url maps)" || return 1; [ -n "$u" ] || return 1; printf '%s' "${u%/}"; }

uploads_has() { # SHA: rc 0 when already recorded as uploaded
  [ -r "$UPLOADS_JSON" ] || return 1
  grep -q "\"$1\"" "$UPLOADS_JSON"
}
uploads_record() { # SHA FILE DUPLICATE DEVICES
  mkdir -p "$STAG_STATE"
  if stag_have python3; then
    UP_SHA="$1" UP_FILE="$2" UP_DUP="$3" UP_DEV="$4" UP_AT="$(now_iso)" python3 - "$UPLOADS_JSON" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
dev = os.environ["UP_DEV"]
d[os.environ["UP_SHA"]] = {
    "file": os.environ["UP_FILE"],
    "uploaded_at": os.environ["UP_AT"],
    "duplicate": os.environ["UP_DUP"] == "true",
    "devices": int(dev) if dev.isdigit() else None,
}
tmp = p + ".tmp"
json.dump(d, open(tmp, "w"), indent=0)
os.replace(tmp, p)
PY
  else
    # fallback: never reached on the target (python3 is in base), keeps sync working without it
    [ -s "$UPLOADS_JSON" ] || printf '{}\n' > "$UPLOADS_JSON"
    say "python3 missing: upload bookkeeping is append-only"
    printf '%s\n' "$1" >> "$UPLOADS_JSON.plain"
  fi
}

upload_one() { # FILE SHA ENDPOINT -> rc 0 on success, sets REPLY to the response body
  local f="$1" sha="$2" endpoint="$3" try resp clean
  for try in 1 2 3; do
    resp="$(curl -sS --connect-timeout 15 --max-time 1800 -F "file=@$f" -F "host=$(host_name)" "$endpoint" 2>/dev/null)"
    clean="${resp//[[:space:]]/}"   # tolerate spaces in the server's JSON
    if [ -n "$resp" ] && [[ "$clean" == *'"ok":true'* ]]; then REPLY="$clean"; return 0; fi
    [ "$try" -lt 3 ] && sleep "$((try * 2))"
  done
  REPLY="$resp"; return 1
}

cmd_sync() {
  stag_have curl || fail 3 "curl is not installed"
  if ! is_online; then printf '{"ok":true,"online":false,"uploaded":0}\n'; return 0; fi
  local base; base="$(maps_base)" || { printf '{"ok":true,"online":true,"reachable":false,"uploaded":0}\n'; return 0; }
  local endpoint="$base/api/field/kismet"
  local f sha up=0 dup=0 failed=0 dupflag devcount now mtime age live=""
  now="$(stag_now)"
  # the log dir of a running field session: Kismet is still writing there, and a partial log uploaded now would be
  # counted again (different sha256) once it is finished
  if stag_field_active && stag_kismet_running; then live="$(fj_get log_dir)"; fi
  while IFS= read -r f; do
    [ -s "$f" ] || continue
    [ -n "$live" ] && [ "${f%/*}" = "$live" ] && continue
    [ -e "$f-journal" ] && continue
    # skip a log kismet is still writing (changed in the last 15 s)
    mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"; age=$((now - mtime))
    [ "$age" -lt 15 ] && continue
    sha="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"; [ -n "$sha" ] || continue
    uploads_has "$sha" && continue
    if upload_one "$f" "$sha" "$endpoint"; then
      dupflag=false; [[ "$REPLY" == *'"duplicate":true'* ]] && { dupflag=true; dup=$((dup + 1)); }
      devcount=""; [[ "$REPLY" =~ \"devices\":([0-9]+) ]] && devcount="${BASH_REMATCH[1]}"
      uploads_record "$sha" "$f" "$dupflag" "$devcount"
      up=$((up + 1))
      now_iso > "$LAST_SYNC_FILE"
    else
      failed=$((failed + 1))
      say "sync: upload failed for $f"
    fi
  done < <(find "$FIELD_ROOT" -type f -name '*.kismet' 2>/dev/null | sort)
  printf '{"ok":%s,"online":true,"reachable":true,"uploaded":%s,"duplicates":%s,"failed":%s}\n' \
    "$([ "$failed" -eq 0 ] && echo true || echo false)" "$up" "$dup" "$failed"
  [ "$failed" -eq 0 ]
}

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
case "${1:-}" in
  on) cmd_on ;;
  off) cmd_off ;;
  sync) cmd_sync ;;
  status) cmd_status ;;
  -h|--help|help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
