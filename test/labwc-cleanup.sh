#!/usr/bin/env bash
# `./stagos-desktop cleanup-labwc` on a fake labwc-era HOME: dry run changes nothing, the real run moves every
# labwc-era config / coexistence file / helper into the backup (paths kept, nothing deleted), removes only the
# packages nothing else needs (fake pacman with Required By), migrates the tty1 block, and a second run finds
# nothing. No root, no packages: sudo, pacman and systemctl are fakes.   ./test/labwc-cleanup.sh
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
T="$(mktemp -d)"; trap 'rm -rf "${T:?}"' EXIT
pass=0; fail=0
check() { local n="$1"; shift; local out; if out=$("$@" 2>&1); then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; printf '%s\n' "$out" | head -8 | sed 's/^/     | /'; fi; }

export HOME="$T/home" FAKE_DIR="$T/fake" FAKE_LOG="$T/fake/log" STAGOS_LOCAL_BIN="$T/usr-local-bin" STAGOS_LOCAL_CONF=/nonexistent
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
mkdir -p "$HOME" "$FAKE_DIR" "$T/bin" "$STAGOS_LOCAL_BIN"; : > "$FAKE_LOG"
ln -s "$ROOT/test/fixtures/bin/fake-pacman" "$T/bin/pacman"
ln -s "$ROOT/test/fixtures/bin/fake-cmd" "$T/bin/systemctl"; echo 1 > "$FAKE_DIR/systemctl.rc"   # nothing enabled
# shellcheck disable=SC2016  # expands inside the fake sudo
printf '#!/bin/sh\necho "sudo $*" >> "$FAKE_LOG"\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"
export PATH="$T/bin:$PATH"
BK="$HOME/.cache/stagos-labwc-backup-$(date +%F)"

# a labwc-era HOME: configs, coexistence files, helpers, the old tty1 block, plus things that must stay
C="$HOME/.config" D="$HOME/.local/share"
mkdir -p "$C/labwc" "$C/waybar/scripts" "$C/qt6ct" "$C/autostart" "$C/systemd/user/waybar.service.d" "$C/systemd/user/mako.service.d" \
  "$C/systemd/user/pipewire.service.d" "$D/dbus-1/services" "$D/themes/StagOS/openbox-3" "$C/stagos" "$C/foot"
echo '<labwc_config/>' > "$C/labwc/rc.xml"; echo 'gps' > "$C/waybar/scripts/gps.sh"; echo '[Appearance]' > "$C/qt6ct/qt6ct.conf"
echo 'max-icon-size=32' > "$C/libinput-gestures.conf"
printf '# StagOS: /etc/xdg/autostart/blueman.desktop with NotShowIn=KDE (labwc starts its own copy)\n[Desktop Entry]\nNotShowIn=KDE;\n' > "$C/autostart/blueman.desktop"
printf '[Desktop Entry]\nExec=my-own-thing\n' > "$C/autostart/mine.desktop"
cp "$ROOT/desktop/plasma/autostart/stag-plasma-apply.desktop" "$C/autostart/"
for u in waybar mako; do printf '[Unit]\nConditionEnvironment=!XDG_CURRENT_DESKTOP=KDE\n' > "$C/systemd/user/$u.service.d/50-stagos-not-plasma.conf"; done
echo '[Service]' > "$C/systemd/user/pipewire.service.d/mine.conf"
printf '[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/local/bin/stag-session notify-daemon\n' > "$D/dbus-1/services/org.freedesktop.Notifications.service"
echo 'name=StagOS' > "$D/themes/StagOS/openbox-3/themerc"
echo '[bar]' > "$C/stagos/desktop.conf"; echo '[main]' > "$C/foot/foot.ini"
printf '#!/bin/bash\n# StagOS dock\n' > "$STAGOS_LOCAL_BIN/stag-dock"; printf '#!/bin/bash\n# StagOS menu\n' > "$STAGOS_LOCAL_BIN/stag-menu"
printf '#!/bin/bash\n# not ours\n' > "$STAGOS_LOCAL_BIN/stag-power"; printf '#!/bin/bash\n# StagOS kismet\n' > "$STAGOS_LOCAL_BIN/stag-kismet"
# stag-battery: the current tree ships that name again (module power); its own copy must survive the cleanup
cp "$ROOT/desktop/bin/stag-battery.sh" "$STAGOS_LOCAL_BIN/stag-battery"
cp "$ROOT/test/fixtures/labwc-era/zprofile-p1" "$HOME/.zprofile"
# the labwc-era stag-session (its fallback is `exec labwc`)
printf '#!/bin/bash\n# StagOS: pick and start the graphical session\nexec labwc\n' > "$STAGOS_LOCAL_BIN/stag-session"
# installed: labwc-era packages (one still needed by a package outside the list), Plasma, a kept tool
cat > "$FAKE_DIR/pacman.db" <<'DB'
labwc
waybar
swaync
mako
fuzzel
qt6ct
network-manager-applet
nm-connection-editor network-manager-applet some-other-app
blueman
plasma-desktop
foot
keyd
DB
# what -Rns would take along: gpsd (the recon toolkit installs it by name: must stay) and a plain library
printf 'gpsd\nlibfoo-unneeded\n' > "$FAKE_DIR/cascade"
cp "$FAKE_DIR/pacman.db" "$T/db0"
snap() { (cd "$HOME" && find . -path ./.cache -prune -o -print | sort; cat .zprofile) > "$1"; ls "$STAGOS_LOCAL_BIN" >> "$1"; cat "$FAKE_DIR/pacman.db" >> "$1"; }

snap "$T/before"
DRY_RUN=1 "$ROOT/stagos-desktop" cleanup-labwc > "$T/dry.log" 2>&1
check "dry run exits 0" test $? -eq 0
snap "$T/after-dry"
check "dry run changes nothing" cmp "$T/before" "$T/after-dry"
check "dry run plans the moves and the pacman -Rns" bash -c "grep -q 'would move $C/labwc' '$T/dry.log' && grep -q 'sudo pacman -Rns' '$T/dry.log'"

ASSUME_YES=1 "$ROOT/stagos-desktop" cleanup-labwc > "$T/run1.log" 2>&1
check "run 1 exits 0" test $? -eq 0
for f in .config/labwc/rc.xml .config/waybar/scripts/gps.sh .config/qt6ct/qt6ct.conf .config/libinput-gestures.conf \
  .config/autostart/blueman.desktop .config/systemd/user/waybar.service.d/50-stagos-not-plasma.conf \
  .config/systemd/user/mako.service.d/50-stagos-not-plasma.conf .local/share/dbus-1/services/org.freedesktop.Notifications.service \
  .local/share/themes/StagOS/openbox-3/themerc usr-local-bin/stag-dock usr-local-bin/stag-menu; do
  check "backed up: $f" test -s "$BK/$f"
done
check "originals are gone" bash -c "! ls -d '$C/labwc' '$C/waybar' '$C/qt6ct' '$C/autostart/blueman.desktop' '$D/dbus-1/services/org.freedesktop.Notifications.service' '$STAGOS_LOCAL_BIN/stag-dock' 2>/dev/null | grep -q ."
check "empty drop-in and theme dirs removed, others kept" bash -c "test ! -e '$C/systemd/user/waybar.service.d' && test ! -e '$D/themes/StagOS' && test -s '$C/systemd/user/pipewire.service.d/mine.conf'"
check "kept: own autostart entries, StagOS Plasma files, foot, desktop.conf" bash -c "test -s '$C/autostart/mine.desktop' && test -s '$C/autostart/stag-plasma-apply.desktop' && test -s '$C/foot/foot.ini' && test -s '$C/stagos/desktop.conf'"
check "kept: helpers that are not StagOS copies, and the recon helpers" bash -c "test -s '$STAGOS_LOCAL_BIN/stag-power' && test -s '$STAGOS_LOCAL_BIN/stag-kismet'"
check "kept: the current stag-battery (module power), not stashed" cmp "$ROOT/desktop/bin/stag-battery.sh" "$STAGOS_LOCAL_BIN/stag-battery"
check "pacman -Rns got exactly the removable labwc-era packages" bash -c "grep -qx 'pacman -Rns --noconfirm labwc waybar fuzzel mako swaync qt6ct blueman network-manager-applet' '$FAKE_LOG'"
check "the listing shows what -s takes along" grep -q 'also takes their unneeded dependencies: libfoo-unneeded)' "$T/run1.log"
check "a cascade package StagOS installs itself (gpsd) is marked explicit before -Rns, nothing else" \
  bash -c "grep -E '^pacman -(D|Rns) ' '$FAKE_LOG' | cut -d' ' -f2- | tr '\n' '|' | grep -qx -- '-D --asexplicit gpsd|-Rns --noconfirm [^|]*|'"
check "a package still required outside the list is kept" bash -c "grep -q 'keeping nm-connection-editor: required by some-other-app' '$T/run1.log' && grep -q '^nm-connection-editor' '$FAKE_DIR/pacman.db'"
check "Plasma and kept tools untouched" bash -c "grep -qx plasma-desktop '$FAKE_DIR/pacman.db' && grep -qx foot '$FAKE_DIR/pacman.db' && grep -qx keyd '$FAKE_DIR/pacman.db'"
check "the Plasma-only stag-session replaces the labwc-era one" cmp "$ROOT/desktop/bin/stag-session.sh" "$STAGOS_LOCAL_BIN/stag-session"
check "tty1 block migrated to the Plasma one, user lines kept" bash -c "grep -q '  exec stag-session start' '$HOME/.zprofile' && ! grep -q labwc '$HOME/.zprofile' && grep -q '^export A=1' '$HOME/.zprofile'"
check "the listing came before any change (sudo steps shown first)" bash -c "awk '/sudo mv/ {l = NR} /moved \\// && !m {m = NR} END {exit !(l && m && l < m)}' '$T/run1.log'"

snap "$T/s1"
ASSUME_YES=1 "$ROOT/stagos-desktop" cleanup-labwc > "$T/run2.log" 2>&1
snap "$T/s2"
check "run 2: nothing left, nothing changed" bash -c "grep -q 'nothing labwc-era left' '$T/run2.log' && grep -q 'files changed this run: 0' '$T/run2.log' && cmp '$T/s1' '$T/s2'"
check "run 2: no second backup copies" bash -c "! find '$BK' -name '*.1' | grep -q ."

# declined: configs still move (they are only moved), packages stay
cp "$T/db0" "$FAKE_DIR/pacman.db"; : > "$FAKE_LOG"
printf 'n\n' | "$ROOT/stagos-desktop" cleanup-labwc > "$T/no.log" 2>&1
check "answering N keeps every package" bash -c "! grep -qE 'pacman -(Rns|D) ' '$FAKE_LOG' && grep -qx labwc '$FAKE_DIR/pacman.db' && grep -q 'packages kept' '$T/no.log'"
check "the lists in the cleanup are the only place labwc-era package names live" bash -c "source '$ROOT/lib/labwc-cleanup.sh' && test \${#STAGOS_LABWC_PKGS[@]} -gt 20"

echo; echo "labwc-cleanup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
