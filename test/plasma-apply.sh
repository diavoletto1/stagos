#!/usr/bin/env bash
# stag-plasma-apply and stag-settings-apply against fake kwriteconfig6 / kreadconfig6 (real INI files in a
# temp HOME, test/fixtures/bin/fake-kconfig), a fake qdbus6 and a fake plasmashell. No Plasma, no display.
#   ./test/plasma-apply.sh
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
T="$(mktemp -d)"; trap 'rm -rf "${T:?}"' EXIT
pass=0; fail=0
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi; }
APPLY="$ROOT/desktop/bin/stag-plasma-apply.sh"
WRAP="$ROOT/desktop/plasma/settings/stag-settings-apply.sh"
ORIG_PATH="$PATH"

sandbox() { # fresh HOME with fakes first on PATH; $1 = "up" when Plasma answers on D-Bus
  rm -rf "${T:?}/h" "${T:?}/bin" "${T:?}/fake" "${T:?}/share" "${T:?}/run"
  mkdir -p "$T/h" "$T/bin" "$T/fake" "$T/share/applications" "$T/h/.local/share/applications" "$T/run"
  export HOME="$T/h" FAKE_DIR="$T/fake" FAKE_LOG="$T/fake/log" XDG_DATA_DIRS="$T/share" XDG_RUNTIME_DIR="$T/run"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME; : > "$FAKE_LOG"
  ln -s "$ROOT/test/fixtures/bin/fake-kconfig" "$T/bin/kwriteconfig6"; ln -s "$ROOT/test/fixtures/bin/fake-kconfig" "$T/bin/kreadconfig6"
  ln -s "$ROOT/test/fixtures/bin/fake-cmd" "$T/bin/qdbus6"; ln -s "$ROOT/test/fixtures/bin/fake-cmd" "$T/bin/plasmashell"
  PATH="$T/bin:$ORIG_PATH"
  if [ "${1:-}" = up ]; then echo 'stagos-layout: yes' > "$FAKE_DIR/qdbus6.out"; else echo 1 > "$FAKE_DIR/qdbus6.rc"; fi
  export STAGOS_PLASMA_DATA="$ROOT/desktop/plasma" STAGOS_DESKTOP_CONF="$T/h/dc.conf"
  local a; for a in foot chromium thunar stag-mon; do printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$a" "$a" > "$T/share/applications/$a.desktop"; done
}
kr() { kreadconfig6 --file "$1" --group "$2" --key "$3"; }
conf() { printf '%s\n' "$@" > "$STAGOS_DESKTOP_CONF"; }
LAY() { echo "$HOME/.local/share/plasma/look-and-feel/org.stagos.desktop/contents/layouts/org.kde.plasma.desktop-layout.js"; }
hashes() { find "$@" -type f | sort | xargs -r md5sum; }

# ---- defaults (no desktop.conf at all) ----
sandbox; rm -f "$STAGOS_DESKTOP_CONF"
out="$("$APPLY" 2>&1)"
check "defaults: blur on"                test "$(kr kwinrc Plugins blurEnabled)" = true
check "defaults: animation factor 0.7"   test "$(kr kdeglobals KDE AnimationDurationFactor)" = 0.7
check "defaults: dock from desktop.conf.default, installed ones kept" bash -c "grep -q 'foot.desktop' '$(LAY)' && grep -q 'chromium.desktop' '$(LAY)' && grep -q 'stag-mon.desktop' '$(LAY)'"
check "defaults: two dock groups (separator)" bash -c "grep -q 'var STAGOS_DOCK = \[\[.*\],\[.*\]\];' '$(LAY)'"
check "defaults: missing launchers skipped with a warning" bash -c "grep -q 'skipping obsidian.desktop' <<< '$out' && grep -q 'skipping org.wireshark.Wireshark.desktop' <<< '$out'"
check "defaults: exit 0 without Plasma running, says it skipped" bash -c "grep -q 'Plasma is not running' <<< '$out' && grep -q 'KWin is not running' <<< '$out'"
check "defaults: exit code 0" bash -c "'$APPLY' >/dev/null 2>&1"
check "defaults: no D-Bus call except the probe" bash -c "! grep -E '^qdbus6 .*(evaluateScript|reconfigure|loadLookAndFeel)' '$FAKE_LOG'"
check "defaults: does not touch [bar] or [session] keys" bash -c "! grep -E 'stag_menu|appmenu|clock_format' '$FAKE_LOG'"

# ---- each toggle ----
sandbox
conf '[effects]' 'blur=false' 'animation_factor=1.0'
"$APPLY" --quiet >/dev/null 2>&1
check "toggle: blur=false"               test "$(kr kwinrc Plugins blurEnabled)" = false
check "toggle: factor 1.0 (slow)"        test "$(kr kdeglobals KDE AnimationDurationFactor)" = 1.0
conf '[effects]' 'blur=true' 'animation_factor=0.4'
"$APPLY" --quiet >/dev/null 2>&1
check "toggle: blur=true again"          test "$(kr kwinrc Plugins blurEnabled)" = true
check "toggle: factor 0.4 (fast)"        test "$(kr kdeglobals KDE AnimationDurationFactor)" = 0.4
conf '[effects]' 'blur=no' 'animation_factor=0'
"$APPLY" --quiet >/dev/null 2>&1
check "toggle: blur=no counts as off"    test "$(kr kwinrc Plugins blurEnabled)" = false
check "toggle: factor 0 accepted"        test "$(kr kdeglobals KDE AnimationDurationFactor)" = 0
conf '[effects]' 'blur=on' 'animation_factor=fast'
out="$("$APPLY" 2>&1)"
check "toggle: blur=on counts as on"     test "$(kr kwinrc Plugins blurEnabled)" = true
check "toggle: junk factor -> 0.7" test "$(kr kdeglobals KDE AnimationDurationFactor)" = 0.7
check "toggle: junk factor warns" grep -q "is not a number" <<< "$out"
conf '[effects]' 'blur=false'
"$APPLY" --quiet >/dev/null 2>&1
check "toggle: missing animation_factor -> default 0.7" test "$(kr kdeglobals KDE AnimationDurationFactor)" = 0.7
conf '[dock]' 'launchers=foot.desktop;|;thunar.desktop'
"$APPLY" --quiet >/dev/null 2>&1
check "dock: custom list, separator kept, others dropped" bash -c "grep -q 'var STAGOS_DOCK = \[\[{id: \"foot.desktop\", path: \"[^\"]*\"}\],\[{id: \"thunar.desktop\"' '$(LAY)' && ! grep -q chromium '$(LAY)'"
check "dock: a remember rule per dock app" bash -c "kreadconfig6 --file kwinrulesrc --group General --key rules | grep -q 'stagos-foot,stagos-thunar'"
conf '[dock]' 'launchers='
check "dock: empty list is fine" bash -c "'$APPLY' --quiet >/dev/null 2>&1 && grep -q 'var STAGOS_DOCK = \[\[\]\];' '$(LAY)'"

conf '[bar]' 'appmenu=false'
"$APPLY" --quiet >/dev/null 2>&1
check "appmenu=false: the first-start layout leaves it out" grep -q '^var STAGOS_APPMENU = false;' "$(LAY)"
conf '[bar]' 'appmenu=true'
"$APPLY" --quiet >/dev/null 2>&1
check "appmenu=true: the first-start layout has it" grep -q '^var STAGOS_APPMENU = true;' "$(LAY)"
check "layout.js: appmenu only when STAGOS_APPMENU allows it" grep -q 'STAGOS_APPMENU' "$ROOT/desktop/plasma/layout.js"

# ---- --dry-run writes nothing ----
sandbox; conf '[effects]' 'blur=false'
before="$(hashes "$HOME")"
out="$("$APPLY" --dry-run 2>&1)"; rc=$?
check "dry-run: exits 0 and prints the plan" bash -c "test $rc -eq 0 && grep -q '\[dry\]' <<< '$out'"
check "dry-run: no kwriteconfig6 call" bash -c "! grep -q '^kwriteconfig6' '$FAKE_LOG'"
check "dry-run: no file written or changed" test "$before" = "$(hashes "$HOME")"
"$APPLY" --base --dry-run >/dev/null 2>&1
check "dry-run --base: no kwriteconfig6 call either" bash -c "! grep -q '^kwriteconfig6' '$FAKE_LOG'"

# ---- second run is a no-op ----
sandbox; conf '[effects]' 'blur=true' 'animation_factor=0.7'
out1="$("$APPLY" --base 2>&1)"
check "idempotent: first run changes files" bash -c "grep -qE 'done \([1-9][0-9]* config file' <<< '$out1'"
before="$(hashes "$HOME/.config" "$HOME/.local/share")"
out2="$("$APPLY" --base 2>&1)"
check "idempotent: second run changes 0 files" bash -c "grep -q 'done (0 config file(s) changed)' <<< '$out2'"
check "idempotent: second run leaves every file byte-identical" test "$before" = "$(hashes "$HOME/.config" "$HOME/.local/share")"
check "idempotent: same without --base" bash -c "'$APPLY' 2>&1 | grep -q 'done (0 config file(s) changed)'"
conf '[effects]' 'blur=false'
check "changing one value changes exactly the file it lives in" bash -c "'$APPLY' 2>&1 | grep -q 'done (1 config file(s) changed)'"

# ---- Plasma running ----
sandbox up; conf '[effects]' 'blur=true'
"$APPLY" --quiet >/dev/null 2>&1
check "plasma up: KWin reconfigured" grep -q '^qdbus6 org.kde.KWin /KWin reconfigure' "$FAKE_LOG"
: > "$FAKE_LOG"; "$APPLY" --quiet >/dev/null 2>&1
check "plasma up: later runs sync the dock, never reload the layout" bash -c "grep -q stagosSyncDock '$FAKE_LOG' && ! grep -q loadLookAndFeel '$FAKE_LOG'"
check "plasma up: later runs sync the appmenu live" bash -c "grep -q 'stagosSyncAppmenu(STAGOS_APPMENU)' '$FAKE_LOG' && grep -q 'var STAGOS_APPMENU = true;' '$FAKE_LOG'"
conf '[bar]' 'appmenu=false'; : > "$FAKE_LOG"; "$APPLY" --quiet >/dev/null 2>&1
check "plasma up: appmenu=false reaches the shell" grep -q 'var STAGOS_APPMENU = false;' "$FAKE_LOG"
: > "$FAKE_LOG"; "$APPLY" --quiet --reset-layout >/dev/null 2>&1
check "plasma up: --reset-layout reloads the layout" grep -q loadLookAndFeelDefaultLayout "$FAKE_LOG"

# ---- stag-settings-apply (the path unit's service) ----
sandbox; mkdir -p "$HOME/.local/state/stagos"
# shellcheck disable=SC2016  # literal $* for the fake script
printf '#!/bin/sh\necho "stag-plasma-apply $*" >> "$FAKE_LOG"\n' > "$T/bin/stag-plasma-apply"; chmod +x "$T/bin/stag-plasma-apply"
"$WRAP"
check "settings-apply: plain change runs --quiet only" bash -c "grep -qx 'stag-plasma-apply --quiet' '$FAKE_LOG' && ! grep -q reset-layout '$FAKE_LOG'"
: > "$FAKE_LOG"; echo "reset-layout now" > "$HOME/.local/state/stagos/reset-layout.request"
"$WRAP"
check "settings-apply: request runs --reset-layout" grep -qx 'stag-plasma-apply --quiet --reset-layout' "$FAKE_LOG"
check "settings-apply: request file consumed" test ! -e "$HOME/.local/state/stagos/reset-layout.request"
: > "$FAKE_LOG"; "$WRAP"
check "settings-apply: next run is plain again" bash -c "! grep -q reset-layout '$FAKE_LOG'"

# ---- the path unit watches what the app writes ----
U="$ROOT/desktop/plasma/settings/units/stagos-desktop-apply.path"
check "path unit: watches desktop.conf" grep -q '^PathChanged=%E/stagos/desktop.conf' "$U"
check "path unit: watches the reset request" grep -q '^PathExists=%S/stagos/reset-layout.request' "$U"

echo; echo "plasma-apply: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
