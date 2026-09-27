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
