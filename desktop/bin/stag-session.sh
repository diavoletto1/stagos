#!/bin/bash
# StagOS: start Plasma on tty1 (exec'd by the ~/.zprofile block, see stagos_tty1_block in lib/common.sh).
#   stag-session start      start Plasma (when it ends, so does the tty1 login and autologin starts it again)
#   stag-session retry      clear the crash fallback, then start Plasma now (on tty1) or at the next login
#   stag-session --status   print next= (what start would do, and why) and fails=
# Plasma = plasma-dbus-run-session-if-needed startplasma-wayland. If it exits within 30 s twice in a row (any
# exit code), start stops trying: it prints what failed and execs a plain login shell on tty1
# (STAGOS_NO_SESSION=1 keeps the .zprofile block from starting it again, so there is no loop). The fallback
# lasts until `stag-session retry` or a reboot. Everything is logged to ~/.cache/stagos/session.log.
set -uo pipefail

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/stagos"
LOG="$CACHE/session.log"
FAILS="$CACHE/session-plasma-fails"
STARTPLASMA="${STAGOS_STARTPLASMA:-/usr/bin/startplasma-wayland}"
DBUS_WRAP="${STAGOS_PLASMA_DBUS_WRAPPER:-/usr/lib/plasma-dbus-run-session-if-needed}"
FAST="${STAGOS_SESSION_FAST_SECS:-30}"
MAX_FAILS=2
LOGIN_SHELL="${STAGOS_LOGIN_SHELL:-}"

log() { mkdir -p "$CACHE"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# the fail counter is "N BOOT_ID": a reboot starts from 0, so it never sticks across boots
boot_id() { echo "${STAGOS_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)}"; }
fails() {
  local n b
  read -r n b < "$FAILS" 2>/dev/null || { echo 0; return; }
  if [[ "$n" =~ ^[0-9]+$ && "$b" == "$(boot_id)" ]]; then echo "$n"; else echo 0; fi
}
set_fails() { echo "$1 $(boot_id)" > "$FAILS" 2>/dev/null; }
plasma_installed() { [ -x "$STARTPLASMA" ]; }

# next: what `start` would do now, plus the reason
next_session() {
  if ! plasma_installed; then echo "shell (plasma not installed: ./stagos-desktop plasma)"; return; fi
  if [ "$(fails)" -ge "$MAX_FAILS" ]; then echo "shell (plasma failed $(fails)x within ${FAST}s; run: stag-session retry)"; return; fi
  echo "plasma"
}

fallback_msg() {
  printf '\nStagOS: %s\n  log:   %s\n  retry: stag-session retry   (or reboot)\n\n' "$1" "${LOG/#$HOME/\~}" >&2
}

run_plasma() {
  local t0 rc dur n tries=0 cmd=()
  [ -x "$DBUS_WRAP" ] && cmd+=("$DBUS_WRAP")
  cmd+=("$STARTPLASMA")
  while :; do
    log "start plasma (fails so far: $(fails))"
    t0="$(date +%s)"
    "${cmd[@]}"
    rc=$?; dur=$(( $(date +%s) - t0 ))
    # a clean exit counts as well when it is fast: a Plasma that returns 0 at once would loop tty1 otherwise
    if [ "$dur" -ge "$FAST" ]; then
      set_fails 0
      log "plasma exited rc=$rc after ${dur}s"
      return 0
    fi
    n=$(( $(fails) + 1 )); set_fails "$n"; tries=$((tries + 1))
    log "plasma failed fast: rc=$rc after ${dur}s ($n/$MAX_FAILS)"
    # tries: never loop on Plasma even when the counter file cannot be written
    if [ "$n" -ge "$MAX_FAILS" ] || [ "$tries" -ge "$MAX_FAILS" ]; then
      log "FALLBACK: plasma failed $n times in a row within ${FAST}s; tty1 stays a login shell"
      fallback_msg "Plasma failed to start $n times in a row (exit $rc within ${FAST}s), staying in this shell."
      return 1
    fi
  done
}

# fallback: a plain login shell in place of the session (only on a terminal; otherwise just rc 1).
# shell_instead -i: an interactive shell that does not read ~/.zprofile again
shell_instead() {
  local sh="${LOGIN_SHELL:-${SHELL:-/bin/bash}}"
  if [ -n "$LOGIN_SHELL" ] || [ -t 0 ]; then exec env STAGOS_NO_SESSION=1 "$sh" "${1:--l}"; fi
  return 1
}

start() {
  local next
  # started again from the fallback shell's own login: an older .zprofile block that does not check
  # STAGOS_NO_SESSION. A login shell would read that block again (a loop), so this one is not a login shell.
  if [ -n "${STAGOS_NO_SESSION:-}" ]; then log "start skipped: STAGOS_NO_SESSION is set"; shell_instead -i; return; fi
  next="$(next_session)"
  case "$next" in
    plasma) run_plasma || shell_instead ;;
    *) log "no plasma: $next"; fallback_msg "not starting Plasma: ${next#shell }."; shell_instead ;;
  esac
}

on_tty1() { [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty 2>/dev/null)" = /dev/tty1 ]; }

mkdir -p "$CACHE"
case "${1:-}" in
  start) start; exit ;;
  retry)
    set_fails 0
    log "retry requested"
    # from the fallback shell: Plasma runs in its foreground, back to the shell when it ends
    if on_tty1 || [ "${STAGOS_SESSION_FORCE_START:-0}" = 1 ]; then unset STAGOS_NO_SESSION; LOGIN_SHELL=""; run_plasma; exit; fi
    echo "fallback cleared: the next tty1 login starts Plasma"
    exit 0 ;;
  --status|status)
    echo "next=$(next_session)"
    echo "fails=$(fails)"
    exit 0 ;;
  -h|--help|'') sed -n '2,9p' "$0" | sed 's/^# \?//'; [ -n "${1:-}" ] ;;
  *) echo "stag-session: unknown command $1 (see --help)" >&2; exit 2 ;;
esac
