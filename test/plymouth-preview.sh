#!/usr/bin/env bash
# Render the StagOS Plymouth theme headless and screenshot each state. Needs podman (Arch container; installs
# plymouth, gtk3 for plymouth's x11 renderer, Xvfb, imagemagick and xdotool into it). plymouthd runs inside the
# container against a virtual X display, so no GPU, framebuffer or VT is used and the host is untouched.
#   ./test/plymouth-preview.sh [OUTDIR]     default OUTDIR: assets/plymouth/preview (committed reference shots)
# Shots: boot-early/boot-later (ring + progress line), prompt-empty, prompt-typed (dots), prompt-error, prompt-submitted.
# Fails if plymouthd does not parse and run the script or any shot is blank.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="$(realpath -m "${1:-assets/plymouth/preview}")"
if [[ "${PLY_INNER:-}" != 1 ]]; then
  mkdir -p "$OUT" "${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}"
  exec flock "$HOME/.cache/stagos-podman.lock" nice -n 15 ionice -c3 podman run --rm -e PLY_INNER=1 \
    -v "${STAGOS_TEST_CACHE:-/tmp/stagos-pkgcache}:/var/cache/pacman/pkg" -v "$PWD:/src:ro" -v "$OUT:/out" \
    docker.io/archlinux:latest bash /src/test/plymouth-preview.sh /out
fi

pacman -Sy --noconfirm >/dev/null 2>&1
pacman -S --needed --noconfirm plymouth gtk3 xorg-server-xvfb imagemagick xdotool >/dev/null 2>&1
mkdir -p /usr/share/plymouth/themes/stagos
cp /src/assets/plymouth/stagos/* /usr/share/plymouth/themes/stagos/
plymouth-set-default-theme stagos
themes="$(plymouth-set-default-theme -l)"; grep -qx stagos <<<"$themes"
Xvfb :99 -screen 0 1280x720x24 >/tmp/xvfb.log 2>&1 &
sleep 2
export DISPLAY=:99
LOG=/tmp/ply.log
# plymouthd wants a terminal: give it a pty
script -qfc "plymouthd --no-daemon --debug --debug-file=$LOG --mode=boot --graphical-boot --no-boot-log --tty=\$(tty)" /tmp/plymouthd.out >/dev/null 2>&1 </dev/null &
sleep 3
plymouth show-splash
sleep 3; import -window root "$OUT/boot-early.png"
sleep 9; import -window root "$OUT/boot-later.png"
ask() { plymouth ask-for-password --prompt="Enter passphrase" > /tmp/pw.txt 2>&1 & }
ask; sleep 3; import -window root "$OUT/prompt-empty.png"
xdotool type --delay 100 "hunter2abc"; sleep 1; import -window root "$OUT/prompt-typed.png"
xdotool key Return; sleep 1; import -window root "$OUT/prompt-submitted.png"
wait %3 2>/dev/null || true
ask; sleep 3; import -window root "$OUT/prompt-error.png"
xdotool key Return; sleep 1
plymouth quit; sleep 1

grep -q 'executing script file' "$LOG" || { echo "FAIL: plymouthd never ran the script"; exit 1; }
if grep -qiE 'parse error|syntax error|script.*(fail|error)' "$LOG"; then grep -iE 'parse error|syntax error|script.*(fail|error)' "$LOG"; echo "FAIL: script error"; exit 1; fi
# every shot must show more than the flat background: some pixel brighter than the 10,10,10 fill
for f in boot-early boot-later prompt-empty prompt-typed prompt-error prompt-submitted; do
  max="$(magick "$OUT/$f.png" -format '%[fx:maxima*255]' info:)"
  [[ "${max%.*}" -gt 40 ]] || { echo "FAIL: $f.png is blank"; exit 1; }
done
# the ring must be visible while booting (the middle of the screen is empty background otherwise)
mid="$(magick "$OUT/boot-later.png" -crop 480x340+400+150 -format '%[fx:maxima*255]' info:)"
[[ "${mid%.*}" -gt 40 ]] || { echo "FAIL: no logo ring in the boot shot"; exit 1; }
echo "ok: theme parsed and ran; shots in $OUT"
