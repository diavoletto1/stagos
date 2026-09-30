#!/usr/bin/env bash
# Runs as jack inside the container. Assertions print PASS/FAIL; exit code 1 if any FAIL.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export HOME=/home/jack FAKE_LOG=/tmp/fake-tools.log
pass=0; fail=0
t() { local n="$1" out; shift; if out=$("$@" 2>&1); then pass=$((pass+1)); echo "PASS $n"; else fail=$((fail+1)); echo "FAIL $n"; printf '%s\n' "$out" | head -8 | sed 's/^/     | /'; fi; }
sec() { echo; echo "=== $* ==="; }

phase="$1"; shift
if [[ "$phase" == modules ]]; then
  sec "real run, only: $*"
  ./stagos-desktop "$@"; rc=$?
  echo "RESULT (subset): stagos-desktop exit $rc"; exit "$rc"
fi

# ---- module plasma: shared by the "all" and "plasma" phases ----
PLASMA_PKGS="plasma-desktop plasma-workspace kwin kscreen plasma-nm plasma-pa bluedevil powerdevil kdeplasma-addons ksystemstats
  libksysguard breeze xdg-desktop-portal-kde systemsettings kde-cli-tools kirigami qqc2-desktop-style qt6-declarative plasma5support spectacle kpackage
  qt6-tools qt6-wayland plasma-integration polkit-kde-agent knighttime"
kr() { kreadconfig6 --file "$1" "${@:2}"; }
plasma_checks() {
  local C="$HOME/.config" D="$HOME/.local/share" p f
  sec "module plasma: packages, files, Plasma config, session picker"
  for p in $PLASMA_PKGS; do t "plasma pkg $p" pacman -Q "$p"; done
  t "kde-gtk-config not pulled in (would rewrite the labwc GTK settings)" bash -c "! pacman -Q kde-gtk-config"
  t "power-profiles-daemon not pulled in (TLP stays)" bash -c "! pacman -Q power-profiles-daemon"
  t "no display manager pulled in" bash -c "! pacman -Q sddm plasma-login-manager 2>/dev/null | grep -q ."
  for f in stagos/plasma/base.kconf stagos/plasma/layout.js stagos/plasma/dock.js stagos/plasma/desktop.conf.default \
    color-schemes/StagOS.colors plasma/desktoptheme/StagOS/metadata.json plasma/desktoptheme/StagOS/widgets/panel-background.svg \
    plasma/look-and-feel/org.stagos.desktop/metadata.json plasma/look-and-feel/org.stagos.desktop/contents/layouts/org.kde.plasma.desktop-layout.js \
    applications/stag-kismet.desktop applications/stag-mon.desktop icons/hicolor/scalable/apps/stag-kismet.svg \
    icons/hicolor/scalable/apps/stag-mon.svg dbus-1/services/org.freedesktop.Notifications.service; do
    t "share/$f" test -s "$D/$f"
  done
  for f in stagos/desktop.conf stagos/desktop.env autostart/stag-plasma-apply.desktop systemd/user/mako.service.d/50-stagos-not-plasma.conf \
    systemd/user/swaync.service.d/50-stagos-not-plasma.conf systemd/user/waybar.service.d/50-stagos-not-plasma.conf; do
    t "config/$f" test -s "$C/$f"
  done
  t "/usr/local/bin/stag-session" test -x /usr/local/bin/stag-session
  t "/usr/local/bin/stag-plasma-apply" test -x /usr/local/bin/stag-plasma-apply
  t "wallpapers in /usr/share/stagos" test -s /usr/share/stagos/stag-wall-stag.png -a -s /usr/share/stagos/stag-lock.png
  t "kdeglobals: StagOS global theme" test "$(kr kdeglobals --group KDE --key LookAndFeelPackage)" = org.stagos.desktop
  t "kdeglobals: StagOS colors" test "$(kr kdeglobals --group Colors:Window --key BackgroundNormal)" = 10,10,10
  t "kdeglobals: Inter 10 / JetBrains Mono 10" bash -c "kreadconfig6 --file kdeglobals --group General --key font | grep -q '^Inter,10,' && kreadconfig6 --file kdeglobals --group General --key fixed | grep -q '^JetBrains Mono,10,'"
  t "kdeglobals: animation factor 0.7" test "$(kr kdeglobals --group KDE --key AnimationDurationFactor)" = 0.7
  t "kwinrc: buttons min/max/close on the right" bash -c "test \"\$(kreadconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnRight)\" = IAX && test -z \"\$(kreadconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnLeft)\""
  t "kwinrc: blur on, wobbly/magic lamp/translucency off" bash -c "test \"\$(kreadconfig6 --file kwinrc --group Plugins --key blurEnabled)\" = true && for e in wobblywindows magiclamp translucency; do test \"\$(kreadconfig6 --file kwinrc --group Plugins --key \${e}Enabled)\" = false || exit 1; done"
  t "kwinrc: 4 desktops, click to focus" bash -c "test \"\$(kreadconfig6 --file kwinrc --group Desktops --key Number)\" = 4 && test \"\$(kreadconfig6 --file kwinrc --group Windows --key FocusPolicy)\" = ClickToFocus"
  t "kcminputrc: tap to click + natural scroll (all touchpads)" bash -c "test \"\$(kreadconfig6 --file kcminputrc --group Libinput --group Defaults --group Touchpad --key TapToClick)\" = true && test \"\$(kreadconfig6 --file kcminputrc --group Libinput --group Defaults --group Touchpad --key NaturalScroll)\" = true"
  t "powerdevil: lid = sleep, nothing on AC idle" bash -c "test \"\$(kreadconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key LidAction)\" = 1 && test \"\$(kreadconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction)\" = 0"
  t "shortcuts: Meta+Space KRunner, Print region" bash -c "kreadconfig6 --file kglobalshortcutsrc --group services --group org.kde.krunner.desktop --key _launch | grep -q '^Meta+Space' && kreadconfig6 --file kglobalshortcutsrc --group services --group org.kde.spectacle.desktop --key RectangularRegionScreenShot | grep -q '^Print'"
  t "kwinrulesrc: per-app remember rules" bash -c "kreadconfig6 --file kwinrulesrc --group General --key rules | grep -q 'stagos-stag-mon' && test \"\$(kreadconfig6 --file kwinrulesrc --group stagos-stag-mon --key positionrule)\" = 4"
  t "generated layout keeps the p2 widget slots" bash -c "for w in menu status control; do grep -qx \"// STAGOS_WIDGET \$w\" '$D/plasma/look-and-feel/org.stagos.desktop/contents/layouts/org.kde.plasma.desktop-layout.js' || exit 1; done"
  t "kpackagetool6 sees the StagOS global theme" bash -c "kpackagetool6 --type Plasma/LookAndFeel --list 2>/dev/null | grep -qx org.stagos.desktop"
  t "kpackagetool6 sees the StagOS Plasma theme" bash -c "kpackagetool6 --type Plasma/Theme --list 2>/dev/null | grep -qx StagOS"
  pacman -Q desktop-file-utils >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm desktop-file-utils >/dev/null 2>&1
  t "desktop-file-validate: every shipped .desktop (repo) and installed copy" bash -c "desktop-file-validate desktop/share/*.desktop desktop/plasma/autostart/*.desktop desktop/plasma/settings/share/*.desktop '$D/applications/stag-kismet.desktop' '$D/applications/stag-mon.desktop' '$D/applications/stag-settings.desktop' '$D/plasma/systemsettings/externalmodules/stag-settings.desktop' '$C/autostart/stag-plasma-apply.desktop'"
  sec "module plasma: StagOS Settings (app, launcher, System Settings entry, apply path unit)"
  for f in stagos/settings/main.qml stagos/settings/Conf.qml stagos/settings/ini.js stagos/settings/PageFrame.qml stagos/settings/DockPage.qml \
    icons/hicolor/scalable/apps/stag-settings.svg applications/stag-settings.desktop plasma/systemsettings/externalmodules/stag-settings.desktop; do
    t "share/$f" test -s "$D/$f"
  done
  for f in systemd/user/stagos-desktop-apply.path systemd/user/stagos-desktop-apply.service; do t "config/$f" test -s "$C/$f"; done
  t "/usr/local/bin/stag-settings + stag-settings-apply" test -x /usr/local/bin/stag-settings -a -x /usr/local/bin/stag-settings-apply
  t "System Settings entry: external module in the workspace category" bash -c "grep -q '^X-KDE-System-Settings-Parent-Category=workspace' '$D/plasma/systemsettings/externalmodules/stag-settings.desktop' && grep -q '^Exec=stag-settings' '$D/plasma/systemsettings/externalmodules/stag-settings.desktop'"
  t "module .desktop parses as a KService (name, icon, exec)" python3 - "$D/plasma/systemsettings/externalmodules/stag-settings.desktop" <<'PY'
import configparser, sys
c = configparser.ConfigParser(interpolation=None, strict=False); c.optionxform = str
c.read(sys.argv[1]); e = c["Desktop Entry"]
assert e["Name"] == "StagOS" and e["Icon"] == "stag-settings" and e["Exec"] == "stag-settings"
PY
  t "systemd-analyze verify: apply path + service" bash -c "cd '$C/systemd/user' && systemd-analyze --user verify stagos-desktop-apply.path stagos-desktop-apply.service 2>&1 | grep -v 'is not executable' | grep -v '^$' | (! grep .)"
  t "stag-settings --print-context works installed" bash -c "stag-settings --print-context | python3 -m json.tool >/dev/null"
  if [[ -f /etc/xdg/autostart/blueman.desktop ]]; then
    t "blueman stays out of Plasma (NotShowIn=KDE override)" grep -q '^NotShowIn=KDE;' "$C/autostart/blueman.desktop"
    t "blueman override is a valid .desktop" desktop-file-validate "$C/autostart/blueman.desktop"
  fi
  t "every shipped INI/rc/colors file parses (configparser, no interpolation)" python3 - "$PWD/desktop/plasma" "$C/stagos/desktop.conf" <<'PY'
import configparser, glob, json, sys
src = sys.argv[1]
ini = [src + "/desktop.conf.default", src + "/StagOS.colors", sys.argv[2], src + "/look-and-feel/org.stagos.desktop/contents/defaults"]
ini += glob.glob(src + "/**/*.conf", recursive=True) + glob.glob(src + "/**/*rc", recursive=True) + glob.glob(src + "/**/*.colors", recursive=True)
for f in sorted(set(ini)):
    c = configparser.ConfigParser(interpolation=None, strict=False); c.optionxform = str
    c.read_string(open(f).read(), f)
for f in glob.glob(src + "/**/metadata.json", recursive=True):
    json.load(open(f))
PY
  t "path/service/desktop files have no em dashes" bash -c "! grep -rlI \$'\\xe2\\x80\\x94' desktop/plasma/settings desktop/plasma/desktop.conf.default"
  t "tty1 block runs stag-session, old 'exec labwc' block gone" bash -c "grep -q 'exec stag-session start' '$HOME/.zprofile' && test \$(grep -c '# StagOS: autostart' '$HOME/.zprofile') -eq 1 && ! grep -q 'autostart labwc on tty1' '$HOME/.zprofile'"
  t "stag-session --status: plasma by default" bash -c "stag-session --status | grep -qx 'next=plasma (default)'"
  # the installed stag-session with fake startplasma/labwc: two fast crashes fall back to labwc
  local fk; fk="$(mktemp -d)"; mkdir -p "$fk/bin" "$fk/fake"
  ln -s "$PWD/test/fixtures/bin/fake-session" "$fk/bin/startplasma-wayland"; ln -s "$PWD/test/fixtures/bin/fake-session" "$fk/bin/labwc"
  echo 1 > "$fk/fake/startplasma-wayland.rc"
  HOME="$fk" FAKE_DIR="$fk/fake" FAKE_LOG="$fk/log" PATH="$fk/bin:$PATH" STAGOS_STARTPLASMA="$fk/bin/startplasma-wayland" \
    STAGOS_PLASMA_DBUS_WRAPPER=/nonexistent stag-session start >/dev/null 2>&1
  t "stag-session (installed): 2 fast Plasma failures -> labwc" bash -c "test \$(grep -c '^startplasma-wayland' '$fk/log') -eq 2 && grep -q '^labwc' '$fk/log' && grep -q FALLBACK '$fk/.cache/stagos/session.log'"
  rm -rf "$fk"
  stag-plasma-apply --base > /tmp/apply-again.log 2>&1
  t "stag-plasma-apply --base again changes 0 files" grep -q 'done (0 config file(s) changed)' /tmp/apply-again.log
}

# the Plasma test layer (p3): apply against fake kwriteconfig6/qdbus6, tty1 block, the Settings app headless
plasma_test_layer() {
  sec "Plasma test layer"
  t "test/plasma-apply.sh" bash test/plasma-apply.sh
  t "test/plasma-session.sh" bash test/plasma-session.sh
  mkdir -p /tmp/plasma-shots
  t "test/plasma-settings.sh (app loads headless, round trips, screenshots)" env STAGOS_SHOT_DIR=/tmp/plasma-shots bash test/plasma-settings.sh
}

if [[ "$phase" == plasma ]]; then
  sec "static: shellcheck (plasma module and helpers)"
  t "shellcheck clean" shellcheck -x -s bash stagos-desktop lib/*.sh provision/desktop/20-plasma.sh desktop/bin/stag-session.sh desktop/bin/stag-plasma-apply.sh test/*.sh config/stagos.conf
  sec "plasma: dry run"
  DRY_RUN=1 ./stagos-desktop plasma > /tmp/dry.log 2>&1; t "dry run exits 0" test $? -eq 0
  t "dry run changed nothing on disk" test ! -e "$HOME/.local/share/stagos/plasma"
  # an existing labwc-era tty1 block must be migrated
  # shellcheck disable=SC2016  # the old block, verbatim
  printf 'export EDITOR=vim\n\n# StagOS: autostart labwc on tty1\nif [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then\n  exec labwc\nfi\n' > "$HOME/.zprofile"
  sec "plasma: REAL run 1"
  ./stagos-desktop plasma > /tmp/run1.log 2>&1; t "run 1 exits 0" test $? -eq 0
  grep -a -E 'files changed|warn' /tmp/run1.log | grep -v 'is up to date' | tail -12
  sec "plasma: REAL run 2 (idempotency: nothing may change)"
  ./stagos-desktop plasma > /tmp/run2.log 2>&1; t "run 2 exits 0" test $? -eq 0
  grep -a 'wrote ' /tmp/run2.log | sed 's/\x1b\[[0-9;]*m//g' | head -20
  t "run 2 changed 0 files" grep -q 'files changed this run: 0$' /tmp/run2.log
  t "user's own .zprofile lines kept" grep -q '^export EDITOR=vim' "$HOME/.zprofile"
  plasma_checks
  sec "helper unit tests"
  t "test/desktop-scripts.sh" bash test/desktop-scripts.sh
  plasma_test_layer
  echo; echo "PLASMA RESULT: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]; exit
fi

if [[ "$phase" == install || "$phase" == all ]]; then
sec "static: shellcheck / xml / json / keyd"
t "shellcheck clean" shellcheck -x -s bash stagos-desktop lib/*.sh provision/desktop/*.sh desktop/bin/*.sh test/*.sh config/local.conf.example
t "xmllint labwc+fontconfig" xmllint --noout desktop/labwc/*.xml desktop/fontconfig/fonts.conf
t "waybar jsonc parses" bash -c "grep -v '^ *//' desktop/waybar/config.jsonc | python3 -m json.tool"
t "swaync json parses" python3 -m json.tool desktop/swaync/config.json

sec "module list"
./stagos-desktop --list | tr '\n' ' '; echo

sec "dry run of everything"
DRY_RUN=1 ./stagos-desktop > /tmp/dry.log 2>&1; t "dry run exits 0" test $? -eq 0
t "dry run changed nothing on disk" test ! -e "$HOME/.config/waybar"
tail -3 /tmp/dry.log

sec "package names resolve (incl. the heavy ones excluded from the real run)"
pacman -Sy --noconfirm >/dev/null 2>&1 || sudo pacman -Sy --noconfirm >/dev/null 2>&1
for p in blender freecad libreoffice-fresh qemu-desktop virt-manager libvirt dnsmasq chromium obsidian spotify-launcher openscad \
  arm-none-eabi-gcc arm-none-eabi-newlib mission-center gnome-disk-utility papers imv xournalpp gnome-calculator nodejs npm flatpak \
  swaync swayosd waybar fuzzel plocate libqalculate keyd blueman bluez bluez-utils grim slurp swappy wf-recorder cliphist wlsunset \
  tlp tlp-rdw swayidle swaylock wlopm fwupd upower restic snapper snap-pac grub-btrfs inotify-tools gnome-keyring seahorse libsecret \
  wtype libinput pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol playerctl alsa-utils nm-connection-editor network-manager-applet \
  inter-font ttf-jetbrains-mono ttf-nerd-fonts-symbols noto-fonts noto-fonts-emoji brightnessctl wlr-randr papirus-icon-theme $PLASMA_PKGS; do
  t "pkg $p" pacman -Si "$p"
done

sec "REAL run 1 (all modules)"
./stagos-desktop > /tmp/run1.log 2>&1; t "run 1 exits 0" test $? -eq 0
tail -12 /tmp/run1.log
echo; echo "INSTALL PHASE: $pass passed, $fail failed"
if [[ "$phase" == install ]]; then [ "$fail" -eq 0 ]; exit; fi
fi

sec "REAL run 2 (idempotency: nothing may change)"
./stagos-desktop > /tmp/run2.log 2>&1; t "run 2 exits 0" test $? -eq 0
grep 'files changed this run' /tmp/run2.log
grep -a 'wrote ' /tmp/run2.log | sed 's/\x1b\[[0-9;]*m//g' | head -20
t "run 2 changed 0 files" grep -q 'files changed this run: 0$' /tmp/run2.log
sec "each module alone, again (still 0 changes)"
for m in $(./stagos-desktop --list); do
  ./stagos-desktop "$m" > "/tmp/mod-$m.log" 2>&1; t "module $m reruns clean" grep -q 'files changed this run: 0$' "/tmp/mod-$m.log"
done

sec "files landed"
C="$HOME/.config"
for f in labwc/rc.xml labwc/autostart waybar/config.jsonc waybar-dock/config.jsonc waybar-dock/style.css swaync/config.json swayosd/style.css fuzzel/fuzzel.ini \
  keyd/app.conf fontconfig/fonts.conf chromium-flags.conf libinput-gestures.conf stagos/desktop.env swappy/config \
  systemd/user/stagos-restic.timer systemd/user/stagos-restic.service stagos/backup.env stagos/stag-services; do
  t "config/$f" test -s "$C/$f"
done
for f in /etc/keyd/default.conf /etc/tlp.d/50-stagos.conf /etc/systemd/logind.conf.d/50-stagos-lid.conf /usr/local/bin/stag-spotlight \
  /usr/local/bin/stag-dock /usr/local/bin/stag-screenshot /usr/local/bin/stag-record /usr/local/bin/stag-clip /usr/local/bin/stag-menu \
  /usr/local/bin/stag-toggle /usr/local/bin/stag-nightlight /usr/local/bin/stag-battery /usr/local/bin/stag-lock; do
  t "$f" test -x "$f" -o -s "$f"
done
t "stagos-backup in ~/.local/bin" test -x "$HOME/.local/bin/stagos-backup"
t "6 stag launchers"  bash -c "test \$(ls $HOME/.local/share/applications/stag-*.desktop | wc -l) -eq 6"
t "stag urls only in home, not repo" bash -c "! grep -rq 'stag.test.invalid' $PWD --include='*' --exclude=local.conf --exclude-dir=.git --exclude='desktop-container*'"
t "stag desktop entries valid Exec" grep -q 'Exec=chromium --app=https://stag.test.invalid/tasks/' "$HOME/.local/share/applications/stag-tasks.desktop"
t "waybar-dock config is valid JSONC" python3 -c "import json,re,sys; json.loads(re.sub(r'(?m)^\s*//.*\$', '', open(sys.argv[1]).read()))" "$C/waybar-dock/config.jsonc"
t "claude launcher" grep -q 'chromium --app=https://claude.ai' "$HOME/.local/share/applications/claude.desktop"
t "claude code CLI installed" test -x "$HOME/.local/bin/claude"
t "empty-password keyring created" test -s "$HOME/.local/share/keyrings/login.keyring"
t "keyring is plain-text (no password)" grep -q '^\[keyring\]' "$HOME/.local/share/keyrings/login.keyring"
t "AUR names went to (fake) paru" grep -q 'onedrive-abraunegg' /tmp/fake-tools.log
t "flathub ids went to (fake) flatpak" grep -q 'com.bambulab.BambuStudio' /tmp/fake-tools.log
t "tlp.d not conflicting with ppd" bash -c "! pacman -Q power-profiles-daemon"
t "capture-card NM drop-in untouched (module network)" bash -c "! test -e /etc/NetworkManager/conf.d/zz-stagos-mac.conf"
t "scale in env" grep -q 'STAGOS_OUTPUT_SCALE=1.5' "$C/stagos/desktop.env"
t "fc: sans -> Inter" bash -c "fc-match sans-serif | grep -qi inter"
t "fc: monospace -> JetBrains Mono" bash -c "fc-match monospace | grep -qi jetbrains"

plasma_checks

sec "static validation of installed configs"
t "keyd check /etc/keyd/default.conf" keyd check /etc/keyd/default.conf
t "fuzzel --check-config" fuzzel --check-config --config "$C/fuzzel/fuzzel.ini"
t "systemd-analyze verify restic units" systemd-analyze verify "$C/systemd/user/stagos-restic.service" "$C/systemd/user/stagos-restic.timer"
t "logind drop-in syntax" grep -q '^HandleLidSwitch=suspend' /etc/systemd/logind.conf.d/50-stagos-lid.conf

sec "headless labwc: rc.xml + autostart + bar + dock + notifications"
export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman XDG_CONFIG_HOME="$C"
pacman -Q labwc >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm labwc >/dev/null 2>&1
cat > /tmp/probe.sh <<'PROBE'
#!/bin/sh
sleep 2
(timeout 6 waybar -c "$HOME/.config/waybar/config.jsonc" -s "$HOME/.config/waybar/style.css" > /tmp/waybar.log 2>&1) &
(timeout 6 swaync > /tmp/swaync.log 2>&1) &
(timeout 6 swayosd-server > /tmp/swayosd.log 2>&1) &
(timeout 6 waybar -c "$HOME/.config/waybar-dock/config.jsonc" -s "$HOME/.config/waybar-dock/style.css" > /tmp/waybar-dock.log 2>&1) &
sleep 7
labwc --exit 2>/dev/null; kill -TERM "$PPID" 2>/dev/null
PROBE
chmod +x /tmp/probe.sh
timeout 40 labwc -d -C "$C/labwc" -s /tmp/probe.sh > /tmp/labwc.log 2>&1 || true
echo "--- labwc.log"; head -30 /tmp/labwc.log
t "labwc read our rc.xml" grep -q "$C/labwc/rc.xml" /tmp/labwc.log
t "labwc: no rc.xml/keybind/libinput config errors" bash -c "! grep -E '\[(ERROR|WARN)\]' /tmp/labwc.log | grep -Ei 'rcxml|rc\.xml|keybind|libinput|action|unknown|invalid|theme' "
echo "--- waybar.log"; head -20 /tmp/waybar.log
t "waybar config loads (no parse error)" bash -c "! grep -Ei 'parse|Error\]|failed to load|invalid' /tmp/waybar.log"
echo "--- swaync.log"; head -8 /tmp/swaync.log
t "swaync config+css load" bash -c "! grep -Ei 'Failed to (load|parse)|CSS Error|invalid' /tmp/swaync.log"
echo "--- waybar-dock.log"; head -8 /tmp/waybar-dock.log
t "waybar dock config loads (no parse error)" bash -c "! grep -Ei 'parse|Error\]|failed to load|invalid' /tmp/waybar-dock.log"

sec "btrfs branch (simulated: real pacman installs, snapper/grub-btrfs actions dry)"
STAGOS_ROOT_FSTYPE=btrfs DRY_RUN=1 ./stagos-desktop snapshots > /tmp/btrfs.log 2>&1
t "btrfs path plans snapper create-config + grub-btrfs" bash -c "grep -q 'snapper -c root create-config /' /tmp/btrfs.log && grep -q 'grub-btrfsd' /tmp/btrfs.log"
t "btrfs path does not plan restic timer" bash -c "! grep -q 'stagos-restic.timer' /tmp/btrfs.log"
t "ext4 path plans restic timer" grep -q 'stagos-restic.timer' /tmp/dry.log

sec "helper unit tests"
t "test/desktop-scripts.sh" bash test/desktop-scripts.sh
plasma_test_layer

echo; echo "CONTAINER RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
