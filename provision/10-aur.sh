#!/usr/bin/env bash
# OPTIONAL, not in the default provision run (everything StagOS needs is in official repos).
# Builds paru from source so it always matches the installed libalpm (paru-bin broke on this).
# Run manually later if you want AUR access:  bash -c 'source lib/common.sh; source provision/10-aur.sh; stagos_10_aur'
stagos_10_aur() {
  if have paru && paru --version >/dev/null 2>&1; then ok "paru working"; return 0; fi
  run sudo pacman -Rns --noconfirm paru-bin 2>/dev/null || true
  run sudo pacman -S --needed --noconfirm base-devel git rust
  local tmp
  tmp="$(mktemp -d)"
  run git clone https://aur.archlinux.org/paru.git "$tmp/paru"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    run "cd $tmp/paru && makepkg -si --noconfirm"
  else
    (cd "$tmp/paru" && makepkg -si --noconfirm)
  fi
  ok "paru built from source"
}
