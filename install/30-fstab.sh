#!/usr/bin/env bash
# fstab: UUID-based.
stagos_30_fstab() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    run "genfstab -U /mnt >> /mnt/etc/fstab"
  else
    genfstab -U /mnt >> /mnt/etc/fstab
  fi
  ok "fstab generated"
}
