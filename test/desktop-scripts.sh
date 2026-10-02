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
# helpers are called by their installed names (stag-session, stag-plasma-apply): a shim dir maps them
mkdir -p "$T/shim"
for f in "$BIN"/stag-*.sh; do ln -s "$f" "$T/shim/$(basename "$f" .sh)"; done
BIN="$T/shim"; ORIG_PATH="$T/shim:$PATH"

# ---- stag-session (tty1: Plasma, or a plain shell after two fast failures) ----
FS="$ROOT/test/fixtures/bin/fake-session"
session_sandbox() { # fresh HOME + fake startplasma; $1 = 1 when Plasma is "installed"
  sandbox
  mkdir -p "$T/sess"; rm -f "$T/sess/"*
  ln -s "$FS" "$T/sess/startplasma-wayland"
  export STAGOS_STARTPLASMA="$T/sess/startplasma-wayland" STAGOS_BOOT_ID=boot-1
  # the fallback login shell: logs how it was started (args, STAGOS_NO_SESSION), never a real shell
  # shellcheck disable=SC2016  # expands inside the fake shell, not here
  printf '#!/bin/sh\necho "login-shell $* NO_SESSION=$STAGOS_NO_SESSION" >> "$FAKE_LOG"\n' > "$T/sess/login-shell"; chmod +x "$T/sess/login-shell"
  export STAGOS_PLASMA_DBUS_WRAPPER="$ROOT/test/fixtures/bin/plasma-dbus-run-session-if-needed"
  [ "${1:-1}" = 1 ] || rm -f "$T/sess/startplasma-wayland"
}
FAILS_F() { echo "$HOME/.cache/stagos/session-plasma-fails"; }
session_sandbox 1
check "session: next is plasma on a fresh HOME" bash -c "stag-session --status | grep -qx 'next=plasma'"
check "session: --status on a fresh HOME prints nothing on stderr (no missing fails file error)" bash -c "test -z \"\$(stag-session --status 2>&1 >/dev/null)\""
check "session: --status on a fresh HOME creates no cache dir (it only reads; stagos-desktop calls it under DRY_RUN too)" bash -c "test ! -e \"\${XDG_CACHE_HOME:-\$HOME/.cache}/stagos\""
STAGOS_SESSION_FAST_SECS=0 stag-session start >/dev/null 2>&1; rc=$?
check "session: start runs startplasma through the dbus wrapper" bash -c "grep -q '^dbus-wrapper $T/sess/startplasma-wayland' '$FAKE_LOG' && grep -q '^startplasma-wayland' '$FAKE_LOG'"
check "session: clean plasma exit returns 0, no shell (the tty1 login ends)" bash -c "test $rc = 0 && ! grep -q '^login-shell' '$FAKE_LOG'"
: > "$FAKE_LOG"; QT_QPA_PLATFORMTHEME=kde STAGOS_SESSION_FAST_SECS=0 stag-session start >/dev/null 2>&1
check "session: the environment reaches Plasma untouched" grep -q '^startplasma-wayland .*QT_QPA_PLATFORMTHEME=kde ' "$FAKE_LOG"
: > "$FAKE_LOG"; STAGOS_LOGIN_SHELL="$T/sess/login-shell" stag-session start >/dev/null 2>&1
check "session: a fast clean exit (rc 0) twice also falls back (no tty1 loop)" bash -c "test \$(grep -c '^startplasma-wayland' '$FAKE_LOG') -eq 2 && grep -qx 'login-shell -l NO_SESSION=1' '$FAKE_LOG'"
rm -f "$(FAILS_F)"
: > "$FAKE_LOG"; STAGOS_NO_SESSION=1 STAGOS_LOGIN_SHELL="$T/sess/login-shell" stag-session start >/dev/null 2>&1
check "session: start from the fallback shell (old .zprofile block): no plasma, a non-login shell (no loop)" bash -c "! grep -q '^startplasma-wayland' '$FAKE_LOG' && grep -qx 'login-shell -i NO_SESSION=1' '$FAKE_LOG'"
echo 1 > "$FAKE_DIR/startplasma-wayland.rc"; : > "$FAKE_LOG"
err="$(stag-session start 2>&1 >/dev/null)"; rc=$?
check "session: 2 fast plasma failures, then stop (no third try)" test "$(grep -c '^startplasma-wayland' "$FAKE_LOG")" = 2
check "session: fallback without a terminal returns 1" test "$rc" = 1
: > "$FAKE_LOG"; STAGOS_LOGIN_SHELL="$T/sess/login-shell" STAGOS_BOOT_ID=boot-0 stag-session start >/dev/null 2>&1
check "session: fallback on tty1 execs a login shell with STAGOS_NO_SESSION=1 (no loop)" bash -c "test \$(grep -c '^startplasma-wayland' '$FAKE_LOG') -eq 2 && grep -qx 'login-shell -l NO_SESSION=1' '$FAKE_LOG'"
echo "2 boot-1" > "$(FAILS_F)"
check "session: fallback message says what failed, the log and how to retry" bash -c "grep -q 'Plasma failed to start 2 times' <<< \"\$1\" && grep -q 'session.log' <<< \"\$1\" && grep -q 'stag-session retry' <<< \"\$1\"" _ "$err"
check "session: fallback logged" grep -q 'FALLBACK' "$HOME/.cache/stagos/session.log"
check "session: status shows the fallback" bash -c "stag-session --status | grep -q '^next=shell (plasma failed 2x'"
: > "$FAKE_LOG"; stag-session start >/dev/null 2>&1; rc=$?
check "session: fallback sticks (no plasma retry, rc 1)" bash -c "! grep -q '^startplasma-wayland' '$FAKE_LOG' && test $rc = 1"
STAGOS_BOOT_ID=boot-2 stag-session --status > "$T/st" 2>&1
check "session: a reboot clears the fallback (counter is per boot)" grep -qx 'next=plasma' "$T/st"
SC="$HOME/.config/stagos/desktop.conf"; mkdir -p "${SC%/*}"; printf '[session]\ndefault=labwc\n' > "$SC"
check "session: an old [session] default=labwc is ignored" bash -c "STAGOS_BOOT_ID=boot-2 stag-session --status | grep -qx 'next=plasma'"
rm "$FAKE_DIR/startplasma-wayland.rc"; : > "$FAKE_LOG"
out="$(stag-session retry 2>&1)"
check "session: retry outside tty1 clears the counter and starts nothing" bash -c "grep -q 'fallback cleared' <<< \"\$1\" && ! grep -q startplasma '$FAKE_LOG' && stag-session --status | grep -qx 'fails=0'" _ "$out"
echo "2 boot-1" > "$(FAILS_F)"; : > "$FAKE_LOG"
STAGOS_NO_SESSION=1 STAGOS_SESSION_FORCE_START=1 STAGOS_SESSION_FAST_SECS=0 stag-session retry >/dev/null 2>&1; rc=$?
check "session: retry on tty1 starts Plasma now (in the foreground)" bash -c "grep -q '^startplasma-wayland' '$FAKE_LOG' && test $rc = 0 && ! grep -q '^login-shell' '$FAKE_LOG'"
echo 2 > "$(FAILS_F)"
check "session: an old counter without a boot id counts as 0" bash -c "stag-session --status | grep -qx 'fails=0'"
rm -f "$(FAILS_F)"; mkdir "$(FAILS_F)"; echo 1 > "$FAKE_DIR/startplasma-wayland.rc"
: > "$FAKE_LOG"; stag-session start >/dev/null 2>&1; rc=$?
check "session: unwritable fail counter still stops after 2 tries (no loop)" bash -c "test \$(grep -c '^startplasma-wayland' '$FAKE_LOG') -eq 2 && test $rc = 1"
rmdir "$(FAILS_F)"
: > "$FAKE_LOG"; STAGOS_SESSION_FAST_SECS=0 stag-session start >/dev/null 2>&1; rc=$?
check "session: a slow plasma crash is not a fast failure" bash -c "test \$(grep -c '^startplasma-wayland' '$FAKE_LOG') -eq 1 && test $rc = 0 && stag-session --status | grep -qx 'fails=0'"
session_sandbox 0
check "session: no Plasma installed -> shell" bash -c "stag-session --status | grep -q '^next=shell (plasma not installed'"
stag-session start >/dev/null 2>&1; rc=$?
check "session: no Plasma installed: start returns 1, runs nothing" bash -c "test $rc = 1 && ! test -s '$FAKE_LOG'"
STAGOS_LOGIN_SHELL="$T/sess/login-shell" stag-session start >/dev/null 2>&1
check "session: no Plasma installed: login shell on tty1" grep -qx 'login-shell -l NO_SESSION=1' "$FAKE_LOG"
check "session: labwc is gone (unknown command)" bash -c "! stag-session labwc 2>/dev/null"
check "session: rejects junk" bash -c "! stag-session bogus"
unset STAGOS_STARTPLASMA STAGOS_PLASMA_DBUS_WRAPPER STAGOS_BOOT_ID

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
check "apply --base: global theme + colors + shortcuts" bash -c "grep -q -- '--key LookAndFeelPackage -- org.stagos.desktop' '$FAKE_LOG' && grep -q -- '--group Colors:Window --key BackgroundNormal -- 10,10,10' '$FAKE_LOG' && grep -q -- '--group Colors:Header --group Inactive' '$FAKE_LOG' && grep -q -- \"--group kwin --key Overview -- Meta+Tab\"\$'\t'\"Ctrl+Up\" '$FAKE_LOG' && grep -q -- '--group kwin --key Walk Through Windows -- Alt+Tab,' '$FAKE_LOG'"
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
check "base.kconf: Spectacle on Print (region), Shift+Print (full), Meta+Shift+R (record region)" bash -c "grep -q '^kglobalshortcutsrc|services/org.kde.spectacle.desktop|RectangularRegionScreenShot|Print' '$P/base.kconf' && grep -q '^kglobalshortcutsrc|services/org.kde.spectacle.desktop|FullScreenScreenShot|Shift+Print' '$P/base.kconf' && grep -q '^kglobalshortcutsrc|services/org.kde.spectacle.desktop|RecordRegion|Meta+Shift+R' '$P/base.kconf'"
check "base.kconf: every line is file|group|key|value" bash -c "grep -vE '^(#|$)' '$P/base.kconf' | awk -F'|' 'NF < 4 { bad = 1 } END { exit bad }'"
check "base.kconf: no hot corner, no wobbly/magic lamp/translucency" bash -c "grep -q '^kwinrc|Effect-overview|BorderActivate|9$' '$P/base.kconf' && for e in wobblywindows magiclamp translucency; do grep -q \"^kwinrc|Plugins|\${e}Enabled|false$\" '$P/base.kconf' || exit 1; done"
check "window edges: active title bar #111111 over inactive #0a0a0a, Breeze outline Medium" bash -c "awk '/^\\[Colors:Header\\]\$/ {g = 1; next} /^\\[/ {g = 0} g && /^BackgroundNormal=17,17,17\$/ {ok = 1} END {exit !ok}' '$P/StagOS.colors' && grep -q '^breezerc|Common|OutlineIntensity|OutlineMedium\$' '$P/base.kconf'"
check "StagOS.colors uses the contract palette" bash -c "grep -q 'BackgroundNormal=10,10,10' '$P/StagOS.colors' && grep -q 'DecorationFocus=200,16,46' '$P/StagOS.colors' && grep -q 'ForegroundNormal=240,240,240' '$P/StagOS.colors'"
check "desktop.conf.default: contract sections" bash -c "for s in bar dock effects recon link; do grep -qx \"\\[\$s\\]\" '$P/desktop.conf.default' || exit 1; done"
check "layout.js: dock dodges windows, bar is 26px" bash -c "grep -q 'dock.hiding = \"dodgewindows\"' '$P/layout.js' && grep -q 'bar.height = 26' '$P/layout.js'"

# ---- stag-fw (firewall switch) and stag-mac (trusted wifi networks) ----
fw_sandbox() {
  sandbox nft systemd-run systemctl
  printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"
  export STAG_FW_CONF="$T/nftables.conf"; echo '# test ruleset' > "$STAG_FW_CONF"
}
fw_sandbox
check "stag-fw off-for 10m: arms a 600s restore, then deletes the table" bash -c "stag-fw off-for 10m | grep -q 'OFF for 600s' && grep -n 'systemd-run.*--on-active=600s' '$FAKE_LOG' | head -1 | cut -d: -f1 > '$T/n1' && grep -n '^nft delete table inet stagos' '$FAKE_LOG' | head -1 | cut -d: -f1 > '$T/n2' && test \$(cat '$T/n1') -lt \$(cat '$T/n2')"
check "stag-fw off-for: the restore reloads the ruleset file" grep -q "systemd-run.*/usr/bin/nft -f $STAG_FW_CONF" "$FAKE_LOG"
fw_sandbox
check "stag-fw off-for 2h: refused (max 1h), table untouched" bash -c "! stag-fw off-for 2h && ! grep -q 'delete table' '$FAKE_LOG'"
check "stag-fw off-for abc: refused" bash -c "! stag-fw off-for abc && ! grep -q 'delete table' '$FAKE_LOG'"
check "stag-fw off-for 0: refused" bash -c "! stag-fw off-for 0s"
check "stag-fw off-for with no argument: refused" bash -c "! stag-fw off-for"
fw_sandbox
check "stag-fw on: syntax-checks, then loads the ruleset, cancels a pending timer" bash -c "stag-fw on | grep -q 'ON' && grep -q 'nft -c -f $STAG_FW_CONF' '$FAKE_LOG' && grep -q 'nft -f $STAG_FW_CONF' '$FAKE_LOG' && grep -q 'systemctl stop stag-fw-restore.timer' '$FAKE_LOG'"
fw_sandbox; echo 1 > "$FAKE_DIR/nft.rc"
check "stag-fw on: a ruleset that does not parse is never loaded" bash -c "! stag-fw on 2>/dev/null && ! grep -q '^nft -f' '$FAKE_LOG'"
fw_sandbox
check "stag-fw status: ON when the table lists" bash -c "stag-fw status | grep -q 'firewall: ON'"
echo 1 > "$FAKE_DIR/nft.rc"
check "stag-fw status: OFF when the table is gone" bash -c "stag-fw status | grep -q 'firewall: OFF'"
check "stag-fw unknown command: usage, exit 2" bash -c "stag-fw frobnicate >/dev/null 2>&1; test \$? -eq 2"
unset STAG_FW_CONF

mac_sandbox() {
  sandbox
  cat > "$T/bin/nmcli" <<'NMEOF'
#!/bin/bash
echo "nmcli $*" >> "$FAKE_LOG"
case "$*" in
  "-t -f NAME,TYPE connection show") printf 'home:802-11-wireless\ncafe\\:guest:802-11-wireless\nwired:802-3-ethernet\nvpn:vpn\n' ;;
  "-g 802-11-wireless.cloned-mac-address connection show id home") echo permanent ;;
  "-g 802-11-wireless.cloned-mac-address connection show id cafe:guest") echo "" ;;
esac
NMEOF
  chmod +x "$T/bin/nmcli"
}
mac_sandbox
check "stag-mac list: only wifi connections, trusted vs random" bash -c "stag-mac list > '$T/list'; grep -q '^home .*trusted' '$T/list' && grep -q '^cafe:guest .*random per network' '$T/list' && ! grep -q 'wired\\|vpn' '$T/list'"
check "stag-mac trust: sets the hardware MAC on that connection" bash -c "stag-mac trust home && grep -q 'nmcli connection modify id home 802-11-wireless.cloned-mac-address permanent' '$FAKE_LOG'"
check "stag-mac untrust: clears it" bash -c "stag-mac untrust home && grep -q 'nmcli connection modify id home 802-11-wireless.cloned-mac-address \$' '$FAKE_LOG'"
check "stag-mac trust: unknown or non-wifi connection refused" bash -c "! stag-mac trust wired 2>/dev/null && ! stag-mac trust nope 2>/dev/null && ! stag-mac trust 2>/dev/null"

# ---- hardening config invariants ----
check "nftables.conf: default deny, tailscale0 accepted, drop-ins included inside chain input" bash -c "f='$ROOT/desktop/firewall/nftables.conf'; grep -q 'policy drop' \$f && grep -q 'iifname \"tailscale0\" accept' \$f && awk '/chain input/ {g=1} g && /include \"\/etc\/nftables.d\/\*.nft\"/ {ok=1} END {exit !ok}' \$f"
check "nftables.conf: never flushes the whole ruleset" bash -c "! grep -v '^#' '$ROOT/desktop/firewall/nftables.conf' | grep -q 'flush ruleset'"
check "nftables.conf: allows tailscaled UDP 41641 and established/related" bash -c "grep -q 'udp dport 41641 accept' '$ROOT/desktop/firewall/nftables.conf' && grep -q 'established, related' '$ROOT/desktop/firewall/nftables.conf'"
check "MAC drop-in: scan randomisation + stable per connection, parses as ini" python3 - "$ROOT/desktop/network/20-stagos-mac.conf" <<'PYEOF'
import configparser, sys
c = configparser.ConfigParser(interpolation=None)
c.read(sys.argv[1])
assert c["device-mac-randomization"]["wifi.scan-rand-mac-address"] == "yes"
assert c["connection-mac-randomization"]["wifi.cloned-mac-address"] == "stable"
PYEOF
check "plymouth theme: every image the script loads is shipped" bash -c "cd '$ROOT/assets/plymouth/stagos' && for i in \$(grep -o 'Image(\"[a-z.]*\")\|scaled(\"[a-z.]*\")' stagos.script | grep -o '\"[a-z.]*\"' | tr -d '\"' | sort -u); do test -s \$i || { echo missing \$i; exit 1; }; done"
check "plymouth theme: descriptor is a script theme named StagOS" bash -c "grep -q '^ModuleName=script' '$ROOT/assets/plymouth/stagos/stagos.plymouth' && grep -q '^Name=StagOS' '$ROOT/assets/plymouth/stagos/stagos.plymouth'"

# ---- config invariants ----
check "keyd map covers the ten Cmd keys" bash -c "for k in c v x z a q w t f s; do grep -q \"^\$k = C-\" '$ROOT/desktop/keyd/default.conf' || exit 1; done"
check "foot never gets bare Ctrl from Cmd" bash -c "! sed -n '/^\[foot\]/,\$p' '$ROOT/desktop/keyd/app.conf' | grep -E '= C-[a-z]\$'"
check "keyd passes Super+Shift+V through (Plasma clipboard history)" grep -qx 'v = M-S-v' "$ROOT/desktop/keyd/default.conf"
check "no em dashes in tracked text" bash -c "cd '$ROOT' && ! grep -rlI --exclude-dir=.git \$'\xe2\x80\x94' . | grep -q ."

# ---- snapshots module: backup.env must survive sourcing with hostile repo strings ----
sandbox
BE=$(bash "$ROOT/test/fixtures/snapshots-env.sh" "$ROOT" "$HOME")
# shellcheck disable=SC2016  # literal $ and backtick on purpose
check "backup.env round-trips a repo with dollar, quote, backtick, space" test "$BE" = 'rest:https://u:p$w"x`id`@h/a b'
check "backup.env is mode 600" test "$(stat -c %a "$HOME/.config/stagos/backup.env")" = 600

echo; echo "desktop-scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
