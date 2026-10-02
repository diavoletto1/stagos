#!/usr/bin/env bash
# DRY_RUN=1 ./stagos-desktop (every module) on a clean Arch container must only print: no file under /etc, /usr,
# /var/lib or the user's HOME changes, no package gets installed. Rootless podman, no package downloads beyond sudo.
#   ./test/dryrun-container.sh
# Runs under flock (one container at a time on this box) and nice/ionice. Package cache: $CACHE (reused).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ "${1:-}" == --inner ]]; then
  set +e   # report every check below instead of stopping at the first non-zero
  pacman -Sy --noconfirm >/dev/null; pacman -S --needed --noconfirm sudo >/dev/null 2>&1
  useradd -m -G wheel -s /bin/bash jack 2>/dev/null || true   # same as desktop-container-inner.sh (skel copy is refused rootless)
  echo 'jack ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/jack
  cp -a /src /home/jack/stagos
  printf 'STAGOS_STAG_HOST="stag.test.invalid"\nSTAGOS_STAG_PATHS=(tasks maps)\nSTAGOS_RESTIC_REPO="/tmp/restic-test-repo"\nSTAGOS_LAB_SSH_PUBKEY="ssh-ed25519 AAAAtest staglab@server"\nSTAGOS_LAB_SSH_FROM="100.64.0.1"\n' \
    > /home/jack/stagos/config/local.conf
  chown -R jack:jack /home/jack/stagos
  snap() { find /etc /usr/local /usr/share/plymouth /var/lib/stagos /home/jack -path /home/jack/stagos -prune -o -print0 2>/dev/null \
    | sort -z | xargs -0 stat -c '%n %s %Y %a' 2>/dev/null; pacman -Qq; }
  snap > /tmp/before
  su jack -c 'cd ~/stagos && DRY_RUN=1 ./stagos-desktop' > /tmp/dry.log 2>&1
  rc=$?
  snap > /tmp/after
  pass=0 fail=0
  check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi; }
  check "DRY_RUN=1 ./stagos-desktop (all modules) exits 0" test "$rc" = 0
  for m in power snapshots update field link lab firewall boot network plasma; do
    check "the dry run went through module $m" grep -q "$m" /tmp/dry.log
  done
  # (no diffutils in the base image: comm lists what differs)
  check "nothing changed on disk or in the package set" test -z "$(comm -3 /tmp/before /tmp/after)"
  [ "$rc" = 0 ] || tail -30 /tmp/dry.log
  comm -3 /tmp/before /tmp/after | head -20
  echo "dryrun-container: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  exit
fi
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
mkdir -p "$CACHE"
flock "$HOME/.cache/stagos-podman.lock" nice -n 15 ionice -c3 podman run --rm -v "$CACHE:/var/cache/pacman/pkg" \
  -v "$PWD:/src:ro" docker.io/archlinux:latest bash /src/test/dryrun-container.sh --inner
