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
Public tunables are in `config/stagos.conf` (scale, dock autohide, night-light lat/lon, keyring flag, flatpak ids).
**Private values** (stag host, restic remote) go in `config/local.conf`, which is untracked; copy `config/local.conf.example`.
On stagpad: `cd /opt/stagos && git pull && ./stagos-desktop`, then log out and back in.

| Module | What it does |
|---|---|
| `bluetooth` | bluez, bluez-utils, blueman tray; adapter powered at boot; TLP told never to autosuspend btusb |
| `bar` | waybar top bar (workspaces, taskbar, clock, notifications, STAG menu, wifi, bluetooth, volume, brightness, battery, tray, dock toggle, power) and `nwg-dock` bottom dock with pinned apps (`~/.cache/nwg-dock-pinned`, seeded once). Autohide by `STAGOS_DOCK_AUTOHIDE` |
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
| `apps` | chromium (Wayland flags), obsidian, VS Code (AUR), spotify-launcher, blender, freecad, openscad, arm-none-eabi gcc/newlib, foot + StagOS zsh, Mission Center, gnome-disks, Papers, imv, xournalpp, virt-manager (+libvirt), onedrive (AUR), libreoffice-fresh, gnome-calculator, Claude web app launcher, Claude Code CLI (npm, `~/.local`), Flatpak + Flathub with Bambu Studio and LocalSend. `STAGOS_APPS_EXCLUDE="blender freecad"` skips packages on a small disk |
| `keyring` | gnome-keyring + seahorse. With `STAGOS_KEYRING_EMPTY=1` creates a login keyring with an empty password so it opens under autologin; **off by default**, see the note |
| `stag` | `chromium --app` launcher per service in `STAGOS_STAG_PATHS` at `<scheme>://<host>/<name>/` (from `config/local.conf`), icon tiles, pinned in the dock, listed in the bar's STAG menu. URLs are written only under `~/.local` and `~/.config` |
| `hidpi` | output scale `STAGOS_OUTPUT_SCALE` (default 1.5), Inter + JetBrains Mono, fontconfig light hinting with grayscale AA, `desktop.env` for the runtime tunables |

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

### Testing

```
./test/desktop-scripts.sh                    # helper scripts + config invariants, no root, fakes from test/fixtures/bin
./test/desktop-container.sh install          # rootless podman Arch: shellcheck, dry run, real run of every module
./test/desktop-container.sh verify           # 2nd run must change 0 files, per-module reruns, config validation, headless labwc/waybar/swaync
./test/desktop-container.sh clean            # remove the image and package cache
```

### Needs an on-device check (a container cannot do these)

1. `Super+C`/`V` in chromium and in foot; `Super+Shift+V` opens the clipboard picker (composite keyd layer `[cmd+shift]`); `keyd monitor` if not.
2. `Super+Shift+3/4/5/6` (labwc key names with Shift+digit), files appear in `~/Pictures/Screenshots`.
3. Trackpad: tap, natural scroll, palm rejection while typing, 3-finger swipe switches workspace (after re-login for the `input` group).
4. Waybar layout at 1.5x fits the 2560x1440 panel without overflow; `ext/workspaces` shows the 4 desktops; taskbar clicks.
5. nwg-dock draws, autohides, pins persist, icons show; `Super+Shift+D` toggles.
6. swaync opens on Super+G, toggles reflect real state; SwayOSD appears for volume/brightness; caps-lock OSD needs `swayosd-libinput-backend.service`.
7. Bluetooth pairing via blueman; audio keys; `tlp-stat -s`; lid close suspends and the lock screen is up on resume; low-battery notice.
8. Lid, `fwupdmgr get-updates`, `wlsunset` schedule, `wf-recorder` (try `STAGOS_REC_CODEC=h264_vaapi`).
9. `systemctl --user status stagos-restic.timer`, one manual `systemctl --user start stagos-restic.service`; on btrfs: `snapper list` after a pacman run.
10. gnome-keyring: a chromium password save survives a reboot (with the flag on); `onedrive` authorisation; Flatpak installs of Bambu Studio and LocalSend; VS Code and libinput-gestures AUR builds (slow on this CPU).
