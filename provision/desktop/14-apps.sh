#!/usr/bin/env bash
# Daily apps. Official repos first; AUR via paru (onedrive); Flathub for Bambu Studio and
# LocalSend (both official Flathub apps; the AUR builds are heavy for this laptop).
stagos_dm_apps() {
  # STAGOS_APPS_EXCLUDE: space separated packages to skip (small disks, container tests)
  local pkgs=(chromium obsidian spotify-launcher blender freecad openscad \
    arm-none-eabi-gcc arm-none-eabi-newlib foot zsh \
    mission-center gnome-disk-utility papers imv xournalpp virt-manager \
    qemu-desktop libvirt dnsmasq libreoffice-fresh gnome-calculator \
    nodejs npm flatpak xdg-utils)
  local keep=() p
  for p in "${pkgs[@]}"; do [[ " ${STAGOS_APPS_EXCLUDE:-} " == *" $p "* ]] || keep+=("$p"); done
  dm_pkgs "${keep[@]}"
  dm_aur onedrive-abraunegg
  # shellcheck disable=SC2086  # the id list is space separated on purpose
  dm_flatpak $STAGOS_FLATPAK_APPS

  dm_enable_system libvirtd.socket
  dm_add_group libvirt

  # chromium on Wayland
  dm_install "$HERE/desktop/chromium/chromium-flags.conf" "$(dm_cfg)/chromium-flags.conf" 644
  # foot with the StagOS zsh config (foot.ini is in the labwc-era config set)
  dm_config foot
  dm_install "$HERE/desktop/zsh/.zshrc" "$HOME/.zshrc" 644

  # Claude: web app launcher + Claude Code CLI (npm, user prefix: no sudo, on PATH via ~/.local/bin)
  dm_install "$HERE/desktop/share/claude.desktop" "$HOME/.local/share/applications/claude.desktop" 644
  dm_install "$HERE/desktop/share/claude.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/claude.svg" 644
  if [[ ! -x "$HOME/.local/bin/claude" ]] || dm_dry; then
    run npm install -g --prefix "$HOME/.local" @anthropic-ai/claude-code
  fi
  dm_note "apps: run 'onedrive' once to authorise, then 'systemctl --user enable --now onedrive'"
  ok "apps installed"
}
