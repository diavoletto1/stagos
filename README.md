# StagOS

Arch Linux build for **stagpad** (ThinkPad X1 Carbon Gen2, 2014): a war-driving daily driver in the StagSystem lab.
Reproducible from a blank disk: one installer, one provisioner.

## Layout

```
install.sh            run from the Arch ISO (root): partition, LUKS2, pacstrap, chroot, GRUB, users
provision.sh          run on first boot (as jack): repos, toolkit, services, branding, dev env, verify
config/stagos.conf    host, user, disk, LUKS, kernel, capture card
install/ provision/   numbered steps, each one function (stagos_NN_name)
assets/               motd, os-release pacman hook (plymouth/grub themes go here)
tools/                flash-usb-macos.sh (guarded ISO flasher), update-and-provision.sh (LAN updater)
test/dryrun.sh        shellcheck + full dry run of both layers, incl. a mock capture card
```

## Install

1. Flash the Arch ISO (`tools/flash-usb-macos.sh` on macOS, or Etcher). BIOS: Secure Boot off, UEFI only. F12 to boot.
2. `iwctl station wlan0 connect "<SSID>"`
3. Get this repo onto the live env, then `./install.sh` (it lists disks and asks which one).
4. Reboot, log in, `nmcli --ask device wifi connect "<SSID>"`, then `/opt/stagos/provision.sh`.

## Test without hardware

```
./test/dryrun.sh
```
`DRY_RUN=1` prints every state-changing command instead of running it. `STAGOS_MOCK_WIFI=wlan1 STAGOS_CAPTURE_IFACE=wlan1` exercises the capture-card path.

## Capture card

The built-in Intel card stays with NetworkManager. When the add-on card is in, set `STAGOS_CAPTURE_IFACE` in
`config/stagos.conf` to its interface and rerun `provision.sh`. Only a named, second card is ever handed to capture duty.

## Toolkit

aircrack-ng, kismet, gpsd, wifite, hashcat, hcxtools, hcxdumptool, macchanger, plus iw, tcpdump, wireshark-cli, nmap.
All from official Arch repos; no AUR helper needed (`provision/10-aur.sh` builds paru from source if you want one).

## Desktop modules (`stagos-desktop`)

macOS-class daily-driver layer on top of `provision/60-desktop.sh` + `65-extras.sh`. Run as your user (uses sudo):

```
./stagos-desktop              # all modules, in order
./stagos-desktop keys bar     # just those
./stagos-desktop --list
DRY_RUN=1 ./stagos-desktop    # print state-changing commands only
```

Modules live in `provision/desktop/NN-name.sh`, are idempotent (files are rewritten only when content differs; a
second run reports `files changed this run: 0`) and individually runnable. Shared helpers: `lib/desktop.sh`.
Public tunables are in `config/stagos.conf` (scale, night-light lat/lon, keyring flag, flatpak ids).
**Private values** (stag host, restic remote) go in `config/local.conf`, which is untracked; copy `config/local.conf.example`.
On stagpad: `cd /opt/stagos && git pull && ./stagos-desktop`, then log out and back in.

| Module | What it does |
|---|---|
| `bluetooth` | bluez, bluez-utils, blueman tray; adapter powered at boot; TLP told never to autosuspend btusb |
| `bar` | waybar top bar (workspaces, taskbar, clock, notifications, STAG menu, wifi, bluetooth, volume, brightness, battery, tray, dock toggle, power) and a second waybar (`~/.config/waybar-dock`) as the bottom app dock, toggled with `Super+Shift+D`. nwg-dock is not used: it needs sway/hyprland IPC and exits under labwc |
| `launcher` | fuzzel on **Super+Space**. **Super+Shift+Space** = `stag-spotlight`: type `= 2*(3+4)` or a number for qalc (result copied), `/ name` or `f name` for plocate file search, anything else opens fuzzel pre-filtered. plocate index refreshed by its timer |
| `notify` | swaync Control Center (**Super+G**): DND, wifi / bluetooth / night-light toggles, mpris, history. SwayOSD for volume, brightness, caps lock. Falls back to mako if swaync is absent |
| `network` | NetworkManager + nm-applet + nm-connection-editor. Touches nothing about wifi modes: the capture-card `unmanaged-devices` drop-in from `30-services` is left alone and no MAC-randomisation drop-ins are added, so the monitor-mode tooling is unaffected |
| `audio` | pipewire, pipewire-pulse/alsa, wireplumber, pavucontrol, playerctl; volume, mic-mute, play/next/prev keys |
| `trackpad` | labwc `<libinput>`: tap to click, natural scroll, two-finger right click, disable-while-typing (palm rejection). libinput-gestures (AUR): 3-finger swipe left/right switches workspace (4 workspaces) by typing Ctrl+Alt+Left/Right with wtype. Adds you to `input` |
| `keys` | keyd: **Super acts as Cmd**. See map below |
| `capture` | Super+Shift+3 full, +4 region, +6 region then annotate (swappy), Print = region, **Super+Shift+5** toggles wf-recorder (region). Screenshots to `~/Pictures/Screenshots` and the clipboard, recordings to `~/Videos/Recordings` (`STAGOS_REC_CODEC=h264_vaapi` to use the Intel encoder) |
| `clipboard` | wl-clipboard + cliphist (text and images), **Super+Shift+V** picker, `stag-clip clear` |
| `nightlight` | wlsunset from `STAGOS_LAT/LON` (Tampa), 3500K at night; toggle in the Control Center |
| `power` | **TLP** kept (see note), lid close = suspend (docked with external display = ignore), swayidle locks at 5 min and before sleep, screen off at 6, low-battery notifications at 20% and 10%, fwupd + refresh timer, faillock lock screen unchanged |
| `snapshots` | Detects the root filesystem. **btrfs**: snapper + snap-pac (snapshot around every pacman transaction) + grub-btrfs (GRUB). **Anything else** (the default ext4): restic to `STAGOS_RESTIC_REPO` from `config/local.conf` via the `stagos-restic.timer` user timer; without a repo it installs restic and warns |
| `apps` | chromium (Wayland flags), obsidian, spotify-launcher, blender, freecad, openscad, arm-none-eabi gcc/newlib, foot + StagOS zsh, Mission Center, gnome-disks, Papers, imv, xournalpp, virt-manager (+libvirt), onedrive (AUR), libreoffice-fresh, gnome-calculator, Claude web app launcher, Claude Code CLI (npm, `~/.local`), Flatpak + Flathub with Bambu Studio and LocalSend. `STAGOS_APPS_EXCLUDE="blender freecad"` skips packages on a small disk |
| `keyring` | gnome-keyring + seahorse. With `STAGOS_KEYRING_EMPTY=1` creates a login keyring with an empty password so it opens under autologin; **off by default**, see the note |
| `stag` | `chromium --app` launcher per service in `STAGOS_STAG_PATHS` at `<scheme>://<host>/<name>/` (from `config/local.conf`), icon tiles, listed in the bar's STAG menu. URLs are written only under `~/.local` and `~/.config` |
| `hidpi` | output scale `STAGOS_OUTPUT_SCALE` (default 1.5), Inter + JetBrains Mono, fontconfig light hinting with grayscale AA, `desktop.env` for the runtime tunables |
| `plasma` | a minimal KDE Plasma 6 Wayland session next to labwc (see [Plasma](#plasma)): StagOS HUD look, top bar + floating dock, `stag-session` on tty1. `STAGOS_DESKTOP_PLASMA=0` skips it |

**Why TLP, not power-profiles-daemon:** the repo already enables TLP; the two conflict; TLP's runtime PM and USB/PCIe/SATA
tuning matter more on a 2014 ThinkPad battery than PPD's three profiles.

### Mac-like keys (module `keys`)

Super stays Super for the compositor. While it is held keyd translates only these keys, so `Super+Return`, `Super+Space`,
`Super+Shift+3/4`, `Super+L`, arrows etc. still reach labwc:

| Press | Sends | In foot (terminal) |
|---|---|---|
| Super+C / V | Ctrl+C / V | Ctrl+Shift+C / V (never SIGINT) |
| Super+X, Z, A, T, F, S | Ctrl+X, Z, A, T, F, S | nothing (no suspend, XOFF, readline surprises) |
| Super+Q, W | Ctrl+Q, W | Alt+F4 (close window) |
| Super+Shift+Z | Ctrl+Shift+Z (redo) | nothing |
| Super+Shift+V | clipboard history picker (not "paste plain") | same |

Real Ctrl+key is never remapped. The per-app rows come from `~/.config/keyd/app.conf` via `keyd-application-mapper` (wlroots
foreign-toplevel backend, started from labwc autostart). labwc-side changes: close is Alt+F4, fullscreen Super+F11, maximize
Super+Up, dock toggle Super+Shift+D, Super+Tab switches windows.

### Keyring decision

Autologin follows the LUKS unlock, so PAM never sees your password and a normal keyring can never auto-unlock (apps ask every session).
`STAGOS_KEYRING_EMPTY=1` gives an empty-password `login` keyring: silent, protected at rest by LUKS only, readable by anything running as you.
Set it in `config/stagos.conf` (or the environment) and run `./stagos-desktop keyring`. An existing keyring is never overwritten.

### Plasma

A second desktop, installed next to labwc (labwc keeps working unchanged): KDE Plasma 6 on Wayland with a
Mac-style layout and the StagOS HUD look. Minimal package set (not the whole `plasma` group, no display
manager, no SDDM): the LUKS passphrase stays the only login, tty1 autologin then starts the session.

- **Look**: `StagOS` color scheme (bg `#0a0a0a`, surface `#111111`, hairline `#2a2a2a`, accent `#c8102e`), a `StagOS`
  Plasma theme (flat panels and popups, 1 px hairline, 3 px corners), Breeze window decoration in those colors with
  a thin title bar and minimize/maximize/close on the right, Inter 10 and JetBrains Mono 10, Papirus-Dark icons.
- **Layout** (`org.stagos.desktop` global theme): 26 px top bar with the STAG menu, the global app menu, a tray for
  third-party icons and the StagOS readouts; a floating dock at the bottom center that hides only when a window
  overlaps it, launchers from `[dock] launchers` in `~/.config/stagos/desktop.conf` (`|` = separator, missing apps
  skipped); no desktop icons.
- **Top bar** (plasmoids `org.stagos.menu`, `org.stagos.status`): **STAG** opens the menu (About This Computer, StagOS
  Settings, System Settings, the stag apps, switch to labwc, lock/sleep/restart/shut down/log out, destructive ones
  ask first). The readouts (TS / GPS / MON, CPU / RAM / temp, BOT, wifi, bt, volume, battery, clock) come from
  `stag-status --json` every 3 s; it reads `[bar]` on every call, so toggles apply live. Click them for the
  **Control Center**: wifi / bluetooth / Do Not Disturb / Night Light (on = warm now until turned off), volume and
  brightness, now playing, recon (Kismet start/stop, monitor mode), Stagbot (service dots, "Ask Stagbot": the
  question goes to the clipboard and the chat opens). Every action is a `stag-ctl` subcommand (`stag-ctl --help`,
  JSON out) that also works from a shell. Plasma's own network/volume/battery/bluetooth/media tray applets are not
  loaded; notifications and clipboard stay loaded but hidden, so notification popups and DND work as usual.
- **StagOS Settings** (`stag-settings`, in the STAG menu, KRunner and System Settings > StagOS): top bar switches,
  dock launchers, blur and animation speed, default session, layout reset, capture interface. It edits
  `desktop.conf` in place; the `stagos-desktop-apply.path` user unit then runs `stag-plasma-apply`. Details:
  `desktop/plasma/settings/README.md`.
- **KWin**: blur for panels/popups, no wobbly/magic lamp/translucency, animations at 0.7, drag to an edge tiles,
  Overview on **Meta+Tab** / **Ctrl+Up** / the 4-finger swipe, 4 desktops, click to focus, and every dock app
  remembers its window position and size (one KWin rule per app).
- **Keys**: **Meta+Space** KRunner (Spotlight), **Meta+L** lock, **Print** region shot, Super+Shift+3/4/5 like labwc,
  Super+Return foot, Super+E files, Super+Up/Down maximize/minimize, Ctrl+Alt+Left/Right desktops.
- **Touchpad and power**: tap to click, natural scroll, clickfinger (every touchpad until you change one in System
  Settings); lid closes to sleep, screen dims, no automatic sleep on AC, locks at 5 min and on resume.

Everything Plasma-side is written by `stag-plasma-apply` with `kwriteconfig6`, one key at a time, so settings you
change in System Settings stay unless `./stagos-desktop plasma` sets the same key again.

**Switch sessions** (takes effect at the next tty1 login; log out to switch now):

```
stag-session plasma      # default: Plasma
stag-session labwc       # default: labwc
stag-session --status    # default=, next= (what tty1 will start and why), fails=
```

**Fallback**: without Plasma installed tty1 starts labwc. If Plasma exits with an error within 30 s twice in a
row, stag-session starts labwc instead and logs it to `~/.cache/stagos/session.log`; it keeps starting labwc until
you run `stag-session plasma` or save any change in StagOS Settings. Escape hatch as before: log in on tty2 for a
plain shell.

**Reset the layout** (top bar + dock back to the StagOS layout): `stag-plasma-apply --reset-layout`. With Plasma
running it rebuilds now; from a tty the old layout is moved aside (`plasma-org.kde.plasma.desktop-appletsrc.stagos-bak-*`)
and the next Plasma start builds a fresh one. A normal `stag-plasma-apply` never touches your layout, it only
syncs the dock launchers; the first Plasma login applies the layout once (`~/.local/state/stagos/plasma-layout-applied`).

**Coexistence**: `QT_QPA_PLATFORMTHEME=qt6ct` and `GTK_THEME` exist only in labwc's environment and stag-session
strips them from Plasma. nm-applet, blueman and the other labwc helpers get `NotShowIn=KDE` autostart overrides and
their systemd user units a `ConditionEnvironment=!XDG_CURRENT_DESKTOP=KDE` drop-in, so Plasma has one tray icon per
thing. `org.freedesktop.Notifications` has one owner per session (`stag-session notify-daemon`: Plasma's own under
KDE, swaync or mako under labwc). `kde-gtk-config` is not installed on purpose: it rewrites `~/.config/gtk-3.0` and
`gtk-4.0` at every Plasma login, which would change the labwc GTK look; GTK apps use the same StagOS settings in both
sessions. gnome-keyring stays the secret store (KWallet disabled), baloo indexing is off (plocate covers search).
The panel scale (`STAGOS_OUTPUT_SCALE`, 1.5 on the internal eDP panel) is set once at the first Plasma login with
kscreen-doctor; change it later in System Settings > Display.

**Internals** (for changing the Plasma side):
- `stagos-desktop plasma` installs the data to `~/.local/share/stagos/plasma/` (`StagOS.colors base.kconf layout.js
  dock.js desktop.conf.default`; new files go in the module's `for f in ...` list), the color scheme, the `StagOS`
  Plasma theme and the `org.stagos.desktop` global theme under `~/.local/share`, and copies `desktop.conf.default`
  to `~/.config/stagos/desktop.conf` once (never overwritten).
- `stag-plasma-apply` writes the global theme's layout script
  (`~/.local/share/plasma/look-and-feel/org.stagos.desktop/contents/layouts/org.kde.plasma.desktop-layout.js`) as a
  generated header (`STAGOS_DOCK`, `STAGOS_APPMENU`, `STAGOS_WALLPAPER`) + `dock.js` + `layout.js`. It runs on the
  very first plasmashell start and on `--reset-layout` (`loadLookAndFeelDefaultLayout`). Panels are tagged
  `[General] stagosRole=bar|dock`; later runs only call `stagosSyncDock` / `stagosSyncAppmenu` through
  `evaluateScript`. `--base` (only `stagos-desktop` passes it) also rewrites the `base.kconf` keys; the settings path
  unit runs it without `--base`, so System Settings tweaks survive. Runs are serialized with a lock in
  `$XDG_RUNTIME_DIR`; `--session` is the Plasma autostart (first-login layout, eDP scale, dock sync).
- Window positions: a KWin rule remembers one geometry, so each dock app gets its own `stagos-<id>` rule (normal
  windows only); apps outside the dock get no memory.
- Global shortcut changes (`kglobalshortcutsrc`) take effect at the next Plasma login.
- Test overrides: `STAGOS_PLASMA_DATA STAGOS_DESKTOP_CONF STAGOS_QDBUS STAGOS_PLASMA_WAIT STAG_PLASMA_APPLY_COUNT_FILE`
  (apply), `STAGOS_STARTPLASMA STAGOS_PLASMA_DBUS_WRAPPER STAGOS_LABWC STAGOS_SESSION_FAST_SECS STAGOS_PLASMA_WAITFORNAME`
  (session), `STAGOS_SYS STAGOS_PROC STAGOS_CACHE STAGOS_QDBUS` (stag-ctl, stag-status).
- Visual smoke in rootless podman: `kwin_wayland --virtual` + spectacle hangs there, so the smoke drops the file
  capability (`setcap -r /usr/bin/kwin_wayland`), runs `Xvfb`, `kwin_wayland --x11-display` and plasmashell inside
  `dbus-run-session`, and grabs the X root with `xwd` (`test/stag-widgets-smoke.sh`).

### Testing

```
./test/desktop-scripts.sh                    # helper scripts + config invariants, no root, fakes from test/fixtures/bin
./test/desktop-container.sh all              # rootless podman Arch: shellcheck, dry run, real run, 2nd run must change 0 files, per-module reruns, config validation, headless labwc/waybar/swaync, btrfs branch
./test/desktop-container.sh plasma           # module plasma only: dry run, run 1, run 2 = 0 changes, Plasma config + session checks
./test/desktop-container.sh clean            # remove the image and package cache
```

### Needs an on-device check (a container cannot do these)

1. `Super+C`/`V` in chromium and in foot; `Super+Shift+V` opens the clipboard picker (composite keyd layer `[cmd+shift]`); `keyd monitor` if not.
2. `Super+Shift+3/4/5/6` (labwc key names with Shift+digit), files appear in `~/Pictures/Screenshots`.
3. Trackpad: tap, natural scroll, palm rejection while typing, 3-finger swipe switches workspace (after re-login for the `input` group).
4. Waybar layout at 1.5x fits the 2560x1440 panel without overflow; `ext/workspaces` shows the 4 desktops; taskbar clicks.
5. The waybar dock draws at the bottom center with all tiles; `Super+Shift+D` toggles it.
6. swaync opens on Super+G, toggles reflect real state; SwayOSD appears for volume/brightness; caps-lock OSD needs `swayosd-libinput-backend.service`.
7. Bluetooth pairing via blueman; audio keys; `tlp-stat -s`; lid close suspends and the lock screen is up on resume; low-battery notice.
8. Lid, `fwupdmgr get-updates`, `wlsunset` schedule, `wf-recorder` (try `STAGOS_REC_CODEC=h264_vaapi`).
9. `systemctl --user status stagos-restic.timer`, one manual `systemctl --user start stagos-restic.service`; on btrfs: `snapper list` after a pacman run.
10. gnome-keyring: a chromium password save survives a reboot (with the flag on); `onedrive` authorisation; Flatpak installs of Bambu Studio and LocalSend; VS Code and libinput-gestures AUR builds (slow on this CPU).
11. Plasma: `stag-session plasma`, log out; top bar + dock appear, Meta+Space opens KRunner, the 4-finger swipe opens
    Overview, lid close suspends, the internal panel is at 1.5; a window reopens where it was closed; `stag-session labwc`
    brings labwc back unchanged (bar, dock, notifications, GTK look).
