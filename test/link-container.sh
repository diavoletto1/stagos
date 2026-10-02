#!/usr/bin/env bash
# Modules link + lab for real in the rootless podman Arch container: packages, files, run 2 changes 0 files,
# the KDE Connect drop-in through `nft -c` inside an input chain, `sshd -t` with the lab drop-in, the
# notifier and runner against the packaged python-dbus/gobject (KRunner D-Bus activation on a private bus).
#   ./test/link-container.sh            log in /tmp/stagos-link-container.log
# --cap-add NET_ADMIN is for `nft -c` only, inside the container's own network namespace.
# Serialized with other container runs (flock), nice/ionice, same package cache as desktop-container.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
LOG="${STAGOS_TEST_LOG:-/tmp/stagos-link-container.log}"
mkdir -p "$CACHE"
flock "$HOME/.cache/stagos-podman.lock" nice -n 15 ionice -c3 podman run --rm --cap-add NET_ADMIN -v "$CACHE:/var/cache/pacman/pkg" \
  -v "$PWD:/src:ro" docker.io/archlinux:latest bash /src/test/link-container-inner.sh 2>&1 | tee "$LOG"
exit "${PIPESTATUS[0]}"
