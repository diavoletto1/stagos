#!/usr/bin/env bash
# Runs INSIDE the container (see test/link-container.sh): root sets up, then the checks run as jack.
set -uo pipefail
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  pacman -Sy --noconfirm >/dev/null
  pacman -S --needed --noconfirm sudo diffutils python python-pytest nftables >/dev/null 2>&1 || { echo "base packages failed"; exit 1; }
  useradd -m -s /bin/bash jack 2>/dev/null || true
  echo 'jack ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/jack
  rm -rf /home/jack/stagos; cp -a /src /home/jack/stagos
  cat > /home/jack/stagos/config/local.conf <<'CONF'
STAGOS_STAG_HOST="stag.test.invalid"
STAGOS_STAG_PATHS=(tasks maps control)
STAGOS_NTFY_USER="stagpad"
STAGOS_LAB_SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly000000000000000000000 staglab@test"
STAGOS_LAB_SSH_FROM="100.64.0.1"
CONF
  chown -R jack:jack /home/jack/stagos
  exec su jack -c "bash /home/jack/stagos/test/link-container-inner.sh"
fi
cd ~/stagos || exit 1
pass=0; fail=0
t() { local n="$1" out; shift; if out=$("$@" 2>&1); then pass=$((pass+1)); echo "PASS $n"; else fail=$((fail+1)); echo "FAIL $n"; printf '%s\n' "$out" | head -8 | sed 's/^/     | /'; fi; }
sec() { echo; echo "=== $* ==="; }
C="$HOME/.config" D="$HOME/.local/share"

sec "run 1: link lab"
./stagos-desktop link lab > /tmp/run1.log 2>&1; t "run 1 exits 0" test $? -eq 0
tail -15 /tmp/run1.log
sec "run 2: nothing may change"
./stagos-desktop link lab > /tmp/run2.log 2>&1; t "run 2 exits 0" test $? -eq 0
grep -a 'wrote \|enabled \|chmod ' /tmp/run2.log | head
t "run 2 changed 0 files" grep -q 'files changed this run: 0$' /tmp/run2.log
for m in link lab; do
  ./stagos-desktop "$m" > "/tmp/mod-$m.log" 2>&1; t "module $m alone reruns clean" grep -q 'files changed this run: 0$' "/tmp/mod-$m.log"
done

sec "packages"
t "notifier/runner deps" pacman -Q python python-dbus python-gobject libnotify xdg-utils curl
t "kdeconnect + sshfs" pacman -Q kdeconnect sshfs
t "openssh (lab key set)" pacman -Q openssh
t "no node exporter by default" bash -c "! pacman -Q prometheus-node-exporter"

sec "files"
t "notifier installed 755" test "$(stat -c %a ~/.local/lib/stagos/stag-ntfy-notify)" = 755
t "runner installed 755" test "$(stat -c %a ~/.local/lib/stagos/stag-krunner)" = 755
t "link.env 600 with url, user, topics" bash -c "test \$(stat -c %a $C/stagos/link.env) = 600 && grep -qx 'NTFY_URL=https://stag.test.invalid:8443' $C/stagos/link.env && grep -qx 'NTFY_USER=stagpad' $C/stagos/link.env && grep -qx 'NTFY_TOPICS=stag-alerts,stag-agents' $C/stagos/link.env"
t "credentials template 600, empty" bash -c "test \$(stat -c %a $C/stagos/ntfy.credentials) = 600 && ! grep -qE '^NTFY_[A-Z]+=.+' $C/stagos/ntfy.credentials"
t "credentials never overwritten" bash -c "printf 'NTFY_PASSWORD=pw\n' > $C/stagos/ntfy.credentials && ./stagos-desktop link >/dev/null 2>&1 && grep -qx NTFY_PASSWORD=pw $C/stagos/ntfy.credentials"
t "credentials mode fixed back to 600" bash -c "chmod 644 $C/stagos/ntfy.credentials && ./stagos-desktop link >/dev/null 2>&1 && test \$(stat -c %a $C/stagos/ntfy.credentials) = 600"
t "notifier --check sees the config, prints no secret" bash -c "out=\$(python3 ~/.local/lib/stagos/stag-ntfy-notify --check 2>&1) && grep -q 'stag.test.invalid:8443' <<< \"\$out\" && ! grep -q pw <<< \"\$out\""
for f in systemd/user/stagos-ntfy.service systemd/user/stagos-krunner.service; do t "config/$f" cmp "desktop/link/${f##*/}" "$C/$f"; done
t "krunner plugin metadata" cmp desktop/link/stagos-krunner.desktop "$D/krunner/dbusplugins/stagos-krunner.desktop"
t "dbus activation with the real HOME" grep -qx "Exec=/usr/bin/python3 $HOME/.local/lib/stagos/stag-krunner" "$D/dbus-1/services/org.stagos.krunner.service"
t "icon + desktop entry" test -s "$D/icons/hicolor/scalable/apps/stag-ntfy.svg" -a -s "$D/applications/stag-ntfy.desktop"
t "systemd unit syntax (systemd-analyze verify)" bash -c "! command -v systemd-analyze >/dev/null || systemd-analyze --user verify $C/systemd/user/stagos-ntfy.service $C/systemd/user/stagos-krunner.service 2>&1 | grep -v -e 'Failed to connect' -e 'XDG_RUNTIME_DIR' -e 'not executable' | grep -q . && exit 1 || exit 0"

sec "KDE Connect firewall drop-in"
t "/etc/nftables.d/kdeconnect.nft from the repo" cmp desktop/link/kdeconnect.nft /etc/nftables.d/kdeconnect.nft
printf 'table inet stagos_test {\n chain input {\n  type filter hook input priority 0; policy drop;\n  ct state established,related accept\n  iifname "tailscale0" accept\n  include "/etc/nftables.d/*.nft"\n }\n}\n' > /tmp/fw.nft
t "nft -c: the drop-in inside an input chain" sudo nft -c -f /tmp/fw.nft

sec "lab: sshd"
t "sshd drop-in" grep -qx 'PasswordAuthentication no' /etc/ssh/sshd_config.d/50-stagos-lab.conf
t "Arch sshd_config includes sshd_config.d" grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config
sudo ssh-keygen -A >/dev/null 2>&1
t "sshd -t accepts the config" sudo sshd -t
t "effective sshd config: keys only, no root" bash -c "sudo sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' && sudo sshd -T | grep -qx 'permitrootlogin no' && sudo sshd -T | grep -qx 'authenticationmethods publickey'"
t "authorized_keys: one stagos-lab line limited to stagmini" bash -c "test \$(grep -c ' stagos-lab$' ~/.ssh/authorized_keys) = 1 && grep -q '^from=\"100.64.0.1\",no-agent-forwarding' ~/.ssh/authorized_keys && test \$(stat -c %a ~/.ssh/authorized_keys) = 600"

sec "notifier + runner on the packaged python"
t "pytest test/link" python3 -m pytest -q -p no:cacheprovider test/link
mkdir -p /tmp/kr/services /tmp/kr/bin /tmp/kr/fake; : > /tmp/kr/fake/log
cp "$D/dbus-1/services/org.stagos.krunner.service" /tmp/kr/services/
for x in stag-ctl notify-send; do ln -sf ~/stagos/test/fixtures/bin/fake-cmd "/tmp/kr/bin/$x"; done
cat > /tmp/kr/bus.conf <<'CONF'
<busconfig><type>session</type><listen>unix:dir=/tmp/kr</listen><servicedir>/tmp/kr/services</servicedir>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>
CONF
mkdir -p "$C/stagos"
printf 'maps|https://stag.test.invalid/maps/\nmedia|https://stag.test.invalid/media/\n' > "$C/stagos/stag-services"
t "krunner: D-Bus activation from the installed files, Match/Run" env FAKE_DIR=/tmp/kr/fake FAKE_LOG=/tmp/kr/fake/log \
  PATH="/tmp/kr/bin:$PATH" timeout 60 dbus-run-session --config-file=/tmp/kr/bus.conf -- python3 test/link/krunner_dbus.py /tmp/kr

echo; echo "LINK CONTAINER: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
