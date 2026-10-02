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

cmd_on() {
  stag_field_active && { say "field mode is already on (stag-field off first)"; cmd_status; return 0; }
  local iface; iface="$(stag_capture_iface)"
  [ -n "$iface" ] || fail 3 "no capture card configured ([recon] capture_iface in desktop.conf, or STAGOS_CAPTURE_IFACE)"
  local mode; mode="$(stag_iface_mode "$iface")"
  [ "$mode" = absent ] && fail 3 "$iface is not present (is the capture card plugged in?)"

  # 1. capture card -> monitor mode
  if [ "$mode" != monitor ]; then
    iface_to_mode "$iface" monitor || fail 1 "could not put $iface into monitor mode"
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

  # 3. Kismet -> ~/field/<date>/ (user owns the logs; --log-prefix overrides kismet's log_prefix)
  local day log_dir; day="$(date +%Y-%m-%d)"; log_dir="$FIELD_ROOT/$day"
  mkdir -p "$log_dir" || fail 1 "could not create $log_dir"
  if ! stag_kismet_running; then
    stag_have kismet || fail 3 "kismet is not installed"
    ( cd "$log_dir" && setsid -f kismet --no-ncurses --log-prefix "$log_dir" -c "$iface" \
        >"$log_dir/kismet.out" 2>&1 </dev/null ) || fail 1 "kismet did not start"
    say "kismet: logging to $log_dir"
  fi

  # 4. randomize the built-in wifi MAC, but never drop a live connection
  local bi mac_orig="" mac_note=""
  if bi="$(builtin_iface)"; then
    if iface_connected "$bi"; then
      mac_note="kept: $bi is connected"
      say "mac: $mac_note"
    elif stag_have macchanger; then
      mac_orig="$(stag_read "$STAG_SYS/class/net/$bi/address")"
      if priv ip link set "$bi" down && priv macchanger -r "$bi" >/dev/null && priv ip link set "$bi" up; then
        say "mac: $bi randomized"
      else
        mac_orig=""; mac_note="randomize failed"; say "mac: randomize failed on $bi"
      fi
    else
      mac_note="macchanger not installed"
    fi
  else
    mac_note="no built-in card to randomize"
  fi

  # 5. power: a notch dimmer, TLP battery mode
  local br_orig=""
  br_orig="$(bright_pct)"
  if [ -n "$br_orig" ] && stag_have brightnessctl; then
    local target=$((br_orig - 15)); [ "$target" -lt 5 ] && target=5
    brightnessctl -q set "${target}%" >/dev/null 2>&1 || true
  fi
  if stag_have tlp; then priv tlp bat >/dev/null 2>&1 || say "tlp: could not switch to battery mode"; fi

  # 6. hold a sleep/idle inhibit for the whole session. Backgrounded (not setsid) so $! is the inhibit's own
  # pid and stag-field off can release it; disown keeps it off the shell job table so it survives our exit.
  local inhibit_pid=0
  if stag_have systemd-inhibit; then
    # shellcheck disable=SC2086  # INHIBIT_CMD is a test seam, word splitting is intended
    systemd-inhibit --what=sleep:idle:handle-lid-switch --who=stag-field \
      --why="StagOS field mode" --mode=block $INHIBIT_CMD >/dev/null 2>&1 &
    inhibit_pid=$!
    disown 2>/dev/null || true
  fi

  write_state true "$iface" "$log_dir" "$gps" "$inhibit_pid" "$mac_orig" "$mac_note" "$br_orig" "$bi"
  say "field mode on"
  cmd_status
}

cmd_off() {
  stag_field_active || { say "field mode is not on"; cmd_status; return 0; }
  local iface log_dir inhibit_pid mac_orig br_orig bi
  iface="$(fj_get iface)"; log_dir="$(fj_get log_dir)"; inhibit_pid="$(fj_get inhibit_pid)"
  mac_orig="$(fj_get mac_original)"; br_orig="$(fj_get brightness_original)"; bi="$(fj_get builtin)"

  # 1. Kismet: stop cleanly so it flushes the sqlite log
  if stag_kismet_running; then
    pkill -x kismet 2>/dev/null || true
    local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do stag_kismet_running || break; sleep 0.5; done
    if stag_kismet_running; then say "kismet: still running (did not stop)"; else say "kismet: stopped"; fi
  fi

  # 2. capture card back to managed
  if [ -n "$iface" ] && [ "$(stag_iface_mode "$iface")" = monitor ]; then
    iface_to_mode "$iface" managed || say "could not return $iface to managed mode"
  fi

  # 3. release the inhibit
  if [[ "$inhibit_pid" =~ ^[0-9]+$ ]] && [ "$inhibit_pid" -gt 0 ]; then
    kill "$inhibit_pid" 2>/dev/null || true
  fi

  # 4. restore MAC (only if we changed it) and brightness, hand power back to TLP auto
  if [ -n "$mac_orig" ] && [ -n "$bi" ] && stag_have macchanger; then
    if priv ip link set "$bi" down && priv macchanger --mac "$mac_orig" "$bi" >/dev/null && priv ip link set "$bi" up; then
      say "mac: $bi restored"
    else
      say "mac: could not restore $bi"
    fi
  fi
  if [[ "$br_orig" =~ ^[0-9]+$ ]] && stag_have brightnessctl; then
    brightnessctl -q set "${br_orig}%" >/dev/null 2>&1 || true
  fi
  if stag_have tlp; then priv tlp start >/dev/null 2>&1 || true; fi

  clear_state
  say "field mode off"

  # 5. sync in the background when online (the --user timer catches up otherwise)
  if is_online; then
    ( "$0" sync ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    say "sync: started in the background"
  else
    say "sync: offline, left for the field-sync timer"
  fi
  cmd_status
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
write_state() { # active iface log_dir gps inhibit_pid mac_orig mac_note br_orig builtin
  mkdir -p "$STAG_STATE"
  local extra=""
  [ -n "$6" ] && extra+=",\"mac_original\":\"$(stag_json_esc "$6")\""
  [ -n "$7" ] && extra+=",\"mac_note\":\"$(stag_json_esc "$7")\""
  [ -n "$8" ] && extra+=",\"brightness_original\":$8"
  printf '{"active":%s,"iface":"%s","log_dir":"%s","started":%s,"gps_fix":%s,"inhibit_pid":%s,"builtin":"%s"%s}\n' \
    "$1" "$(stag_json_esc "$2")" "$(stag_json_esc "$3")" "$(stag_now)" "${4:-0}" "${5:-0}" "$(stag_json_esc "$9")" "$extra" \
    > "$FIELD_JSON.tmp.$$" && mv -f "$FIELD_JSON.tmp.$$" "$FIELD_JSON"
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
    resp="$(curl -sS --max-time 300 -F "file=@$f" -F "host=$(host_name)" "$endpoint" 2>/dev/null)"
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
  local f sha up=0 dup=0 failed=0 dupflag devcount now mtime age
  now="$(stag_now)"
  while IFS= read -r f; do
    [ -s "$f" ] || continue
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
