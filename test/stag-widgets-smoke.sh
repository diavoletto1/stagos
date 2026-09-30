#!/usr/bin/env bash
# Visual smoke for the StagOS widgets. Runs as jack INSIDE the throwaway test container, after
# `stagos-desktop plasma` (see test/stag-widgets-container.sh). Xvfb + kwin_wayland on its X11 backend +
# plasmashell (what works in rootless podman, see desktop/plasma/NOTES-for-p2-p3.md), then screenshots:
# the bar, the Control Center, the STAG menu, a notification popup with the notifications applet hidden
# in the tray, and the same notification with Do Not Disturb on. Output: $1 (default /out).
# The readouts get a stagpad-like /sys and /proc (test/fixtures/fake-desktop.sh) so the bar is not empty.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
out="${1:-/out}"
mkdir -p "$out"
log() { echo "smoke: $*"; }

sudo pacman -S --needed --noconfirm xorg-server-xvfb xorg-xwd imagemagick libnotify xdotool >/dev/null 2>&1 \
  || { log "could not install the X tools"; exit 1; }

# stagpad-like sysfs/procfs for the readouts, and stag services for the Stagbot section
fk="$(mktemp -d)"
bash -c '. test/fixtures/fake-desktop.sh && fake_desktop_setup "$1"' _ "$fk/sb" >/dev/null 2>&1
mkdir -p "$HOME/.config/stagos"
printf 'control|https://stag.test.invalid/control/\nmaps|https://stag.test.invalid/maps/\ntasks|https://stag.test.invalid/tasks/\n' \
  > "$HOME/.config/stagos/stag-services"
export STAGOS_SYS="$fk/sb/sys" STAGOS_PROC="$fk/sb/proc"

# Qt logs to journald when stderr is not a tty; the container has none
export QT_FORCE_STDERR_LOGGING=1
export XDG_RUNTIME_DIR=/tmp/xdg-smoke XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true XDG_SESSION_TYPE=wayland
# D-Bus activated services (kactivitymanagerd, portals, the notification daemon) inherit the bus environment:
# without these they abort (no display) and plasmashell refuses to load the shell
export WAYLAND_DISPLAY=wayland-9 QT_QPA_PLATFORM=wayland
install -d -m 700 "$XDG_RUNTIME_DIR"

session() {
  local xv kw ps ids
  Xvfb :5 -screen 0 1706x960x24 >"$out/xvfb.log" 2>&1 & xv=$!
  sleep 2
  env -u WAYLAND_DISPLAY -u QT_QPA_PLATFORM DISPLAY=:5 kwin_wayland --x11-display :5 --width 1706 --height 960 --socket wayland-9 --no-lockscreen \
    >"$out/kwin.log" 2>&1 & kw=$!
  for _ in $(seq 40); do [ -S "$XDG_RUNTIME_DIR/wayland-9" ] && break; sleep 0.5; done
  log "kwin alive: $(kill -0 "$kw" 2>/dev/null && echo yes || echo no), sockets: $(echo "$XDG_RUNTIME_DIR"/*)"
  plasmashell --no-respawn >"$out/plasmashell.log" 2>&1 & ps=$!
  # first start on a slow box: QML compiles, the global theme layout runs; wait until both widgets exist
  local t0=$SECONDS
  while [ $((SECONDS - t0)) -lt 240 ]; do
    kill -0 "$ps" 2>/dev/null || { log "plasmashell exited ($(wait "$ps"; echo $?))"; break; }
    ids="$(qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
      panels().forEach(function (p) { p.widgets().forEach(function (w) {
        if (w.type == "org.stagos.status" || w.type == "org.stagos.menu") print(w.type + " " + w.id);
      }); });' 2>/dev/null)"
    # print() in evaluateScript adds no newline: pick the "type id" pairs out
    ids="$(printf '%s' "$ids" | grep -oE 'org\.stagos\.[a-z]+ [0-9]+')"
    [ "$(printf '%s\n' "$ids" | grep -c '^org.stagos')" -ge 2 ] && break
    sleep 3
  done
  log "plasmashell up after $((SECONDS - t0)) s, widgets: $(printf '%s' "$ids" | tr '\n' ' ')"
  printf '%s\n' "$ids" > "$out/widgets.txt"
  # a global shortcut on each widget registers its "activate widget <id>" action with kglobalaccel
  qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
    panels().forEach(function (p) { p.widgets().forEach(function (w) {
      if (w.type == "org.stagos.status") w.globalShortcut = "Ctrl+Alt+Shift+F11";
      if (w.type == "org.stagos.menu") w.globalShortcut = "Ctrl+Alt+Shift+F12";
    }); });' >/dev/null 2>&1
  sleep 20   # widgets paint, first stag-status poll returns
  shot() { xwd -root -silent -display :5 | magick xwd:- "$out/plasma-p2-$1.png" && log "shot $1"; }
  shot bar
  magick "$out/plasma-p2-bar.png" -crop 1706x40+0+0 "$out/plasma-p2-bar-crop.png" 2>/dev/null

  open_widget() { # type: toggle its popup
    local id
    id="$(awk -v t="$1" '$1 == t {print $2; exit}' "$out/widgets.txt")"
    [ -n "$id" ] || { log "no $1 in the layout"; return 1; }
    qdbus6 org.kde.kglobalaccel /component/plasmashell org.kde.kglobalaccel.Component.invokeShortcut "activate widget $id" \
      >/dev/null 2>&1 && return 0
    log "invokeShortcut failed for $1, clicking instead"
    return 1
  }
  if open_widget org.stagos.status || DISPLAY=:5 xdotool mousemove 1600 12 click 1; then
    sleep 6; shot control-center
    open_widget org.stagos.status || DISPLAY=:5 xdotool mousemove 1600 12 click 1; sleep 2
  fi
  if open_widget org.stagos.menu || DISPLAY=:5 xdotool mousemove 20 12 click 1; then
    sleep 4; shot stag-menu
    DISPLAY=:5 xdotool mousemove 80 52 click 1; sleep 3; shot stag-menu-about   # "About This Computer"
    open_widget org.stagos.menu || DISPLAY=:5 xdotool mousemove 20 12 click 1; sleep 2
  fi

  # notifications: popups must show with the notifications applet hidden in the tray, and not with DND on
  notify-send -a StagOS "StagOS smoke" "notification popup with the tray applet hidden"; sleep 3; shot notify
  stag-ctl dnd on > "$out/dnd.json"; sleep 2
  notify-send -a StagOS "StagOS smoke" "this one must NOT pop up (Do Not Disturb)"; sleep 3; shot notify-dnd
  stag-ctl dnd off >/dev/null

  cp "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" "$out/appletsrc.txt" 2>/dev/null
  cp "$HOME/.config/plasmanotifyrc" "$out/plasmanotifyrc.txt" 2>/dev/null
  kill "$ps" 2>/dev/null; sleep 2; kill "$kw" 2>/dev/null; sleep 1; kill "$xv" 2>/dev/null
  wait 2>/dev/null
}
export -f session log
export out
timeout 480 dbus-run-session -- bash -c session
log "plasmashell lines about org.stagos:"
grep -a -iE 'org\.stagos|stagos.*(error|warn)' "$out/plasmashell.log" | head -30
log "tray config:"
grep -a -E '^(extraItems|hiddenItems)=' "$out/appletsrc.txt" 2>/dev/null
rm -rf "$fk"
ls -la "$out"
