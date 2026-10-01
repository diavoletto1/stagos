#!/usr/bin/env bash
# The tty1 autostart block (what ~/.zprofile runs): tty1 starts stag-session, Plasma's clean end logs the tty out,
# a failed start (stag-session returns 1) leaves a plain login shell, tty2 is always a plain shell, an existing
# Wayland session is left alone, and older blocks (exec labwc, the p1 stag-session/labwc one) are migrated.
# stag-session itself (fail counter, fallback message, retry) is tested in test/desktop-scripts.sh.
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

# a zprofile made the way stagos-desktop makes it, run by bash with a fake tty / stag-session (rc from $SESSION_RC)
stagos_tty1_block > "$T/zprofile"
printf '#!/bin/sh\necho "$FAKE_TTY"\n' > "$T/bin/tty"
printf '#!/bin/sh\necho "stag-session $*" >> %s\nexit "${SESSION_RC:-0}"\n' "$T/log" > "$T/bin/stag-session"
chmod +x "$T/bin/"*
run() { # run <tty> [extra env]: sources the block in a login-like shell, prints SHELL-REACHED if the block fell through
  : > "$T/log"
  env -i PATH="$T/bin:/usr/bin:/bin" FAKE_TTY="$1" "${@:2}" bash -c ". '$T/zprofile'; echo SHELL-REACHED" 2>&1
}
r() { bash -c "$(declare -f run); T='$T'; $1"; }
check "tty1 starts stag-session start"                   r "run /dev/tty1 >/dev/null; grep -qx 'stag-session start' '$T/log'"
check "tty1: Plasma ran (rc 0) -> the login shell exits"  r "out=\$(run /dev/tty1); ! grep -q SHELL-REACHED <<< \"\$out\""
check "tty1: Plasma failed (rc 1) -> plain login shell"   r "out=\$(run /dev/tty1 SESSION_RC=1); grep -q SHELL-REACHED <<< \"\$out\" && grep -qx 'stag-session start' '$T/log'"
check "tty2 gets a plain shell (escape hatch)"            r "out=\$(run /dev/tty2); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
check "tty3, ssh (not a tty) get a plain shell"           r "out=\$(run 'not a tty'); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
check "tty1 inside a running Wayland session: nothing"    r "out=\$(run /dev/tty1 WAYLAND_DISPLAY=wayland-0); test -z \"\$(cat '$T/log')\" && grep -q SHELL-REACHED <<< \"\$out\""
rm -f "$T/bin/stag-session"
check "tty1 without stag-session: plain shell"           r "out=\$(run /dev/tty1); grep -q SHELL-REACHED <<< \"\$out\""
check "the block never mentions another session"         bash -c "! grep -qiE 'labwc|sway' '$T/zprofile'"

# migration: the old block is replaced, the user's own lines survive, a second sync changes nothing
printf 'export EDITOR=vim\n\n# StagOS: autostart labwc on tty1\nif [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then\n  exec labwc\nfi\n' > "$T/old"
stagos_zprofile_sync "$T/old" >/dev/null 2>&1
check "migration: old exec-labwc block replaced"   bash -c "grep -q '  stag-session start && exit 0' '$T/old' && ! grep -q 'autostart labwc on tty1' '$T/old'"
check "migration: user lines kept"                 grep -q '^export EDITOR=vim' "$T/old"
# the p1 block (stag-session, else exec labwc) is replaced as well
printf 'export A=1\n\n# StagOS: autostart the desktop on tty1 (stag-session: Plasma or labwc)\nif [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then\n  if command -v stag-session >/dev/null 2>&1; then exec stag-session start; fi\n  exec labwc\nfi\n' > "$T/p1"
stagos_zprofile_sync "$T/p1" >/dev/null 2>&1
check "migration: p1 stag-session/labwc block replaced" bash -c "! grep -q labwc '$T/p1' && grep -q '  stag-session start && exit 0' '$T/p1' && grep -q '^export A=1' '$T/p1' && test \$(grep -c '# StagOS: autostart' '$T/p1') -eq 1"
cp "$T/old" "$T/old2"; stagos_zprofile_sync "$T/old" >/dev/null 2>&1
check "second sync changes nothing"                 bash -c "test \"\$(cat '$T/old')\" = \"\$(cat '$T/old2')\" && test \$(grep -c '# StagOS: autostart' '$T/old') -eq 1"

echo; echo "plasma-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
