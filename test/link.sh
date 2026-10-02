#!/usr/bin/env bash
# Tests for the link and lab modules (ntfy notifications, KRunner runner, KDE Connect, stag-lab node) and
# `stag-ctl task add`. No network, no root, no Plasma: curl/notify-send/stag-ctl are fakes (test/fixtures),
# the ntfy server is test/fixtures/fake_ntfy.py on loopback, and the KRunner D-Bus check runs on a private
# bus (dbus-run-session). Real module runs (packages, second run 0 changes): test/link-container.sh.
# Run: ./test/link.sh
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ORIG_PATH="$PATH"
# shellcheck source=test/fixtures/fake-desktop.sh
. "$ROOT/test/fixtures/fake-desktop.sh"
pass=0; fail=0; skip=0
check() { # check "name" command...
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi
}
skipped() { skip=$((skip+1)); echo "skip $*"; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
jfield() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

# ---- stag-ctl task add (fake curl) ----
fake_desktop_setup "$T/sb"
check "task add: no services file -> 3" test "$(rc stag-ctl task add x)" = 3
printf 'control|https://stag.example/control/\ntasks|https://stag.example/tasks/\n' > "$HOME/.config/stagos/stag-services"
check "task add: no text -> 2" test "$(rc stag-ctl task add '  ')" = 2
check "task: unknown verb -> 2" test "$(rc stag-ctl task list)" = 2
printf '{"id": 42, "type": "task", "title": "x", "tags": [{"id": 6, "name": "software"}]}' > "$FAKE_DIR/curl.body"
printf 'https://stag.example/tasks/api/items 201\n' > "$FAKE_DIR/curl.codes"
J="$(stag-ctl task add '  buy "oat" milk	now ')"
check "task add: prints the new id" test "$(jfield "$J" id)" = 42
check "task add: created true, title trimmed" test "$(jfield "$J" title)" = 'buy "oat" milk	now'
check "task add: POST to <tasks>/api/items" grep -q -- "-X POST .*https://stag.example/tasks/api/items$" "$FAKE_LOG"
check "task add: owner CSRF header, JSON in and out" bash -c "grep -q \"X-Stag-Request: 1\" '$FAKE_LOG' && grep -q 'Content-Type: application/json' '$FAKE_LOG' && grep -q 'Accept: application/json' '$FAKE_LOG'"
check "task add: no token, no Origin (owner device auth)" bash -c "! grep -qiE 'Authorization|Origin|Bearer' '$FAKE_LOG'"
check "task add: body is a task with the escaped title" python3 -c '
import json,sys; b=json.load(open(sys.argv[1])); sys.exit(b != {"type":"task","title":"buy \"oat\" milk\tnow"})' "$FAKE_DIR/curl.stdin"
check "task add: 10 s timeout" grep -q -- '--max-time 10' "$FAKE_LOG"
printf '{"error": "not_owner", "node": "someones-laptop"}' > "$FAKE_DIR/curl.body"
printf 'https://stag.example/tasks/api/items 403\n' > "$FAKE_DIR/curl.codes"
J="$(stag-ctl task add x)"; r=$?
check "task add: 403 -> 1 with the server's error" bash -c "test $r = 1 && test \"$(jfield "$J" error)\" = 'stag-tasks: HTTP 403 not_owner'"
printf '<html>oops</html>' > "$FAKE_DIR/curl.body"; printf 'https://stag.example/tasks/api/items 502\n' > "$FAKE_DIR/curl.codes"
check "task add: 502 without JSON -> 1" test "$(jfield "$(stag-ctl task add x)" error)" = "stag-tasks: HTTP 502"
printf '{"ok": true}' > "$FAKE_DIR/curl.body"; printf 'https://stag.example/tasks/api/items 201\n' > "$FAKE_DIR/curl.codes"
check "task add: 201 without an id -> 1" test "$(rc stag-ctl task add x)" = 1
printf 'https://stag.example/tasks/api/items 000\n' > "$FAKE_DIR/curl.codes"
check "task add: unreachable -> 1" test "$(jfield "$(stag-ctl task add x)" error)" = "stag-tasks unreachable"
check "stag-ctl --help lists task add" bash -c "stag-ctl --help | grep -q 'task add TEXT'"
check "stag-ctl usage still ends at the last command line" bash -c "stag-ctl 2>&1 | tail -1 | grep -q 'stag-ctl control'"
PATH="$ORIG_PATH"

# ---- python: notifier + runner unit tests ----
if command -v uv >/dev/null 2>&1; then
  if (cd "$ROOT" && timeout 300 uv run --no-project --with pytest pytest -q -p no:cacheprovider test/link) > "$T/pytest.log" 2>&1; then
    pass=$((pass+1)); echo "ok   python unit tests: $(tail -1 "$T/pytest.log")"
  else
    fail=$((fail+1)); echo "FAIL python unit tests"; tail -30 "$T/pytest.log"
  fi
elif python3 -c 'import pytest' 2>/dev/null; then
  if python3 -m pytest -q -p no:cacheprovider test/link > "$T/pytest.log" 2>&1; then
    pass=$((pass+1)); echo "ok   python unit tests: $(tail -1 "$T/pytest.log")"
  else
    fail=$((fail+1)); echo "FAIL python unit tests"; tail -30 "$T/pytest.log"
  fi
else
  skipped "python unit tests (no uv, no pytest)"
fi
check "python: both scripts compile" python3 -m py_compile desktop/link/stag-ntfy-notify.py desktop/link/stag-krunner.py
rm -rf desktop/link/__pycache__

# ---- KRunner over D-Bus: activation from the generated .service, Match/Actions/Run ----
if [ -x /usr/bin/python3 ] && /usr/bin/python3 -c 'import dbus, gi; from gi.repository import GLib' 2>/dev/null \
   && command -v dbus-run-session >/dev/null && command -v dbus-daemon >/dev/null; then
  K="$T/kr"; mkdir -p "$K/home/.local/lib/stagos" "$K/home/.config/stagos" "$K/services" "$K/bin" "$K/home/fake"
  install -m755 desktop/link/stag-krunner.py "$K/home/.local/lib/stagos/stag-krunner"
  sed "s|@HOME@|$K/home|" desktop/link/org.stagos.krunner.service.in > "$K/services/org.stagos.krunner.service"
  printf 'maps|https://stag.example/maps/\nmedia|https://stag.example/media/\n' > "$K/home/.config/stagos/stag-services"
  for t in stag-ctl notify-send; do ln -s "$ROOT/test/fixtures/bin/fake-cmd" "$K/bin/$t"; done
  : > "$K/home/fake/log"
  cat > "$K/bus.conf" <<CONF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:dir=$K</listen><servicedir>$K/services</servicedir>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>
CONF
  if HOME="$K/home" FAKE_DIR="$K/home/fake" FAKE_LOG="$K/home/fake/log" PATH="$K/bin:$ORIG_PATH" \
     timeout 60 dbus-run-session --config-file="$K/bus.conf" -- /usr/bin/python3 test/link/krunner_dbus.py "$K/home" > "$T/dbus.log" 2>&1; then
    pass=$((pass+1)); echo "ok   krunner D-Bus: $(grep -c '^ok' "$T/dbus.log") checks"
  else
    fail=$((fail+1)); echo "FAIL krunner D-Bus"; cat "$T/dbus.log"
  fi
else
  skipped "krunner D-Bus (needs /usr/bin/python3 with python-dbus + gi, dbus-run-session)"
fi

# ---- modules: dry run, no secrets, config ----
LC="$T/local.conf"
cat > "$LC" <<'CONF'
STAGOS_STAG_HOST="stag.test.invalid"
STAGOS_STAG_PATHS=(tasks control)
STAGOS_NTFY_USER="stagpad"
STAGOS_LAB_SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly000000000000000000000 staglab@test"
STAGOS_LAB_SSH_FROM="100.64.0.1"
CONF
H="$T/dryhome"; mkdir -p "$H"
out="$(HOME="$H" DRY_RUN=1 STAGOS_LOCAL_CONF="$LC" ./stagos-desktop link lab 2>&1)"; r=$?
check "dry run: link lab exit 0" test "$r" = 0
check "dry run: nothing written to HOME" test -z "$(find "$H" -mindepth 1 -print -quit)"
check "dry run: packages for the notifier and runner" grep -q 'pacman -S --needed --noconfirm python python-dbus python-gobject libnotify xdg-utils curl' <<< "$out"
check "dry run: kdeconnect + its nft drop-in" bash -c "grep -q 'pacman -S --needed --noconfirm kdeconnect' <<< \"\$1\" && grep -q 'install -Dm644 .*/kdeconnect.nft /etc/nftables.d/kdeconnect.nft' <<< \"\$1\"" _ "$out"
check "dry run: link.env, krunner plugin, dbus activation" bash -c "for f in link.env dbusplugins/stagos-krunner.desktop dbus-1/services/org.stagos.krunner.service systemd/user/stagos-ntfy.service; do grep -q \"\$f\" <<< \"\$1\" || exit 1; done" _ "$out"
check "dry run: lab hardening drop-in and sshd" bash -c "grep -q '/etc/ssh/sshd_config.d/50-stagos-lab.conf' <<< \"\$1\" && grep -q 'systemctl enable --now sshd.service' <<< \"\$1\"" _ "$out"
check "dry run: files changed 0" grep -q 'files changed this run: 0' <<< "$out"
out="$(HOME="$H" DRY_RUN=1 STAGOS_LINK_KDECONNECT=0 STAGOS_LOCAL_CONF=/dev/null ./stagos-desktop link lab 2>&1)"
check "no local.conf: ntfy off with a warning, no sshd without a key" bash -c "grep -q 'no ntfy host' <<< \"\$1\" && grep -q 'no sshd for the stag-lab terminal' <<< \"\$1\" && ! grep -q sshd_config.d <<< \"\$1\"" _ "$out"
check "STAGOS_LINK_KDECONNECT=0 skips KDE Connect" bash -c "! grep -q kdeconnect <<< \"\$1\"" _ "$out"
printf 'STAGOS_LAB_SSH_PUBKEY="ssh-ed25519 AAAA x"\nSTAGOS_LAB_SSH_FROM="any; rm -rf /"\n' > "$T/bad.conf"
out="$(HOME="$H" DRY_RUN=1 STAGOS_LOCAL_CONF="$T/bad.conf" ./stagos-desktop lab 2>&1)"
check "lab: a junk STAGOS_LAB_SSH_FROM is refused" bash -c "grep -q 'STAGOS_LAB_SSH_FROM must be' <<< \"\$1\" && ! grep -q sshd_config.d <<< \"\$1\"" _ "$out"
check "local.conf.example: ntfy and lab keys documented, no values" bash -c "grep -q '^STAGOS_NTFY_USER=' config/local.conf.example && grep -q '^STAGOS_LAB_SSH_PUBKEY=\"\"' config/local.conf.example"
check "desktop.conf.default: [link] ntfy=true" python3 -c '
import configparser,sys; c=configparser.ConfigParser(interpolation=None); c.read("desktop/plasma/desktop.conf.default"); sys.exit(c["link"]["ntfy"] != "true")'
check "credentials template has no values" bash -c "! grep -qE '^NTFY_[A-Z]+=.+' desktop/link/ntfy.credentials.example"
check "ntfy unit: with Plasma, restarts on failure" bash -c "grep -q '^WantedBy=plasma-workspace.target' desktop/link/stagos-ntfy.service && grep -q '^Restart=on-failure' desktop/link/stagos-ntfy.service"
if command -v desktop-file-validate >/dev/null; then
  check "stag-ntfy.desktop validates" desktop-file-validate desktop/link/stag-ntfy.desktop
else skipped "desktop-file-validate (not installed)"; fi

# ---- lab: the authorized_keys line (the helper, on a sandbox HOME) ----
(
  set +u
  HOME="$T/labhome"; mkdir -p "$HOME/.ssh"; chmod 755 "$HOME/.ssh"
  printf 'ssh-ed25519 AAAAmine me@mac\nfrom="1.2.3.4" ssh-ed25519 AAAAold stagos-lab\n' > "$HOME/.ssh/authorized_keys"
  # shellcheck source=lib/common.sh
  . lib/common.sh; . lib/desktop.sh; . provision/desktop/19-lab.sh
  stagos_lab_authorized_key "ssh-ed25519 AAAAnew staglab@stagmini" "100.64.0.1" >/dev/null 2>&1
  first=$DM_CHANGED
  stagos_lab_authorized_key "ssh-ed25519 AAAAnew staglab@stagmini" "100.64.0.1" >/dev/null 2>&1
  printf '%s\n' "$first" "$DM_CHANGED" "$(stat -c %a "$HOME/.ssh") $(stat -c %a "$HOME/.ssh/authorized_keys")" > "$T/lab.res"
)
cat > "$T/lab.want" <<'EOF'
ssh-ed25519 AAAAmine me@mac
from="100.64.0.1",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ssh-ed25519 AAAAnew stagos-lab
EOF
check "lab: one managed key line, restricted to stagmini, other keys kept" cmp "$T/lab.want" "$T/labhome/.ssh/authorized_keys"
check "lab: second run changes nothing; ~/.ssh 700, authorized_keys 600" test "$(tr '\n' ' ' < "$T/lab.res")" = "2 2 700 600 "

# ---- KDE Connect firewall drop-in: valid inside an input chain (nft -c, own user + net namespace) ----
if command -v nft >/dev/null && unshare -rn true 2>/dev/null; then
  printf 'table inet stagos_test {\n chain input {\n  type filter hook input priority 0; policy drop;\n  ct state established,related accept\n  include "%s"\n }\n}\n' \
    "$ROOT/desktop/link/kdeconnect.nft" > "$T/fw.nft"
  check "kdeconnect.nft: nft -c accepts it inside an input chain" unshare -rn nft -c -f "$T/fw.nft"
else
  skipped "nft -c (needs nft and unprivileged user namespaces; the container test runs it)"
fi

# ---- hygiene ----
files=(provision/desktop/18-link.sh provision/desktop/19-lab.sh desktop/bin/stag-ctl.sh test/link.sh test/link-container.sh
  test/link-container-inner.sh test/fixtures/bin/fake-desktop)
check "shellcheck (INFO level) on the link files" shellcheck -x -s bash -S info "${files[@]}"
check "no em dashes in link files" bash -c "! grep -rlP '\x{2014}' desktop/link test/link test/fixtures/fake_ntfy.py ${files[*]} config README.md"
check "no tailnet names or addresses in the repo files" bash -c "! grep -rEn 'ts\.net|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+' desktop/link test/link test/fixtures/fake_ntfy.py provision/desktop/18-link.sh provision/desktop/19-lab.sh config README.md | grep -v '100.64.0'"

echo
echo "link: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
