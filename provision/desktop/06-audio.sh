#!/usr/bin/env bash
# Audio: pipewire (+pulse/alsa) with wireplumber, pavucontrol, playerctl. Volume, mic-mute and media keys
# are Plasma's own (kglobalaccel); the Control Center uses wpctl and playerctl through stag-ctl.
stagos_dm_audio() {
  dm_pkgs pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol playerctl alsa-utils
  dm_enable_user pipewire.socket pipewire-pulse.socket wireplumber.service
  ok "audio ready"
}
