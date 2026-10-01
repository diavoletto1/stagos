#!/usr/bin/env bash
# The tty1 autostart block (what ~/.zprofile runs) and the stag-session gaps test/desktop-scripts.sh does not
# cover: tty1 starts the session, tty2 gets a plain shell, an existing Wayland session is left alone.
# stag-session itself (default choice, no Plasma -> labwc, two fast failures -> labwc, status, notify-daemon)
# is tested in test/desktop-scripts.sh. No display, no Plasma.   ./test/plasma-session.sh
# shellcheck disable=SC1091,SC2016  # sources lib/common.sh; fake scripts keep $* literal
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
T="$(mktemp -d)"; trap 'rm -rf "${T:?}"' EXIT
pass=0; fail=0
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi; }
source "$ROOT/lib/common.sh" 2>/dev/null
mkdir -p "$T/bin"

# a zprofile made the way stagos-desktop makes it, run by bash with fake tty / stag-session / labwc
block() { stagos_tty1_block > "$T/zprofile"; }
block
printf '#!/bin/sh\necho "$FAKE_TTY"\n' > "$T/bin/tty"
printf '#!/bin/sh\necho "stag-session $*" >> %s\n' "$T/log" > "$T/bin/stag-session"
printf '#!/bin/sh\necho "labwc $*" >> %s\n' "$T/log" > "$T/bin/labwc"
chmod +x "$T/bin/"*
run() { # run <tty> [extra env]: sources the block in a login-like shell, prints SHELL-REACHED if the block fell through
  : > "$T/log"
  env -i PATH="$T/bin:/usr/bin:/bin" FAKE_TTY="$1" "${@:2}" bash -c ". '$T/zprofile'; echo SHELL-REACHED" 2>&1
}
check "tty1 starts stag-session start"        bash -c "$(declare -f run); T='$T'; run /dev/tty1 >/dev/null; grep -qx 'stag-session start' '$T/log'"
check "tty1: no labwc when stag-session exists" bash -c "$(declare -f run); T='$T'; run /dev/tty1 >/dev/null; ! grep -q '^labwc' '$T/log'"
check "tty2 gets a plain shell (escape hatch)" bash -c "$(declare -f run); T='$T'; out=\$(run /dev/tty2); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
check "tty3, ssh (not a tty) get a plain shell" bash -c "$(declare -f run); T='$T'; out=\$(run 'not a tty'); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
check "tty1 inside a running Wayland session: no second session" bash -c "$(declare -f run); T='$T'; out=\$(run /dev/tty1 WAYLAND_DISPLAY=wayland-0); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
rm -f "$T/bin/stag-session"
check "tty1 without stag-session falls back to labwc" bash -c "$(declare -f run); T='$T'; run /dev/tty1 >/dev/null; grep -qx 'labwc ' '$T/log'"

# migration: the old block is replaced, the user's own lines survive, a second sync changes nothing
printf 'export EDITOR=vim\n\n# StagOS: autostart labwc on tty1\nif [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then\n  exec labwc\nfi\n' > "$T/old"
stagos_zprofile_sync "$T/old" >/dev/null 2>&1
check "migration: old exec-labwc block replaced"   bash -c "grep -q 'exec stag-session start' '$T/old' && ! grep -q 'autostart labwc on tty1' '$T/old'"
check "migration: user lines kept"                 grep -q '^export EDITOR=vim' "$T/old"
cp "$T/old" "$T/old2"; stagos_zprofile_sync "$T/old" >/dev/null 2>&1
check "second sync changes nothing"                 bash -c "test \"\$(cat '$T/old')\" = \"\$(cat '$T/old2')\" && test \$(grep -c '# StagOS: autostart' '$T/old') -eq 1"

echo; echo "plasma-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
