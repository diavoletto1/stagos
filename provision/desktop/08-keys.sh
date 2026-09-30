#!/usr/bin/env bash
# Mac-like keys: keyd makes Super+C/V/X/Z/A/Q/W/T/F/S act like Cmd shortcuts; foot gets
# non-Ctrl versions so terminal Ctrl behavior (SIGINT, suspend, XOFF) is never triggered.
stagos_dm_keys() {
  dm_pkgs keyd
  dm_install "$HERE/desktop/keyd/default.conf" /etc/keyd/default.conf 644 sudo
  dm_install "$HERE/desktop/keyd/app.conf" "$(dm_cfg)/keyd/app.conf" 644
  dm_add_group keyd
  dm_config labwc
  dm_enable_system keyd.service
  if ! dm_dry && dm_have_systemd && systemctl is-active --quiet keyd; then sudo keyd reload || true; fi
  dm_note "keys: verify Super+C/V in a GUI app and a foot terminal (see README, module keys)"
  ok "keyd map installed"
}
