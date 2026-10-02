#!/usr/bin/env bash
# Bluetooth: bluez, powered on at boot, USB BT never autosuspended. The tray and pairing UI is Plasma's
# bluedevil (module plasma); the Control Center toggle is stag-ctl bt (bluetoothctl).
stagos_dm_bluetooth() {
  dm_pkgs bluez bluez-utils
  # power the adapter on at boot (idempotent edit of the stock main.conf)
  if ! dm_dry && [[ -f /etc/bluetooth/main.conf ]]; then
    sudo sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
  fi
  # TLP would otherwise autosuspend the btusb dongle: dropouts and reconnect loops
  dm_install "$HERE/desktop/tlp/50-stagos.conf" /etc/tlp.d/50-stagos.conf 644 sudo
  dm_enable_system bluetooth.service
  ok "bluetooth ready (pairing: bluedevil in Plasma, or bluetoothctl)"
}
