#!/bin/bash
# StagOS restic backup, run by the stagos-restic user timer. Reads ~/.config/stagos/backup.env
# (repo, password file, paths), written by `stagos-desktop snapshots` from config/local.conf.
set -euo pipefail
env_file="$HOME/.config/stagos/backup.env"
[ -r "$env_file" ] || { echo "no $env_file; run: stagos-desktop snapshots" >&2; exit 1; }
# shellcheck source=/dev/null
. "$env_file"
export RESTIC_REPOSITORY="$STAGOS_RESTIC_REPO" RESTIC_PASSWORD_FILE="$STAGOS_RESTIC_PASSWORD_FILE"
restic snapshots >/dev/null 2>&1 || restic init
# shellcheck disable=SC2086  # paths are a space separated list
restic backup --exclude-caches --exclude "$HOME/.cache" --exclude "$HOME/.local/share/Trash" $STAGOS_RESTIC_PATHS
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
