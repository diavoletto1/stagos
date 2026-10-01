#!/bin/bash
# StagOS shared shell helpers, sourced (not run) by stag-ctl and stag-status:
#   . stag-lib        (bash finds it on PATH; installed as /usr/local/bin/stag-lib)
# Everything here is cheap: /proc and /sys are read with bash builtins, slow probes (tailscale,
# gpsd) go through stag_cached so a bar poll never waits on them.
# Test overrides: STAGOS_SYS (/sys), STAGOS_PROC (/proc), STAGOS_CACHE (~/.cache/stagos),
# STAGOS_DESKTOP_CONF, STAGOS_PLASMA_DATA, STAGOS_CONF (config/stagos.conf).
# shellcheck disable=SC2034  # variables set here are read by the scripts that source it

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "stag-lib: helper library, source it (. stag-lib)" >&2
  exit 2
fi

STAG_SYS="${STAGOS_SYS:-/sys}"
STAG_PROC="${STAGOS_PROC:-/proc}"
STAG_CACHE="${STAGOS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/stagos}"
STAG_CONF="${STAGOS_DESKTOP_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/stagos/desktop.conf}"
STAG_CONF_DEFAULT="${STAGOS_PLASMA_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/stagos/plasma}/desktop.conf.default"

stag_have() { command -v "$1" >/dev/null 2>&1; }
stag_now() { printf '%(%s)T' -1; }

# ---- desktop.conf (INI): missing file or key = desktop.conf.default = $3 ----
# One pass over both files per process: STAG_INI["section.key"]; the file wins over the defaults.
declare -gA STAG_INI=()
STAG_INI_LOADED=0
stag_ini_load() {
  local f line sec="" key val
  STAG_INI=()
  for f in "$STAG_CONF_DEFAULT" "$STAG_CONF"; do
    [ -r "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in
        ''|'#'*|';'*) continue ;;
        '['*']'*) sec="${line#[}"; sec="${sec%%]*}"; continue ;;
        *=*) key="${line%%=*}"; val="${line#*=}"
             key="${key%"${key##*[![:space:]]}"}"
             val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
             STAG_INI["$sec.$key"]="$val" ;;
      esac
    done < "$f"
  done
  STAG_INI_LOADED=1
}
stag_conf() { # stag_conf SECTION KEY [DEFAULT]
  [ "$STAG_INI_LOADED" = 1 ] || stag_ini_load
  if [ -n "${STAG_INI["$1.$2"]+x}" ]; then printf '%s' "${STAG_INI["$1.$2"]}"; else printf '%s' "${3:-}"; fi
}
stag_conf_bool() { # rc 0 when true (true/1/yes/on), DEFAULT when absent (no subshell: called per field)
  [ "$STAG_INI_LOADED" = 1 ] || stag_ini_load
  local v="${3:-true}"
  [ -n "${STAG_INI["$1.$2"]+x}" ] && v="${STAG_INI["$1.$2"]}"
  case "$v" in true|1|yes|on|True|TRUE) return 0 ;; *) return 1 ;; esac
}

# ---- JSON ----
stag_json_esc() { # prints $1 escaped for a JSON string (no quotes)
  local s
  stag_json_esc_v s "$1"
  printf '%s' "$s"
}
stag_json_esc_v() { # VAR STRING: VAR = STRING escaped for JSON (no fork)
  local _s="$2"
  _s="${_s//\\/\\\\}"; _s="${_s//\"/\\\"}"
  _s="${_s//$'\n'/\\n}"; _s="${_s//$'\t'/\\t}"; _s="${_s//$'\r'/}"
  _s="${_s//[$'\x01'-$'\x1f']/}"
  printf -v "$1" '%s' "$_s"
}
stag_jb() { if [ "$1" = 1 ] || [ "$1" = true ]; then printf true; else printf false; fi; }

# ---- small file readers (builtins only) ----
stag_read() { # stag_read FILE: first line, rc 1 when unreadable
  local v
  [ -r "$1" ] || return 1
  IFS= read -r v < "$1" || [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# ---- cache: file = "EPOCH" line + value lines ----
# stag_cached NAME TTL FUNC: prints the cached value of FUNC. Fresh: as is. Stale or missing: prints
# what is there (maybe nothing) and refreshes it in the background, one refresher at a time.
# STAGOS_CACHE_SYNC=1 refreshes in the foreground instead (tests, the Control Center).
stag_cache_get() { # NAME TTL -> value on stdout, rc 0 fresh / 1 stale / 2 missing
  local f="$STAG_CACHE/$1" lines=() now
  [ -r "$f" ] || return 2
  local IFS=$'\n'
  mapfile -t lines < "$f"
  [ "${#lines[@]}" -ge 1 ] || return 2
  printf '%s' "${lines[*]:1}"
  now="$(stag_now)"
  [[ "${lines[0]}" =~ ^[0-9]+$ ]] && [ $((now - lines[0])) -lt "$2" ]
}
stag_cache_put() { # NAME, value on stdin
  local f="$STAG_CACHE/$1"
  mkdir -p "$STAG_CACHE"
  { stag_now; echo; cat; } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}
stag_cache_refresh() { # NAME FUNC: run FUNC under a lock, store its output
  mkdir -p "$STAG_CACHE"
  (
    if stag_have flock; then flock -n 9 || exit 0; fi
    "$2" | stag_cache_put "$1"
  ) 9>"$STAG_CACHE/$1.lock"
}
stag_cached() { # NAME TTL FUNC
  local v rc
  v="$(stag_cache_get "$1" "$2")"; rc=$?
  if [ "$rc" = 0 ]; then printf '%s' "$v"; return 0; fi
  if [ "${STAGOS_CACHE_SYNC:-0}" = 1 ]; then
    stag_cache_refresh "$1" "$3"
    stag_cache_get "$1" 999999999
    return 0
  fi
  ( stag_cache_refresh "$1" "$3" ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  printf '%s' "$v"
}

# ---- recon: tailscale, gps, capture card, kismet ----
stag_ts() { # "none" | "down" | "up <ipv4>"
  if ! stag_have tailscale; then echo none; return; fi
  if tailscale status >/dev/null 2>&1; then
    local ip; ip="$(tailscale ip -4 2>/dev/null | head -1)"
    echo "up ${ip:-?}"
  else
    echo down
  fi
}
stag_gps() { # gpsd fix mode: "na" (no gpspipe) | 0 | 2 | 3. STAGOS_GPSD=host:port overrides.
  if ! stag_have gpspipe; then echo na; return; fi
  local j mode
  # shellcheck disable=SC2086
  j="$(timeout 2 gpspipe -w -n 8 ${STAGOS_GPSD:-} 2>/dev/null | grep -m1 '"class":"TPV"')"
  mode="$(printf '%s' "$j" | grep -oE '"mode":[0-9]' | grep -oE '[0-9]$')"
  case "${mode:-0}" in 2|3) echo "$mode" ;; *) echo 0 ;; esac
}
stag_capture_iface() { # the capture card: desktop.conf [recon] capture_iface, else STAGOS_CAPTURE_IFACE
  # (env, else config/local.conf or config/stagos.conf of the checkout, like stag-mon)
  local i c line v
  i="$(stag_conf recon capture_iface "")"
  [ -n "$i" ] && { printf '%s' "$i"; return 0; }
  [ -n "${STAGOS_CAPTURE_IFACE:-}" ] && { printf '%s' "$STAGOS_CAPTURE_IFACE"; return 0; }
  c="${STAGOS_CONF:-$HOME/stagos/config/stagos.conf}"
  for c in "${c%/*}/local.conf" "$c"; do
    [ -r "$c" ] || continue
    while IFS= read -r line; do
      case "$line" in
        STAGOS_CAPTURE_IFACE=*)
          v="${line#*=}"; v="${v%%#*}"; v="${v//[\"\' ]/}"
          case "$v" in *'$'*|'') ;; *) printf '%s' "$v"; return 0 ;; esac ;;
      esac
    done < "$c"
  done
}
stag_iface_mode() { # IFACE: monitor | managed | absent (ARPHRD 803 = radiotap = monitor mode)
  local d="$STAG_SYS/class/net/$1" t
  [[ -n "$1" && -d "$d" ]] || { echo absent; return; }
  t="$(stag_read "$d/type")"
  if [ "$t" = 803 ]; then echo monitor
  elif [ -d "$d/wireless" ] || [ -e "$d/phy80211" ]; then echo managed
  else echo absent; fi
}
stag_mon_iface() { # first wifi iface in monitor mode (any card), empty when none
  local d
  for d in "$STAG_SYS"/class/net/*; do
    [ -r "$d/type" ] || continue
    [ "$(stag_read "$d/type")" = 803 ] && { printf '%s' "${d##*/}"; return 0; }
  done
  return 1
}
stag_kismet_running() { pgrep -x kismet >/dev/null 2>&1; }

# ---- stag services (~/.config/stagos/stag-services: "name|url" lines, from module stag) ----
stag_services_file() { printf '%s' "${STAGOS_STAG_LIST:-${XDG_CONFIG_HOME:-$HOME/.config}/stagos/stag-services}"; }
stag_service_url() { # NAME -> url
  local n u
  while IFS='|' read -r n u; do
    [ "$n" = "$1" ] && [ -n "$u" ] && { printf '%s' "$u"; return 0; }
  done < "$(stag_services_file)" 2>/dev/null
  return 1
}
