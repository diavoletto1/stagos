#!/usr/bin/env bash
# StagOS widgets in the podman test container: the plasma phase of desktop-container.sh (module plasma, run 1,
# run 2, Plasma checks incl. the widget checks and unit tests), then the visual smoke (test/stag-widgets-smoke.sh).
#   ./test/stag-widgets-container.sh [OUTDIR]     screenshots + logs in OUTDIR (default /tmp/stag-widgets-out)
#   ./test/stag-widgets-container.sh --smoke-only [OUTDIR]   module plasma (one real run), then the smoke
# Serialized with other agents' container runs (flock), nice/ionice, same package cache as desktop-container.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
PHASE=plasma
if [[ "${1:-}" == --smoke-only ]]; then PHASE="modules plasma"; shift; fi
OUT="${1:-/tmp/stag-widgets-out}"
mkdir -p "$CACHE" "$OUT"; chmod 777 "$OUT"
# shellcheck disable=SC2016  # $PHASE and $? expand inside the container
exec flock "$HOME/.cache/stagos-podman.lock" nice -n 15 ionice -c3 podman run --rm \
  -v "$CACHE:/var/cache/pacman/pkg" -v "$PWD:/src:ro" -v "$OUT:/out" -e PHASE="$PHASE" docker.io/archlinux:latest bash -c '
    bash /src/test/desktop-container-inner.sh $PHASE; echo "PLASMA PHASE ($PHASE) EXIT $?"
    setcap -r /usr/bin/kwin_wayland 2>/dev/null || true   # the file capability makes exec fail in rootless podman
    su jack -c "cd ~/stagos && bash test/stag-widgets-smoke.sh /out"; echo "SMOKE EXIT $?"'
