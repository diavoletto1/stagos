#!/usr/bin/env bash
# Unit tests for the desktop helper scripts and config invariants. No display, no root, no packages:
# external tools are replaced by test/fixtures/bin/fake-cmd. Run: ./test/desktop-scripts.sh
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
BIN="$ROOT/desktop/bin"
FAKE="$ROOT/test/fixtures/bin/fake-cmd"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { # check "name" command...
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi
}
# sandbox: fresh fake dir with the given tools on PATH
sandbox() {
  rm -rf "${T:?}/fake" "${T:?}/bin"; mkdir -p "$T/fake" "$T/bin"
  export FAKE_DIR="$T/fake" FAKE_LOG="$T/fake/log" HOME="$T/home"
  # CI runners may export XDG_*; helpers must resolve under the sandbox HOME
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  mkdir -p "$HOME"; : > "$FAKE_LOG"
  local t; for t in "$@"; do ln -s "$FAKE" "$T/bin/$t"; done
  PATH="$T/bin:$ORIG_PATH"
}
# helpers call each other by their installed names (stag-nightlight, stag-lock): a shim dir maps them
mkdir -p "$T/shim"
for f in "$BIN"/stag-*.sh; do ln -s "$f" "$T/shim/$(basename "$f" .sh)"; done
BIN="$T/shim"; ORIG_PATH="$T/shim:$PATH"

# ---- stag-toggle ----
sandbox nmcli bluetoothctl rfkill pgrep pkill setsid wlsunset
echo enabled > "$FAKE_DIR/nmcli.out"
check "toggle wifi status true"  test "$(stag-toggle wifi status)" = true
echo disabled > "$FAKE_DIR/nmcli.out"
check "toggle wifi status false" test "$(stag-toggle wifi status)" = false
echo "Powered: yes" > "$FAKE_DIR/bluetoothctl.out"
check "toggle bt status true"    test "$(stag-toggle bluetooth status)" = true
: > "$FAKE_DIR/bluetoothctl.out"
check "toggle bt status false"   test "$(stag-toggle bluetooth status)" = false
stag-toggle bluetooth toggle >/dev/null 2>&1
check "toggle bt off->on unblocks + powers on" grep -q 'bluetoothctl power on' "$FAKE_LOG"
echo 1 > "$FAKE_DIR/pgrep.rc"
check "nightlight status false"  test "$(stag-nightlight status)" = false
echo 0 > "$FAKE_DIR/pgrep.rc"
check "nightlight status true"   test "$(stag-nightlight status)" = true
echo 1 > "$FAKE_DIR/pgrep.rc"; : > "$FAKE_LOG"
stag-nightlight start >/dev/null 2>&1
check "nightlight start uses Tampa defaults" grep -q 'wlsunset -l 27.95 -L -82.46' "$FAKE_LOG"
check "stag-toggle rejects junk" bash -c "! '$BIN/stag-toggle' bogus"

# ---- stag-battery ----
sandbox notify-send
mkdir -p "$T/ps/BAT0"; export STAGOS_BAT_SYS="$T/ps" STAGOS_BAT_ONCE=1
bat() { echo "$1" > "$T/ps/BAT0/capacity"; echo "$2" > "$T/ps/BAT0/status"; : > "$FAKE_LOG"; stag-battery; }
bat 50 Discharging;  check "battery 50% silent"        test ! -s "$FAKE_LOG"
bat 18 Discharging;  check "battery 18% notifies"      grep -q 'notify-send -u normal' "$FAKE_LOG"
bat 8 Discharging;   check "battery 8% critical"       grep -q 'notify-send -u critical' "$FAKE_LOG"
bat 8 Charging;      check "battery charging silent"   test ! -s "$FAKE_LOG"
unset STAGOS_BAT_SYS STAGOS_BAT_ONCE

# ---- stag-screenshot ----
sandbox grim slurp swappy wl-copy notify-send
export STAGOS_SHOT_DIR="$T/shots"
# grim must leave a file behind (last argument), like the real one
rm "$T/bin/grim"
cat > "$T/bin/grim" <<'GRIM'
#!/bin/bash
echo "grim $*" >> "$FAKE_LOG"
for a; do f="$a"; done
echo png > "$f"
GRIM
chmod +x "$T/bin/grim"
stag-screenshot full
check "screenshot full writes cmd"   grep -q "^grim $T/shots/.*\.png" "$FAKE_LOG"
check "screenshot copies + notifies" bash -c "grep -q '^wl-copy' '$FAKE_LOG' && grep -q '^notify-send' '$FAKE_LOG'"
echo "10,20 30x40" > "$FAKE_DIR/slurp.out"; : > "$FAKE_LOG"
stag-screenshot region
check "screenshot region passes geometry" grep -q '^grim -g 10,20 30x40 ' "$FAKE_LOG"
echo 1 > "$FAKE_DIR/slurp.rc"; : > "$FAKE_LOG"
stag-screenshot region
check "screenshot region cancelled: no grim" bash -c "! grep -q '^grim' '$FAKE_LOG'"
unset STAGOS_SHOT_DIR

# ---- stag-spotlight routing ----
route() { # route <typed text> -> log
  sandbox fuzzel qalc wl-copy notify-send plocate xdg-open
  printf '%s\n' "$1" > "$FAKE_DIR/fuzzel.out"
  echo "42" > "$FAKE_DIR/qalc.out"
  stag-spotlight >/dev/null 2>&1
}
route "= 6*7";        check "spotlight '=' -> qalc"      grep -q '^qalc -t  6\*7' "$FAKE_LOG"
route "2+2";          check "spotlight digits -> qalc"   grep -q '^qalc -t 2+2' "$FAKE_LOG"
route "/notes.md";    check "spotlight '/' -> plocate"   grep -q '^plocate -i -l 200 -- notes.md' "$FAKE_LOG"
route "f budget";     check "spotlight 'f ' -> plocate"  grep -q '^plocate -i -l 200 -- budget' "$FAKE_LOG"
route "chromium";     check "spotlight text -> fuzzel --search" grep -q '^fuzzel --search chromium' "$FAKE_LOG"

# ---- stag-menu ----
sandbox fuzzel chromium notify-send
printf 'tasks|https://h.invalid/tasks/\nmaps|https://h.invalid/maps/\n' > "$T/list"
echo maps > "$FAKE_DIR/fuzzel.out"
STAGOS_STAG_LIST="$T/list" stag-menu >/dev/null 2>&1
check "stag-menu opens chosen url as app" grep -q '^chromium --app=https://h.invalid/maps/' "$FAKE_LOG"
: > "$FAKE_LOG"; STAGOS_STAG_LIST="$T/none" stag-menu >/dev/null 2>&1
check "stag-menu without config notifies" grep -q '^notify-send Stag' "$FAKE_LOG"

# ---- stag-clip ----
sandbox cliphist fuzzel wl-copy
stag-clip pick >/dev/null 2>&1
check "clip pick pipes cliphist->fuzzel->wl-copy" bash -c "grep -q '^cliphist list' '$FAKE_LOG' && grep -q '^cliphist decode' '$FAKE_LOG' && grep -q '^wl-copy' '$FAKE_LOG'"

# ---- stag-session (tty1 session picker) ----
FS="$ROOT/test/fixtures/bin/fake-session"
session_sandbox() { # fresh HOME + fake startplasma/labwc; $1 = 1 when Plasma is "installed"
  sandbox
  mkdir -p "$T/sess"; rm -f "$T/sess/"*
  ln -s "$FS" "$T/sess/startplasma-wayland"; ln -s "$FS" "$T/bin/labwc"
  export STAGOS_STARTPLASMA="$T/sess/startplasma-wayland" STAGOS_LABWC=labwc
  export STAGOS_PLASMA_DBUS_WRAPPER="$ROOT/test/fixtures/bin/plasma-dbus-run-session-if-needed"
  export STAGOS_PLASMA_DATA="$ROOT/desktop/plasma"
  [ "${1:-1}" = 1 ] || rm -f "$T/sess/startplasma-wayland"
}
session_sandbox 1
check "session: default is plasma without desktop.conf" test "$(stag-session --status | head -1)" = default=plasma
stag-session start >/dev/null 2>&1
check "session: start runs startplasma through the dbus wrapper" bash -c "grep -q '^dbus-wrapper $T/sess/startplasma-wayland' '$FAKE_LOG' && grep -q '^startplasma-wayland' '$FAKE_LOG'"
check "session: clean plasma exit starts no labwc" bash -c "! grep -q '^labwc' '$FAKE_LOG'"
: > "$FAKE_LOG"; QT_QPA_PLATFORMTHEME=qt6ct GTK_THEME=Adwaita:dark stag-session start >/dev/null 2>&1
check "session: qt6ct never reaches Plasma" grep -q '^startplasma-wayland .*QT_QPA_PLATFORMTHEME= ' "$FAKE_LOG"
echo 1 > "$FAKE_DIR/startplasma-wayland.rc"; : > "$FAKE_LOG"
stag-session start >/dev/null 2>&1
check "session: 2 fast plasma failures -> labwc" bash -c "test \$(grep -c '^startplasma-wayland' '$FAKE_LOG') -eq 2 && grep -q '^labwc' '$FAKE_LOG'"
check "session: fallback logged" grep -q 'FALLBACK' "$HOME/.cache/stagos/session.log"
check "session: status shows the fallback" bash -c "stag-session --status | grep -q '^next=labwc (plasma failed 2x'"
: > "$FAKE_LOG"; stag-session start >/dev/null 2>&1
check "session: fallback sticks (no plasma retry)" bash -c "! grep -q '^startplasma-wayland' '$FAKE_LOG' && grep -q '^labwc' '$FAKE_LOG'"
stag-session plasma >/dev/null
check "session: 'stag-session plasma' clears the fallback" bash -c "stag-session --status | grep -qx 'fails=0'"
: > "$FAKE_LOG"; STAGOS_SESSION_FAST_SECS=0 stag-session start >/dev/null 2>&1
check "session: a slow plasma crash is not a fast failure" bash -c "grep -q '^startplasma-wayland' '$FAKE_LOG' && ! grep -q '^labwc' '$FAKE_LOG' && stag-session --status | grep -qx 'fails=0'"
cp "$ROOT/test/fixtures/plasma-desktop.conf" "$HOME/dc.conf"; export STAGOS_DESKTOP_CONF="$HOME/dc.conf"
stag-session labwc >/dev/null
check "session: labwc sets [session] default=labwc" test "$(stag-session --status | head -1)" = default=labwc
check "session: desktop.conf keeps comments and other sections" bash -c "grep -q '^# keep this comment' '$HOME/dc.conf' && grep -q '^blur=false' '$HOME/dc.conf' && test \$(grep -c '^default=' '$HOME/dc.conf') -eq 1"
: > "$FAKE_LOG"; stag-session start >/dev/null 2>&1
check "session: default labwc starts labwc only" bash -c "grep -q '^labwc' '$FAKE_LOG' && ! grep -q '^startplasma' '$FAKE_LOG'"
rm -f "$HOME/dc2.conf"; STAGOS_DESKTOP_CONF="$HOME/dc2.conf" stag-session plasma >/dev/null
check "session: creates desktop.conf with a [session] section" bash -c "grep -q '^\[session\]' '$HOME/dc2.conf' && grep -q '^default=plasma' '$HOME/dc2.conf'"
unset STAGOS_DESKTOP_CONF
session_sandbox 0
check "session: no Plasma installed -> labwc" bash -c "stag-session --status | grep -q '^next=labwc (plasma not installed)'"
stag-session start >/dev/null 2>&1
check "session: no Plasma installed starts labwc" grep -q '^labwc' "$FAKE_LOG"
check "session: rejects junk" bash -c "! stag-session bogus"
# notify-daemon: one owner for org.freedesktop.Notifications per session
session_sandbox 1
ln -s "$FS" "$T/bin/swaync"; ln -s "$FS" "$T/bin/plasma_waitforname"; export STAGOS_PLASMA_WAITFORNAME="$T/bin/plasma_waitforname"
XDG_CURRENT_DESKTOP=KDE stag-session notify-daemon
check "notify: Plasma waits for plasmashell" grep -q '^plasma_waitforname org.freedesktop.Notifications' "$FAKE_LOG"
: > "$FAKE_LOG"; XDG_CURRENT_DESKTOP=labwc:wlroots stag-session notify-daemon
check "notify: labwc gets swaync" grep -q '^swaync' "$FAKE_LOG"
unset STAGOS_PLASMA_WAITFORNAME STAGOS_STARTPLASMA STAGOS_LABWC STAGOS_PLASMA_DBUS_WRAPPER

# ---- stag-plasma-apply (kwriteconfig6/kreadconfig6/qdbus6 faked) ----
apply_sandbox() {
  sandbox kwriteconfig6 kreadconfig6 qdbus6
  export STAGOS_PLASMA_DATA="$ROOT/desktop/plasma" STAGOS_DESKTOP_CONF="$HOME/dc.conf" XDG_DATA_DIRS="$T/share"
  cp "$ROOT/test/fixtures/plasma-desktop.conf" "$HOME/dc.conf"
  mkdir -p "$T/share/applications" "$HOME/.local/share/applications"
  printf '[Desktop Entry]\nName=Foot\nExec=foot\n' > "$T/share/applications/foot.desktop"
  cp "$ROOT/desktop/share/stag-mon.desktop" "$HOME/.local/share/applications/"
}
LAY="$T/home/.local/share/plasma/look-and-feel/org.stagos.desktop/contents/layouts/org.kde.plasma.desktop-layout.js"
apply_sandbox; echo 1 > "$FAKE_DIR/qdbus6.rc"; echo 'mine,stagos-old' > "$FAKE_DIR/kreadconfig6.out"
out="$(stag-plasma-apply 2>&1)"
check "apply: missing launcher skipped with a warning" grep -q 'skipping missing-app.desktop' <<< "$out"
check "apply: odd launcher name ignored" grep -q "ignoring odd launcher name 'bad name.desktop'" <<< "$out"
check "apply: blur=false -> kwinrc" grep -q -- '--file kwinrc --group Plugins --key blurEnabled -- false' "$FAKE_LOG"
check "apply: bad animation_factor -> 0.7" grep -q -- '--key AnimationDurationFactor -- 0.7' "$FAKE_LOG"
check "apply: layout has both dock groups" grep -q 'var STAGOS_DOCK = \[\[{id: "foot.desktop", path: "'"$T"'/share/applications/foot.desktop"}\],\[{id: "stag-mon.desktop"' "$LAY"
check "apply: layout keeps the p2 widget slots" bash -c "for w in menu status control; do grep -qx \"// STAGOS_WIDGET \$w\" '$LAY' && grep -qx \"// END_STAGOS_WIDGET \$w\" '$LAY' || exit 1; done"
check "apply: remember rule per app, class from StartupWMClass" grep -q -- '--group stagos-stag-mon --key wmclass -- (?i)^stag-mon\$' "$FAKE_LOG"
check "apply: rule remembers position" grep -q -- '--group stagos-foot --key positionrule -- 4' "$FAKE_LOG"
check "apply: keeps Jack's rules, drops stale stagos-*" grep -q -- '--group General --key rules -- mine,stagos-foot,stagos-stag-mon' "$FAKE_LOG"
check "apply: Plasma down -> no D-Bus calls beyond the probe" bash -c "! grep -q 'evaluateScript\|reconfigure\|loadLookAndFeel' '$FAKE_LOG'"
check "apply: no base look without --base" bash -c "! grep -q 'LookAndFeelPackage' '$FAKE_LOG'"
: > "$FAKE_LOG"; stag-plasma-apply --base --quiet >/dev/null 2>&1
check "apply --base: global theme + colors + shortcuts" bash -c "grep -q -- '--key LookAndFeelPackage -- org.stagos.desktop' '$FAKE_LOG' && grep -q -- '--group Colors:Window --key BackgroundNormal -- 10,10,10' '$FAKE_LOG' && grep -q -- '--group Colors:Header --group Inactive' '$FAKE_LOG' && grep -q -- \"--group kwin --key Overview -- Meta+Tab\"\$'\t'\"Ctrl+Up\" '$FAKE_LOG' && grep -q -- '--group plasmashell --key next activity -- none,' '$FAKE_LOG'"
check "apply --base: buttons on the right" grep -q -- '--key ButtonsOnRight -- IAX' "$FAKE_LOG"
: > "$FAKE_LOG"; stag-plasma-apply --base --dry-run >/dev/null 2>&1
check "apply --dry-run writes nothing" bash -c "! grep -q '^kwriteconfig6' '$FAKE_LOG'"
# Plasma running: first run loads the layout, later runs only sync the dock
apply_sandbox; echo 'stagos-layout: no' > "$FAKE_DIR/qdbus6.out"
stag-plasma-apply --quiet >/dev/null 2>&1
check "apply: first run with Plasma loads the StagOS layout" grep -q 'loadLookAndFeelDefaultLayout org.stagos.desktop' "$FAKE_LOG"
check "apply: marker written" test -s "$HOME/.local/state/stagos/plasma-layout-applied"
check "apply: KWin reconfigured" grep -q '^qdbus6 org.kde.KWin /KWin reconfigure' "$FAKE_LOG"
: > "$FAKE_LOG"; stag-plasma-apply --quiet >/dev/null 2>&1
check "apply: normal run never reloads the layout" bash -c "! grep -q loadLookAndFeel '$FAKE_LOG' && grep -q 'stagosSyncDock' '$FAKE_LOG'"
: > "$FAKE_LOG"; stag-plasma-apply --reset-layout --quiet >/dev/null 2>&1
check "apply --reset-layout with Plasma reloads" grep -q loadLookAndFeelDefaultLayout "$FAKE_LOG"
# Plasma not running: --reset-layout moves the layout aside for the next start
echo 1 > "$FAKE_DIR/qdbus6.rc"; echo '[x]' > "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
stag-plasma-apply --reset-layout --quiet >/dev/null 2>&1
check "apply --reset-layout offline: old layout moved aside, marker cleared" bash -c "ls '$HOME'/.config/plasma-org.kde.plasma.desktop-appletsrc.stagos-bak-* && test ! -e '$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc' && test ! -e '$HOME/.local/state/stagos/plasma-layout-applied'"
sandbox
if ! command -v kwriteconfig6 >/dev/null 2>&1; then   # only meaningful where Plasma is really absent
  check "apply: without Plasma installed exits 0" bash -c "STAGOS_PLASMA_DATA='$ROOT/desktop/plasma' stag-plasma-apply 2>&1 | grep -q 'Plasma is not installed'"
fi
unset STAGOS_PLASMA_DATA STAGOS_DESKTOP_CONF XDG_DATA_DIRS

# ---- plasma data invariants ----
P="$ROOT/desktop/plasma"
check "base.kconf: every line is file|group|key|value" bash -c "grep -vE '^(#|$)' '$P/base.kconf' | awk -F'|' 'NF < 4 { bad = 1 } END { exit bad }'"
check "base.kconf: no hot corner, no wobbly/magic lamp/translucency" bash -c "grep -q '^kwinrc|Effect-overview|BorderActivate|9$' '$P/base.kconf' && for e in wobblywindows magiclamp translucency; do grep -q \"^kwinrc|Plugins|\${e}Enabled|false$\" '$P/base.kconf' || exit 1; done"
check "StagOS.colors uses the contract palette" bash -c "grep -q 'BackgroundNormal=10,10,10' '$P/StagOS.colors' && grep -q 'DecorationFocus=200,16,46' '$P/StagOS.colors' && grep -q 'ForegroundNormal=240,240,240' '$P/StagOS.colors'"
check "desktop.conf.default: contract sections" bash -c "for s in session bar dock effects recon; do grep -qx \"\\[\$s\\]\" '$P/desktop.conf.default' || exit 1; done"
check "layout.js: dock dodges windows, bar is 26px" bash -c "grep -q 'dock.hiding = \"dodgewindows\"' '$P/layout.js' && grep -q 'bar.height = 26' '$P/layout.js'"

# ---- config invariants ----
RC="$ROOT/desktop/labwc/rc.xml"
# keys keyd owns must never also be plain labwc Super binds
for k in c v x z a q w t f s; do
  check "rc.xml has no bare W-$k bind (keyd owns it)" bash -c "! grep -q 'key=\"W-$k\"' '$RC'"
done
check "rc.xml: Super+Shift+V clipboard picker" grep -q 'key="W-S-v"' "$RC"
check "rc.xml: screenshot binds 3/4"   bash -c "grep -q 'key=\"W-S-3\"' '$RC' && grep -q 'key=\"W-S-4\"' '$RC'"
check "rc.xml: touchpad tap + natural scroll" bash -c "grep -q '<tap>yes' '$RC' && grep -q '<naturalScroll>yes' '$RC'"
check "keyd map covers the ten Cmd keys" bash -c "for k in c v x z a q w t f s; do grep -q \"^\$k = C-\" '$ROOT/desktop/keyd/default.conf' || exit 1; done"
check "foot never gets bare Ctrl from Cmd" bash -c "! sed -n '/^\[foot\]/,\$p' '$ROOT/desktop/keyd/app.conf' | grep -E '= C-[a-z]\$'"
check "no em dashes in tracked text" bash -c "cd '$ROOT' && ! grep -rlI --exclude-dir=.git \$'\xe2\x80\x94' . | grep -q ."
check "no CDN/external urls in desktop css" bash -c "! grep -rE 'https?://' '$ROOT/desktop/swaync' '$ROOT/desktop/swayosd' '$ROOT/desktop/waybar-dock/style.css' '$ROOT/desktop/waybar/style.css'"

# ---- snapshots module: backup.env must survive sourcing with hostile repo strings ----
sandbox
BE=$(bash "$ROOT/test/fixtures/snapshots-env.sh" "$ROOT" "$HOME")
# shellcheck disable=SC2016  # literal $ and backtick on purpose
check "backup.env round-trips a repo with dollar, quote, backtick, space" test "$BE" = 'rest:https://u:p$w"x`id`@h/a b'
check "backup.env is mode 600" test "$(stat -c %a "$HOME/.config/stagos/backup.env")" = 600

echo; echo "desktop-scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
