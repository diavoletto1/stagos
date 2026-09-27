#!/bin/bash
# flash-usb-macos.sh -- fetch + verify the latest Arch ISO and write it to a USB stick.
# macOS only (bash 3.2 compatible). Refuses anything that isn't an external disk.
set -euo pipefail

MIRROR="https://geo.mirror.pkgbuild.com/iso/latest"
WORK="$HOME/Downloads"
cd "$WORK"

say()  { printf '\033[34m[stagos]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "this script is for macOS"

# 1. ISO + checksum
say "fetching checksum list"
curl -fsSL "$MIRROR/sha256sums.txt" -o sha256sums.txt
ISO="$(awk '{print $2}' sha256sums.txt | grep -E '^archlinux-[0-9.]+-x86_64\.iso$' | head -1)"
[[ -n "$ISO" ]] || die "couldn't find ISO name in sha256sums.txt"
say "latest ISO: $ISO"
curl -fL -C - "$MIRROR/$ISO" -o "$ISO"

say "verifying sha256"
WANT="$(grep " $ISO\$" sha256sums.txt | awk '{print $1}')"
GOT="$(shasum -a 256 "$ISO" | awk '{print $1}')"
[[ "$WANT" == "$GOT" ]] || die "checksum MISMATCH (want $WANT got $GOT). Delete $ISO and rerun."
say "checksum OK"

# 2. pick the stick
echo
say "external disks (your internal drive is NOT listed):"
diskutil list external physical
echo
read -r -p "Disk to ERASE (e.g. disk4): " DISK
[[ "$DISK" =~ ^disk[0-9]+$ ]] || die "expected something like disk4"

INFO="$(diskutil info "/dev/$DISK")" || die "no such disk"
echo "$INFO" | grep -qE 'Device Location: +External|Removable Media: +(Removable|Yes)' \
  || die "/dev/$DISK is not external/removable, refusing"
echo "$INFO" | grep -qE 'Protocol: +USB' || die "/dev/$DISK is not USB, refusing"

echo
echo "$INFO" | grep -E 'Device / Media Name|Disk Size|Protocol|Device Location'
echo
read -r -p "Type YES to wipe /dev/$DISK and write $ISO: " OKAY
[[ "$OKAY" == "YES" ]] || die "aborted, nothing written"

# 3. flash
diskutil unmountDisk "/dev/$DISK"
say "writing (sudo will ask for your Mac password)"
sudo dd if="$ISO" of="/dev/r$DISK" bs=4m status=progress
sync
diskutil eject "/dev/$DISK" || true
say "stick is ready. Pull it."

# 4. next steps
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<stag-mac-ip>')"
cat <<EOF

=== On the ThinkPad ===
1. Stick into the LAPTOP (not the dock). F1 -> BIOS: Secure Boot OFF, UEFI only.
2. F12 -> boot the USB -> "Arch Linux install medium".
3. Wifi:   iwctl station wlan0 connect "<SSID>"
4. Pull the installer from this Mac ($IP):
     scp $(whoami)@$IP:Downloads/stagos.tar.gz . && tar xzf stagos.tar.gz && cd stagos
   (scp refused? Mac: System Settings > General > Sharing > Remote Login ON)
5. Run the installer (it lists disks and asks which one):
     ./install.sh
EOF
