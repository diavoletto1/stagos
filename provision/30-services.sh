#!/usr/bin/env bash
# Services: gpsd, kismet group, and keep NetworkManager off the capture card.
# The capture-card rule is gated on wifi_monitor_iface (mockable via STAGOS_MOCK_WIFI).
stagos_30_services() {
  run sudo systemctl enable gpsd.socket
  run sudo usermod -aG kismet,wireshark "$STAGOS_USER"

  local iface
  if iface="$(wifi_monitor_iface)"; then
    log "monitor-capable iface: $iface -> NetworkManager will leave it alone"
    run sudo mkdir -p /etc/NetworkManager/conf.d
    printf '[keyfile]\nunmanaged-devices=interface-name:%s\n' "$iface" \
      | run sudo tee /etc/NetworkManager/conf.d/10-stagos-capture.conf >/dev/null
  else
    warn "no monitor-capable card detected; capture-iface rule deferred until the card is in"
  fi
  ok "services configured"
}
