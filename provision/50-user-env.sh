#!/usr/bin/env bash
# Dev env (Python/Bash/C/C++), zram for the 8GB box, ThinkPad power + input bits.
stagos_50_user_env() {
  run sudo pacman -S --needed --noconfirm python python-pip gcc gdb clang cmake shellcheck \
    bash-completion zram-generator tlp acpi_call-dkms openssh tailscale
  printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' \
    | run sudo tee /etc/systemd/zram-generator.conf >/dev/null
  run sudo systemctl enable tlp.service tailscaled.service
  ok "user env ready"
}
