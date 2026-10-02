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

The StagOS desktop is KDE Plasma 6 on Wayland, the only session (see [Plasma](#plasma)). `provision/60-desktop.sh`
installs the shared base and runs the `plasma` module; `65-extras.sh` adds the everyday apps. The modules are the
daily-driver layer on top. Run as your user (uses sudo):

```
./stagos-desktop              # all modules, in order
./stagos-desktop keys plasma  # just those
./stagos-desktop --list
DRY_RUN=1 ./stagos-desktop    # print state-changing commands only
```

Modules live in `provision/desktop/NN-name.sh`, are idempotent (files are rewritten only when content differs; a
second run reports `files changed this run: 0`) and individually runnable. Shared helpers: `lib/desktop.sh`.
Public tunables are in `config/stagos.conf` (scale, keyring flag, flatpak ids).
**Private values** (stag host, restic remote) go in `config/local.conf`, which is untracked; copy `config/local.conf.example`.
On stagpad: `cd /opt/stagos && git pull && ./stagos-desktop`, then log out and back in.

| Module | What it does |
|---|---|
| `bluetooth` | bluez, bluez-utils; adapter powered at boot; TLP told never to autosuspend btusb. Pairing UI: Plasma's bluedevil |
| `network` | NetworkManager (UI: Plasma's plasma-nm). Touches nothing about wifi modes: the capture-card `unmanaged-devices` drop-in from `30-services` is left alone and no MAC-randomisation drop-ins are added, so the monitor-mode tooling is unaffected |
| `audio` | pipewire, pipewire-pulse/alsa, wireplumber, pavucontrol, playerctl; volume, mic-mute and media keys are Plasma's |
| `keys` | keyd: **Super acts as Cmd**. See map below |
| `power` | **TLP** kept (see note), lid close = suspend (docked with external display = ignore), fwupd + refresh timer. **Battery care**: charge thresholds start 75 / stop 80 (`STAGOS_BAT_START`/`STAGOS_BAT_STOP` in `config/stagos.conf`, `STAGOS_BAT_FULL=1` = always 100%) in `/etc/tlp.d/51-stagos-battery.conf`; `stag-battery full` charges to 100% for a trip (until the next unplug), `stag-battery hold` goes back to 80. **Optimized charging** (macOS style, `STAGOS_BAT_OPTIMIZED=1` default, `0` = plain thresholds): `stag-charge` (root, `stagos-charge.timer` every 5 min, udev on AC change, after resume) records unplugs in `/var/lib/stagos/battery-history.json`, learns the usual unplug time from the last 14 days (weekdays and weekends apart; needs 5 steady weekdays or 3 weekends, otherwise it just stays at 80) and raises the thresholds to 99/100 about 90 min before it (`STAGOS_BAT_TOPOFF_LEAD`), back to 80 after the unplug or 2 h past the predicted time. A laptop suspended on AC is woken for the top-off (`STAGOS_BAT_WAKE=1`). `stag-battery status` shows the learned schedule and the next top-off, the battery tooltip says "charging on hold at 80%, full by 07:15"; `full`/`hold` start two oneshot units a polkit rule lets a local wheel user start without a password. Idle dimming, the lock screen and low battery are Plasma's (powerdevil, kscreenlocker; keys in `desktop/plasma/base.kconf`) |
| `snapshots` | Detects the root filesystem. **btrfs**: snapper + snap-pac (snapshot around every pacman transaction) + grub-btrfs (GRUB). **Anything else** (the default ext4): restic backups with `stag-backup` (see [Backups](#backups-and-updates)) to `STAGOS_RESTIC_REPO` from `config/local.conf`, driven by the `stagos-restic.timer` user timer; creates the repo password file once; without a repo it installs restic and warns |
| `apps` | chromium (Wayland flags), obsidian, spotify-launcher, blender, freecad, openscad, arm-none-eabi gcc/newlib, foot + StagOS zsh, Mission Center, gnome-disks, Papers, imv, xournalpp, virt-manager (+libvirt), onedrive (AUR), libreoffice-fresh, gnome-calculator, Claude web app launcher, Claude Code CLI (npm, `~/.local`), Flatpak + Flathub with Bambu Studio and LocalSend. `STAGOS_APPS_EXCLUDE="blender freecad"` skips packages on a small disk |
| `keyring` | gnome-keyring + seahorse. With `STAGOS_KEYRING_EMPTY=1` creates a login keyring with an empty password so it opens under autologin; **off by default**, see the note |
| `stag` | `chromium --app` launcher per service in `STAGOS_STAG_PATHS` at `<scheme>://<host>/<name>/` (from `config/local.conf`), icon tiles, listed in the STAG menu and KRunner. URLs are written only under `~/.local` and `~/.config` |
| `hidpi` | Inter + JetBrains Mono, fontconfig light hinting with grayscale AA, `desktop.env` with the panel scale `STAGOS_OUTPUT_SCALE` (default 1.5, applied by the plasma module at the first login) |
| `update` | `stag-update`, the safe update wrapper (see [Updates](#backups-and-updates)) and pacman-contrib (pacdiff) |
| `plasma` | the KDE Plasma 6 Wayland session (see [Plasma](#plasma)): StagOS HUD look, top bar + floating dock, touchpad, night light, Spectacle keys, `stag-session` on tty1, keyd's per-app keys (`stagos-keyd-apps.service`). `STAGOS_DESKTOP_PLASMA=0` skips it |

**Why TLP, not power-profiles-daemon:** the repo already enables TLP; the two conflict; TLP's runtime PM and USB/PCIe/SATA
tuning matter more on a 2014 ThinkPad battery than PPD's three profiles.

### Backups and updates

**Backups** (`stag-backup`, module `snapshots` on a non-btrfs root). restic over SFTP to the home server
(`STAGOS_RESTIC_REPO="sftp:SERVER:/path"` in `config/local.conf`; Tailscale SSH, so no keys). Backed up: `$HOME` and
`/etc` (root-only files in `/etc` are skipped and noted; the snapshot still counts), with the package lists
(`pacman -Qqe`, `-Qqm`) written to `~/.local/state/stagos/` first. Excluded: caches, Trash, Steam/Flatpak runtimes,
browser caches, `node_modules`, `.venv` and friends (`desktop/backup/backup.exclude`, plus any `CACHEDIR.TAG` dir).
Retention: 7 daily, 4 weekly, 6 monthly; every week `restic check` reads a 5% data subset and prunes.

The `stagos-restic.timer` tries every hour; `stag-backup run` makes at most one good backup per 20 h
(`STAGOS_BACKUP_EVERY_H`), only on AC power and only when the server answers (otherwise it skips quietly and the
next hour tries again). A failed backup pings ntfy when `STAGOS_BACKUP_NTFY_URL` (and optionally a 600 token file,
`STAGOS_BACKUP_NTFY_TOKEN_FILE`) is set; nothing is sent otherwise. The repo password is created once, at random, in
`~/.config/stagos/restic.pass` (600). **Copy it to a password manager**: it is never printed, and without it no
backup can be restored.

```
stag-backup now            # back up now (any power source)
stag-backup status         # age of the last good snapshot, last run, last check, the timer
stag-backup restore-test   # restore a few files of the newest snapshot to a temp dir and verify them
stag-backup check          # the weekly check + prune, now
```

The top bar can show the backup age (`BAK 5h`, hot after a failed run or past 3 days): `[bar] bak=true` in
`~/.config/stagos/desktop.conf` or StagOS Settings > Top Bar > Backup. Off by default.

**Updates** (`stag-update`, module `update`). One command instead of `sudo pacman -Syu`:

1. shows the [Arch news](https://archlinux.org/news/) posted since the last run and asks before going on;
2. takes a backup (`stag-backup now`; if the server is away or the backup fails it warns and asks; on btrfs snap-pac does it);
3. `sudo pacman -Syu`;
4. lists `.pacnew`/`.pacsave` files (`pacdiff -o`) and offers `pacdiff` (`DIFFPROG`, else `nvim -d` when installed);
5. lists failed system and user units, and says whether a reboot is needed (running kernel gone) or recommended
   (kernel, microcode, systemd, glibc, mesa, Plasma, Qt updated).

Everything goes to `~/.local/state/stagos/update.log`. `stag-update --dry-run` prints the plan and changes nothing.

**Archive pin (off by default).** To hold the box at a known-good day of the
[Arch Linux Archive](https://archive.archlinux.org/):

```
stag-update --pin 2026/09/15   # mirrorlist -> that day (the old one is kept as mirrorlist.stagos-unpinned)
stag-update --to 2026/09/15    # sync the system to the pinned day (pacman -Syuu; downgrades anything newer)
stag-update                    # while pinned: never goes past the pinned day
stag-update --to 2026/10/01    # move forward to a newer day (-Syuu); if it does not finish, the old pin comes back
stag-update --unpin            # back to the normal mirrors, then: stag-update
stag-update --status           # pinned or not
```

The date must exist in the archive (checked before anything is written). While pinned, `provision/00-repos.sh`
leaves the mirrorlist alone (no reflector).

### Mac-like keys (module `keys`)

Super stays Super (Meta) for KWin. While it is held keyd translates only these keys, so `Super+Return`, `Super+Space`,
`Super+Shift+3/4`, `Super+L`, arrows etc. still reach Plasma:

| Press | Sends | In foot (terminal) |
|---|---|---|
| Super+C / V | Ctrl+C / V | Ctrl+Shift+C / V (never SIGINT) |
| Super+X, Z, A, T, F, S | Ctrl+X, Z, A, T, F, S | nothing (no suspend, XOFF, readline surprises) |
| Super+Q, W | Ctrl+Q, W | Alt+F4 (close window) |
| Super+Shift+Z | Ctrl+Shift+Z (redo) | nothing |
| Super+Shift+V | clipboard history (Plasma, Meta+Shift+V) | same |

Real Ctrl+key is never remapped. The foot column comes from `~/.config/keyd/app.conf`. keyd applies it through
`keyd-application-mapper`, which the plasma module runs as the user unit `stagos-keyd-apps.service`. The unit starts
with Plasma (`plasma-workspace.target`) and stops with it. The mapper's KDE backend loads a small KWin script that
reports every focus change over D-Bus (python-dbus, python-gobject), and answers each one with `keyd bind reset
<that app's rows>`. When Plasma stops, the unit resets the rows, so the tty1 fallback gets the plain map.
The mapper needs the `keyd` group (module `keys`; log out and in once after it is added).

- Check it: `systemctl --user is-active stagos-keyd-apps` prints `active`.
- To name a new `[section]`, run `systemctl --user stop stagos-keyd-apps`, then `keyd-application-mapper -v`. It logs
  each focused window as `class|title`. Stop it with Ctrl+C, then `systemctl --user start stagos-keyd-apps`.
- If KWin restarts but Plasma stays up, its script is gone and the rows stop following focus. Run
  `systemctl --user restart stagos-keyd-apps` to fix that.

### Keyring decision

Autologin follows the LUKS unlock, so PAM never sees your password and a normal keyring can never auto-unlock (apps ask every session).
`STAGOS_KEYRING_EMPTY=1` gives an empty-password `login` keyring: silent, protected at rest by LUKS only, readable by anything running as you.
Set it in `config/stagos.conf` (or the environment) and run `./stagos-desktop keyring`. An existing keyring is never overwritten.

### Plasma

The StagOS desktop: KDE Plasma 6 on Wayland with a Mac-style layout and the StagOS HUD look. Minimal package set
(not the whole `plasma` group, no display manager, no SDDM): the LUKS passphrase stays the only login, tty1
autologin then starts the session.

- **Look**: `StagOS` color scheme (bg `#0a0a0a`, surface `#111111`, hairline `#2a2a2a`, accent `#c8102e`), a `StagOS`
  Plasma theme (flat panels and popups, 1 px hairline, 3 px corners), Breeze window decoration in those colors with
  a thin title bar and minimize/maximize/close on the right, Inter 10 and JetBrains Mono 10, Papirus-Dark icons.
- **Layout** (`org.stagos.desktop` global theme): 26 px top bar with the STAG menu, the global app menu, a tray for
  third-party icons and the StagOS readouts; a floating dock at the bottom center that hides only when a window
  overlaps it, launchers from `[dock] launchers` in `~/.config/stagos/desktop.conf` (`|` = separator, missing apps
  skipped); no desktop icons.
- **Top bar** (plasmoids `org.stagos.menu`, `org.stagos.status`): **STAG** opens the menu (About This Computer, StagOS
  Settings, System Settings, the stag apps, lock/sleep/restart/shut down/log out, destructive ones
  ask first). The readouts (TS / GPS / MON, CPU / RAM / temp, BOT, wifi, bt, volume, battery, clock) come from
  `stag-status --json` every 3 s; it reads `[bar]` on every call, so toggles apply live. Click them for the
  **Control Center**: wifi / bluetooth / Do Not Disturb / Night Light (on = warm now until turned off), volume and
  brightness, now playing, recon (Kismet start/stop, monitor mode), Stagbot (service dots, "Ask Stagbot": the
  question goes to the clipboard and the chat opens). Every action is a `stag-ctl` subcommand (`stag-ctl --help`,
  JSON out) that also works from a shell. Plasma's own network/volume/battery/bluetooth/media tray applets are not
  loaded; notifications and clipboard stay loaded but hidden, so notification popups and DND work as usual.
- **StagOS Settings** (`stag-settings`, in the STAG menu, KRunner and System Settings > StagOS): top bar switches,
  dock launchers, blur and animation speed, session (crash fallback state, retry, layout reset), capture interface. It edits
  `desktop.conf` in place; the `stagos-desktop-apply.path` user unit then runs `stag-plasma-apply`. Details:
  `desktop/plasma/settings/README.md`.
- **KWin**: blur for panels/popups, no wobbly/magic lamp/translucency, animations at 0.7, drag to an edge tiles,
  a 1 px hairline outline around windows and a slightly brighter title bar on the active one,
  Overview on **Meta+Tab** / **Ctrl+Up** / the 4-finger swipe, 4 desktops, click to focus, and every dock app
  remembers its window position and size (one KWin rule per app).
- **Keys**: **Meta+Space** KRunner (Spotlight), **Meta+L** lock, Spectacle: **Print** region shot, **Shift+Print** full
  screen, **Meta+Shift+R** record a region (Super+Shift+4/3/5 do the same, Meta+Shift+S opens Spectacle),
  **Meta+Shift+V** clipboard history, Super+Return foot, Super+E files, Super+Up/Down maximize/minimize,
  Ctrl+Alt+Left/Right desktops.
- **Touchpad, night light and power**: tap to click, natural scroll, clickfinger, palm rejection (every touchpad until
  you change one in System Settings); KWin Night Light at 3500 K (the Control Center toggle keeps it warm until
  turned off); lid closes to sleep, screen dims, no automatic sleep on AC, locks at 5 min and on resume.

Everything Plasma-side is written by `stag-plasma-apply` with `kwriteconfig6`, one key at a time, so settings you
change in System Settings stay unless `./stagos-desktop plasma` sets the same key again.

**tty1 session**: after the LUKS unlock tty1 logs in by itself and the `~/.zprofile` block execs `stag-session start`,
which starts Plasma (`plasma-dbus-run-session-if-needed startplasma-wayland`). Log out of Plasma and autologin starts
it again; tty2 is always a plain shell.

```
stag-session --status    # next= (what tty1 starts, and why), fails=
stag-session retry       # clear the fallback; on tty1 it starts Plasma right away
```

**Fallback**: if Plasma exits within 30 s twice in a row (with an error or not), stag-session stops trying, prints what failed,
the log (`~/.cache/stagos/session.log`) and how to retry, and leaves tty1 as a plain login shell (the `.zprofile` block
sees `STAGOS_NO_SESSION=1` there, so it never loops). It stays that way until `stag-session retry`, "Retry Plasma at
next login" in StagOS Settings > Session, or a reboot (the fail count is per boot). Without Plasma installed tty1 is
a plain shell too.

**Reset the layout** (top bar + dock back to the StagOS layout): `stag-plasma-apply --reset-layout`. With Plasma
running it rebuilds now; from a tty the old layout is moved aside (`plasma-org.kde.plasma.desktop-appletsrc.stagos-bak-*`)
and the next Plasma start builds a fresh one. A normal `stag-plasma-apply` never touches your layout, it only
syncs the dock launchers; the first Plasma login applies the layout once (`~/.local/state/stagos/plasma-layout-applied`).

**Other choices**: `kde-gtk-config` is not installed on purpose: it rewrites `~/.config/gtk-3.0` and `gtk-4.0` at every
Plasma login; GTK apps keep the StagOS settings from `60-desktop`. gnome-keyring stays the secret store (KWallet
disabled), baloo indexing is off (plocate covers file search). The panel scale (`STAGOS_OUTPUT_SCALE`, 1.5 on the
internal eDP panel) is set once at the first Plasma login with kscreen-doctor; change it later in System Settings > Display.

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
  (apply), `STAGOS_STARTPLASMA STAGOS_PLASMA_DBUS_WRAPPER STAGOS_SESSION_FAST_SECS STAGOS_BOOT_ID STAGOS_LOGIN_SHELL`
  (session), `STAGOS_SYS STAGOS_PROC STAGOS_CACHE STAGOS_QDBUS` (stag-ctl, stag-status).
- Visual smoke in rootless podman: `kwin_wayland --virtual` + spectacle hangs there, so the smoke drops the file
  capability (`setcap -r /usr/bin/kwin_wayland`), runs `Xvfb`, `kwin_wayland --x11-display` and plasmashell inside
  `dbus-run-session`, and grabs the X root with `xwd` (`test/plasma-smoke.sh`, run by `test/stag-widgets-container.sh`).

### Moving off labwc

History: until the Plasma-only change StagOS also shipped a labwc session (waybar, fuzzel, swaync, swaylock...); a box
installed back then still has its configs and packages. After `git pull`:

```
./stagos-desktop cleanup-labwc     # lists everything first; DRY_RUN=1 to only look
./stagos-desktop                   # the current modules (also rewrites the tty1 block)
```

`cleanup-labwc` moves the old user configs and coexistence files to `~/.cache/stagos-labwc-backup-<date>/` (nothing is
deleted), moves the old helpers out of `/usr/local/bin` and installs the current `stag-session` (sudo; an old one
would fall back to the removed labwc), and after a y/N question runs `sudo pacman -Rns` on
the old packages that are installed and that nothing else needs (the list is `STAGOS_LABWC_PKGS` in
`lib/labwc-cleanup.sh`). It also lists the dependencies `-s` takes along; one StagOS installs by name itself (gpsd,
which waybar pulled in too) is marked explicitly installed first, so it stays. Run it again any time: it reports nothing left.

### Testing

```
./test/dryrun.sh                             # shellcheck, dry runs, and every host test below (what CI runs)
./test/desktop-scripts.sh                    # stag-session, stag-plasma-apply, config invariants; fakes from test/fixtures/bin
./test/stag-widgets.sh                       # stag-ctl, stag-status, plasmoids
./test/plasma-apply.sh ./test/plasma-session.sh ./test/plasma-settings.sh   # Plasma apply, tty1 block, StagOS Settings
./test/safety.sh                             # stag-backup, stag-update (news, pacdiff, archive pin), stag-battery, stag-charge (python unit tests: test/stag-charge-test.py), modules power/snapshots/update; fakes
./test/labwc-cleanup.sh                      # cleanup-labwc against a fake old HOME (fake pacman, sudo)
./test/keyd-apps.sh                          # keyd per-app keys: the plasma module's user unit (fake systemctl), app.conf invariants
./test/desktop-container.sh all              # rootless podman Arch: shellcheck, dry run, real run, 2nd run must change 0 files, per-module reruns, config validation, btrfs branch
./test/desktop-container.sh plasma           # module plasma only: dry run, run 1, run 2 = 0 changes, Plasma config + session checks
./test/stag-widgets-container.sh             # the plasma phase, then the visual smoke (Xvfb + KWin + plasmashell, screenshots)
./test/labwc-migrate-container.sh            # old main (labwc era) installed, then this tree, cleanup-labwc, then the smoke
./test/keyd-apps-container.sh                # real KWin + the real keyd-application-mapper, a fake keyd: foot's rows follow focus; keyd check on every row
./test/fresh-install-container.sh            # clean box: provision 60/65 + every module, twice (0 changes), nothing labwc, then the smoke
./test/desktop-container.sh power snapshots update   # those modules twice (run 2 = 0 changes), a real restic backup + restore-test, TLP's parser
./test/desktop-container.sh clean            # remove the image and package cache
```

### Needs an on-device check (a container cannot do these)

1. `Super+C`/`V` in chromium; `Super+Shift+V` opens Plasma's clipboard history; `keyd monitor` if not. In foot, `Super+C`/`V`
   copy and paste and `sleep 30` survives `Super+C`, while `Ctrl+C` still interrupts it; `Super+Q`/`W` close the window. A container
   has no keyd daemon (no /dev/uinput), so the real key events are only checked on the device.
2. Print, Shift+Print, Meta+Shift+R (Spectacle region, full screen, region recording); Super+Shift+3/4/5 the same.
3. Trackpad: tap, natural scroll, palm rejection while typing, the 3/4-finger swipes (desktops, Overview).
4. Top bar + dock at 1.5x on the 2560x1440 panel; Meta+Space opens KRunner; a window reopens where it was closed.
5. Bluetooth pairing via bluedevil; audio keys; `tlp-stat -s`; `sudo tlp setcharge` then `stag-battery` shows 75/80 and the optimized charging schedule (`systemctl list-timers stagos-charge.timer`); lid close suspends and the lock screen is up on resume; low-battery notice.
6. `fwupdmgr get-updates`; Night Light from the Control Center.
7. Backups: copy `~/.config/stagos/restic.pass` to a password manager; `stag-backup now` (first run initialises the repo),
   `stag-backup restore-test`, `stag-backup status`; `systemctl --user list-timers stagos-restic.timer`; on btrfs: `snapper list` after a pacman run.
   Updates: `stag-update --dry-run`, then `stag-update`.
8. gnome-keyring: a chromium password save survives a reboot (with the flag on); `onedrive` authorisation; Flatpak installs of Bambu Studio and LocalSend.
9. tty1 fallback: `stag-session --status` says `next=plasma`; tty2 still gives a plain shell.
