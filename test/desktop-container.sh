#!/usr/bin/env bash
# Run the stagos-desktop modules inside a rootless podman Arch container and check the result.
#   ./test/desktop-container.sh all        static checks, dry run, REAL run 1, run 2 (must change 0 files),
#                                          per-module reruns, config validation, headless labwc/waybar/swaync,
#                                          btrfs branch. One container; takes a while on a 2014 mac mini.
#   ./test/desktop-container.sh install    only the first half (through the real run)
#   ./test/desktop-container.sh plasma     module plasma only: dry run, run 1, run 2 (0 changes), Plasma config and
#                                          session checks, helper unit tests
#   ./test/desktop-container.sh keys bar   real run of just those modules in a fresh container
#   ./test/desktop-container.sh clean      remove the pulled image and the package cache
# Runs under nice/ionice. Package cache: $CACHE (reused between runs).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
LOG="${STAGOS_TEST_LOG:-/tmp/stagos-desktop-container.log}"
BASE=docker.io/archlinux:latest
mkdir -p "$CACHE"
pod() { nice -n 15 ionice -c3 podman run --rm -v "$CACHE:/var/cache/pacman/pkg" -v "$PWD:/src:ro" "$BASE" bash /src/test/desktop-container-inner.sh "$@"; }
case "${1:-all}" in
  all|install|plasma) pod "${1:-all}" 2>&1 | tee "$LOG" ;;
  clean) podman rmi -f "$BASE" 2>/dev/null || true; rm -rf "$CACHE" 2>/dev/null || podman unshare rm -rf "$CACHE"; echo cleaned ;;
  *)     pod modules "$@" 2>&1 | tee "$LOG" ;;
esac
