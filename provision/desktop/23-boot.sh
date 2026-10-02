#!/usr/bin/env bash
# Boot splash: the StagOS Plymouth theme (assets/plymouth/stagos): black, STAG wordmark, HUD corners, thin red
# progress line; the LUKS passphrase prompt is part of it (styled as the login page; the encrypt hook asks
# through plymouth, which is why plymouth sits before encrypt in HOOKS). This module installs the theme and selects
# it WITHOUT rebuilding the initramfs: it prints the one step left, `sudo mkinitcpio -P`. Bootloader, LUKS and
# HOOKS order are not touched. Escape hatch: README "Boot splash".
stagos_dm_boot() {
  dm_pkgs plymouth
  local src="$HERE/assets/plymouth/stagos" dst=/usr/share/plymouth/themes/stagos f rel before=$DM_CHANGED
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    dm_install "$f" "$dst/$rel" 644 sudo
  done < <(find "$src" -type f -print0 | sort -z)

  if dm_dry; then
    run sudo plymouth-set-default-theme stagos
    return 0
  fi
  if [[ "$(plymouth-set-default-theme 2>/dev/null)" != stagos ]]; then
    sudo plymouth-set-default-theme stagos
    DM_CHANGED=$((DM_CHANGED + 1))
    log "plymouth theme set to stagos (initramfs not rebuilt)"
  fi

  # does the initramfs the bootloader loads already carry the current theme? (empty in a container: no /boot)
  local img stale=0 listing
  if have lsinitcpio; then
    for img in /boot/initramfs-*.img; do
      [[ -f "$img" && "$img" != *-fallback.img ]] || continue
      listing="$(lsinitcpio -l "$img" 2>/dev/null || true)"
      grep -q 'plymouth/themes/stagos/stagos.script' <<<"$listing" || stale=1
      grep -q 'plymouth/themes/stagos/track.png' <<<"$listing" || stale=1
    done
  fi
  if [[ $stale -eq 1 || $DM_CHANGED -gt $before ]]; then
    dm_note "boot: rebuild the initramfs to put the theme on the boot screen: sudo mkinitcpio -P   (if the screen misbehaves: README 'Boot splash')"
  fi
  ok "boot theme ready"
}
