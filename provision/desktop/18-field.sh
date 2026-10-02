#!/usr/bin/env bash
# Field mode: the stag-field CLI (monitor mode + gpsd + Kismet logging + MAC/power profile + sleep inhibit,
# uploads to stag-maps) and a systemd --user timer that syncs finished .kismet logs once the laptop is back
# online. The Control Center "Field mode" tile and the FIELD top-bar readout are part of the plasma module
# (stag-ctl/stag-status). Privileged steps in stag-field go through sudo, the same path stag-mon uses; this
# module adds no sudoers rule. Idempotent and DRY_RUN aware.
stagos_dm_field() {
  dm_bins stag-field
  dm_install "$HERE/desktop/systemd/stagos-field-sync.service" "$(dm_cfg)/systemd/user/stagos-field-sync.service" 644
  dm_install "$HERE/desktop/systemd/stagos-field-sync.timer" "$(dm_cfg)/systemd/user/stagos-field-sync.timer" 644
  dm_enable_user stagos-field-sync.timer
  dm_note "field mode: run 'stag-field on' from a terminal (sudo prompts there); logs land in ~/field/<date>/"
  ok "field mode installed (stag-field + field-sync timer)"
}
