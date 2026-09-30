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

if [[ "$phase" == install ]]; then
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
  swaync swayosd nwg-dock waybar fuzzel plocate libqalculate keyd blueman bluez bluez-utils grim slurp swappy wf-recorder cliphist wlsunset \
  tlp tlp-rdw swayidle swaylock wlopm fwupd upower restic snapper snap-pac grub-btrfs inotify-tools gnome-keyring seahorse libsecret \
  wtype libinput pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol playerctl alsa-utils nm-connection-editor network-manager-applet \
  inter-font ttf-jetbrains-mono ttf-nerd-fonts-symbols noto-fonts noto-fonts-emoji brightnessctl wlr-randr papirus-icon-theme; do
  t "pkg $p" pacman -Si "$p"
done

sec "REAL run 1 (all modules)"
./stagos-desktop > /tmp/run1.log 2>&1; t "run 1 exits 0" test $? -eq 0
tail -12 /tmp/run1.log
echo; echo "INSTALL PHASE: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
exit
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
for f in labwc/rc.xml labwc/autostart waybar/config.jsonc nwg-dock/style.css swaync/config.json swayosd/style.css fuzzel/fuzzel.ini \
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
t "dock pinned has stag + claude" bash -c "grep -q stag-maps ~/.cache/nwg-dock-pinned && grep -q claude ~/.cache/nwg-dock-pinned"
t "claude launcher" grep -q 'chromium --app=https://claude.ai' "$HOME/.local/share/applications/claude.desktop"
t "claude code CLI installed" test -x "$HOME/.local/bin/claude"
t "empty-password keyring created" test -s "$HOME/.local/share/keyrings/login.keyring"
t "keyring is plain-text (no password)" grep -q '^\[keyring\]' "$HOME/.local/share/keyrings/login.keyring"
t "AUR names went to (fake) paru" grep -q 'visual-studio-code-bin' /tmp/fake-tools.log
t "flathub ids went to (fake) flatpak" grep -q 'com.bambulab.BambuStudio' /tmp/fake-tools.log
t "tlp.d not conflicting with ppd" bash -c "! pacman -Q power-profiles-daemon"
t "capture-card NM drop-in untouched (module network)" bash -c "! test -e /etc/NetworkManager/conf.d/zz-stagos-mac.conf"
t "scale in env" grep -q 'STAGOS_OUTPUT_SCALE=1.5' "$C/stagos/desktop.env"
t "fc: sans -> Inter" bash -c "fc-match sans-serif | grep -qi inter"
t "fc: monospace -> JetBrains Mono" bash -c "fc-match monospace | grep -qi jetbrains"

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
(timeout 6 nwg-dock -p bottom -i 44 -nows -s "$HOME/.config/nwg-dock/style.css" > /tmp/nwgdock.log 2>&1) &
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
echo "--- nwgdock.log"; head -8 /tmp/nwgdock.log

sec "btrfs branch (simulated: real pacman installs, snapper/grub-btrfs actions dry)"
STAGOS_ROOT_FSTYPE=btrfs DRY_RUN=1 ./stagos-desktop snapshots > /tmp/btrfs.log 2>&1
t "btrfs path plans snapper create-config + grub-btrfs" bash -c "grep -q 'snapper -c root create-config /' /tmp/btrfs.log && grep -q 'grub-btrfsd' /tmp/btrfs.log"
t "btrfs path does not plan restic timer" bash -c "! grep -q 'stagos-restic.timer' /tmp/btrfs.log"
t "ext4 path plans restic timer" grep -q 'stagos-restic.timer' /tmp/dry.log

sec "helper unit tests"
t "test/desktop-scripts.sh" bash test/desktop-scripts.sh

echo; echo "CONTAINER RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
