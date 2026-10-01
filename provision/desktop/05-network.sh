#!/usr/bin/env bash
# Networking: NetworkManager. Keeps the existing setup: NM stays in charge of the built-in card, and the
# dedicated capture card (unmanaged-devices drop-in from 30-services) is not touched, so monitor-mode tooling
# keeps working. No MAC/scan randomisation drop-ins are added. The UI is Plasma's plasma-nm (module plasma)
# and stag-ctl wifi (nmcli).
stagos_dm_network() {
  dm_pkgs networkmanager
  dm_enable_system NetworkManager.service
  if [[ -f /etc/NetworkManager/conf.d/10-stagos-capture.conf ]]; then
    ok "capture card exemption present: $(grep -o 'interface-name:[^ ]*' /etc/NetworkManager/conf.d/10-stagos-capture.conf)"
  else
    log "no dedicated capture card configured (30-services decides that); nothing to preserve"
  fi
  ok "networking ready"
}
