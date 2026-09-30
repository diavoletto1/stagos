#!/bin/bash
# StagOS Spotlight (Super+Shift+Space; plain Super+Space is the fuzzel app launcher).
# One prompt, mode by what you type:
#   = 2*(3+4)  or anything starting with a digit/paren   calculator (qalc), result -> clipboard
#   / report    (or "f report")                          file search (plocate), pick to open
#   anything else                                        opens the app launcher pre-filtered
# `stag-spotlight files|calc|apps` jumps straight to a mode.
prompt() { fuzzel --dmenu --prompt-only "$1" --width 44; }

calc() {
  local expr="$1" out
  [ -n "$expr" ] || expr=$(prompt 'calc> ') || exit 0
  [ -n "$expr" ] || exit 0
  out=$(qalc -t "$expr" 2>&1 | tail -n1)
  printf '%s' "$out" | wl-copy
  notify-send "$expr" "$out  (copied)"
}

files() {
  local q="$1" hit
  [ -n "$q" ] || q=$(prompt 'find> ') || exit 0
  [ -n "$q" ] || exit 0
  hit=$(plocate -i -l 200 -- "$q" | fuzzel --dmenu --prompt 'open> ' --width 80) || exit 0
  [ -n "$hit" ] && exec xdg-open "$hit"
}

apps() { exec fuzzel ${1:+--search "$1"}; }

case "${1:-}" in
  files) files ""; exit ;;
  calc)  calc ""; exit ;;
  apps)  apps ""; exit ;;
esac

q=$(prompt 'spotlight> ') || exit 0
[ -n "$q" ] || exit 0
case "$q" in
  =*)                calc "${q#=}" ;;
  /*)                files "${q#/}" ;;
  "f "*)             files "${q#f }" ;;
  [0-9\(.-]*)      calc "$q" ;;
  *)                 apps "$q" ;;
esac
