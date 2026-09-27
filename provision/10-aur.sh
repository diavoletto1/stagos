#!/usr/bin/env bash
# AUR helper bootstrap (paru-bin, no rust build on a 2014 CPU).
stagos_10_aur() {
  if have paru; then ok "paru already present"; return 0; fi
  local tmp
  tmp="$(mktemp -d)"
  run git clone https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    run "cd $tmp/paru-bin && makepkg -si --noconfirm"
  else
    (cd "$tmp/paru-bin" && makepkg -si --noconfirm)
  fi
  ok "paru installed"
}
