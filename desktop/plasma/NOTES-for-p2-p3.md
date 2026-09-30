# Plasma base: notes for p2 (widgets) and p3 (settings + tests)

Written by p1. p4 deletes this file at the end.

## What p1 ships

- `provision/desktop/20-plasma.sh` (module `plasma`, gated by `STAGOS_DESKTOP_PLASMA`, default 1).
- Packages (verified in the Arch repos, Plasma 6.7.5 / KF 6.30):
  `plasma-desktop plasma-workspace kwin kscreen plasma-nm plasma-pa bluedevil powerdevil kdeplasma-addons
  ksystemstats libksysguard breeze xdg-desktop-portal-kde systemsettings kde-cli-tools kirigami qt6-declarative
  plasma5support spectacle kpackage qt6-tools qt6-wayland plasma-integration polkit-kde-agent knighttime`
  (+ papirus-icon-theme inter-font ttf-jetbrains-mono). About 510 packages, 685 MiB download.
  Left out on purpose: `kde-gtk-config` and `breeze-gtk` (kde-gtk-config rewrites ~/.config/gtk-3.0 and gtk-4.0 at
  every Plasma login, even with its kded module disabled; checked in the container), `sddm`, `plasma-login-manager`,
  `power-profiles-daemon` (TLP stays; powerdevil only optdepends on it).
- Data is installed to `~/.local/share/stagos/plasma/` (`StagOS.colors base.kconf layout.js dock.js
  desktop.conf.default`). The module lists these files explicitly: add new ones to the `for f in ...` loop.
- `~/.local/share/color-schemes/StagOS.colors`, `~/.local/share/plasma/desktoptheme/StagOS/`,
  `~/.local/share/plasma/look-and-feel/org.stagos.desktop/` (global theme; `LookAndFeelPackage` points at it).

## Layout (p2)

- `desktop/plasma/layout.js` is Plasma desktop scripting. It never runs alone: `stag-plasma-apply` writes
  `~/.local/share/plasma/look-and-feel/org.stagos.desktop/contents/layouts/org.kde.plasma.desktop-layout.js` =
  a generated header (`var STAGOS_DOCK = [...]; var STAGOS_WALLPAPER = "...";`) + `dock.js` + `layout.js`.
- It runs (a) on the very first plasmashell start (the global theme's default layout) and (b) on
  `stag-plasma-apply --reset-layout` or a pending first-login apply, via
  `qdbus6 org.kde.plasmashell /PlasmaShell loadLookAndFeelDefaultLayout org.stagos.desktop`, which wipes the
  layout first. So layout.js always starts from an empty shell; `panels().forEach(remove)` is only a safety net.
- Widget slots: replace everything from `// STAGOS_WIDGET <name>` through `// END_STAGOS_WIDGET <name>` (both
  lines are exact, one per slot: `menu`, `status`, `control`). Stand-ins today: `menu` = kickoff, `status` =
  systemtray + digitalclock, `control` = nothing. The top panel variable is `bar`. `appmenu` and the spacer sit
  between `menu` and `status`, outside the slots.
- If `status` drops the stock `org.kde.plasma.systemtray`, apps with tray icons (Spotify, Obsidian, nm/bt
  indicators from Plasma) lose them; consider keeping a systemtray next to org.stagos.status.
- The bar is 26 px (logical), `opacity = "opaque"`, drawn by the StagOS Plasma theme (#0a0a0a, hairline bottom).
  Popups use `dialogs/background.svg` of the same theme (#111111, hairline, 3 px corners).
- Panels are tagged in their containment config: `[General] stagosRole=bar|dock`. `dock.js` has
  `stagosFindPanel(role)`, `stagosBuildDock(panel, groups)`, `stagosSyncDock(groups)`, `stagosHasLayout()`.
- The dock is `icontasks` (first launcher group + running windows) then `marginsseparator` + `quicklaunch` for
  each later `|` group. `stagosSyncDock` rebuilds it only when the launcher list changed (signature in
  `[General] stagosDock`).
- Desktops are Folder View (scripts cannot switch the containment type in 6.7); icons are hidden with
  `filterMode=2`, `filterPattern=*`.
- Verified live in the container (kwin_wayland + plasmashell): first start used the global theme layout, a
  normal apply reports `dock: unchanged`, `--reset-layout` reloads. Screenshots: `~/repos/_briefs/shots/plasma-p1-*.png`.

## Interfaces (p2, p3)

- `stag-session start | plasma | labwc | --status | notify-daemon`. `--status` prints three lines:
  `default=plasma|labwc`, `next=<what start runs> (<reason>)`, `fails=<n>`. `stag-session plasma|labwc` edits
  `[session] default` in desktop.conf in place (comments and other sections kept) and clears the crash fallback.
- `stag-plasma-apply [--base] [--reset-layout] [--session] [--dry-run] [--quiet]`. Reads `[effects] blur`,
  `[effects] animation_factor`, `[dock] launchers`. It does not read `[bar]` (p2's stag-status does) or `[session]`
  (stag-session does). `--base` also writes `base.kconf` + the color scheme: only stagos-desktop should pass it,
  otherwise every settings change would revert Jack's own System Settings tweaks to those keys.
- The p3 path unit should run `stag-plasma-apply --quiet` (no `--base`). It is safe without Plasma running and
  exits 0 when Plasma is not installed. Concurrent runs are serialized with flock on
  `$XDG_RUNTIME_DIR/stag-plasma-apply.lock`.
- Env overrides for tests: `STAGOS_PLASMA_DATA`, `STAGOS_DESKTOP_CONF`, `STAGOS_QDBUS`, `STAGOS_PLASMA_WAIT`,
  `STAG_PLASMA_APPLY_COUNT_FILE` (apply); `STAGOS_STARTPLASMA`, `STAGOS_PLASMA_DBUS_WRAPPER`, `STAGOS_LABWC`,
  `STAGOS_SESSION_FAST_SECS`, `STAGOS_PLASMA_WAITFORNAME` (session).
- `desktop.conf.default` (p3 owns it now): installed to `~/.local/share/stagos/plasma/` and copied once to
  `~/.config/stagos/desktop.conf` if that file does not exist; never overwritten afterwards.
- Autostart `~/.config/autostart/stag-plasma-apply.desktop` (OnlyShowIn=KDE) runs `--session --quiet` at each
  Plasma login: waits for plasmashell, applies the layout once (marker `~/.local/state/stagos/plasma-layout-applied`),
  sets the eDP scale once (`plasma-scale-applied`), syncs the dock.

## Tests (p3)

- Unit: `test/desktop-scripts.sh` has stag-session and stag-plasma-apply sections. Fixtures:
  `test/fixtures/bin/fake-session` (fake startplasma/labwc/swaync/plasma_waitforname that logs leaked env),
  `test/fixtures/bin/plasma-dbus-run-session-if-needed`, `test/fixtures/plasma-desktop.conf`.
  Note: `test/fixtures/bin/fake-cmd` reads stdin, so never call it inside a `while read` loop without `</dev/null`.
- Container: `./test/desktop-container.sh plasma` (79 checks); `plasma_checks` in `test/desktop-container-user.sh`
  also runs in the `all` phase.
- Visual smoke that works in rootless podman: `setcap -r /usr/bin/kwin_wayland` (as root in the throwaway
  container; the file capability makes exec fail with EPERM), `Xvfb :5 -screen 0 1706x960x24`, then
  `kwin_wayland --x11-display :5 --width 1706 --height 960 --socket wayland-9 --no-lockscreen`, plasmashell with
  `WAYLAND_DISPLAY=wayland-9 QT_QPA_PLATFORM=wayland`, and `xwd -root -silent | magick xwd:- out.png`
  (packages xorg-server-xvfb xorg-xwd imagemagick). Set XDG_RUNTIME_DIR before `dbus-run-session`.
  Does not work: `kwin_wayland --virtual` + spectacle (hangs) or the KWin ScreenShot2 D-Bus API (cancelled).

## Known caveats

- keyd maps Super+W to Ctrl+W system wide, so Meta+W never reaches KWin while keyd runs; Ctrl+Up and the
  4-finger swipe open Overview.
- KWin "Remember" stores one geometry per rule, hence one rule per dock app (`stagos-<id>`), matched on the app id /
  StartupWMClass, normal windows only. Apps not in the dock get no memory.
- kglobalshortcutsrc changes take effect at the next Plasma login (kglobalacceld caches them).
