#!/usr/bin/env bash
# Networking: NetworkManager + nm-applet. Keeps the existing setup: NM stays in charge of the
# built-in card, and the dedicated capture card (unmanaged-devices drop-in from 30-services)
# is not touched, so monitor-mode tooling keeps working. No MAC/scan randomisation drop-ins are added.
stagos_dm_network() {
  dm_pkgs networkmanager network-manager-applet nm-connection-editor
  dm_enable_system NetworkManager.service
  if [[ -f /etc/NetworkManager/conf.d/10-stagos-capture.conf ]]; then
    ok "capture card exemption present: $(grep -o 'interface-name:[^ ]*' /etc/NetworkManager/conf.d/10-stagos-capture.conf)"
  else
    log "no dedicated capture card configured (30-services decides that); nothing to preserve"
  fi
  ok "networking ready (nm-applet starts from labwc autostart)"
}
