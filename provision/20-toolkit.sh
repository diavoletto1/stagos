#!/usr/bin/env bash
# War-driving toolkit. CORE = your stated list; EXTRA = optional, trim freely.
STAGOS_TOOLS_CORE=(aircrack-ng kismet gpsd wifite hashcat hcxtools hcxdumptool macchanger)
STAGOS_TOOLS_EXTRA=(iw wireless_tools tcpdump wireshark-cli nmap)

stagos_20_toolkit() {
  run sudo pacman -S --needed --noconfirm "${STAGOS_TOOLS_CORE[@]}" "${STAGOS_TOOLS_EXTRA[@]}"
  ok "toolkit installed"
}
