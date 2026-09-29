#!/usr/bin/env bash
# StagOS provisioning -- run on first boot as the StagOS user (has sudo).
# Installs the war-driving toolkit, services, branding, and dev env.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=config/stagos.conf
source "$HERE/config/stagos.conf"

STEPS=(00-repos 20-toolkit 30-services 40-branding 50-user-env 60-desktop 65-extras 99-verify)
# run only named steps if given, e.g. ./provision.sh 60-desktop 65-extras
if [[ $# -gt 0 ]]; then STEPS=("$@"); fi
for step in "${STEPS[@]}"; do
  log "provision step: $step"
  # shellcheck disable=SC1090
  source "$HERE/provision/${step}.sh"
  "stagos_${step//-/_}"
  ok "done: $step"
done

log "StagOS provisioning complete."
