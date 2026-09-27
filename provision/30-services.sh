#!/usr/bin/env bash
# Services: gpsd, kismet group, and keep NetworkManager off the capture card.
# Capture card must be named in config (STAGOS_CAPTURE_IFACE) and be a second card; never auto-detected.
stagos_30_services() {
  run sudo systemctl enable gpsd.socket
  run sudo usermod -aG kismet,wireshark "$STAGOS_USER"

  # Only hand a card to capture duty when it's explicitly named AND it isn't the only wifi card.
  # (Auto-detect grabbed the built-in Intel card on first run and killed normal wifi.)
  local ncards
  ncards=$(find /sys/class/net -maxdepth 2 -name wireless 2>/dev/null | wc -l)
  if [[ -n "${STAGOS_CAPTURE_IFACE:-}" && ( "$ncards" -ge 2 || -n "${STAGOS_MOCK_WIFI:-}" ) ]]; then
    log "capture iface: $STAGOS_CAPTURE_IFACE -> NetworkManager will leave it alone"
    run sudo mkdir -p /etc/NetworkManager/conf.d
    printf '[keyfile]\nunmanaged-devices=interface-name:%s\n' "$STAGOS_CAPTURE_IFACE" \
      | run sudo tee /etc/NetworkManager/conf.d/10-stagos-capture.conf >/dev/null
  else
    run sudo rm -f /etc/NetworkManager/conf.d/10-stagos-capture.conf
    warn "no dedicated capture card configured; all wifi stays with NetworkManager"
  fi
  ok "services configured"
}
