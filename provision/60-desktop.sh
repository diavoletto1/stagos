#!/usr/bin/env bash
# StagOS desktop: labwc (Wayland), HUD-themed. Real title bars, app bar, power menu.
# Installs the stack, drops configs, autostarts labwc on tty1. Skipped when STAGOS_DESKTOP=0.
stagos_60_desktop() {
  if [[ "${STAGOS_DESKTOP:-1}" != "1" ]]; then
    warn "STAGOS_DESKTOP=0, skipping desktop layer"
    return 0
  fi
  local pkgs=(labwc swaybg swayidle swaylock waybar foot fuzzel mako
    wlr-randr grim slurp wl-clipboard brightnessctl playerctl polkit
    xdg-desktop-portal-wlr network-manager-applet pavucontrol
    pipewire pipewire-pulse wireplumber
    papirus-icon-theme ttf-jetbrains-mono inter-font)
  run sudo pacman -S --needed --noconfirm "${pkgs[@]}"

  # drop configs into ~/.config (idempotent: -a over existing)
  local cfg="$HOME/.config"
  run mkdir -p "$cfg"
  local d
  for d in labwc waybar foot fuzzel mako swaylock; do
    run cp -a "$HERE/desktop/$d" "$cfg/"
  done
  run chmod +x "$cfg"/waybar/scripts/*.sh

  # power menu on PATH for the labwc session (keybind + bar button)
  run sudo install -Dm755 "$HERE/desktop/bin/stag-power.sh" /usr/local/bin/stag-power

  # wallpapers: home = STAG OS wordmark, lock = Ultron orb (regen: tools/make-walls.py)
  run sudo install -Dm644 -t /usr/share/stagos "$HERE/desktop/wall/stag-wall.png" "$HERE/desktop/wall/stag-lock.png"

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
