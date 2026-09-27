#!/usr/bin/env bash
# preflight: UEFI, target disk, network, clock. Refuses to continue without explicit confirm.
stagos_00_preflight() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    warn "dry-run: skipping UEFI/disk/network checks"
    return 0
  fi
  [[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode (BIOS: UEFI only, Secure Boot off)"
  if [[ -z "${STAGOS_DISK:-}" ]]; then
    log "disks on this machine (the USB stick is the one you booted from, don't pick it):"
    lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -v -E 'loop|sr0'
    read -r -p "Install StagOS to which disk (e.g. /dev/sda): " STAGOS_DISK
  fi
  [[ -n "${STAGOS_DISK:-}" ]] || die "no disk chosen"
  [[ -b "$STAGOS_DISK" ]]     || die "STAGOS_DISK=$STAGOS_DISK is not a block device"
  ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "no network -- use iwctl or ethernet first"
  timedatectl set-ntp true
  lsblk "$STAGOS_DISK"
  warn "This will DESTROY everything on $STAGOS_DISK."
  confirm "Wipe $STAGOS_DISK and install StagOS?" || die "aborted"
  ok "preflight passed"
}
