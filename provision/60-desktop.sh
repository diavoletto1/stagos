#!/usr/bin/env bash
# StagOS desktop base: KDE Plasma 6 (Wayland), HUD-themed. Installs the shared pieces every session needs
# (terminal, fonts, audio, GTK look, wallpapers, zsh), then delegates the Plasma session itself to the
# plasma module (`stagos-desktop plasma`: packages, StagOS look and layout, widgets, Settings, tty1 autostart).
# Skipped when STAGOS_DESKTOP=0.
stagos_60_desktop() {
  if [[ "${STAGOS_DESKTOP:-1}" != "1" ]]; then
    warn "STAGOS_DESKTOP=0, skipping desktop layer"
    return 0
  fi
  local pkgs=(foot wl-clipboard libnotify brightnessctl playerctl polkit
    pavucontrol pipewire pipewire-pulse wireplumber
    papirus-icon-theme ttf-jetbrains-mono inter-font
    firefox yazi wireshark-qt)
  run sudo pacman -S --needed --noconfirm "${pkgs[@]}"

  # drop configs into ~/.config (idempotent: -a over existing)
  local cfg="$HOME/.config"
  run mkdir -p "$cfg"
  local d
  for d in foot gtk-3.0 gtk-4.0; do
    run cp -a "$HERE/desktop/$d" "$cfg/"
  done
  run cp "$HERE/desktop/mimeapps.list" "$cfg/mimeapps.list"

  # recon helpers on PATH (kismet launcher, monitor-mode toggle; stag-lib is sourced by stag-ctl/stag-status)
  local b
  for b in stag-kismet stag-mon stag-lib; do
    run sudo install -Dm755 "$HERE/desktop/bin/$b.sh" "/usr/local/bin/$b"
  done

  # wallpapers: home = STAG OS wordmark, lock = Ultron orb (regen: tools/make-walls.py)
  run sudo install -Dm644 -t /usr/share/stagos "$HERE/desktop/wall/stag-wall.png" "$HERE/desktop/wall/stag-wall-stag.png" "$HERE/desktop/wall/stag-lock.png"

  # zsh config
  run cp -a "$HERE/desktop/zsh/.zshrc" "$HOME/.zshrc"

  # forgiving lockout ceiling so lock-screen typos don't trap you (kscreenlocker authenticates through PAM)
  run sudo sed -i 's/^# *deny = 3/deny = 10/; s/^# *unlock_time = 600/unlock_time = 120/' /etc/security/faillock.conf

  # the Plasma session: its own idempotent module (also writes the tty1 autostart block via stag-session);
  # stagos-desktop honours DRY_RUN itself
  "$HERE/stagos-desktop" plasma
  ok "Plasma desktop installed (log out to tty and stag-session starts it on tty1)"
}
