#!/usr/bin/env bash
# Runs INSIDE the container as root (see desktop-container.sh). Phases: all | install | plasma | migrate | fresh | modules <names...>
set -euo pipefail
phase="${1:-install}"; shift || true
# multi-GB; names are checked to resolve. STAGOS_APPS_EXCLUDE_EXTRA: more to skip (test/fresh-install-container.sh)
export STAGOS_APPS_EXCLUDE="blender freecad libreoffice-fresh qemu-desktop virt-manager ${STAGOS_APPS_EXCLUDE_EXTRA:-}"
export STAGOS_KEYRING_EMPTY=1

if true; then
  pacman -Sy --noconfirm >/dev/null
  pacman -S --needed --noconfirm sudo git shellcheck libxml2 systemd python >/dev/null 2>&1
  useradd -m -G wheel -s /bin/bash jack 2>/dev/null || true
  echo 'jack ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/jack
  # fixtures: heavy or network-bound tools are faked (AUR builds, flatpak installs)
  install -m755 /src/test/fixtures/bin/paru /src/test/fixtures/bin/flatpak /usr/local/bin/
fi
# fresh copy of the repo every phase (the image keeps only what the modules installed)
rm -rf /home/jack/stagos; cp -a /src /home/jack/stagos
cat > /home/jack/stagos/config/local.conf <<'CONF'
STAGOS_STAG_HOST="stag.test.invalid"
STAGOS_STAG_SCHEME="https"
STAGOS_STAG_PATHS=(tasks maps control lab media fitness)
STAGOS_RESTIC_REPO="/tmp/restic-test-repo"
STAGOS_RESTIC_PASSWORD_FILE="$HOME/.config/stagos/restic.pass"
CONF
# migrate phase: the labwc-era StagOS tree (git archive of the old ref, see test/labwc-migrate-container.sh)
if [[ -d /old ]]; then rm -rf /home/jack/stagos-old; cp -a /old /home/jack/stagos-old; chown -R jack:jack /home/jack/stagos-old; fi
chown -R jack:jack /home/jack/stagos
exec su jack -c "cd ~/stagos && STAGOS_APPS_EXCLUDE='$STAGOS_APPS_EXCLUDE' STAGOS_KEYRING_EMPTY=1 bash test/desktop-container-user.sh $phase $*"
