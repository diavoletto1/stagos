#!/usr/bin/env bash
# pacman tuning + fastest US mirrors + full upgrade.
stagos_00_repos() {
  run sudo sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
  run sudo reflector --country US --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
  run sudo pacman -Syu --noconfirm
  ok "repos tuned, system updated"
}
