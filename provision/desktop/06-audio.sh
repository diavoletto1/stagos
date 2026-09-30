#!/usr/bin/env bash
# Audio: pipewire (+pulse/alsa) with wireplumber, pavucontrol, media keys (bound in labwc rc.xml).
stagos_dm_audio() {
  dm_pkgs pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol playerctl alsa-utils
  dm_enable_user pipewire.socket pipewire-pulse.socket wireplumber.service
  ok "audio ready (volume/mute/mic/play/next/prev keys live in labwc rc.xml)"
}
