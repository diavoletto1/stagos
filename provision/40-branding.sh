#!/usr/bin/env bash
# StagOS identity. /etc/os-release belongs to the filesystem pkg, so we ship
# /etc/stagos-release, symlink to it, and a pacman hook re-applies it after upgrades.
stagos_40_branding() {
  local rel
  rel=$'NAME="StagOS"\nPRETTY_NAME="StagOS"\nID=stagos\nID_LIKE=arch\nBUILD_ID=rolling\nANSI_COLOR="38;2;0;200;255"\nHOME_URL="https://github.com/diavoletto1/stagos"'
  printf '%s\n' "$rel" | run sudo tee /etc/stagos-release >/dev/null
  run sudo ln -sf /etc/stagos-release /etc/os-release
  run sudo install -Dm644 "$HERE/assets/stagos-release.hook" /etc/pacman.d/hooks/stagos-release.hook

  run sudo install -Dm644 "$HERE/assets/motd" /etc/motd

  # Plymouth + GRUB themes: stock placeholders until custom assets land in assets/.
  if [[ -d "$HERE/assets/plymouth/stagos" ]]; then
    run sudo cp -r "$HERE/assets/plymouth/stagos" /usr/share/plymouth/themes/
    run sudo plymouth-set-default-theme -R stagos
  else
    run sudo plymouth-set-default-theme -R spinner
    warn "custom plymouth theme not built yet (assets/plymouth/stagos)"
  fi
  # GRUB: background + stag colors; menu hidden (hold Esc/Shift at boot to show it)
  if [[ -f "$HERE/assets/grub/stagos/background.png" ]]; then
    run sudo install -Dm644 "$HERE/assets/grub/stagos/background.png" /boot/grub/stagos-bg.png
    run sudo sed -i \
      -e 's|^#\?GRUB_THEME=.*|#GRUB_THEME=|' \
      -e 's|^#\?GRUB_BACKGROUND=.*|GRUB_BACKGROUND="/boot/grub/stagos-bg.png"|' \
      -e 's|^#\?GRUB_COLOR_NORMAL=.*|GRUB_COLOR_NORMAL="light-gray/black"|' \
      -e 's|^#\?GRUB_COLOR_HIGHLIGHT=.*|GRUB_COLOR_HIGHLIGHT="light-red/black"|' \
      -e 's|^#\?GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=hidden|' \
      -e 's|^#\?GRUB_TIMEOUT=.*|GRUB_TIMEOUT=1|' \
      /etc/default/grub
    grep -q '^GRUB_BACKGROUND=' /etc/default/grub 2>/dev/null || \
      run sudo tee -a /etc/default/grub >/dev/null <<'GEOF'
GRUB_BACKGROUND="/boot/grub/stagos-bg.png"
GRUB_COLOR_NORMAL="light-gray/black"
GRUB_COLOR_HIGHLIGHT="light-red/black"
GEOF
    run sudo grub-mkconfig -o /boot/grub/grub.cfg
  else
    warn "grub background not built yet (assets/grub/stagos/background.png)"
  fi
  ok "branding applied"
}
