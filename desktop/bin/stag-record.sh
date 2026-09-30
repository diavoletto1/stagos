#!/bin/bash
# StagOS screen recording toggle (Super+Shift+5): first press picks a region and starts
# wf-recorder, second press stops it. Files go to ~/Videos/Recordings.
# STAGOS_REC_CODEC=h264_vaapi uses the Intel encoder (default libx264, works everywhere).
dir="${STAGOS_REC_DIR:-$HOME/Videos/Recordings}"
pidfile="${XDG_RUNTIME_DIR:-/tmp}/stag-record.pid"
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
  kill -INT "$(cat "$pidfile")"
  rm -f "$pidfile"
  notify-send "Recording stopped" "$dir"
  exit 0
fi
mkdir -p "$dir"
geom=$(slurp) || exit 0
file="$dir/$(date +%F_%H-%M-%S).mp4"
args=(-g "$geom" -f "$file")
if [ "${STAGOS_REC_CODEC:-}" = h264_vaapi ]; then args+=(-c h264_vaapi -d /dev/dri/renderD128); fi
wf-recorder "${args[@]}" >/dev/null 2>&1 &
echo $! > "$pidfile"
notify-send "Recording" "Super+Shift+5 again to stop"
