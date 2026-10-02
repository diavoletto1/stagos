#!/usr/bin/env bash
# stag-fw: look at and (briefly) lift the StagOS firewall. The ruleset is table inet stagos in /etc/nftables.conf.
#   stag-fw status          is the table loaded, the service enabled, is a restore timer pending, drop counters
#   stag-fw off-for 10m     delete the table now and put it back automatically after 10m (s, m or h; max 1h)
#   stag-fw on              reload the ruleset now and cancel a pending restore
#   stag-fw check           syntax-check /etc/nftables.conf and its drop-ins without loading them
# Only table inet stagos is touched: the tables tailscaled and libvirt keep are left alone. A reboot always
# restores the firewall, since nothing here changes what nftables.service loads at boot.
set -euo pipefail
CONF="${STAG_FW_CONF:-/etc/nftables.conf}"
TABLE=(inet stagos)
TIMER=stag-fw-restore
MAX=3600

usage() { sed -n '2,7p' "$0" | sed 's/^# \?//'; }
die() { echo "stag-fw: $*" >&2; exit 1; }
root() { if [[ ${EUID:-$(id -u)} -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# seconds from 10m / 90s / 1h / 600 (a bare number is seconds)
to_seconds() {
  [[ "$1" =~ ^([0-9]+)([smh]?)$ ]] || die "bad duration '$1' (use e.g. 90s, 10m, 1h)"
  local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]:-s}"
  case "$u" in s) echo "$n" ;; m) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; *) die "bad unit" ;; esac
}

loaded() { root nft list table "${TABLE[@]}" >/dev/null 2>&1; }
pending() { systemctl is-active --quiet "$TIMER.timer" 2>/dev/null; }

cmd_status() {
  if loaded; then echo "firewall: ON (table ${TABLE[*]} loaded)"; else echo "firewall: OFF (table ${TABLE[*]} not loaded)"; fi
  echo "nftables.service: enabled=$(systemctl is-enabled nftables.service 2>/dev/null || true) active=$(systemctl is-active nftables.service 2>/dev/null || true)"
  if pending; then echo "restore timer pending: $(systemctl list-timers "$TIMER.timer" --no-legend 2>/dev/null | head -1)"; fi
  if loaded; then
    echo "--- inbound policy and drop counters"
    root nft list table "${TABLE[@]}" | grep -E 'policy|counter' || true
  fi
}

cmd_on() {
  root nft -c -f "$CONF" || die "$CONF does not parse; not touching the running ruleset"
  root nft -f "$CONF"
  if pending; then root systemctl stop "$TIMER.timer" "$TIMER.service" 2>/dev/null || true; fi
  echo "firewall: ON"
}

cmd_off_for() {
  [[ $# -eq 1 ]] || die "usage: stag-fw off-for 10m"
  local s; s="$(to_seconds "$1")"
  [[ "$s" -ge 1 && "$s" -le "$MAX" ]] || die "duration must be 1s to 1h"
  # arm the restore first: if this fails we never leave the firewall open without a way back
  if pending; then root systemctl stop "$TIMER.timer" "$TIMER.service" 2>/dev/null || true; fi
  root systemd-run --quiet --unit="$TIMER" --on-active="${s}s" --description="StagOS firewall restore" \
    /usr/bin/nft -f "$CONF"
  root nft delete table "${TABLE[@]}" 2>/dev/null || true
  echo "firewall: OFF for ${s}s, restores itself (stag-fw on to restore now)"
}

case "${1:-status}" in
  status) cmd_status ;;
  on) cmd_on ;;
  off-for) shift; cmd_off_for "$@" ;;
  check) root nft -c -f "$CONF" && echo "ok: $CONF parses" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
