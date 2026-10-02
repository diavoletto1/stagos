#!/usr/bin/env bash
# Migration test for `./stagos-desktop cleanup-labwc` in rootless podman: a box first gets the labwc-era StagOS
# (STAGOS_OLD_REF, default main: provision 60-desktop + 65-extras and its desktop modules), then this tree's
# modules, then the cleanup (dry run, real run, second run), then the Plasma visual smoke (test/plasma-smoke.sh)
# to show Plasma still starts. Phase `migrate` of test/desktop-container-user.sh does the checks.
#   ./test/labwc-migrate-container.sh [OUTDIR]      screenshots + logs in OUTDIR (default /tmp/stagos-migrate-out)
# Serialized with other container runs (flock), nice/ionice, same package cache as desktop-container.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
OUT="${1:-/tmp/stagos-migrate-out}"
REF="${STAGOS_OLD_REF:-main}"
old="$(mktemp -d)"; trap 'rm -rf "$old"' EXIT
git archive "$REF" | tar -x -C "$old"
git rev-parse --short "$REF" > "$old/.stagos-ref"
mkdir -p "$CACHE" "$OUT"; chmod 777 "$OUT"
# shellcheck disable=SC2016  # $? expands inside the container
flock "$HOME/.cache/stagos-podman.lock" nice -n 15 ionice -c3 podman run --rm \
  -v "$CACHE:/var/cache/pacman/pkg" -v "$PWD:/src:ro" -v "$old:/old:ro" -v "$OUT:/out" docker.io/archlinux:latest bash -c '
    bash /src/test/desktop-container-inner.sh migrate; echo "MIGRATE PHASE EXIT $?"
    setcap -r /usr/bin/kwin_wayland 2>/dev/null || true   # the file capability makes exec fail in rootless podman
    su jack -c "cd ~/stagos && SHOT_PREFIX=migrate bash test/plasma-smoke.sh /out"; echo "SMOKE EXIT $?"'
