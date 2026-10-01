#!/usr/bin/env bash
# HiDPI: Inter + JetBrains Mono (+ symbols, emoji), fontconfig light hinting with grayscale AA, and desktop.env
# with the panel scale (STAGOS_OUTPUT_SCALE, default 1.5 on the 2560x1440 panel). The scale itself is set by the
# plasma module's first-login autostart (stag-plasma-apply --session, kscreen-doctor).
stagos_dm_hidpi() {
  dm_pkgs inter-font ttf-jetbrains-mono ttf-nerd-fonts-symbols noto-fonts noto-fonts-emoji fontconfig
  dm_config fontconfig
  dm_env_write
  if ! dm_dry && have fc-cache; then fc-cache -f >/dev/null 2>&1 || true; fi
  ok "hidpi configured (scale $STAGOS_OUTPUT_SCALE at the first Plasma login)"
}
