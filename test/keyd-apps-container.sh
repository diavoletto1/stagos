#!/usr/bin/env bash
# keyd per-app keys under Plasma, end to end in the podman test container: real KWin 6 (kwin_wayland on Xvfb, as in
# test/plasma-smoke.sh), the real keyd-application-mapper from the keyd package with the environment
# stagos-keyd-apps.service gives it, and a fake keyd (test/fixtures/bin/fake-keyd: the daemon needs /dev/uinput)
# that records every `keyd bind`. Also runs every desktop/keyd/app.conf row through the real `keyd check`.
#   ./test/keyd-apps-container.sh [OUTDIR]     logs in OUTDIR (default /tmp/keyd-apps-out)
# Serialized with other container runs (flock), nice/ionice, same package cache as desktop-container.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
OUT="${1:-/tmp/keyd-apps-out}"
mkdir -p "$CACHE" "$OUT"; chmod 777 "$OUT"
exec flock "$HOME/.cache/stagos-podman.lock" nice -n 15 ionice -c3 podman run --rm \
  -v "$CACHE:/var/cache/pacman/pkg" -v "$PWD:/src:ro" -v "$OUT:/out" docker.io/archlinux:latest bash -c '
    pacman -Sy --noconfirm >/dev/null
    pacman -S --needed --noconfirm kwin keyd python-dbus python-gobject foot ttf-dejavu xorg-server-xvfb qt6-wayland \
      >/dev/null 2>&1 || { echo "package install failed"; exit 1; }
    setcap -r /usr/bin/kwin_wayland 2>/dev/null || true   # the file capability makes exec fail in rootless podman
    useradd -m jack
    su jack -c "bash /src/test/keyd-apps-session.sh /out"'
