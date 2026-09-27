#!/usr/bin/env bash
# chroot config: locale/tz/host, initramfs (LUKS + plymouth hooks), GRUB, users.
# Config values are baked into the generated script at write time.
stagos_40_chroot_config() {
  run mkdir -p /mnt/opt/stagos
  run cp -a "$HERE/." /mnt/opt/stagos/

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    warn "dry-run: would write /mnt/root/stagos-chroot.sh and arch-chroot into it"
    return 0
  fi

  cat > /mnt/root/stagos-chroot.sh <<CHROOT
#!/usr/bin/env bash
set -euo pipefail
ln -sf "/usr/share/zoneinfo/${STAGOS_TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i 's/^#${STAGOS_LOCALE}/${STAGOS_LOCALE}/' /etc/locale.gen
locale-gen
echo "LANG=${STAGOS_LOCALE}"   > /etc/locale.conf
echo "KEYMAP=${STAGOS_KEYMAP}" > /etc/vconsole.conf
echo "${STAGOS_HOSTNAME}"      > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s\n' "${STAGOS_HOSTNAME}" > /etc/hosts
systemctl enable NetworkManager

hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth"
[[ "${STAGOS_LUKS}" == "1" ]] && hooks="\$hooks encrypt"
sed -i "s/^HOOKS=.*/HOOKS=(\$hooks filesystems fsck)/" /etc/mkinitcpio.conf
mkinitcpio -P

sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash"/' /etc/default/grub
if [[ "${STAGOS_LUKS}" == "1" ]]; then
  uuid=\$(blkid -s UUID -o value "${STAGOS_ROOT_PART}")
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\${uuid}:stagos_crypt root=/dev/mapper/stagos_crypt\"|" /etc/default/grub
fi
sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="StagOS"/' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=StagOS
grub-mkconfig -o /boot/grub/grub.cfg

echo ">> root password"; passwd
useradd -m -G wheel -s /bin/zsh "${STAGOS_USER}"
echo ">> ${STAGOS_USER} password"; passwd "${STAGOS_USER}"
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
chown -R "${STAGOS_USER}:${STAGOS_USER}" /opt/stagos
CHROOT

  chmod +x /mnt/root/stagos-chroot.sh
  arch-chroot /mnt /root/stagos-chroot.sh
  rm -f /mnt/root/stagos-chroot.sh
  ok "chroot config complete"
}
