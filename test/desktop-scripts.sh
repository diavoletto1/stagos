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
