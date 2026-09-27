#!/bin/bash
# Pull the latest StagOS repo from stag-mac over LAN, clean up the broken paru-bin, rerun provisioning.
set -euo pipefail
SRC="http://192.168.1.102:8080/stagos.tar.gz"
curl -fsS "$SRC" -o /tmp/stagos.tar.gz
tar xzf /tmp/stagos.tar.gz -C /tmp
cp -a /tmp/stagos/. /opt/stagos/
echo "[stagos] repo updated, removing broken paru-bin (sudo password may be asked)"
# shellcheck disable=SC2024  # tty redirect is intentional (sudo prompt when piped)
sudo pacman -Rns --noconfirm paru-bin < /dev/tty 2>/dev/null || true
exec bash /opt/stagos/provision.sh < /dev/tty
