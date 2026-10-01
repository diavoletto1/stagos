#!/usr/bin/env bash
# Runs as jack INSIDE the container of test/keyd-apps-container.sh: keyd-application-mapper against a real KWin.
# The mapper gets only what stagos-keyd-apps.service gives it (its Environment= lines, the session bus, HOME, PATH)
# and KEYD_BIN = the fake keyd. Then: foot gets focus -> foot's rows, another app -> no rows, foot again -> its rows.
set -uo pipefail
src=/src
out="${1:-/out}"
unit="$src/desktop/keyd/stagos-keyd-apps.service"
pass=0; fail=0
check() { # check "name" command...
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi
}
mkdir -p "$HOME/.config/keyd"
install -m644 "$src/desktop/keyd/app.conf" "$HOME/.config/keyd/app.conf"

# ---- every app.conf row is a valid keyd binding: the real parser (keyd check) on default.conf with the rows ----
# added to the layer they name. A broken row fails here; the negative control proves keyd check would notice.
rows_cfg() { # rows_cfg ROWFILE: default.conf with each "layer.key = action" row appended under its [layer...] header
  awk -v rows="$1" '
    BEGIN { while ((getline l < rows) > 0) { split(l, a, "."); layer = a[1]; sub(/^[^.]*\./, "", l); add[layer] = add[layer] l "\n" } }
    { print }
    /^\[/ { h = $0; gsub(/^\[|\]$/, "", h); sub(/:.*/, "", h); if (h in add) { printf "%s", add[h]; delete add[h] } }
    END { for (k in add) exit 3 }' "$src/desktop/keyd/default.conf"
}
sections="$(grep -E '^\[[^]]+\]$' "$HOME/.config/keyd/app.conf" | tr -d '[]')"
for s in $sections; do
  sed -n "/^\[$s\]\$/,/^\[/p" "$HOME/.config/keyd/app.conf" | grep -vE '^\[|^#|^$' > "/tmp/rows-$s"
  check "app.conf [$s]: $(wc -l < "/tmp/rows-$s") rows, every layer exists in default.conf" rows_cfg "/tmp/rows-$s"
  rows_cfg "/tmp/rows-$s" > "/tmp/check-$s.conf"
  check "app.conf [$s]: keyd check accepts every row" keyd check "/tmp/check-$s.conf"
done
echo 'cmd.c = not-an-action(' > /tmp/rows-bad; rows_cfg /tmp/rows-bad > /tmp/check-bad.conf
check "negative control: keyd check rejects a broken row" bash -c '! keyd check /tmp/check-bad.conf'

# ---- the mapper against KWin ----
export XDG_RUNTIME_DIR=/tmp/xdg-keyd
install -d -m 700 "$XDG_RUNTIME_DIR"
mkdir -p "$HOME/.config/systemd/user"; install -m644 "$unit" "$HOME/.config/systemd/user/"
check "systemd-analyze verify: the unit is clean (keyd installed)" systemd-analyze --user verify "$HOME/.config/systemd/user/${unit##*/}"
export FAKE_KEYD_LOG="$out/keyd-binds.log"; : > "$FAKE_KEYD_LOG"
exec_start="$(sed -n 's/^ExecStart=//p' "$unit")"
foot_rows="$(grep -vE '^\[|^#|^$' "/tmp/rows-foot" | paste -sd'|' | sed 's/|/ | /g')"

# shellcheck disable=SC2317,SC2329  # run by name below (export -f session; dbus-run-session -- bash -c session)
session() {
  local xv kw mp f1 f2 t0 n unit_env
  mapfile -t unit_env < <(sed -n 's/^Environment=//p' "$unit")
  wait_for() { # wait_for SECONDS LINE [FROM]: until the fake keyd log has exactly LINE after its first FROM lines
    t0=$SECONDS
    while [ $((SECONDS - t0)) -lt "$1" ]; do tail -n +"$((${3:-0} + 1))" "$FAKE_KEYD_LOG" | grep -qxF "$2" && return 0; sleep 0.5; done
    return 1
  }
  # before KWin is up the mapper must fail, not hang or exit 0: Restart=on-failure then retries until KWin is there
  # shellcheck disable=SC2016  # expands in the inner bash
  check "no KWin on the bus: the mapper exits non-zero (the unit restarts it)" bash -c \
    '! timeout 30 env -i HOME="$HOME" PATH="$PATH" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" "$@" KEYD_BIN=/bin/true "$exec_start" >"$out/mapper-nokwin.log" 2>&1' \
    _ "${unit_env[@]}"
  check "... because org.kde.KWin is missing" grep -q 'org.kde.KWin' "$out/mapper-nokwin.log"
  rm -f "$HOME/.config/keyd/app.lock"
  Xvfb :5 -screen 0 1024x700x24 >"$out/xvfb.log" 2>&1 & xv=$!
  sleep 2
  DISPLAY=:5 kwin_wayland --x11-display :5 --width 1024 --height 700 --socket wayland-9 --no-lockscreen >"$out/kwin.log" 2>&1 & kw=$!
  for _ in $(seq 60); do [ -S "$XDG_RUNTIME_DIR/wayland-9" ] && break; sleep 0.5; done
  echo "kwin $(kwin_wayland --version 2>/dev/null) alive: $(kill -0 "$kw" 2>/dev/null && echo yes || echo no)"

  env -i HOME="$HOME" PATH="$PATH" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" "${unit_env[@]}" \
    KEYD_BIN="$src/test/fixtures/bin/fake-keyd" FAKE_KEYD_LOG="$FAKE_KEYD_LOG" PYTHONUNBUFFERED=1 \
    "$exec_start" -v >"$out/mapper.log" 2>&1 & mp=$!
  touch "$out/mapper.log"
  for _ in $(seq 30); do grep -q 'detected' "$out/mapper.log" && break; sleep 0.5; done
  sleep 2   # the KWin script is loaded right after the backend is picked
  check "mapper picks the KDE backend" grep -qx 'kde detected' "$out/mapper.log"
  check "mapper is running" kill -0 "$mp"

  WAYLAND_DISPLAY=wayland-9 foot >/dev/null 2>&1 & f1=$!
  check "foot focused: keyd bind reset + foot's rows" wait_for 30 "bind | reset | $foot_rows"
  n="$(wc -l < "$FAKE_KEYD_LOG")"
  WAYLAND_DISPLAY=wayland-9 foot --app-id=org.stagos.notaterm >/dev/null 2>&1 & f2=$!
  check "another app focused: keyd bind reset, no rows" wait_for 30 'bind | reset' "$n"
  kill "$f2"; wait "$f2" 2>/dev/null
  t0=$SECONDS; while [ $((SECONDS - t0)) -lt 30 ]; do [ "$(tail -1 "$FAKE_KEYD_LOG")" != "bind | reset" ] && break; sleep 0.5; done
  # shellcheck disable=SC2016  # $1/$2 expand in the inner bash
  check "back to foot: its rows again" bash -c '[ "$(tail -1 "$1")" = "$2" ]' _ "$FAKE_KEYD_LOG" "bind | reset | $foot_rows"
  # shellcheck disable=SC2016  # $1 expands in the inner bash
  check "every bind call is a reset (nothing stays bound across windows)" bash -c '! grep -v "^bind | reset" "$1"' _ "$FAKE_KEYD_LOG"
  echo "mapper log:"; sed 's/^/  /' "$out/mapper.log"
  echo "keyd calls:"; sed 's/^/  /' "$FAKE_KEYD_LOG"
  kill "$f1" "$mp" "$kw" "$xv" 2>/dev/null; wait 2>/dev/null
  echo "RESULT $pass $fail"
}
export -f session check
export out src unit FAKE_KEYD_LOG exec_start foot_rows pass fail
r="$(timeout 300 dbus-run-session -- bash -c session | tee /dev/stderr | sed -n 's/^RESULT //p')"
read -r p f <<< "${r:-0 1}"
pass=$((pass + p)); fail=$((fail + f))
echo "keyd-apps: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
