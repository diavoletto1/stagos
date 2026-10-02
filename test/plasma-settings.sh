#!/usr/bin/env bash
# StagOS Settings app tests: loads every page headless (QT_QPA_PLATFORM=offscreen) without QML errors,
# scripted round trips through the same conf.set / conf.dock* code the UI handlers call, and the
# desktop.conf format checks (configparser + the shell readers). Needs the qml runtime (qt6-declarative)
# and kirigami; without them the app tests are skipped. Screenshots go to $STAGOS_SHOT_DIR if set.
#   ./test/plasma-settings.sh
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
S="$ROOT/desktop/plasma/settings/stag-settings.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0; skip=0
check() { local n="$1"; shift; local out; if out=$("$@" 2>&1); then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; printf '%s\n' "$out" | head -8 | sed 's/^/     | /'; fi; }

export HOME="$T/home"; mkdir -p "$HOME"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_DATA_DIRS
export STAGOS_DESKTOP_CONF="$T/desktop.conf" STAGOS_PLASMA_DATA="$ROOT/desktop/plasma" STAGOS_SETTINGS_DIR="$ROOT/desktop/plasma/settings"
export STAGOS_SETTINGS_ROOT="$T/noroot"
export STAGOS_SESSION_BIN="$ROOT/desktop/bin/stag-session.sh"
export XDG_STATE_HOME="$T/state"; mkdir -p "$XDG_STATE_HOME"
export XDG_DATA_DIRS="$T/share"; mkdir -p "$T/share/applications"
printf '[Desktop Entry]\nType=Application\nName=Foot\nIcon=foot\nExec=foot\n' > "$T/share/applications/foot.desktop"
printf '[Desktop Entry]\nType=Application\nName=Hidden thing\nNoDisplay=true\nExec=x\n' > "$T/share/applications/hidden.desktop"
printf '[Desktop Entry]\nType=Application\nName=Quote "Me" \\ back\nIcon=/tmp/i.svg\nExec=q\n' > "$T/share/applications/quote.desktop"

# ---- launcher context (no qml needed) ----
ctx="$("$S" --print-context)"
check "context is JSON" python3 -c "import json,sys; json.loads(sys.argv[1])" "$ctx"
check "context lists installed apps, skips NoDisplay" python3 - "$ctx" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); ids = {a["id"]: a for a in d["apps"]}
assert "foot.desktop" in ids and ids["foot.desktop"]["name"] == "Foot" and ids["foot.desktop"]["icon"] == "foot"
assert "hidden.desktop" not in ids
assert ids["quote.desktop"]["name"] == 'Quote "Me" \\ back', ids["quote.desktop"]
assert d["conf"].endswith("desktop.conf") and d["request"].endswith("reset-layout.request") and d["defaults"].endswith("desktop.conf.default")
PY
check "context: session state from stag-session --status" python3 - "$("$S" --print-context)" <<'PY2'
import json, sys
d = json.loads(sys.argv[1])
assert d["session_fails"] == 0 and d["session_next"] and d["session_fails_file"].endswith("/stagos/session-plasma-fails"), d
PY2
check "context: version unknown without a checkout" bash -c "grep -q '\"version\":\"unknown\"' <<< '$ctx'"
mkdir -p "$T/noroot" && git -C "$T/noroot" init -q && git -C "$T/noroot" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
check "context: version from git describe" bash -c "'$S' --print-context | grep -qE '\"version\":\"[0-9a-f]{7,}'"

# ---- desktop.conf.default: the contract ----
python3 - "$ROOT" > "$T/keys" <<'PY'
import configparser, sys
c = configparser.ConfigParser(interpolation=None); c.read(sys.argv[1] + "/desktop/plasma/desktop.conf.default")
for s in c.sections():
    for k in c[s]: print(f"{s}.{k}")
PY
want="bar.stag_menu bar.appmenu bar.recon bar.stagbot bar.cpu bar.ram bar.temp bar.net bar.bt bar.vol bar.bak bar.bat bar.clock bar.clock_format dock.launchers effects.blur effects.animation_factor recon.capture_iface link.ntfy"
check "desktop.conf.default has exactly the contract keys, in order" test "$(tr '\n' ' ' < "$T/keys")" = "$want "
check "every default key has a comment line right above it (or its group)" python3 - "$ROOT/desktop/plasma/desktop.conf.default" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n"); keys = 0; bare = []
for i, l in enumerate(lines):
    if "=" in l and not l.startswith("#"):
        k = l.split("=")[0]; keys += 1
        j = i - 1
        while j >= 0 and lines[j].startswith("#"):
            if lines[j].startswith("# " + k + ":") or lines[j].startswith("# " + k + " "): break
            j -= 1
        else:
            pass
        # the documenting comment must mention the key name somewhere directly above (block of # lines)
        blk = []; j = i - 1
        while j >= 0 and lines[j].startswith("#"): blk.append(lines[j]); j -= 1
        if not any(k in b for b in blk): bare.append(k)
assert not bare, bare
PY

if ! command -v "${QML_BIN:-qml6}" >/dev/null 2>&1 && ! command -v qml >/dev/null 2>&1 && ! [ -x /usr/lib/qt6/bin/qml ]; then
  echo "skip the app tests: no Qt 6 qml runtime here (they run in the container)"; skip=1
else
  export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
  export STAGOS_SETTINGS_CONTEXT="$T/ctx.json"
  "$S" --print-context | sed 's#"ifaces":\[[^]]*\]#"ifaces":["wlan0","wlan1"]#' > "$STAGOS_SETTINGS_CONTEXT"
  rm -f "$STAGOS_DESKTOP_CONF"
  ss() { timeout 60 "$S" "$@" 2>&1; }          # stderr has the QML warnings
  bad='(\.qml:[0-9]+|Error|TypeError|ReferenceError|is not a type|not installed|Cannot assign|Unable to assign|is not defined|Binding loop)'

  out="$(ss --selftest=set:effects.blur=true)"
  check "selftest: app loads, no QML errors" bash -c "grep -q 'SELFTEST OK' <<< '$out'"
  check "missing desktop.conf is created from the defaults, comments kept" bash -c "test -f '$STAGOS_DESKTOP_CONF' && grep -q '^# clock_format:' '$STAGOS_DESKTOP_CONF'"

  # round trips, same code path as the UI
  rt() { ss --selftest="$1" | grep -q 'SELFTEST OK'; }
  get() { python3 -c "import configparser,sys; c=configparser.ConfigParser(interpolation=None); c.read(sys.argv[1]); print(c[sys.argv[2]][sys.argv[3]], end='')" "$STAGOS_DESKTOP_CONF" "$1" "$2"; }
  rt "set:bar.cpu=false,set:effects.animation_factor=0.4,set:recon.capture_iface=wlan1,set:bar.clock_format=HH:mm"
  check "round trip: bar.cpu=false"            test "$(get bar cpu)" = false
  check "round trip: other bar items untouched" test "$(get bar ram)" = true
  check "round trip: animation_factor=0.4"     test "$(get effects animation_factor)" = 0.4
  check "round trip: recon.capture_iface"      test "$(get recon capture_iface)" = wlan1
  check "round trip: clock_format"             test "$(get bar clock_format)" = HH:mm
  check "round trip keeps comments"            grep -q '^# blur: blur behind panels' "$STAGOS_DESKTOP_CONF"
  check "desktop.conf still parses with configparser" python3 -c "import configparser,sys; configparser.ConfigParser(interpolation=None).read(sys.argv[1])" "$STAGOS_DESKTOP_CONF"
  ini_get() { awk -v s="$1" -v k="$2" '/^[[:space:]]*[#;]/{next} /^\[/{sec=$0; gsub(/[][]/,"",sec); next} sec==s && index($0,"=") { key=substr($0,1,index($0,"=")-1); if (key==k) { print substr($0,index($0,"=")+1); exit } }' "$STAGOS_DESKTOP_CONF"; }
  check "shell reader (stag-plasma-apply style awk) sees the same values" bash -c "test \"$(ini_get effects animation_factor)\" = 0.4 && test \"$(ini_get bar clock_format)\" = HH:mm"
  cp "$STAGOS_DESKTOP_CONF" "$T/before"; rt "set:bar.cpu=false"
  check "setting the same value rewrites nothing" test "$(cat "$T/before")" = "$(cat "$STAGOS_DESKTOP_CONF")"

  # dock list
  rt "set:dock.launchers=a.desktop;b.desktop;|;c.desktop,dock-add:d.desktop,dock-add:a.desktop,dock-sep,dock-move:0:1,dock-remove:3"
  check "dock: add, no duplicate, separator, move, remove" test "$(get dock launchers)" = "b.desktop;a.desktop;|;d.desktop;|"
  rt "dock-move:0:-1,dock-move:4:1"
  check "dock: moves past the ends are ignored" test "$(get dock launchers)" = "b.desktop;a.desktop;|;d.desktop;|"

  # a key or section missing from an old file is added in the right place
  printf '[bar]\n# keep me\ncpu=true\n\n[effects]\nblur=true\n' > "$STAGOS_DESKTOP_CONF"
  rt "set:bar.ram=false,set:recon.capture_iface=wlan0,set:effects.animation_factor=1.0"
  check "missing keys and sections are added" bash -c "test \"$(get bar ram)\" = false && test \"$(get recon capture_iface)\" = wlan0 && test \"$(get effects animation_factor)\" = 1.0 && grep -q '^# keep me' '$STAGOS_DESKTOP_CONF'"

  # reset request
  rm -f "$XDG_STATE_HOME/stagos/reset-layout.request"; mkdir -p "$XDG_STATE_HOME/stagos"
  rt "reset-layout"
  check "reset layout writes the request file" grep -q '^reset-layout ' "$XDG_STATE_HOME/stagos/reset-layout.request"
  # Session page: "Retry Plasma at next login" clears the stag-session fail counter (same file, same effect as retry)
  fails_file="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["session_fails_file"])' "$STAGOS_SETTINGS_CONTEXT")"
  mkdir -p "${fails_file%/*}"; echo "2 $(cat /proc/sys/kernel/random/boot_id)" > "$fails_file"
  check "session: fallback visible to stag-session before the retry" bash -c "STAGOS_STARTPLASMA=/bin/true '$ROOT/desktop/bin/stag-session.sh' --status | grep -q '^next=shell (plasma failed 2x'"
  rt "session-retry"
  check "session-retry clears the fallback (stag-session --status: next=plasma)" bash -c "STAGOS_STARTPLASMA=/bin/true '$ROOT/desktop/bin/stag-session.sh' --status | grep -qx 'next=plasma'"
  check "unknown selftest action fails" bash -c "! '$S' --selftest=bogus >/dev/null 2>&1"

  # every page loads clean, screenshot each (with the StagOS color scheme in kdeglobals when kwriteconfig6 exists)
  command -v kwriteconfig6 >/dev/null 2>&1 && "$ROOT/desktop/bin/stag-plasma-apply.sh" --base --quiet >/dev/null 2>&1
  cp "$ROOT/test/fixtures/plasma-desktop.conf" "$STAGOS_DESKTOP_CONF"
  shots="${STAGOS_SHOT_DIR:-$T/shots}"; mkdir -p "$shots"
  # the Session page with the crash fallback active (shows the Retry button)
  echo "2 $(cat /proc/sys/kernel/random/boot_id)" > "$fails_file"
  STAGOS_STARTPLASMA=/bin/true "$S" --print-context | sed 's#"ifaces":\[[^]]*\]#"ifaces":["wlan0","wlan1"]#' > "$STAGOS_SETTINGS_CONTEXT"
  check "context: fallback reported (session_fails=2, next=shell)" python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['session_fails'] == 2 and d['session_next'].startswith('shell')" "$STAGOS_SETTINGS_CONTEXT"
  for p in bar dock look session recon about; do
    out="$(ss --page=$p --shot="$shots/plasma-p3-settings-$p.png")"
    check "page $p loads without QML errors" bash -c "grep -q 'SHOT OK' <<< '$out' && ! grep -E '$bad' <<< '$out'"
    check "page $p screenshot is non-empty" test -s "$shots/plasma-p3-settings-$p.png"
  done
fi
echo; echo "plasma-settings: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
