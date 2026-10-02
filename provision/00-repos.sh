#!/usr/bin/env bash
# pacman tuning + fastest US mirrors + full upgrade.
stagos_00_repos() {
  run sudo sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
  # a box pinned to the Arch Linux Archive (stag-update --pin) keeps its mirrorlist: reflector would unpin it
  if grep -q '^# StagOS archive pin:' "${STAGOS_MIRRORLIST:-/etc/pacman.d/mirrorlist}" 2>/dev/null; then
    warn "mirrorlist is pinned to the Arch Linux Archive (stag-update --status): reflector skipped"
  else
    run sudo reflector --country US --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
  fi
  run sudo pacman -Syu --noconfirm
  ok "repos tuned, system updated"
}
