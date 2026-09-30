#!/usr/bin/env bash
# Screenshots + recording: grim/slurp/swappy (Super+Shift+3 full, +4 region, +6 annotate),
# wf-recorder toggle on Super+Shift+5. Files: ~/Pictures/Screenshots, ~/Videos/Recordings.
stagos_dm_capture() {
  dm_pkgs grim slurp swappy wf-recorder wl-clipboard libnotify
  dm_bins stag-screenshot stag-record
  if ! dm_dry; then mkdir -p "$HOME/Pictures/Screenshots" "$HOME/Videos/Recordings"; fi
  dm_write "$(dm_cfg)/swappy/config" 644 <<'SWAPPY'
[Default]
save_dir=$HOME/Pictures/Screenshots
save_filename_format=annotated-%Y-%m-%d_%H-%M-%S.png
show_panel=false
line_size=5
text_size=20
early_exit=true
SWAPPY
  dm_config labwc
  ok "capture ready"
}
