#!/usr/bin/env bash
# Verify: every core tool resolvable, key services enabled. Reports, never exits hard.
stagos_99_verify() {
  local gaps=0 bin
  for bin in aircrack-ng kismet gpsd wifite hashcat hcxpcapngtool hcxdumptool macchanger; do
    if have "$bin"; then ok "found $bin"; else warn "missing $bin"; gaps=$((gaps+1)); fi
  done
  local svc
  for svc in NetworkManager gpsd.socket tlp tailscaled; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then ok "enabled $svc"; else warn "not enabled $svc"; gaps=$((gaps+1)); fi
  done
  if wifi_monitor_iface >/dev/null; then ok "monitor-capable wifi present"; else warn "no monitor-capable wifi (expected until card swap)"; fi
  if [[ $gaps -eq 0 ]]; then ok "verify clean"; else warn "verify: $gaps gap(s)"; fi
}
