#!/usr/bin/env bash
# StagOS installer -- run from the Arch ISO live environment as root.
# Layers: partition -> pacstrap -> chroot config. Reboot, then run provision.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=config/stagos.conf
source "$HERE/config/stagos.conf"

require_root

STEPS=(00-preflight 10-partition 20-pacstrap 30-fstab 40-chroot-config)
for step in "${STEPS[@]}"; do
  log "install step: $step"
  # shellcheck disable=SC1090
  source "$HERE/install/${step}.sh"
  "stagos_${step//-/_}"
  ok "done: $step"
done

log "Base install complete. Reboot into StagOS, log in as $STAGOS_USER,"
log "then run: /opt/stagos/provision.sh"
