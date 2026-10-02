#!/usr/bin/env bash
# stag-update's Arch Linux Archive pin for real, in a rootless podman Arch container (needs network: the archive):
# --pin, a package install from the pinned day, --to (pacman -Syuu), a --to that fails and one that is interrupted
# (the old pin must come back), bad dates (nothing written), --unpin (the original mirrorlist, byte for byte), and
# pacman still syncs at the end. The mirrorlist is checked after every step: it always parses and names a server.
#   ./test/update-pin-container.sh [PIN_DATE [TO_DATE]]     defaults: 8 and 5 days ago
# Runs under flock (one container at a time on this box) and nice/ionice. Package cache: $CACHE (reused).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ "${1:-}" == --inner ]]; then
  shift
  PIN="$1" TO="$2"
  pass=0 fail=0
  check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi; }
  ML=/etc/pacman.d/mirrorlist
  # shellcheck disable=SC2317,SC2329  # run through check
  sane() { # the mirrorlist parses and core resolves to at least one server
    [ -s "$ML" ] && pacman-conf --repo core Server 2>/dev/null | grep -q '^http'
  }
  # stag-update calls sudo; the container runs as root. FAILPAC=fail|hang makes pacman -Syu/-Syuu fail or hang.
  cat > /usr/local/bin/sudo <<'EOF'
#!/bin/bash
if [ "$1" = pacman ] && [[ "${2:-}" == -Syu* ]]; then
  case "${FAILPAC:-}" in fail) echo "fake: pacman failed" >&2; exit 1 ;; hang) exec sleep 600 ;; esac
fi
exec "$@"
EOF
  chmod +x /usr/local/bin/sudo
  install -m755 /src/desktop/bin/stag-update.sh /usr/local/bin/stag-update
  export STAGOS_ROOT_FSTYPE=ext4 HOME=/root
  pacman -Sy --noconfirm --needed pacman-contrib >/dev/null 2>&1 || true
  cp -p "$ML" /tmp/orig; ORIG_SHA="$(sha256sum < "$ML")"
  # shellcheck disable=SC2317,SC2329  # run through check
  same() { [ "$(sha256sum < "$1")" = "$(sha256sum < "$2")" ]; }   # no cmp (diffutils) in the base image

  echo "== bad dates write nothing =="
  check "--pin in the future refuses" bash -c "! stag-update --pin 2099/01/01"
  check "--pin a day the archive lacks refuses" bash -c "! stag-update --pin 2001/01/01"
  check "--pin garbage refuses" bash -c "! stag-update --pin yesterday"
  check "--to while not pinned refuses" bash -c "! stag-update --to $TO"
  check "mirrorlist untouched" test "$(sha256sum < "$ML")" = "$ORIG_SHA"

  echo; echo "== --pin $PIN =="
  check "--pin succeeds" stag-update --pin "$PIN"
  check "the original is kept as mirrorlist.stagos-unpinned" same /tmp/orig "$ML.stagos-unpinned"
  check "mirrorlist names the archive day" grep -q "^Server = https://archive.archlinux.org/repos/$PIN/\$repo/os/\$arch" "$ML"
  check "status says pinned" bash -c "stag-update --status | grep -q 'pinned: $PIN'"
  check "mirrorlist sane" sane
  check "pacman syncs from the archive" pacman -Sy --noconfirm
  check "a package installs from the pinned day" pacman -S --noconfirm --needed tree
  check "it came from the archive" bash -c "mkdir -p /tmp/nocache && pacman -Sp --cachedir /tmp/nocache tree | grep -q 'archive.archlinux.org/repos/$PIN/'"
  stag-update --pin "$PIN" >/dev/null 2>&1
  check "--pin again (re-pin) keeps the original backup" same /tmp/orig "$ML.stagos-unpinned"

  echo; echo "== --to that fails / is interrupted: the old pin comes back =="
  check "--to with a failing pacman exits non-zero" bash -c "! yes y | FAILPAC=fail stag-update --to $TO"
  check "after the failure the mirrorlist is back on $PIN" grep -q "/repos/$PIN/" "$ML"
  check "mirrorlist sane" sane
  # Ctrl-C signals the whole foreground group (stag-update and the pacman it waits on): do the same
  # (job control on: a plain & job would start with SIGINT ignored, which a terminal's Ctrl-C never does)
  set -m
  FAILPAC=hang stag-update --to "$TO" < <(yes y) >/dev/null 2>&1 &
  p=$!
  set +m
  for _ in $(seq 120); do pgrep -x sleep >/dev/null && break; sleep 0.5; done
  check "--to reached pacman (hanging)" pgrep -x sleep
  kill -INT -- "-$p" 2>/dev/null || true
  rc=0; wait "$p" 2>/dev/null || rc=$?
  check "interrupted --to exits 130" test "$rc" = 130
  check "after Ctrl-C the mirrorlist is back on $PIN" grep -q "/repos/$PIN/" "$ML"
  check "no pacman left running" bash -c "! pgrep -x sleep"

  echo; echo "== --to $TO =="
  check "--to succeeds (pacman -Syuu)" bash -c "yes y | stag-update --to $TO"
  check "mirrorlist names $TO" grep -q "/repos/$TO/" "$ML"
  check "the backup is still the original" same /tmp/orig "$ML.stagos-unpinned"
  check "mirrorlist sane" sane
  check "the log has the run" grep -q 'stag-update' /root/.local/state/stagos/update.log

  echo; echo "== --unpin =="
  check "--unpin succeeds" stag-update --unpin
  check "the original mirrorlist is back, byte for byte" test "$(sha256sum < "$ML")" = "$ORIG_SHA"
  check "status says not pinned" bash -c "stag-update --status | grep -q 'pinned: no'"
  check "--unpin twice is harmless" stag-update --unpin
  check "pacman syncs from the normal mirrors" pacman -Sy --noconfirm
  check "--dry-run --pin writes nothing" bash -c "stag-update --dry-run --pin $PIN >/dev/null && test \"\$(sha256sum < $ML)\" = '$ORIG_SHA'"

  echo; echo "update-pin: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  exit
fi
CACHE="${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
PIN="${1:-$(date -d '8 days ago' +%Y/%m/%d)}"
TO="${2:-$(date -d '5 days ago' +%Y/%m/%d)}"
mkdir -p "$CACHE"
flock "$HOME/.cache/stagos-podman.lock" nice -n 15 ionice -c3 podman run --rm -v "$CACHE:/var/cache/pacman/pkg" \
  -v "$PWD:/src:ro" docker.io/archlinux:latest bash /src/test/update-pin-container.sh --inner "$PIN" "$TO"
