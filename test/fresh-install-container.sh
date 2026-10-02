#!/usr/bin/env bash
# Fresh install in rootless podman: a clean Arch container gets provision's desktop steps (60-desktop, 65-extras),
# then every stagos-desktop module, then both again (0 changes), checks that nothing labwc-era is installed, and
# ends with the Plasma visual smoke (test/plasma-smoke.sh). Phase `fresh` of test/desktop-container-user.sh.
#   ./test/fresh-install-container.sh [OUTDIR]      screenshots + logs in OUTDIR (default /tmp/stagos-fresh-out)
# Heavy apps that have nothing to do with the session are skipped (STAGOS_APPS_EXCLUDE_EXTRA); chromium stays
# (module stag). Serialized with other container runs (flock), nice/ionice, same package cache as the others.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
OUT="${1:-/tmp/stagos-fresh-out}"
EXTRA="${STAGOS_APPS_EXCLUDE_EXTRA-obsidian spotify-launcher arm-none-eabi-gcc arm-none-eabi-newlib mission-center xournalpp gnome-disk-utility papers openscad}"
mkdir -p "$CACHE" "$OUT"; chmod 777 "$OUT"
# shellcheck disable=SC2016  # $? and $SHOT_PREFIX expand inside the container
flock "$HOME/.cache/stagos-podman.lock" nice -n 15 ionice -c3 podman run --rm \
  -v "$CACHE:/var/cache/pacman/pkg" -v "$PWD:/src:ro" -v "$OUT:/out" -e STAGOS_APPS_EXCLUDE_EXTRA="$EXTRA" \
  -e SHOT_PREFIX="${SHOT_PREFIX:-fresh}" docker.io/archlinux:latest bash -c '
    bash /src/test/desktop-container-inner.sh fresh; echo "FRESH PHASE EXIT $?"
    setcap -r /usr/bin/kwin_wayland 2>/dev/null || true   # the file capability makes exec fail in rootless podman
    su jack -c "cd ~/stagos && SHOT_PREFIX=$SHOT_PREFIX bash test/plasma-smoke.sh /out"; echo "SMOKE EXIT $?"'
