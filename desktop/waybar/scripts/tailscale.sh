#!/bin/bash
# waybar: tailscale state. Green when up + this node online.
if ! command -v tailscale >/dev/null; then
  printf '{"text":"TS n/a","class":"off"}\n'; exit 0
fi
if tailscale status >/dev/null 2>&1; then
  ip=$(tailscale ip -4 2>/dev/null | head -1)
  printf '{"text":"TS %s","class":"ok","tooltip":"tailnet up"}\n' "${ip:-up}"
else
  printf '{"text":"TS off","class":"off","tooltip":"not connected"}\n'
fi
