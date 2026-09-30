#!/usr/bin/env bash
# Snapshots. Detects the root filesystem:
#   btrfs      -> snapper + snap-pac (snapshot before/after every pacman transaction), + grub-btrfs on GRUB
#   otherwise  -> restic to STAGOS_RESTIC_REPO (config/local.conf) driven by a systemd user timer
stagos_dm_snapshots() {
  local fs; fs="$(dm_root_fstype)"
  log "root filesystem: $fs"
  if [[ "$fs" == "btrfs" ]]; then
    dm_pkgs snapper snap-pac
    if [[ ! -f /etc/snapper/configs/root ]]; then
      run sudo snapper -c root create-config /
    fi
    if [[ "${STAGOS_BOOTLOADER:-grub}" == "grub" ]]; then
      dm_pkgs grub-btrfs inotify-tools
      dm_enable_system grub-btrfsd.service
    fi
    dm_enable_system snapper-timeline.timer snapper-cleanup.timer
    ok "btrfs snapshots: snapper + snap-pac"
    return 0
  fi

  dm_pkgs restic
  dm_bins stagos-backup
  local repo="${STAGOS_RESTIC_REPO:-}"
  if [[ -z "$repo" ]]; then
    warn "root is $fs (not btrfs) and STAGOS_RESTIC_REPO is unset in config/local.conf: restic installed, timer not enabled"
    return 0
  fi
  dm_write "$(dm_cfg)/stagos/backup.env" 600 <<EOF2
STAGOS_RESTIC_REPO="$repo"
STAGOS_RESTIC_PASSWORD_FILE="${STAGOS_RESTIC_PASSWORD_FILE:-$HOME/.config/stagos/restic.pass}"
STAGOS_RESTIC_PATHS="${STAGOS_RESTIC_PATHS:-$HOME}"
EOF2
  # the backup script is a user command; the units run it from ~/.local/bin
  dm_install "$HERE/desktop/bin/stagos-backup.sh" "$HOME/.local/bin/stagos-backup" 755
  dm_install "$HERE/desktop/systemd/stagos-restic.service" "$(dm_cfg)/systemd/user/stagos-restic.service" 644
  local sched="${STAGOS_RESTIC_SCHEDULE:-daily}"
  sed "s|@SCHEDULE@|$sched|" "$HERE/desktop/systemd/stagos-restic.timer" | dm_write "$(dm_cfg)/systemd/user/stagos-restic.timer" 644
  if [[ ! -f "${STAGOS_RESTIC_PASSWORD_FILE:-$HOME/.config/stagos/restic.pass}" ]]; then
    warn "create the restic password file (chmod 600): ${STAGOS_RESTIC_PASSWORD_FILE:-$HOME/.config/stagos/restic.pass}"
  fi
  dm_enable_user stagos-restic.timer
  dm_note "snapshots: systemctl --user start stagos-restic.service once, then check 'restic snapshots'"
  ok "restic backups scheduled ($sched)"
}
