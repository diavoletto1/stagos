#!/usr/bin/env bash
# Stag integration: a chromium --app launcher for each stag-* service, listed in the STAG menu on
# the bar. Host and paths come from config/local.conf (untracked).
stagos_dm_stag() {
  dm_pkgs chromium fuzzel
  dm_bins stag-menu
  dm_config waybar
  local host="${STAGOS_STAG_HOST:-}" scheme="${STAGOS_STAG_SCHEME:-https}"
  if [[ -z "$host" || "$host" == CHANGEME* ]] || [[ ${#STAGOS_STAG_PATHS[@]} -eq 0 ]]; then
    warn "STAGOS_STAG_HOST not set in config/local.conf: no stag launchers generated (copy config/local.conf.example)"
    return 0
  fi
  local apps="$HOME/.local/share/applications" icons="$HOME/.local/share/icons/hicolor/scalable/apps"
  local list="" p url title initial
  for p in "${STAGOS_STAG_PATHS[@]}"; do
    url="$scheme://$host/$p/"
    title="Stag ${p^}"; initial="${p:0:1}"; initial="${initial^^}"
    list+="$p|$url"$'\n'
    dm_write "$apps/stag-$p.desktop" 644 <<DESK
[Desktop Entry]
Type=Application
Name=$title
Comment=stag-$p in an app window
Exec=chromium --app=$url
Icon=stag-$p
Terminal=false
Categories=Network;
StartupWMClass=chrome-${host}_$(printf '%s' "/$p/" | tr '/' '_')-Default
DESK
    # HUD tile icon: black square, hairline border, red initial
    dm_write "$icons/stag-$p.svg" 644 <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><rect width="128" height="128" fill="#0a0a0a"/><rect x="2" y="2" width="124" height="124" fill="none" stroke="#2a2a2a" stroke-width="2"/><rect x="2" y="120" width="124" height="6" fill="#c8102e"/><text x="64" y="84" font-family="Inter, sans-serif" font-size="64" font-weight="700" fill="#f0f0f0" text-anchor="middle">$initial</text></svg>
SVG
  done
  printf '%s' "$list" | dm_write "$(dm_cfg)/stagos/stag-services" 600
  ok "stag launchers: ${STAGOS_STAG_PATHS[*]}"
}
