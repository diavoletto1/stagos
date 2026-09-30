#!/bin/bash
# waybar: tailscale state. Short label, the address goes in the tooltip.
if ! command -v tailscale >/dev/null; then
  printf '{"text":"TS","class":"off","tooltip":"tailscale not installed"}\n'; exit 0
fi
if tailscale status >/dev/null 2>&1; then
  ip=$(tailscale ip -4 2>/dev/null | head -1)
  printf '{"text":"TS","class":"ok","tooltip":"tailnet up  %s"}\n' "${ip:-?}"
else
  printf '{"text":"TS","class":"off","tooltip":"tailnet down"}\n'
fi
