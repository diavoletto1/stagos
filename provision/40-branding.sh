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
  if [[ -d "$HERE/assets/grub/stagos" ]]; then
    run sudo cp -r "$HERE/assets/grub/stagos" /boot/grub/themes/
    run sudo sed -i 's|^#\?GRUB_THEME=.*|GRUB_THEME="/boot/grub/themes/stagos/theme.txt"|' /etc/default/grub
    run sudo grub-mkconfig -o /boot/grub/grub.cfg
  else
    warn "custom grub theme not built yet (assets/grub/stagos)"
  fi
  ok "branding applied"
}
