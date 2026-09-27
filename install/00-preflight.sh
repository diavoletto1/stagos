#!/usr/bin/env bash
# preflight: UEFI, target disk, network, clock. Refuses to continue without explicit confirm.
stagos_00_preflight() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    warn "dry-run: skipping UEFI/disk/network checks"
    return 0
  fi
  [[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode (BIOS: UEFI only, Secure Boot off)"
  [[ -n "${STAGOS_DISK:-}" ]] || die "STAGOS_DISK unset -- set it in config/stagos.conf (see lsblk)"
  [[ -b "$STAGOS_DISK" ]]     || die "STAGOS_DISK=$STAGOS_DISK is not a block device"
  ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "no network -- use iwctl or ethernet first"
  timedatectl set-ntp true
  lsblk "$STAGOS_DISK"
  warn "This will DESTROY everything on $STAGOS_DISK."
  confirm "Wipe $STAGOS_DISK and install StagOS?" || die "aborted"
  ok "preflight passed"
}
