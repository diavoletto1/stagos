#!/usr/bin/env bash
# pacstrap: minimal base + what the bootloader/network/branding layers need at first boot.
stagos_20_pacstrap() {
  local pkgs=(base base-devel "$STAGOS_KERNEL" "${STAGOS_KERNEL}-headers" linux-firmware
    intel-ucode grub efibootmgr networkmanager iwd sudo git vim zsh reflector plymouth)
  [[ "${STAGOS_LUKS:-0}" == "1" ]] && pkgs+=(cryptsetup)
  [[ "$STAGOS_FS" == "btrfs" ]] && pkgs+=(btrfs-progs)
  run pacstrap -K /mnt "${pkgs[@]}"
  ok "base system installed"
}
