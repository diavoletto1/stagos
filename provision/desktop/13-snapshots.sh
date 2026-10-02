#!/usr/bin/env bash
# Snapshots. Detects the root filesystem:
#   btrfs      -> snapper + snap-pac (snapshot before/after every pacman transaction), + grub-btrfs on GRUB
#   otherwise  -> restic to STAGOS_RESTIC_REPO (config/local.conf): stag-backup + the stagos-restic.timer user timer
#                 ($HOME and /etc, package lists, retention 7 daily / 4 weekly / 6 monthly, weekly check + prune)
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

  dm_pkgs restic openssh
  dm_bins stag-backup
  stagos_dm_backup_legacy
  local repo="${STAGOS_RESTIC_REPO:-}" pass="${STAGOS_RESTIC_PASSWORD_FILE:-$HOME/.config/stagos/restic.pass}"
  if [[ -z "$repo" ]]; then
    warn "root is $fs (not btrfs) and STAGOS_RESTIC_REPO is unset in config/local.conf: restic installed, timer not enabled"
    return 0
  fi
  # %q keeps repo URLs with $ " ` or spaces (rest:https://user:pa$$@host) intact when backup.env is sourced.
  # dm_write reads a process substitution, not a pipe: in a pipeline it would run in a subshell and its
  # DM_CHANGED count would be lost
  dm_write "$(dm_cfg)/stagos/backup.env" 600 < <({
    printf 'STAGOS_RESTIC_REPO=%q\n' "$repo"
    printf 'STAGOS_RESTIC_PASSWORD_FILE=%q\n' "$pass"
    printf 'STAGOS_RESTIC_PATHS=%q\n' "${STAGOS_RESTIC_PATHS:-$HOME /etc}"
    printf 'STAGOS_BACKUP_EVERY_H=%q\n' "${STAGOS_BACKUP_EVERY_H:-20}"
    printf 'STAGOS_RESTIC_CHECK_SUBSET=%q\n' "${STAGOS_RESTIC_CHECK_SUBSET:-5%}"
    # ntfy ping on failure: only when local.conf names a topic URL (and optionally a 600 token file)
    printf 'STAGOS_NTFY_URL=%q\n' "${STAGOS_BACKUP_NTFY_URL:-}"
    printf 'STAGOS_NTFY_TOKEN_FILE=%q\n' "${STAGOS_BACKUP_NTFY_TOKEN_FILE:-}"
  })
  dm_install "$HERE/desktop/backup/backup.exclude" "$(dm_cfg)/stagos/backup.exclude" 644
  dm_install "$HERE/desktop/systemd/stagos-restic.service" "$(dm_cfg)/systemd/user/stagos-restic.service" 644
  local sched="${STAGOS_RESTIC_SCHEDULE:-hourly}"
  dm_write "$(dm_cfg)/systemd/user/stagos-restic.timer" 644 < <(sed "s|@SCHEDULE@|$sched|" "$HERE/desktop/systemd/stagos-restic.timer")
  stagos_dm_restic_pass "$pass"
  dm_enable_user stagos-restic.timer
  dm_note "backups: stag-backup now (first run initialises the repo), then stag-backup restore-test and stag-backup status"
  ok "restic backups scheduled ($sched attempts, one good backup per ${STAGOS_BACKUP_EVERY_H:-20} h)"
}

# stagos_dm_restic_pass FILE: a random repo password, created once (0600). Never printed: Jack copies it himself.
stagos_dm_restic_pass() {
  local f="$1"
  if [[ -s "$f" ]]; then
    if ! dm_dry && [[ ! -L "$f" && "$(stat -c %a "$f")" != 600 ]]; then
      chmod 600 "$f"; DM_CHANGED=$((DM_CHANGED + 1)); log "chmod 600 $f"
    fi
    return 0
  fi
  if dm_dry; then log "[dry] would create the restic password file $f (600, random)"; return 0; fi
  mkdir -p "$(dirname "$f")"
  ( umask 077; head -c 33 /dev/urandom | base64 | tr -d '\n' > "$f" )
  chmod 600 "$f"
  DM_CHANGED=$((DM_CHANGED + 1))
  log "wrote $f"
  warn "NEW restic password created in $f"
  warn "COPY IT SOMEWHERE SAFE NOW (password manager): without it no backup can ever be restored"
  dm_note "restic password: copy $f into your password manager (it is not printed anywhere)"
}

# the labwc-era names: stagos-backup in ~/.local/bin and /usr/local/bin (the unit runs stag-backup now)
stagos_dm_backup_legacy() {
  local f
  for f in "$HOME/.local/bin/stagos-backup" /usr/local/bin/stagos-backup; do
    [[ -e "$f" ]] || continue
    if [[ "$f" == /usr/* ]]; then run sudo rm -f "$f"; else run rm -f "$f"; fi
    dm_dry || DM_CHANGED=$((DM_CHANGED + 1))
  done
}
