#!/usr/bin/env bash
# Night light: wlsunset, sunrise/sunset for Tampa (STAGOS_LAT/LON). Toggle in the Control Center.
stagos_dm_nightlight() {
  dm_pkgs wlsunset
  dm_bins stag-nightlight stag-toggle
  dm_env_write
  ok "night light ready ($STAGOS_LAT,$STAGOS_LON)"
}
