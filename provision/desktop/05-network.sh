#!/usr/bin/env bash
# Networking: NetworkManager. NM stays in charge of the built-in card; the dedicated capture card (unmanaged-devices
# drop-in from 30-services) is not touched, so monitor-mode tooling keeps working.
# MAC privacy (desktop/network/20-stagos-mac.conf): random MAC while scanning, and a random MAC per wifi network,
# stable for each saved connection. Networks you trust keep the hardware MAC: `stag-mac trust "<name>"`, or list
# them in STAGOS_TRUSTED_NETS (config/local.conf, space separated connection names; those that exist are marked
# on every run). The UI is Plasma's plasma-nm (module plasma) and stag-ctl wifi (nmcli).
stagos_dm_network() {
  dm_pkgs networkmanager
  dm_enable_system NetworkManager.service
  if [[ -f /etc/NetworkManager/conf.d/10-stagos-capture.conf ]]; then
    ok "capture card exemption present: $(grep -o 'interface-name:[^ ]*' /etc/NetworkManager/conf.d/10-stagos-capture.conf)"
  else
    log "no dedicated capture card configured (30-services decides that); nothing to preserve"
  fi

  local before=$DM_CHANGED
  dm_install "$HERE/desktop/network/20-stagos-mac.conf" /etc/NetworkManager/conf.d/20-stagos-mac.conf 644 sudo
  dm_bins stag-mac
  if [[ $DM_CHANGED -gt $before ]] && ! dm_dry && have nmcli && nmcli general status >/dev/null 2>&1; then
    sudo nmcli general reload conf || warn "NetworkManager did not reload its config; it applies at the next restart"
    dm_note "network: new MAC settings apply when a wifi network is next (re)connected"
  fi
  local n
  for n in ${STAGOS_TRUSTED_NETS:-}; do
    if dm_dry || ! have nmcli || ! nmcli -g connection.id connection show id "$n" >/dev/null 2>&1; then
      log "trusted network '$n': no such saved connection yet (rerun after connecting once)"; continue
    fi
    [[ "$(nmcli -g 802-11-wireless.cloned-mac-address connection show id "$n")" == permanent ]] && continue
    nmcli connection modify id "$n" 802-11-wireless.cloned-mac-address permanent && DM_CHANGED=$((DM_CHANGED + 1))
    log "trusted network '$n': hardware MAC"
  done
  ok "networking ready"
}
