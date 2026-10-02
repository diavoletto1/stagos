#!/usr/bin/env bash
# Runs as jack inside the container. Assertions print PASS/FAIL; exit code 1 if any FAIL.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export HOME=/home/jack FAKE_LOG=/tmp/fake-tools.log
pass=0; fail=0
t() { local n="$1" out; shift; if out=$("$@" 2>&1); then pass=$((pass+1)); echo "PASS $n"; else fail=$((fail+1)); echo "FAIL $n"; printf '%s\n' "$out" | head -8 | sed 's/^/     | /'; fi; }
sec() { echo; echo "=== $* ==="; }

phase="$1"; shift
# ---- safety net, real tools (restic against a local repo, TLP's own parser, stag-update's plan) ----
safety_snapshots() {
  sec "snapshots: a real restic backup to the local test repo"
  local C="$HOME/.config"
  t "password file created once, 600" bash -c "test -s $C/stagos/restic.pass && test \$(stat -c %a $C/stagos/restic.pass) = 600"
  t "systemd-analyze verify restic units" systemd-analyze verify "$C/systemd/user/stagos-restic.service" "$C/systemd/user/stagos-restic.timer"
  t "stag-backup now (initialises the repo; /etc root-only files are skipped, rc 3 kept)" stag-backup now
  t "a second backup, no init" bash -c "stag-backup now && test \$(grep -c 'initialising' ~/.local/state/stagos/backup.log) = 1"
  t "restic sees 2 snapshots tagged stagos" bash -c "set -a; . $C/stagos/backup.env; set +a; RESTIC_REPOSITORY=\$STAGOS_RESTIC_REPO RESTIC_PASSWORD_FILE=\$STAGOS_RESTIC_PASSWORD_FILE restic snapshots --tag stagos --json | grep -o '\"short_id\"' | wc -l | grep -qx 2"
  t "excludes work: ~/.cache and node_modules are not in the snapshot" bash -c "mkdir -p ~/.cache/x ~/proj/node_modules/y && echo a > ~/.cache/x/f && echo b > ~/proj/node_modules/y/f && echo c > ~/proj/keep && stag-backup now >/dev/null && set -a && . $C/stagos/backup.env && set +a && RESTIC_REPOSITORY=\$STAGOS_RESTIC_REPO RESTIC_PASSWORD_FILE=\$STAGOS_RESTIC_PASSWORD_FILE restic ls latest > /tmp/ls.txt && grep -q '/proj/keep\$' /tmp/ls.txt && ! grep -q node_modules /tmp/ls.txt && ! grep -q '/.cache/x' /tmp/ls.txt"
  t "package lists in the snapshot" grep -q 'pkglist-explicit.txt$' /tmp/ls.txt
  t "/etc in the snapshot" grep -q '^/etc/pacman.conf$' /tmp/ls.txt
  t "stag-backup restore-test" stag-backup restore-test
  t "stag-backup check (subset + prune)" stag-backup check
  t "stag-backup status shows a recent snapshot" bash -c "stag-backup status | grep -qE '^last ok:  [0-9]+m ago'"
  t "the password is in no log" bash -c "! grep -rqF \"\$(cat $C/stagos/restic.pass)\" ~/.local/state/stagos /tmp/sub2.log"
}
safety_update() {
  sec "update: stag-update plan (no network, no changes)"
  t "pacdiff present" command -v pacdiff
  t "stag-update --dry-run reaches the pacman step without the news feed" bash -c "STAGOS_NEWS_URL=http://127.0.0.1:9/none stag-update --dry-run </dev/null | grep -q '\[dry\] sudo pacman -Syu'"
  t "stag-update --status: not pinned" bash -c "stag-update --status | grep -qx 'pinned: no'"
}
safety_power() {
  sec "power: TLP battery thresholds"
  t "51-stagos-battery.conf 75/80" bash -c "grep -qx START_CHARGE_THRESH_BAT0=75 /etc/tlp.d/51-stagos-battery.conf && grep -qx STOP_CHARGE_THRESH_BAT0=80 /etc/tlp.d/51-stagos-battery.conf"
  t "TLP's parser reads the thresholds (tlp-stat -c)" bash -c "sudo tlp-stat -c 2>&1 | grep -q 'STOP_CHARGE_THRESH_BAT0=\"80\"'"
  t "stag-battery installed" test -x /usr/local/bin/stag-battery
  sec "power: optimized charging (stag-charge)"
  t "battery.conf: optimized on, hold 75/80" bash -c "grep -qx OPTIMIZED=1 /etc/stagos/battery.conf && grep -qx START=75 /etc/stagos/battery.conf && grep -qx STOP=80 /etc/stagos/battery.conf"
  t "stag-charge, units, udev rule, polkit rule installed" bash -c "test -x /usr/local/bin/stag-charge && test -s /etc/systemd/system/stagos-charge.timer && test -s /etc/systemd/system/stagos-charge-full.service && test -s /etc/udev/rules.d/90-stagos-charge.rules && sudo test -s /etc/polkit-1/rules.d/50-stagos-charge.rules"
  t "systemd-analyze verify: the four charge units" systemd-analyze verify /etc/systemd/system/stagos-charge.service /etc/systemd/system/stagos-charge-full.service /etc/systemd/system/stagos-charge-hold.service /etc/systemd/system/stagos-charge.timer
  t "udev rule parses (udevadm verify)" bash -c "! command -v udevadm >/dev/null || udevadm verify --no-style /etc/udev/rules.d/90-stagos-charge.rules"
  local f; f="$(mktemp -d)"; mkdir -p "$f/sys/class/power_supply/BAT0" "$f/sys/class/power_supply/AC"
  echo Battery > "$f/sys/class/power_supply/BAT0/type"; echo Mains > "$f/sys/class/power_supply/AC/type"; echo 1 > "$f/sys/class/power_supply/AC/online"
  echo 99 > "$f/sys/class/power_supply/BAT0/charge_control_start_threshold"; echo 100 > "$f/sys/class/power_supply/BAT0/charge_control_end_threshold"
  STAGOS_SYS="$f/sys" STAGOS_CHARGE_STATE_DIR="$f/state" STAGOS_CHARGE_NOTE="$f/note" /usr/local/bin/stag-charge tick
  t "installed stag-charge tick (fake sysfs): back to 75/80, history file written" bash -c "test \$(cat $f/sys/class/power_supply/BAT0/charge_control_end_threshold) = 80 && test \$(cat $f/sys/class/power_supply/BAT0/charge_control_start_threshold) = 75 && python -m json.tool $f/state/battery-history.json >/dev/null"
  t "stag-battery status lists the schedule" bash -c "STAGOS_SYS=$f/sys STAGOS_CHARGE_STATE_DIR=$f/state stag-battery status | grep -q 'weekdays: *learning (0 of 5'"
}
if [[ "$phase" == modules ]]; then
  sec "real run, only: $*"
  ./stagos-desktop "$@"; rc=$?
  t "run 1 exits 0" test "$rc" -eq 0
  sec "real run 2, only: $* (idempotency: nothing may change)"
  ./stagos-desktop "$@" > /tmp/sub2.log 2>&1; t "run 2 exits 0" test $? -eq 0
  grep -a 'wrote ' /tmp/sub2.log | sed 's/\x1b\[[0-9;]*m//g' | head -20
  t "run 2 changed 0 files" grep -q 'files changed this run: 0$' /tmp/sub2.log
  for m in "$@"; do
    case "$m" in
      snapshots) safety_snapshots ;;
      update) safety_update ;;
      power) safety_power ;;
    esac
  done
  echo; echo "RESULT (subset $*): $pass passed, $fail failed"
  [ "$fail" -eq 0 ]; exit
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
  t "keyd per-app keys: python-dbus + python-gobject (mapper's KDE backend)" pacman -Q python-dbus python-gobject
  t "keyd per-app keys: stagos-keyd-apps.service matches the repo" cmp desktop/keyd/stagos-keyd-apps.service "$C/systemd/user/stagos-keyd-apps.service"
  t "kde-gtk-config not pulled in (would rewrite the StagOS GTK settings)" bash -c "! pacman -Q kde-gtk-config"
  t "power-profiles-daemon not pulled in (TLP stays)" bash -c "! pacman -Q power-profiles-daemon"
  t "no display manager pulled in" bash -c "! pacman -Q sddm plasma-login-manager 2>/dev/null | grep -q ."
  for f in stagos/plasma/base.kconf stagos/plasma/layout.js stagos/plasma/dock.js stagos/plasma/desktop.conf.default \
    color-schemes/StagOS.colors plasma/desktoptheme/StagOS/metadata.json plasma/desktoptheme/StagOS/widgets/panel-background.svg \
    plasma/look-and-feel/org.stagos.desktop/metadata.json plasma/look-and-feel/org.stagos.desktop/contents/layouts/org.kde.plasma.desktop-layout.js \
    applications/stag-kismet.desktop applications/stag-mon.desktop icons/hicolor/scalable/apps/stag-kismet.svg \
    icons/hicolor/scalable/apps/stag-mon.svg; do
    t "share/$f" test -s "$D/$f"
  done
  for f in stagos/desktop.conf stagos/desktop.env autostart/stag-plasma-apply.desktop; do
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
  t "shortcuts: Spectacle Shift+Print full, Meta+Shift+R record region" bash -c "kreadconfig6 --file kglobalshortcutsrc --group services --group org.kde.spectacle.desktop --key FullScreenScreenShot | grep -q '^Shift+Print' && kreadconfig6 --file kglobalshortcutsrc --group services --group org.kde.spectacle.desktop --key RecordRegion | grep -q '^Meta+Shift+R'"
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
  # no systemd user manager in the container, so systemd-analyze cannot run: check the unit structure instead
  t "apply path + service units: sections and keys" python3 - "$C/systemd/user" <<'PY'
import configparser, sys
def load(f):
    c = configparser.ConfigParser(interpolation=None, strict=False); c.optionxform = str
    c.read(sys.argv[1] + "/" + f); return c
p, s = load("stagos-desktop-apply.path"), load("stagos-desktop-apply.service")
assert p["Path"]["Unit"] == "stagos-desktop-apply.service" and p["Install"]["WantedBy"] == "default.target"
assert p["Path"]["PathChanged"].endswith("/stagos/desktop.conf") and p["Path"]["PathExists"].endswith("reset-layout.request")
assert s["Service"]["Type"] == "oneshot" and s["Service"]["ExecStart"] == "/usr/local/bin/stag-settings-apply"
PY
  t "stag-settings --print-context works installed" bash -c "stag-settings --print-context | python3 -m json.tool >/dev/null"
  t "no coexistence leftovers (drop-ins, notification D-Bus file, NotShowIn overrides)" bash -c "! ls '$C'/systemd/user/*.service.d/50-stagos-not-plasma.conf '$D/dbus-1/services/org.freedesktop.Notifications.service' 2>/dev/null | grep -q . && ! grep -lq '^# StagOS: .*NotShowIn=' '$C'/autostart/*.desktop 2>/dev/null"
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
  t "tty1 block runs stag-session, older blocks gone" bash -c "grep -q '  exec stag-session start' '$HOME/.zprofile' && test \$(grep -c '# StagOS: autostart' '$HOME/.zprofile') -eq 1 && ! grep -q '^  exec [^s]' '$HOME/.zprofile'"
  t "stag-session --status: plasma next" bash -c "stag-session --status | grep -qx 'next=plasma'"
  # the installed stag-session with a fake startplasma: two fast crashes stop (no terminal here: rc 1 instead of a shell)
  local fk rc; fk="$(mktemp -d)"; mkdir -p "$fk/bin" "$fk/fake"
  ln -s "$PWD/test/fixtures/bin/fake-session" "$fk/bin/startplasma-wayland"
  echo 1 > "$fk/fake/startplasma-wayland.rc"
  HOME="$fk" FAKE_DIR="$fk/fake" FAKE_LOG="$fk/log" PATH="$fk/bin:$PATH" STAGOS_STARTPLASMA="$fk/bin/startplasma-wayland" \
    STAGOS_PLASMA_DBUS_WRAPPER=/nonexistent stag-session start >/dev/null 2>&1; rc=$?
  t "stag-session (installed): 2 fast Plasma failures -> shell, rc 1" bash -c "test \$(grep -c '^startplasma-wayland' '$fk/log') -eq 2 && test $rc -eq 1 && grep -q FALLBACK '$fk/.cache/stagos/session.log'"
  rm -rf "$fk"
  stag-plasma-apply --base > /tmp/apply-again.log 2>&1
  t "stag-plasma-apply --base again changes 0 files" grep -q 'done (0 config file(s) changed)' /tmp/apply-again.log
  widget_checks
}

# ---- StagOS widgets (p2): stag-ctl / stag-status installed, plasmoids installed and loadable ----
widget_checks() {
  local D="$HOME/.local/share" id tmp q
  sec "StagOS widgets: stag-ctl, stag-status, plasmoids"
  for f in stag-lib stag-ctl stag-status; do t "/usr/local/bin/$f" test -x "/usr/local/bin/$f"; done
  t "plasma pkg playerctl + wl-clipboard" pacman -Q playerctl wl-clipboard
  for id in org.stagos.menu org.stagos.status; do
    t "plasmoid $id installed (kpackagetool6 --list)" bash -c "kpackagetool6 --type Plasma/Applet --list 2>/dev/null | grep -qx $id"
    t "plasmoid $id matches the repo" diff -rq "$PWD/desktop/plasma/plasmoids/$id" "$D/plasma/plasmoids/$id"
    tmp="$(mktemp -d)"
    t "plasmoid $id: kpackagetool6 --install into a clean HOME" env HOME="$tmp" XDG_DATA_HOME="$tmp/share" \
      kpackagetool6 --type Plasma/Applet --install "$PWD/desktop/plasma/plasmoids/$id"
    rm -rf "$tmp"
  done
  t "generated layout places org.stagos.menu + org.stagos.status" bash -c "L='$D/plasma/look-and-feel/org.stagos.desktop/contents/layouts/org.kde.plasma.desktop-layout.js'; grep -q 'org.stagos.menu' \"\$L\" && grep -q 'org.stagos.status' \"\$L\""
  t "stag-status --json on the installed system parses" bash -c "stag-status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"v\"] == 1 and d[\"fields\"]'"
  t "stag-ctl about on the installed system parses" bash -c "stag-ctl about | python3 -c 'import json,sys; json.load(sys.stdin)'"
  t "STAG menu shows StagOS Settings (stag-ctl about finds /usr/local/bin/stag-settings)" bash -c "stag-ctl about | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"settings\"] is True'"
  # qmllint: a report, not a gate (Plasma's QML modules are not all visible to qmllint outside plasmashell)
  q=/usr/lib/qt6/bin/qmllint
  if [[ -x "$q" ]]; then
    "$q" -I /usr/lib/qt6/qml "$PWD"/desktop/plasma/plasmoids/*/contents/ui/*.qml "$PWD"/desktop/plasma/settings/*.qml > /tmp/qmllint.log 2>&1
    echo "qmllint: $(grep -c '^Warning' /tmp/qmllint.log) warning(s), $(grep -ciE '^Error|: error' /tmp/qmllint.log) error(s) (report only, /tmp/qmllint.log)"
    grep -E '^(Warning|Error)' /tmp/qmllint.log | sed 's|'"$PWD"'/||' | sort | uniq -c | sort -rn | head -25
    t "qmllint: no syntax errors" bash -c "! grep -qiE 'SyntaxError|Expected token|Unexpected token' /tmp/qmllint.log"
  fi
}

# the Plasma test layer (p3): apply against fake kwriteconfig6/qdbus6, tty1 block, the Settings app headless
plasma_test_layer() {
  sec "Plasma test layer"
  t "test/plasma-apply.sh" bash test/plasma-apply.sh
  t "test/plasma-session.sh" bash test/plasma-session.sh
  t "test/keyd-apps.sh" bash test/keyd-apps.sh
  # screenshots next to the smoke's when the runner mounted an output dir
  local shots=/tmp/plasma-shots; [[ -d /out && -w /out ]] && shots=/out
  mkdir -p "$shots"
  t "test/plasma-settings.sh (app loads headless, round trips, screenshots)" env STAGOS_SHOT_DIR="$shots" bash test/plasma-settings.sh
}

if [[ "$phase" == plasma ]]; then
  sec "static: shellcheck (plasma module and helpers)"
  t "shellcheck clean" shellcheck -x -s bash stagos-desktop lib/*.sh provision/desktop/20-plasma.sh desktop/bin/stag-session.sh desktop/bin/stag-plasma-apply.sh test/*.sh config/stagos.conf
  sec "plasma: dry run"
  DRY_RUN=1 ./stagos-desktop plasma > /tmp/dry.log 2>&1; t "dry run exits 0" test $? -eq 0
  t "dry run changed nothing on disk" test ! -e "$HOME/.local/share/stagos/plasma"
  # an existing older tty1 block must be migrated
  cp test/fixtures/labwc-era/zprofile-labwc "$HOME/.zprofile"
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
  t "test/stag-widgets.sh" bash test/stag-widgets.sh
  plasma_test_layer
  echo; echo "PLASMA RESULT: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]; exit
fi

# ---- migrate: a box that ran the labwc-era StagOS, then this tree, then ./stagos-desktop cleanup-labwc ----
if [[ "$phase" == migrate ]]; then
  OLD="$HOME/stagos-old"
  # shellcheck source=lib/labwc-cleanup.sh
  source lib/labwc-cleanup.sh
  NEW_MODS="bluetooth network audio keys power hidpi plasma"
  snap() { { find "$HOME/.config" "$HOME/.local/share" "$HOME/.zprofile" 2>/dev/null | sort; pacman -Qq; ls /usr/local/bin; } > "$1"; }
  sec "old StagOS ($(cat "$OLD/.stagos-ref" 2>/dev/null)): provision 60-desktop + 65-extras, then its desktop modules"
  # the old provision steps as they are, minus systemctl (no systemd here) and three big packages that are not
  # part of the labwc stack (firefox, wireshark-qt, noto-fonts-cjk)
  (cd "$OLD" && bash -c '
    set -e; HERE="$PWD"; source lib/common.sh; source config/stagos.conf
    run() {
      if [[ "$1 $2" == "sudo systemctl" ]]; then echo "[skip] $*"; return 0; fi
      if [[ "$1 $2 $3" == "sudo pacman -S" ]]; then
        local a=() x; for x in "$@"; do [[ " firefox wireshark-qt noto-fonts-cjk " == *" $x "* ]] || a+=("$x"); done; "${a[@]}"; return
      fi
      "$@"
    }
    source provision/60-desktop.sh; stagos_60_desktop
    source provision/65-extras.sh; stagos_65_extras') > /tmp/old-provision.log 2>&1
  t "old provision 60-desktop + 65-extras" test $? -eq 0
  tail -3 /tmp/old-provision.log
  # every old module except apps (heavy), stag (chromium), snapshots and keyring (nothing labwc in them)
  (cd "$OLD" && ./stagos-desktop bluetooth bar launcher notify network audio trackpad keys capture clipboard nightlight power hidpi plasma) \
    > /tmp/old-modules.log 2>&1
  t "old desktop modules" test $? -eq 0
  grep -a 'files changed' /tmp/old-modules.log
  t "old box: labwc stack installed" pacman -Q labwc waybar swaync fuzzel mako qt6ct blueman
  t "old box: configs, coexistence files and helpers present" bash -c "test -d '$HOME/.config/labwc' -a -d '$HOME/.config/waybar-dock' -a -s '$HOME/.config/systemd/user/waybar.service.d/50-stagos-not-plasma.conf' -a -s '$HOME/.local/share/dbus-1/services/org.freedesktop.Notifications.service' -a -x /usr/local/bin/stag-dock"
  cp "$HOME/.zprofile" /tmp/zprofile-old

  sec "this tree: the kept modules ($NEW_MODS)"
  # shellcheck disable=SC2086  # the module list
  ./stagos-desktop $NEW_MODS > /tmp/new1.log 2>&1; t "modules run 1 exits 0" test $? -eq 0
  t "plasma module points at the cleanup" grep -q 'stagos-desktop cleanup-labwc' /tmp/new1.log
  t "plasma module migrated the tty1 block" grep -q '  exec stag-session start' "$HOME/.zprofile"

  sec "cleanup-labwc: dry run"
  # cleanup before ./stagos-desktop (the README order): the labwc-era stag-session and an old default=labwc are
  # still there, and that stag-session falls back to (or starts) labwc
  sudo install -m755 "$OLD/desktop/bin/stag-session.sh" /usr/local/bin/stag-session
  printf '[session]\ndefault=labwc\n' >> "$HOME/.config/stagos/desktop.conf"
  cp /tmp/zprofile-old "$HOME/.zprofile"; snap /tmp/snap-before
  echo "Required By of the installed labwc-era packages (pacman -Qi):"
  for p in "${STAGOS_LABWC_PKGS[@]}"; do pacman -Q "$p" >/dev/null 2>&1 && printf '  %-24s %s\n' "$p" "$(lc_required_by "$p" | tr '\n' ' ')"; done
  pacman -Qq | sort > /tmp/pkgs-before
  DRY_RUN=1 ./stagos-desktop cleanup-labwc > /tmp/cleanup-dry.log 2>&1; t "dry run exits 0" test $? -eq 0
  snap /tmp/snap-dry
  t "dry run changed nothing (files, packages, /usr/local/bin)" cmp /tmp/snap-before /tmp/snap-dry
  sed 's/\x1b\[[0-9;]*m//g' /tmp/cleanup-dry.log | grep -E '^  (sudo|config)' | head -60

  sec "cleanup-labwc: real (ASSUME_YES=1)"
  ASSUME_YES=1 ./stagos-desktop cleanup-labwc > /tmp/cleanup1.log 2>&1; t "cleanup exits 0" test $? -eq 0
  sed 's/\x1b\[[0-9;]*m//g' /tmp/cleanup1.log | grep -E 'keeping|Packages \(|Total Removed|backup:|files changed'
  BK="$(sed -n 's/\x1b\[[0-9;]*m//g; s/^\[stagos\] backup: //p' /tmp/cleanup1.log)"
  for f in labwc waybar waybar-dock fuzzel mako swaync swayosd swaylock qt6ct systemd/user/waybar.service.d/50-stagos-not-plasma.conf \
    systemd/user/mako.service.d/50-stagos-not-plasma.conf; do
    t "backup has .config/$f" test -e "$BK/.config/$f"
  done
  t "backup has the notification D-Bus file and the labwc theme" test -s "$BK/.local/share/dbus-1/services/org.freedesktop.Notifications.service" -a -d "$BK/.local/share/themes/StagOS/openbox-3"
  t "backup has the NotShowIn=KDE autostart overrides" bash -c "ls '$BK'/.config/autostart/*.desktop | grep -q ."
  t "backup has the old /usr/local/bin helpers" bash -c "for b in ${STAGOS_LABWC_BINS[*]}; do test -s '$BK/usr-local-bin/'\$b || exit 1; done"
  t "the originals are gone" bash -c "! ls -d '$HOME/.config/labwc' '$HOME/.config/waybar' /usr/local/bin/stag-dock 2>/dev/null | grep -q ."
  for p in "${STAGOS_LABWC_PKGS[@]}"; do t "package gone: $p" bash -c "! pacman -Q $p"; done
  pacman -Qq | sort > /tmp/pkgs-after
  echo "pacman -Rns also removed (dependencies nothing else needs):"
  comm -23 /tmp/pkgs-before /tmp/pkgs-after | grep -vxF -f <(printf '%s\n' "${STAGOS_LABWC_PKGS[@]}") | tr '\n' ' '; echo
  t "a dependency StagOS installs by name itself stays (gpsd: waybar pulled it in, the recon toolkit needs it)" \
    bash -c "! grep -qx gpsd /tmp/pkgs-before || pacman -Q gpsd"
  t "the Plasma-only stag-session replaced the labwc-era one" cmp desktop/bin/stag-session.sh /usr/local/bin/stag-session
  t "stag-session --status after the cleanup: plasma (old default=labwc ignored)" bash -c "stag-session --status | grep -qx 'next=plasma'"
  t "nothing was kept back for a dependency" bash -c "! grep -q 'keeping ' /tmp/cleanup1.log"
  for p in $PLASMA_PKGS foot keyd tlp pipewire wireplumber pavucontrol bluez bluez-utils networkmanager thunar wl-clipboard playerctl \
    libnotify brightnessctl papirus-icon-theme inter-font ttf-jetbrains-mono gnome-themes-extra xdg-desktop-portal xdg-utils \
    libqalculate plocate udiskie bluetui polkit; do
    t "still installed: $p" pacman -Q "$p"
  done
  for f in stag-lib stag-kismet stag-mon stag-ctl stag-status stag-session stag-plasma-apply stag-settings; do t "kept /usr/local/bin/$f" test -x "/usr/local/bin/$f"; done
  t "tty1 block migrated, one block" bash -c "grep -q '  exec stag-session start' '$HOME/.zprofile' && test \$(grep -c '# StagOS: autostart' '$HOME/.zprofile') -eq 1"

  sec "cleanup-labwc: run 2 (nothing left)"
  snap /tmp/snap-c1
  ASSUME_YES=1 ./stagos-desktop cleanup-labwc > /tmp/cleanup2.log 2>&1; t "run 2 exits 0" test $? -eq 0
  snap /tmp/snap-c2
  t "run 2 finds nothing and changes nothing" bash -c "grep -q 'nothing labwc-era left' /tmp/cleanup2.log && grep -q 'files changed this run: 0' /tmp/cleanup2.log && cmp /tmp/snap-c1 /tmp/snap-c2"

  sec "this tree again after the cleanup (0 changes, no leftover warning)"
  # shellcheck disable=SC2086
  ./stagos-desktop $NEW_MODS > /tmp/new2.log 2>&1; t "modules run 2 exits 0" test $? -eq 0
  t "modules run 2 changed 0 files" grep -q 'files changed this run: 0$' /tmp/new2.log
  t "no leftover warning any more" bash -c "! grep -q cleanup-labwc /tmp/new2.log"
  plasma_checks
  echo; echo "MIGRATE RESULT: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]; exit
fi

# ---- fresh: a clean box, provision's desktop steps (60-desktop, 65-extras), then every stagos-desktop module ----
if [[ "$phase" == fresh ]]; then
  # shellcheck source=lib/labwc-cleanup.sh
  source lib/labwc-cleanup.sh
  prov() { # provision.sh 60-desktop 65-extras as they are, minus systemctl (no systemd here) and three big packages
    bash -c '
      set -e; HERE="$PWD"; source lib/common.sh; source config/stagos.conf
      run() {
        if [[ "$1 $2" == "sudo systemctl" ]]; then echo "[skip] $*"; return 0; fi
        if [[ "$1 $2 $3" == "sudo pacman -S" ]]; then
          local a=() x; for x in "$@"; do [[ " firefox wireshark-qt noto-fonts-cjk " == *" $x "* ]] || a+=("$x"); done; "${a[@]}"; return
        fi
        "$@"
      }
      source provision/60-desktop.sh; stagos_60_desktop
      source provision/65-extras.sh; stagos_65_extras'
  }
  sec "fresh: provision 60-desktop + 65-extras"
  prov > /tmp/prov1.log 2>&1; t "provision desktop steps exit 0" test $? -eq 0
  sed 's/\x1b\[[0-9;]*m//g' /tmp/prov1.log | grep -E 'files changed|plasma installed|warn' | tail -6
  sec "fresh: stagos-desktop, all modules (run 1)"
  ./stagos-desktop > /tmp/run1.log 2>&1; t "run 1 exits 0" test $? -eq 0
  tail -4 /tmp/run1.log
  sec "fresh: second runs (0 changes)"
  prov > /tmp/prov2.log 2>&1; t "provision desktop steps run 2 exit 0" test $? -eq 0
  t "provision run 2: its plasma module changed 0 files" grep -q 'files changed this run: 0$' /tmp/prov2.log
  ./stagos-desktop > /tmp/run2.log 2>&1; t "stagos-desktop run 2 exits 0" test $? -eq 0
  grep -a 'wrote ' /tmp/run2.log | sed 's/\x1b\[[0-9;]*m//g' | head -20
  t "stagos-desktop run 2 changed 0 files" grep -q 'files changed this run: 0$' /tmp/run2.log
  sec "fresh: field mode (module field)"
  t "/usr/local/bin/stag-field" test -x /usr/local/bin/stag-field
  t "stag-field status parses, inactive on a fresh box" bash -c "stag-field status | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"active\"] is False'"
  for f in systemd/user/stagos-field-sync.service systemd/user/stagos-field-sync.timer; do t "config/$f" test -s "$HOME/.config/$f"; done
  t "field-sync units: sections and keys" python3 - "$HOME/.config/systemd/user" <<'PY'
import configparser, sys
def load(f):
    c = configparser.ConfigParser(interpolation=None, strict=False); c.optionxform = str
    c.read(sys.argv[1] + "/" + f); return c
s, tm = load("stagos-field-sync.service"), load("stagos-field-sync.timer")
assert s["Service"]["Type"] == "oneshot" and s["Service"]["ExecStart"] == "/usr/local/bin/stag-field sync"
assert tm["Install"]["WantedBy"] == "timers.target" and "OnUnitActiveSec" in tm["Timer"]
PY
  sec "fresh: nothing labwc-era installed or left"
  for p in "${STAGOS_LABWC_PKGS[@]}"; do t "not installed: $p" bash -c "! pacman -Q $p"; done
  # stag-battery is a labwc-era name the power module ships again (TLP thresholds): lc_bins keeps that copy
  t "no old helpers in /usr/local/bin" bash -c "HERE=\$PWD; source lib/common.sh; source lib/desktop.sh; source lib/labwc-cleanup.sh; test -z \"\$(lc_bins)\""
  t "no labwc-era configs" bash -c "test -z \"\$(source lib/common.sh; source lib/desktop.sh; source lib/labwc-cleanup.sh; lc_user_files)\""
  t "no leftover warning" bash -c "! grep -q cleanup-labwc /tmp/run1.log /tmp/run2.log /tmp/prov1.log"
  ASSUME_YES=1 ./stagos-desktop cleanup-labwc > /tmp/cleanup.log 2>&1
  t "cleanup-labwc on a fresh box: nothing to do, 0 changes" bash -c "grep -q 'nothing labwc-era left' /tmp/cleanup.log && grep -q 'files changed this run: 0' /tmp/cleanup.log"
  t "keyd config loads (keyd check)" keyd check /etc/keyd/default.conf
  plasma_checks
  echo; echo "FRESH RESULT: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]; exit
fi

if [[ "$phase" == install || "$phase" == all ]]; then
sec "static: shellcheck / xml / json / keyd"
t "shellcheck clean" shellcheck -x -s bash stagos-desktop lib/*.sh provision/desktop/*.sh desktop/bin/*.sh test/*.sh config/local.conf.example
t "xmllint fontconfig" xmllint --noout desktop/fontconfig/fonts.conf

sec "module list"
./stagos-desktop --list | tr '\n' ' '; echo

sec "dry run of everything"
DRY_RUN=1 ./stagos-desktop > /tmp/dry.log 2>&1; t "dry run exits 0" test $? -eq 0
t "dry run changed nothing on disk" test ! -e "$HOME/.local/share/stagos/plasma"
tail -3 /tmp/dry.log

sec "package names resolve (incl. the heavy ones excluded from the real run)"
pacman -Sy --noconfirm >/dev/null 2>&1 || sudo pacman -Sy --noconfirm >/dev/null 2>&1
for p in blender freecad libreoffice-fresh qemu-desktop virt-manager libvirt dnsmasq chromium obsidian spotify-launcher openscad \
  arm-none-eabi-gcc arm-none-eabi-newlib mission-center gnome-disk-utility papers imv xournalpp gnome-calculator nodejs npm flatpak \
  keyd bluez bluez-utils networkmanager tlp tlp-rdw fwupd upower restic snapper snap-pac grub-btrfs inotify-tools gnome-keyring seahorse libsecret \
  pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol playerctl alsa-utils \
  inter-font ttf-jetbrains-mono ttf-nerd-fonts-symbols noto-fonts noto-fonts-emoji papirus-icon-theme $PLASMA_PKGS; do
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
for f in keyd/app.conf fontconfig/fonts.conf chromium-flags.conf foot/foot.ini stagos/desktop.env \
  systemd/user/stagos-restic.timer systemd/user/stagos-restic.service stagos/backup.env stagos/stag-services; do
  t "config/$f" test -s "$C/$f"
done
for f in /etc/keyd/default.conf /etc/tlp.d/50-stagos.conf /etc/systemd/logind.conf.d/50-stagos-lid.conf; do
  t "$f" test -x "$f" -o -s "$f"
done
t "stag-backup, stag-update, stag-battery in /usr/local/bin; no labwc-era stagos-backup" bash -c "test -x /usr/local/bin/stag-backup -a -x /usr/local/bin/stag-update -a -x /usr/local/bin/stag-battery && test ! -e $HOME/.local/bin/stagos-backup -a ! -e /usr/local/bin/stagos-backup"
t "restic password file created once, 600" bash -c "test -s $C/stagos/restic.pass && test \$(stat -c %a $C/stagos/restic.pass) = 600"
t "backup excludes installed" cmp desktop/backup/backup.exclude "$C/stagos/backup.exclude"
safety_power
safety_update
t "6 stag launchers"  bash -c "test \$(ls $HOME/.local/share/applications/stag-*.desktop | wc -l) -eq 6"
t "stag urls only in home, not repo" bash -c "! grep -rq 'stag.test.invalid' $PWD --include='*' --exclude=local.conf --exclude-dir=.git --exclude='desktop-container*'"
t "stag desktop entries valid Exec" grep -q 'Exec=chromium --app=https://stag.test.invalid/tasks/' "$HOME/.local/share/applications/stag-tasks.desktop"
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
t "systemd-analyze verify restic units" systemd-analyze verify "$C/systemd/user/stagos-restic.service" "$C/systemd/user/stagos-restic.timer"
t "systemd-analyze verify the keyd per-app unit" systemd-analyze --user verify "$C/systemd/user/stagos-keyd-apps.service"
t "logind drop-in syntax" grep -q '^HandleLidSwitch=suspend' /etc/systemd/logind.conf.d/50-stagos-lid.conf

sec "a fresh run installs nothing the labwc cleanup would remove"
# shellcheck source=lib/labwc-cleanup.sh
source lib/labwc-cleanup.sh
for p in "${STAGOS_LABWC_PKGS[@]}"; do t "not installed: $p" bash -c "! pacman -Q $p"; done
t "no old helpers in /usr/local/bin (the current stag-battery is not one)" bash -c "HERE=\$PWD; source lib/common.sh; source lib/desktop.sh; source lib/labwc-cleanup.sh; test -z \"\$(lc_bins)\""

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
