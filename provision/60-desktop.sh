#!/usr/bin/env bash
# StagOS desktop: labwc (Wayland), HUD-themed. Real title bars, app bar, power menu.
# Installs the stack, drops configs, autostarts labwc on tty1. Skipped when STAGOS_DESKTOP=0.
stagos_60_desktop() {
  if [[ "${STAGOS_DESKTOP:-1}" != "1" ]]; then
    warn "STAGOS_DESKTOP=0, skipping desktop layer"
    return 0
  fi
  local pkgs=(labwc swaybg swayidle swaylock waybar foot fuzzel mako
    wlr-randr grim slurp wl-clipboard libnotify brightnessctl playerctl polkit
    xdg-desktop-portal-wlr network-manager-applet pavucontrol
    pipewire pipewire-pulse wireplumber
    papirus-icon-theme ttf-jetbrains-mono inter-font
    firefox yazi wireshark-qt)
  run sudo pacman -S --needed --noconfirm "${pkgs[@]}"

  # drop configs into ~/.config (idempotent: -a over existing)
  local cfg="$HOME/.config"
  run mkdir -p "$cfg"
  local d
  for d in labwc waybar waybar-dock foot fuzzel mako swaylock gtk-3.0 gtk-4.0 qt6ct; do
    run cp -a "$HERE/desktop/$d" "$cfg/"
  done
  run chmod +x "$cfg"/waybar/scripts/*.sh
  run cp "$HERE/desktop/mimeapps.list" "$cfg/mimeapps.list"
  # StagOS labwc theme (SVG titlebar buttons)
  run mkdir -p "$HOME/.local/share/themes"
  run cp -a "$HERE/desktop/theme/StagOS" "$HOME/.local/share/themes/"

  # stag-* helpers on PATH (power menu, dock toggle, kismet launcher, monitor toggle)
  local b
  for b in "$HERE"/desktop/bin/stag-*.sh; do
    run sudo install -Dm755 "$b" "/usr/local/bin/$(basename "$b" .sh)"
  done

  # wallpapers: home = STAG OS wordmark, lock = Ultron orb (regen: tools/make-walls.py)
  run sudo install -Dm644 -t /usr/share/stagos "$HERE/desktop/wall/stag-wall.png" "$HERE/desktop/wall/stag-wall-stag.png" "$HERE/desktop/wall/stag-lock.png"

  # zsh config
  run cp -a "$HERE/desktop/zsh/.zshrc" "$HOME/.zshrc"

  # swaylock auth (keeps faillock) + forgiving lockout ceiling so typos don't trap you
  run sudo install -Dm644 "$HERE/desktop/pam/swaylock" /etc/pam.d/swaylock
  run sudo sed -i 's/^# *deny = 3/deny = 10/; s/^# *unlock_time = 600/unlock_time = 120/' /etc/security/faillock.conf

  # autostart labwc on tty1 only (migrate any older 'exec sway' block)
  local zp="$HOME/.zprofile"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    run "ensure labwc autostart block in $zp"
  else
    sed -i '/# StagOS: autostart/,/^fi$/d' "$zp" 2>/dev/null || true
    cat >> "$zp" <<'EOF'

# StagOS: autostart labwc on tty1
if [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then
  exec labwc
fi
EOF
  fi
  ok "labwc desktop installed (log out to tty and it starts on tty1)"
}
