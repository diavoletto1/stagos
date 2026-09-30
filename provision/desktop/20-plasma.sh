#!/usr/bin/env bash
# Plasma: a minimal KDE Plasma 6 Wayland session next to labwc (not the whole plasma group, no display
# manager: tty1 autologin runs stag-session, which starts Plasma or labwc). HUD look (StagOS color scheme,
# Plasma theme, Breeze decoration), Mac layout (top bar + floating dock) from the org.stagos.desktop
# global theme, KWin/shortcut/touchpad/power keys from desktop/plasma/base.kconf via stag-plasma-apply.
# STAGOS_DESKTOP_PLASMA=0 skips it. kde-gtk-config is left out on purpose: Plasma must not rewrite the
# labwc GTK settings (~/.config/gtk-3.0, gtk-4.0); GTK apps look the same in both sessions.
stagos_dm_plasma() {
  if [[ "${STAGOS_DESKTOP_PLASMA:-1}" != "1" ]]; then
    dm_note "plasma: STAGOS_DESKTOP_PLASMA=0, Plasma not installed (tty1 keeps starting labwc)"
    return 0
  fi
  dm_pkgs plasma-desktop plasma-workspace kwin kscreen plasma-nm plasma-pa bluedevil powerdevil \
    kdeplasma-addons ksystemstats libksysguard breeze xdg-desktop-portal-kde systemsettings kde-cli-tools \
    kirigami qqc2-desktop-style qt6-declarative plasma5support spectacle kpackage qt6-tools qt6-wayland plasma-integration \
    polkit-kde-agent knighttime papirus-icon-theme inter-font ttf-jetbrains-mono
  dm_bins stag-session stag-plasma-apply
  if pacman -Q kde-gtk-config >/dev/null 2>&1; then
    warn "kde-gtk-config is installed: Plasma rewrites ~/.config/gtk-3.0 (the labwc GTK look) at every login: sudo pacman -Rns kde-gtk-config"
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

  # ---- coexistence: labwc-era helpers stay out of Plasma, Plasma stays out of labwc ----
  # tray applets and daemons Plasma replaces (nm-applet already ships NotShowIn=KDE)
  dm_autostart_not_in KDE blueman nm-applet libinput-gestures waybar swayidle swaybg mako swaync \
    swayosd udiskie wlsunset cliphist
  # the same for systemd user units (graphical-session.target is shared by both sessions)
  for n in mako swaync waybar libinput-gestures swayosd; do
    dm_write "$(dm_cfg)/systemd/user/$n.service.d/50-stagos-not-plasma.conf" 644 <<'UNIT'
# StagOS: labwc-only helper; Plasma has its own (installed by stagos-desktop plasma)
[Unit]
ConditionEnvironment=!XDG_CURRENT_DESKTOP=KDE
UNIT
  done
  # one owner for org.freedesktop.Notifications: Plasma under KDE, swaync (or mako) under labwc.
  # Without this three service files claim the name and D-Bus may activate mako inside Plasma.
  dm_write "$data/dbus-1/services/org.freedesktop.Notifications.service" 644 <<'DBUS'
# StagOS: stag-session notify-daemon picks plasma_waitforname (KDE) or swaync/mako (labwc)
[D-BUS Service]
Name=org.freedesktop.Notifications
Exec=/usr/local/bin/stag-session notify-daemon
DBUS

  # tty1 starts stag-session (migrates the older 'exec labwc' / 'exec sway' block)
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
  dm_note "plasma: log out, then 'stag-session plasma' (or labwc) picks the tty1 session; see README, Plasma"
  ok "plasma installed (default session: $(STAGOS_PLASMA_DATA="$data/stagos/plasma" "$HERE/desktop/bin/stag-session.sh" --status | sed -n 's/^next=//p'))"
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
