#!/usr/bin/env bash
# keyd per-app keys under Plasma, without a session: the plasma module's stagos_plasma_keyd_apps (packages, the
# stagos-keyd-apps.service user unit, enable, start inside Plasma, second run 0 changes) against fakes, plus the
# invariants between desktop/keyd/app.conf, default.conf and the unit. The real mapper against a real KWin runs in
# test/keyd-apps-container.sh.   ./test/keyd-apps.sh
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { # check "name" command...
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi
}
UNIT="$ROOT/desktop/keyd/stagos-keyd-apps.service"
APP="$ROOT/desktop/keyd/app.conf"

# ---- invariants ----
check "unit: started by Plasma (plasma-workspace.target), part of the graphical session" \
  bash -c "grep -qx 'WantedBy=plasma-workspace.target' '$UNIT' && grep -qx 'PartOf=graphical-session.target' '$UNIT'"
check "unit: runs the keyd package's mapper, gated on it and app.conf" \
  bash -c "grep -qx 'ExecStart=/usr/bin/keyd-application-mapper' '$UNIT' && grep -qx 'ConditionPathExists=/usr/bin/keyd-application-mapper' '$UNIT' \
    && grep -qx 'ConditionPathExists=%h/.config/keyd/app.conf' '$UNIT'"
check "unit: KDE backend forced (KDE_SESSION_VERSION=6), retried on failure" \
  bash -c "grep -qx 'Environment=KDE_SESSION_VERSION=6' '$UNIT' && grep -qx 'Restart=on-failure' '$UNIT'"
check "unit: no rows left bound after Plasma stops" grep -qx 'ExecStopPost=-/usr/bin/keyd bind reset' "$UNIT"
check "unit: not daemonized (-d would leave systemd tracking a dead parent)" bash -c "! grep -q 'keyd-application-mapper -d' '$UNIT'"
# the mapper matches the normalized window class (KWin's resourceClass, the Wayland app_id: foot and footclient = foot)
check "app.conf: section names are normalized classes (lowercase, [a-z0-9-])" \
  bash -c "! grep -E '^\[' '$APP' | grep -vE '^\[[a-z0-9-]+(\|[^]]*)?\]$'"
check "app.conf: every row is layer.key = action" bash -c "! grep -vE '^\[|^#|^$' '$APP' | grep -vE '^[a-z0-9+]+\.[a-z0-9]+ = [A-Za-z0-9-]+$'"
check "app.conf: every row's layer is a layer of default.conf" bash -c "
  for l in \$(grep -vE '^\[|^#|^$' '$APP' | cut -d. -f1 | sort -u); do grep -qE \"^\[\$l(:[A-Z-]+)?\]\$\" '$ROOT/desktop/keyd/default.conf' || exit 1; done"
check "app.conf: foot overrides every Cmd key default.conf maps" bash -c "
  for k in \$(sed -n '/^\[cmd:M\]/,/^\[/p' '$ROOT/desktop/keyd/default.conf' | sed -n 's/^\([a-z]\) = .*/\1/p'); do
    sed -n '/^\[foot\]/,/^\[/p' '$APP' | grep -q \"^cmd\.\$k = \" || exit 1; done"
check "foot.ini: no key-bindings override (Ctrl+Shift+C/V stay copy/paste)" bash -c "! grep -qiE '^\[key-bindings\]|clipboard-(copy|paste)' '$ROOT/desktop/foot/foot.ini'"
check "base.kconf: Alt+F4 (foot's Super+Q/W) not taken from KWin's Window Close" bash -c "! grep -qiE 'Alt\+F4' '$ROOT/desktop/plasma/base.kconf'"

# ---- stagos_plasma_keyd_apps against fakes ----
sandbox() { # fresh HOME, fake dir and PATH; $@ = extra tools that are "installed" (fake-cmd)
  rm -rf "${T:?}/home" "${T:?}/fake" "${T:?}/bin"; mkdir -p "$T/home" "$T/fake" "$T/bin"
  export HOME="$T/home" FAKE_DIR="$T/fake" FAKE_LOG="$T/fake/log"
  unset XDG_CONFIG_HOME XDG_DATA_HOME DRY_RUN
  : > "$FAKE_LOG"
  ln -s "$ROOT/test/fixtures/bin/fake-systemctl" "$T/bin/systemctl"
  local t; for t in sudo "$@"; do ln -s "$ROOT/test/fixtures/bin/fake-cmd" "$T/bin/$t"; done
  PATH="$T/bin:$ORIG_PATH"
}
ORIG_PATH="$PATH"
# one module call in a subshell: prints "changed=N" and the notes
mod() {
  bash -c '
    HERE="$1"; source "$HERE/lib/common.sh"; source "$HERE/lib/desktop.sh"; source "$HERE/provision/desktop/20-plasma.sh"
    stagos_plasma_keyd_apps >/dev/null 2>&1
    echo "changed=$DM_CHANGED"; printf "note %s\n" "${DM_NOTES[@]}"' _ "$ROOT"
}
U=stagos-keyd-apps.service
INST="$T/home/.config/systemd/user/$U"

sandbox keyd-application-mapper
r1="$(mod)"
check "run 1: python-dbus and python-gobject installed" grep -q '^sudo pacman -S --needed --noconfirm python-dbus python-gobject$' "$FAKE_LOG"
check "run 1: unit installed as is" cmp -s "$UNIT" "$INST"
check "run 1: daemon-reload, then enabled" bash -c "grep -n 'systemctl --user daemon-reload' '$FAKE_LOG' | head -1 | cut -d: -f1 | { read a; b=\$(grep -n 'systemctl --user enable $U' '$FAKE_LOG' | cut -d: -f1); [ \"\$a\" -lt \"\$b\" ]; }"
check "run 1: counts the unit file and the enable (changed=2)" grep -qx 'changed=2' <<< "$r1"
check "run 1, no Plasma running: not started" bash -c "! grep -qE 'systemctl --user (start|restart)' '$FAKE_LOG'"
check "run 1: no note (keyd present, manager running)" bash -c "! grep -q '^note .' <<< '$r1'"
: > "$FAKE_LOG"; r2="$(mod)"
check "run 2: 0 changes" grep -qx 'changed=0' <<< "$r2"
check "run 2: no enable, no daemon-reload" bash -c "! grep -qE 'systemctl --user (enable|daemon-reload)' '$FAKE_LOG'"

# inside Plasma: started when inactive, restarted when the unit changed, left alone when running and unchanged
echo plasma-workspace.target >> "$FAKE_DIR/active.units"
: > "$FAKE_LOG"; mod >/dev/null
check "in Plasma, unit inactive: started" grep -qx "systemctl --user start $U" "$FAKE_LOG"
: > "$FAKE_LOG"; r3="$(mod)"
check "in Plasma, running, unchanged: untouched, 0 changes" bash -c "! grep -qE 'systemctl --user (start|restart)' '$FAKE_LOG' && grep -qx 'changed=0' <<< '$r3'"
echo '# older copy' >> "$INST"
: > "$FAKE_LOG"; mod >/dev/null
check "in Plasma, unit file changed: daemon-reload + restart" \
  bash -c "grep -qx 'systemctl --user daemon-reload' '$FAKE_LOG' && grep -qx 'systemctl --user restart $U' '$FAKE_LOG'"

sandbox keyd-application-mapper; touch "$FAKE_DIR/no-manager"
r="$(mod)"
check "no user manager: unit installed, a note says how to enable it" \
  bash -c "[ -f '$INST' ] && grep -q '^note plasma: no systemd user manager.*systemctl --user enable --now $U' <<< '$r'"
check "no user manager: nothing enabled" bash -c "! grep -q 'systemctl --user enable' '$FAKE_LOG'"

sandbox
r="$(mod)"
check "keyd not installed: a note says the per-app keys are off" grep -q '^note plasma: keyd is not installed' <<< "$r"

sandbox keyd-application-mapper
r="$(DRY_RUN=1 mod)"
check "dry run: nothing written, nothing enabled" bash -c "[ ! -e '$INST' ] && ! grep -q '^systemctl' '$FAKE_LOG' && grep -q '^note plasma: systemctl --user enable $U (dry run)' <<< '$r'"

echo "keyd-apps: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
