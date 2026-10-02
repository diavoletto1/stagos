#!/usr/bin/env bash
# StagOS desktop extras: everyday apps and system services on top of 60-desktop.
stagos_65_extras() {
  if [[ "${STAGOS_DESKTOP:-1}" != "1" ]]; then
    warn "STAGOS_DESKTOP=0, skipping desktop extras"
    return 0
  fi
  local pkgs=(
    qt6-wayland xorg-xwayland qt6-multimedia-ffmpeg
    gnome-themes-extra
    noto-fonts noto-fonts-emoji noto-fonts-cjk ttf-nerd-fonts-symbols
    thunar thunar-volman thunar-archive-plugin gvfs tumbler xarchiver
    udisks2 udiskie xdg-user-dirs
    imv zathura zathura-pdf-mupdf mpv
    bluez bluez-utils bluetui
    libva-intel-driver earlyoom pacman-contrib
    plocate
    btop fzf zoxide eza bat ripgrep fd tealdeer lazygit restic
  )
  run sudo pacman -S --needed --noconfirm "${pkgs[@]}"
  run sudo systemctl enable --now bluetooth.service earlyoom.service paccache.timer plocate-updatedb.timer
  run xdg-user-dirs-update
  # tty1 autologin: the disk-unlock screen is the login page, so skip the second prompt
  if [[ "${STAGOS_AUTOLOGIN:-1}" == "1" ]]; then
    run sudo install -Dm644 "$HERE/assets/getty-tty1-autologin.conf" /etc/systemd/system/getty@tty1.service.d/autologin.conf
  fi
  ok "desktop extras installed"
}
