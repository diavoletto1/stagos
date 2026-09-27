#!/usr/bin/env bash
# partition: GPT -> EFI (FAT32) + root (optionally LUKS2), then mount at /mnt.
stagos_10_partition() {
  local disk="$STAGOS_DISK" p=""
  [[ "$disk" =~ [0-9]$ ]] && p="p"      # /dev/nvme0n1 -> nvme0n1p1, /dev/sda -> sda1
  STAGOS_EFI_PART="${disk}${p}1"
  STAGOS_ROOT_PART="${disk}${p}2"

  run sgdisk --zap-all "$disk"
  run sgdisk -n1:0:+"$STAGOS_EFI_SIZE" -t1:ef00 -c1:EFI "$disk"
  run sgdisk -n2:0:0 -t2:8300 -c2:stagos_root "$disk"
  run partprobe "$disk"
  run mkfs.fat -F32 -n EFI "$STAGOS_EFI_PART"

  STAGOS_ROOTDEV="$STAGOS_ROOT_PART"
  if [[ "${STAGOS_LUKS:-0}" == "1" ]]; then
    log "LUKS2 on $STAGOS_ROOT_PART (you'll set the passphrase now)"
    run cryptsetup luksFormat --type luks2 "$STAGOS_ROOT_PART"
    run cryptsetup open "$STAGOS_ROOT_PART" stagos_crypt
    STAGOS_ROOTDEV="/dev/mapper/stagos_crypt"
  fi

  case "$STAGOS_FS" in
    ext4)  run mkfs.ext4 -L stagos "$STAGOS_ROOTDEV" ;;
    btrfs) run mkfs.btrfs -f -L stagos "$STAGOS_ROOTDEV" ;;
    *)     die "unknown STAGOS_FS=$STAGOS_FS" ;;
  esac

  run mount "$STAGOS_ROOTDEV" /mnt
  run mkdir -p /mnt/boot
  run mount "$STAGOS_EFI_PART" /mnt/boot
  ok "partitioned + mounted"
}
