#!/usr/bin/env bash
# Visual smoke for StagOS Plasma. Runs as jack INSIDE the throwaway test container, after
# `stagos-desktop plasma` (see test/stag-widgets-container.sh). Xvfb + kwin_wayland on its X11 backend +
# plasmashell (what works in rootless podman, see README, Plasma, Internals), then screenshots and checks:
#   desktop (dock on an empty desktop), window (hairline border), overview (Meta+Tab), window-dodge (dock hides
#   under a big window), control-center, stag-menu, stag-menu-about, notify / notify-dnd (popups with the tray
#   applet hidden, none with DND on), appmenu off/on (live [bar] appmenu toggle, kept after a plasmashell
#   restart), settings (StagOS Settings), systemsettings (the StagOS entry), then a headless labwc start through
#   stag-session. Output: $1 (default /out), file names $SHOT_PREFIX-<name>.png (default plasma).
# The readouts get a stagpad-like /sys and /proc (test/fixtures/fake-desktop.sh) so the bar is not empty.
# $out/experiment.sh, when present, is sourced inside the session after the window shot (one-off probes).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
out="${1:-/out}"
SHOT_PREFIX="${SHOT_PREFIX:-plasma}"
mkdir -p "$out"
log() { echo "smoke: $*"; }

sudo pacman -S --needed --noconfirm xorg-server-xvfb xorg-xwd imagemagick libnotify xdotool foot labwc >/dev/null 2>&1 \
  || { log "could not install the X tools"; exit 1; }
# foot is a dock launcher: resync the dock so it is pinned (Plasma is not running yet: config only)
stag-plasma-apply --quiet

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
  local xv kw ps ids t0 pids=()
  shot() { xwd -root -silent -display :5 | magick xwd:- "$out/$SHOT_PREFIX-$1.png" && log "shot $1"; }
  crop_bar() { magick "$out/$SHOT_PREFIX-$1.png" -crop 1706x40+0+0 "$out/$SHOT_PREFIX-$1-crop.png" 2>/dev/null; }
  js() { qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$1" 2>&1; }
  start_shell() {
    plasmashell --no-respawn >>"$out/plasmashell.log" 2>&1 & ps=$!
    t0=$SECONDS
    while [ $((SECONDS - t0)) -lt 240 ]; do
      kill -0 "$ps" 2>/dev/null || { log "plasmashell exited"; break; }
      ids="$(js 'panels().forEach(function (p) { p.widgets().forEach(function (w) {
          if (w.type == "org.stagos.status" || w.type == "org.stagos.menu") print(w.type + " " + w.id + "\n"); }); });')"
      ids="$(printf '%s' "$ids" | grep -oE 'org\.stagos\.[a-z]+ [0-9]+')"
      [ "$(printf '%s\n' "$ids" | grep -c '^org.stagos')" -ge 2 ] && break
      sleep 3
    done
    log "plasmashell up after $((SECONDS - t0)) s, widgets: $(printf '%s' "$ids" | tr '\n' ' ')"
    printf '%s\n' "$ids" > "$out/widgets.txt"
    # a global shortcut on each widget registers its "activate widget <id>" action with kglobalaccel
    js 'panels().forEach(function (p) { p.widgets().forEach(function (w) {
          if (w.type == "org.stagos.status") w.globalShortcut = "Ctrl+Alt+Shift+F11";
          if (w.type == "org.stagos.menu") w.globalShortcut = "Ctrl+Alt+Shift+F12"; }); });' >/dev/null
  }
  open_widget() { # type: toggle its popup
    local id
    id="$(awk -v t="$1" '$1 == t {print $2; exit}' "$out/widgets.txt")"
    [ -n "$id" ] || { log "no $1 in the layout"; return 1; }
    qdbus6 org.kde.kglobalaccel /component/plasmashell org.kde.kglobalaccel.Component.invokeShortcut "activate widget $id" >/dev/null 2>&1
  }
  runs() { # FILE row|col N: color runs along one pixel row/column (what the window edge is made of)
    local geo; if [ "$2" = row ]; then geo="1706x1+0+$3"; else geo="1x960+$3+0"; fi
    magick "$1" -crop "$geo" +repage -depth 8 rgb:- 2>/dev/null | python3 -c '
import sys
b = sys.stdin.buffer.read(); px = [tuple(b[i:i + 3]) for i in range(0, len(b) - 2, 3)]; last = None
for i, c in enumerate(px + [None]):
    if c != last:
        if last is not None: print("%d..%d #%02x%02x%02x" % ((start, i - 1) + last))
        start, last = i, c'
  }
  appmenu() { # true|false: desktop.conf [bar] appmenu, then what the settings path unit would run
    sed -i "s/^appmenu=.*/appmenu=$1/" "$HOME/.config/stagos/desktop.conf"
    stag-plasma-apply 2>&1 | sed 's/^/  apply: /'
  }
  bar_order() { # applet plugin names of the StagOS top bar, in its saved AppletOrder
    js "$dockjs"'; var b = stagosFindPanel("bar"); b.currentConfigGroup = ["General"]; var o = String(b.readConfig("AppletOrder", "")).split(";");
        var n = {}; b.widgets().forEach(function (w) { n[String(w.id)] = w.type; });
        print(o.map(function (i) { return n[i] || ("?" + i); }).join(" "));' 2>&1 | tail -1
  }
  dockjs="$(cat "$HOME/.local/share/stagos/plasma/dock.js")"

  Xvfb :5 -screen 0 1706x960x24 >"$out/xvfb.log" 2>&1 & xv=$!
  sleep 2
  env -u WAYLAND_DISPLAY -u QT_QPA_PLATFORM DISPLAY=:5 kwin_wayland --x11-display :5 --width 1706 --height 960 --socket wayland-9 --no-lockscreen \
    >"$out/kwin.log" 2>&1 & kw=$!
  for _ in $(seq 40); do [ -S "$XDG_RUNTIME_DIR/wayland-9" ] && break; sleep 0.5; done
  log "kwin alive: $(kill -0 "$kw" 2>/dev/null && echo yes || echo no)"
  start_shell
  # what the Plasma autostart does at login: first-login layout check, dock sync
  stag-plasma-apply --session 2>&1 | sed 's/^/  apply --session: /'
  sleep 20   # widgets paint, first stag-status poll returns
  shot desktop

  # a window: the hairline border must separate it from the black desktop
  foot --window-size-pixels=900x500 >/dev/null 2>&1 & pids+=($!)
  sleep 6; shot window
  log "window edge, row 300 (color runs, desktop #0a0a0a left out):"; runs "$out/$SHOT_PREFIX-window.png" row 300 | grep -v ' #0a0a0a$' | head -8
  log "window edge, column 420 (title bar of the active window, then its content):"; runs "$out/$SHOT_PREFIX-window.png" col 420 | head -8
  # shellcheck disable=SC1091
  [ -f "$out/experiment.sh" ] && . "$out/experiment.sh"

  # Overview (Mission Control): Meta+Tab owns the key (no activity switcher on it)
  log "global shortcuts on Tab / Overview:"; grep -nE 'Tab|^Overview|activity' "$HOME/.config/kglobalshortcutsrc" | sed 's/^/  /'
  DISPLAY=:5 xdotool key super+Tab; sleep 4; shot overview
  if cmp -s <(magick "$out/$SHOT_PREFIX-overview.png" -resize 64x36 txt:- 2>/dev/null) <(magick "$out/$SHOT_PREFIX-window.png" -resize 64x36 txt:- 2>/dev/null); then
    log "Meta+Tab via xdotool did not reach KWin; invoking Overview through kglobalaccel"
    qdbus6 org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut Overview >/dev/null 2>&1
    sleep 4; shot overview
  fi
  qdbus6 org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut Overview >/dev/null 2>&1; sleep 3

  # a big window over the dock: the dock dodges it
  foot --window-size-pixels=1600x880 >/dev/null 2>&1 & pids+=($!)
  sleep 6; shot window-dodge
  kill "${pids[@]}" 2>/dev/null; pids=(); sleep 3

  if open_widget org.stagos.status || DISPLAY=:5 xdotool mousemove 1600 12 click 1; then
    sleep 6; shot control-center
    open_widget org.stagos.status || DISPLAY=:5 xdotool mousemove 1600 12 click 1; sleep 2
  fi
  if open_widget org.stagos.menu || DISPLAY=:5 xdotool mousemove 20 12 click 1; then
    sleep 4; shot stag-menu
    DISPLAY=:5 xdotool mousemove 80 52 click 1; sleep 3; shot stag-menu-about   # "About This Computer"
    open_widget org.stagos.menu || DISPLAY=:5 xdotool mousemove 20 12 click 1; sleep 2
  fi

  # Night Light against the real KWin (D-Bus properties, Mode=Constant); X11-nested KWin may report it unavailable
  log "night light: $(stag-ctl night status) -> on: $(stag-ctl night on) -> $(sleep 2; stag-ctl night status) -> off: $(stag-ctl night off)"
  log "kwinrc NightColor: $(kreadconfig6 --file kwinrc --group NightColor --key Mode) / $(kreadconfig6 --file kwinrc --group NightColor --key Active)"

  # notifications: popups must show with the notifications applet hidden in the tray, and not with DND on
  notify-send -a StagOS "StagOS smoke" "notification popup with the tray applet hidden"; sleep 3; shot notify
  stag-ctl dnd on > "$out/dnd.json"; sleep 2
  notify-send -a StagOS "StagOS smoke" "this one must NOT pop up (Do Not Disturb)"; sleep 3; shot notify-dnd
  stag-ctl dnd off >/dev/null

  # [bar] appmenu: live off/on; a Qt app with a menu bar exports it to the global menu
  log "bar before: $(bar_order); STAG menu geometry: $(js "$dockjs"'; var m = stagosFindPanel("bar").widgets("org.stagos.menu")[0]; print(JSON.stringify(m.geometry));' 2>&1 | tail -1)"
  "$(command -v qdbusviewer6 || echo /usr/lib/qt6/bin/qdbusviewer)" >/dev/null 2>&1 & pids+=($!)
  sleep 8; shot appmenu-on-start; crop_bar appmenu-on-start
  appmenu false; sleep 3; log "bar appmenu=false: $(bar_order)"; shot appmenu-off; crop_bar appmenu-off
  appmenu true; sleep 5; log "bar appmenu=true: $(bar_order)"; shot appmenu-on; crop_bar appmenu-on
  kill "$ps" 2>/dev/null; wait "$ps" 2>/dev/null; start_shell; sleep 10
  log "bar after a plasmashell restart: $(bar_order)"; shot appmenu-restart; crop_bar appmenu-restart
  kill "${pids[@]}" 2>/dev/null; pids=()

  # StagOS Settings, and System Settings with its StagOS entry
  stag-settings >"$out/stag-settings.log" 2>&1 & pids+=($!)
  sleep 15; shot settings
  kill "${pids[@]}" 2>/dev/null; pids=(); sleep 2
  systemsettings >"$out/systemsettings.log" 2>&1 & pids+=($!)
  sleep 25; shot systemsettings
  DISPLAY=:5 xdotool key ctrl+f; sleep 1; DISPLAY=:5 xdotool type --delay 80 StagOS; sleep 4; shot systemsettings-search
  kill "${pids[@]}" 2>/dev/null; pids=()

  cp "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" "$out/appletsrc.txt" 2>/dev/null
  cp "$HOME/.config/kglobalshortcutsrc" "$out/kglobalshortcutsrc.txt" 2>/dev/null
  kill "$ps" 2>/dev/null; sleep 2; kill "$kw" 2>/dev/null; sleep 1; kill "$xv" 2>/dev/null
  wait 2>/dev/null
}
export -f session log
export out SHOT_PREFIX
timeout 900 dbus-run-session -- bash -c session
log "plasmashell lines about org.stagos:"
grep -a -iE 'org\.stagos|stagos.*(error|warn)' "$out/plasmashell.log" | head -30
log "stag-settings / systemsettings warnings:"
grep -a -iE 'error|warn' "$out/stag-settings.log" "$out/systemsettings.log" 2>/dev/null | head -12

# labwc through stag-session, headless: the tty1 path still starts labwc
stag-session labwc >/dev/null
rm -rf /tmp/xdg-labwc; install -d -m 700 /tmp/xdg-labwc
env -u WAYLAND_DISPLAY -u DISPLAY -u QT_QPA_PLATFORM XDG_RUNTIME_DIR=/tmp/xdg-labwc WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
  timeout 8 stag-session start > "$out/labwc.log" 2>&1; rc=$?
log "labwc via stag-session: rc=$rc (124 = still running when the timeout stopped it), session.log: $(tail -1 "$HOME/.cache/stagos/session.log")"
if [ "$rc" = 124 ] && grep -q 'start labwc: labwc (default)' "$HOME/.cache/stagos/session.log"; then log "labwc via stag-session: PASS"
else log "labwc via stag-session: FAIL"; head -20 "$out/labwc.log"; fi
stag-session plasma >/dev/null
rm -rf "$fk"
ls -la "$out"
