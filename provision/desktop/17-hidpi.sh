#!/usr/bin/env bash
# HiDPI: output scale (default 1.5 on the 2560x1440 panel, STAGOS_OUTPUT_SCALE), Inter + JetBrains
# Mono, fontconfig light hinting with grayscale AA.
stagos_dm_hidpi() {
  dm_pkgs inter-font ttf-jetbrains-mono ttf-nerd-fonts-symbols noto-fonts noto-fonts-emoji fontconfig wlr-randr
  dm_config fontconfig
  dm_env_write
  if ! dm_dry && have fc-cache; then fc-cache -f >/dev/null 2>&1 || true; fi
  dm_note "hidpi: scale $STAGOS_OUTPUT_SCALE applies at the next labwc start (wlr-randr in autostart)"
  ok "hidpi configured (scale $STAGOS_OUTPUT_SCALE)"
}
