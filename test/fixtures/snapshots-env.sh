#!/usr/bin/env bash
# Runs the snapshots module (non-btrfs branch) with package/systemd steps stubbed and a hostile
# restic repo string, then sources the generated backup.env and prints the repo. Args: ROOT HOME
set -uo pipefail
HERE="$1"; HOME="$2"; DRY_RUN=0
# shellcheck source=/dev/null
source "$HERE/lib/common.sh"; source "$HERE/lib/desktop.sh"; source "$HERE/provision/desktop/13-snapshots.sh"
dm_pkgs() { :; }; dm_bins() { :; }; dm_enable_user() { :; }; dm_note() { :; }
STAGOS_ROOT_FSTYPE=ext4
STAGOS_RESTIC_REPO='rest:https://u:p$w"x`id`@h/a b'
stagos_dm_snapshots >/dev/null 2>&1
( . "$HOME/.config/stagos/backup.env" && printf '%s' "$STAGOS_RESTIC_REPO" )
