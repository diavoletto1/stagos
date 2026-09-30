#!/usr/bin/env bash
# StagOS widgets in the podman test container: the plasma phase of desktop-container.sh (module plasma, run 1,
# run 2, Plasma checks incl. the widget checks and unit tests), then the visual smoke (test/stag-widgets-smoke.sh).
#   ./test/stag-widgets-container.sh [OUTDIR]     screenshots + logs in OUTDIR (default /tmp/stag-widgets-out)
# Serialized with other agents' container runs (flock), nice/ionice, same package cache as desktop-container.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
OUT="${1:-/tmp/stag-widgets-out}"
mkdir -p "$CACHE" "$OUT"; chmod 777 "$OUT"
exec flock "$HOME/.cache/stagos-podman.lock" nice -n 15 ionice -c3 podman run --rm \
  -v "$CACHE:/var/cache/pacman/pkg" -v "$PWD:/src:ro" -v "$OUT:/out" docker.io/archlinux:latest bash -c '
    bash /src/test/desktop-container-inner.sh plasma; echo "PLASMA PHASE EXIT $?"
    setcap -r /usr/bin/kwin_wayland 2>/dev/null || true   # the file capability makes exec fail in rootless podman
    su jack -c "cd ~/stagos && bash test/stag-widgets-smoke.sh /out"; echo "SMOKE EXIT $?"'
