#!/usr/bin/env bash
# Plasma: the StagOS desktop, a minimal KDE Plasma 6 Wayland session (not the whole plasma group, no display
# manager: tty1 autologin runs stag-session, which starts Plasma). HUD look (StagOS color scheme, Plasma theme,
# Breeze decoration), Mac layout (top bar + floating dock) from the org.stagos.desktop global theme, and the
# KWin, shortcut, touchpad, night light, idle and lid keys from desktop/plasma/base.kconf via stag-plasma-apply.
# STAGOS_DESKTOP_PLASMA=0 skips it. kde-gtk-config is left out on purpose: it rewrites the StagOS GTK settings
# (~/.config/gtk-3.0, gtk-4.0, written by 60-desktop) at every login.
stagos_dm_plasma() {
  if [[ "${STAGOS_DESKTOP_PLASMA:-1}" != "1" ]]; then
    dm_note "plasma: STAGOS_DESKTOP_PLASMA=0, Plasma not installed (tty1 stays a plain shell)"
    return 0
  fi
  dm_pkgs plasma-desktop plasma-workspace kwin kscreen plasma-nm plasma-pa bluedevil powerdevil \
    kdeplasma-addons ksystemstats libksysguard breeze xdg-desktop-portal-kde systemsettings kde-cli-tools \
    kirigami qqc2-desktop-style qt6-declarative plasma5support spectacle kpackage qt6-tools qt6-wayland plasma-integration \
    polkit-kde-agent knighttime papirus-icon-theme inter-font ttf-jetbrains-mono
  dm_bins stag-session stag-plasma-apply
  stagos_plasma_widgets
  if pacman -Q kde-gtk-config >/dev/null 2>&1; then
    warn "kde-gtk-config is installed: Plasma rewrites ~/.config/gtk-3.0 (the StagOS GTK look) at every login: sudo pacman -Rns kde-gtk-config"
  fi

  local src="$HERE/desktop/plasma" data="${XDG_DATA_HOME:-$HOME/.local/share}" f n
  # stag-plasma-apply's data, plus the pieces Plasma finds by name (color scheme, theme, global theme)
  for f in StagOS.colors base.kconf layout.js dock.js desktop.conf.default; do
    dm_install "$src/$f" "$data/stagos/plasma/$f" 644
  done
  dm_install "$src/StagOS.colors" "$data/color-schemes/StagOS.colors" 644
  dm_sync_dir "$src/desktoptheme/StagOS" "$data/plasma/desktoptheme/StagOS"
  dm_sync_dir "$src/look-and-feel/org.stagos.desktop" "$data/plasma/look-and-feel/org.stagos.desktop"
  # desktop.conf is created once from the defaults; after that the StagOS Settings app owns it
  [[ -f "$(dm_cfg)/stagos/desktop.conf" ]] || dm_install "$src/desktop.conf.default" "$(dm_cfg)/stagos/desktop.conf" 644
  dm_env_write
  # dock launchers that no package ships, and the wallpapers the layout and lock screen use
  for n in stag-kismet stag-mon; do
    dm_install "$HERE/desktop/share/$n.desktop" "$data/applications/$n.desktop" 644
    dm_install "$HERE/desktop/share/$n.svg" "$data/icons/hicolor/scalable/apps/$n.svg" 644
  done
  for f in stag-wall-stag.png stag-lock.png; do
    dm_install "$HERE/desktop/wall/$f" "/usr/share/stagos/$f" 644 sudo
  done
  # first Plasma login: layout, panel scale, dock launchers (stag-plasma-apply --session)
  dm_install "$src/autostart/stag-plasma-apply.desktop" "$(dm_cfg)/autostart/stag-plasma-apply.desktop" 644

  # tty1 starts stag-session (migrates any older autostart block)
  if stagos_zprofile_sync "$HOME/.zprofile" && ! dm_dry; then
    DM_CHANGED=$((DM_CHANGED + 1)); log "wrote $HOME/.zprofile"
  fi

  # StagOS look + desktop.conf -> Plasma config (kwriteconfig6; live when Plasma is running)
  local count; count="$(mktemp)"
  if dm_dry; then
    STAGOS_PLASMA_DATA="$src" "$HERE/desktop/bin/stag-plasma-apply.sh" --base --dry-run || true
  else
    STAG_PLASMA_APPLY_COUNT_FILE="$count" STAGOS_PLASMA_DATA="$data/stagos/plasma" \
      "$HERE/desktop/bin/stag-plasma-apply.sh" --base --quiet || warn "stag-plasma-apply failed"
    n="$(cat "$count" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] && DM_CHANGED=$((DM_CHANGED + n))
  fi
  rm -f "$count"
  stagos_dm_plasma_settings
  stagos_plasma_leftovers
  ok "plasma installed (tty1 next: $("$HERE/desktop/bin/stag-session.sh" --status | sed -n 's/^next=//p'))"
}

# StagOS widgets (org.stagos.menu, org.stagos.status) and the shell side they run (stag-ctl, stag-status,
# stag-lib; playerctl for now playing, wl-copy for "Ask Stagbot"). Plasmoids go to
# ~/.local/share/plasma/plasmoids via kpackagetool6, reinstalled only when their content changed.
stagos_plasma_widgets() {
  dm_pkgs playerctl wl-clipboard
  dm_bins stag-lib stag-ctl stag-status
  local src="$HERE/desktop/plasma/plasmoids" dst="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids" p id
  for p in "$src"/*/; do
    p="${p%/}"; id="${p##*/}"
    if dm_dry; then log "[dry] would install plasmoid $id (kpackagetool6)"; continue; fi
    if ! have kpackagetool6; then warn "kpackagetool6 missing: plasmoid $id not installed"; continue; fi
    if [[ -d "$dst/$id" ]]; then
      diff -rq "$p" "$dst/$id" >/dev/null 2>&1 && continue
      kpackagetool6 --type Plasma/Applet --upgrade "$p" >/dev/null || { warn "plasmoid $id: kpackagetool6 --upgrade failed"; continue; }
    else
      kpackagetool6 --type Plasma/Applet --install "$p" >/dev/null || { warn "plasmoid $id: kpackagetool6 --install failed"; continue; }
    fi
    DM_CHANGED=$((DM_CHANGED + 1)); log "plasmoid $id installed"
  done
}

# StagOS Settings (stag-settings), its launcher entries, the System Settings entry and the systemd --user
# path unit that re-runs stag-plasma-apply when desktop.conf changes. No root needed except /usr/local/bin.
stagos_dm_plasma_settings() {
  local src="$HERE/desktop/plasma/settings" data="${XDG_DATA_HOME:-$HOME/.local/share}" f units_before
  for f in main.qml Conf.qml ini.js PageFrame.qml TopBarPage.qml DockPage.qml LookPage.qml SessionPage.qml ReconPage.qml AboutPage.qml; do
    dm_install "$src/$f" "$data/stagos/settings/$f" 644
  done
  dm_install "$src/stag-settings.sh" /usr/local/bin/stag-settings 755 sudo
  dm_install "$src/stag-settings-apply.sh" /usr/local/bin/stag-settings-apply 755 sudo
  dm_install "$src/share/stag-settings.svg" "$data/icons/hicolor/scalable/apps/stag-settings.svg" 644
  # app launcher + KRunner
  dm_install "$src/share/stag-settings.desktop" "$data/applications/stag-settings.desktop" 644
  # Plasma System Settings lists external apps from <XDG data dir>/plasma/systemsettings/externalmodules/*.desktop
  # (systemsettings app/kcmmetadatahelpers.h: findExternalKCMModules), so this needs no system-wide file
  dm_install "$src/share/stag-settings-module.desktop" "$data/plasma/systemsettings/externalmodules/stag-settings.desktop" 644
  # desktop.conf -> stag-plasma-apply on every change
  units_before="$DM_CHANGED"
  for f in stagos-desktop-apply.path stagos-desktop-apply.service; do
    dm_install "$src/units/$f" "$(dm_cfg)/systemd/user/$f" 644
  done
  if dm_dry; then
    dm_note "plasma: systemctl --user enable --now stagos-desktop-apply.path (dry run)"
  elif systemctl --user show-environment >/dev/null 2>&1; then
    [[ "$DM_CHANGED" != "$units_before" ]] && systemctl --user daemon-reload
    systemctl --user enable --now stagos-desktop-apply.path >/dev/null 2>&1 || warn "could not enable stagos-desktop-apply.path"
  else
    dm_note "plasma: no systemd user manager running; after login run: systemctl --user enable --now stagos-desktop-apply.path"
  fi
}

# A box that ran the labwc-era StagOS still has its configs, coexistence files and packages: point at the cleanup.
stagos_plasma_leftovers() {
  local c; c="$(dm_cfg)"
  if [[ -d "$c/labwc" || -d "$c/waybar" || -e "${XDG_DATA_HOME:-$HOME/.local/share}/dbus-1/services/org.freedesktop.Notifications.service" ]] \
    || pacman -Q labwc >/dev/null 2>&1; then
    warn "labwc-era StagOS files or packages are still here: ./stagos-desktop cleanup-labwc (backs configs up, asks before pacman -Rns)"
  fi
}
