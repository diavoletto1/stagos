#!/usr/bin/env bash
# StagOS desktop: Sway (Wayland), HUD-themed. Installs the stack, drops configs,
# and autostarts sway on tty1 login. Skipped when STAGOS_DESKTOP=0.
stagos_60_desktop() {
  if [[ "${STAGOS_DESKTOP:-1}" != "1" ]]; then
    warn "STAGOS_DESKTOP=0, skipping desktop layer"
    return 0
  fi
  local pkgs=(sway swaybg swayidle swaylock waybar foot fuzzel mako
    grim slurp wl-clipboard brightnessctl playerctl polkit
    xdg-desktop-portal-wlr network-manager-applet pavucontrol
    pipewire pipewire-pulse wireplumber
    ttf-jetbrains-mono inter-font)
  run sudo pacman -S --needed --noconfirm "${pkgs[@]}"

  # drop configs into ~/.config (idempotent: -a over existing)
  local cfg="$HOME/.config"
  run mkdir -p "$cfg"
  local d
  for d in sway waybar foot fuzzel mako swaylock; do
    run cp -a "$HERE/desktop/$d" "$cfg/"
  done
  run chmod +x "$cfg"/waybar/scripts/*.sh

  # swaylock auth (keeps faillock) + forgiving lockout ceiling so typos don't trap you
  run sudo install -Dm644 "$HERE/desktop/pam/swaylock" /etc/pam.d/swaylock
  run sudo sed -i 's/^# *deny = 3/deny = 10/; s/^# *unlock_time = 600/unlock_time = 120/' /etc/security/faillock.conf

  # start sway automatically on the first virtual terminal, nowhere else
  local zp="$HOME/.zprofile"
  if ! grep -q 'StagOS: autostart sway' "$zp" 2>/dev/null; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      run "append sway autostart block to $zp"
    else
      cat >> "$zp" <<'EOF'

# StagOS: autostart sway on tty1
if [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then
  exec sway
fi
EOF
    fi
  fi
  ok "sway desktop installed (log out to tty and it starts on tty1)"
}
