#!/usr/bin/env bash
# The tty1 autostart block (what ~/.zprofile runs): tty1 execs stag-session start, the fallback login shell
# (STAGOS_NO_SESSION=1) does not start it again, tty2 is always a plain shell, an existing Wayland session is
# left alone, and older blocks (test/fixtures/labwc-era) are migrated.
# stag-session itself (fail counter, fallback message and shell, retry) is tested in test/desktop-scripts.sh.
# No display, no Plasma.   ./test/plasma-session.sh
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

# a zprofile made the way stagos-desktop makes it, run by bash with a fake tty / stag-session
stagos_tty1_block > "$T/zprofile"
printf '#!/bin/sh\necho "$FAKE_TTY"\n' > "$T/bin/tty"
printf '#!/bin/sh\necho "stag-session $*" >> %s\n' "$T/log" > "$T/bin/stag-session"
chmod +x "$T/bin/"*
run() { # run <tty> [extra env]: sources the block in a login-like shell, prints SHELL-REACHED if the block fell through
  : > "$T/log"
  env -i PATH="$T/bin:/usr/bin:/bin" FAKE_TTY="$1" "${@:2}" bash -c ". '$T/zprofile'; echo SHELL-REACHED" 2>&1
}
r() { bash -c "$(declare -f run); T='$T'; $1"; }
check "tty1 starts stag-session start"                   r "run /dev/tty1 >/dev/null; grep -qx 'stag-session start' '$T/log'"
check "tty1: stag-session replaces the login shell (exec)" r "out=\$(run /dev/tty1); ! grep -q SHELL-REACHED <<< \"\$out\""
check "tty1 fallback shell (STAGOS_NO_SESSION=1): no loop" r "out=\$(run /dev/tty1 STAGOS_NO_SESSION=1); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
check "tty2 gets a plain shell (escape hatch)"            r "out=\$(run /dev/tty2); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
check "tty3, ssh (not a tty) get a plain shell"           r "out=\$(run 'not a tty'); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
check "tty1 inside a running Wayland session: nothing"    r "out=\$(run /dev/tty1 WAYLAND_DISPLAY=wayland-0); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
rm -f "$T/bin/stag-session"
check "tty1 without stag-session: plain shell"           r "out=\$(run /dev/tty1); grep -q SHELL-REACHED <<< \"\$out\""
check "the block starts nothing but stag-session"        bash -c "test \$(grep -c 'exec ' '$T/zprofile') -eq 1"

# migration: the old block is replaced, the user's own lines survive, a second sync changes nothing
cp "$ROOT/test/fixtures/labwc-era/zprofile-labwc" "$T/old"
stagos_zprofile_sync "$T/old" >/dev/null 2>&1
check "migration: the oldest block replaced"   bash -c "grep -q '  exec stag-session start' '$T/old' && test \$(grep -c '# StagOS: autostart' '$T/old') -eq 1 && ! grep -q '^  exec [^s]' '$T/old'"
check "migration: user lines kept"                 grep -q '^export EDITOR=vim' "$T/old"
# the p1 block (stag-session, else the old session) is replaced as well
cp "$ROOT/test/fixtures/labwc-era/zprofile-p1" "$T/p1"
stagos_zprofile_sync "$T/p1" >/dev/null 2>&1
check "migration: p1 block replaced" bash -c "! grep -q '^  exec [^s]' '$T/p1' && grep -q '  exec stag-session start' '$T/p1' && grep -q '^export A=1' '$T/p1' && test \$(grep -c '# StagOS: autostart' '$T/p1') -eq 1"
cp "$T/old" "$T/old2"; stagos_zprofile_sync "$T/old" >/dev/null 2>&1
check "second sync changes nothing"                 bash -c "test \"\$(cat '$T/old')\" = \"\$(cat '$T/old2')\" && test \$(grep -c '# StagOS: autostart' '$T/old') -eq 1"

echo; echo "plasma-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
