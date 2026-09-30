#!/usr/bin/env bash
# Run the stagos-desktop modules inside a rootless podman Arch container and check the result.
#   ./test/desktop-container.sh install    static checks, dry run, REAL run 1 (kept as a local image)
#   ./test/desktop-container.sh verify     from that image: run 2 (idempotent), per-module reruns, file
#                                          and config validation, headless labwc/waybar/swaync, btrfs branch
#   ./test/desktop-container.sh all        install then verify (slow on a 2014 mac mini: > 10 min)
#   ./test/desktop-container.sh keys bar   real run of just those modules in a fresh container
# Runs under nice/ionice. Package cache: $CACHE. Clean up afterwards with
#   ./test/desktop-container.sh clean
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
LOG="${STAGOS_TEST_LOG:-/tmp/stagos-desktop-container.log}"
BASE=docker.io/archlinux:latest
STAGE=localhost/stagos-desktop-stage1
mkdir -p "$CACHE"
pod() { nice -n 15 ionice -c3 podman run --rm -v "$CACHE:/var/cache/pacman/pkg" -v "$PWD:/src:ro" "$@"; }

phase_install() {
  podman rm -f stagos-stage1 >/dev/null 2>&1 || true
  nice -n 15 ionice -c3 podman run --name stagos-stage1 -v "$CACHE:/var/cache/pacman/pkg" -v "$PWD:/src:ro" \
    "$BASE" bash /src/test/desktop-container-inner.sh install
  podman commit stagos-stage1 "$STAGE" >/dev/null
  podman rm stagos-stage1 >/dev/null
}
phase_verify() { pod "$STAGE" bash /src/test/desktop-container-inner.sh verify; }

case "${1:-all}" in
  install) phase_install 2>&1 | tee "$LOG" ;;
  verify)  phase_verify 2>&1 | tee -a "$LOG" ;;
  all)     { phase_install; phase_verify; } 2>&1 | tee "$LOG" ;;
  clean)   podman rmi -f "$STAGE" "$BASE" 2>/dev/null || true; podman rm -f stagos-stage1 2>/dev/null || true
           rm -rf "$CACHE" 2>/dev/null || podman unshare rm -rf "$CACHE"; echo cleaned ;;
  *)       pod "$BASE" bash /src/test/desktop-container-inner.sh modules "$@" 2>&1 | tee "$LOG" ;;
esac
