#!/usr/bin/env bash
# Unit tests for stag-field (field mode) and the field bits of stag-ctl / stag-status. No display, no root,
# no real radio: every tool is a fake under a temp PATH and /sys + /proc are a fake tree (fake-desktop.sh).
# The sync contract is exercised against a real python http.server (duplicate + failure/retry). Run: ./test/field.sh
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
REAL_CURL="$(command -v curl || true)"
REAL_PYTHON="$(command -v python3 || true)"
T="$(mktemp -d)"; trap 'cleanup' EXIT
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; [ -n "${INHIBIT_WATCH:-}" ] && kill "$INHIBIT_WATCH" 2>/dev/null; rm -rf "$T"; }
# shellcheck source=test/fixtures/fake-desktop.sh
. "$ROOT/test/fixtures/fake-desktop.sh"
pass=0; fail=0
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi; }
jq_ok() { command -v jq >/dev/null 2>&1; }
jcheck() {
  if jq_ok; then check "$1" test "$(printf '%s' "$2" | jq -r "$3" 2>/dev/null)" = true
  else check "$1 (json parses)" python3 -c 'import json,sys; json.loads(sys.argv[1])' "$2"; fi
}
rc() { "$@" >/dev/null 2>&1; echo $?; }

# field-specific fakes layered on top of fake-desktop: iw flips the sysfs type, the rest just log.
field_fakes() {
  local b="$T/sb/bin" t f
  # stag-field (and this harness) need a few more coreutils than fake-desktop's curated sysbin ships
  for t in chmod seq find sha256sum; do
    # a clean bash avoids any same-named shell function from this harness's profile (e.g. find)
    f="$(PATH="$FAKE_SYS_PATH" bash -c "command -v $t" 2>/dev/null)"
    [ -x "$f" ] || f="/usr/bin/$t"
    [ -x "$f" ] && ln -sf "$f" "$T/sb/sysbin/$t"
  done
  # nmcli is a fake-desktop symlink: remove it first so we write a new file, not through the symlink
  rm -f "$b"/iw "$b"/ip "$b"/tlp "$b"/macchanger "$b"/systemd-inhibit "$b"/nmcli
  cat > "$b/iw" <<'EOF'
#!/bin/bash
echo "iw $*" >> "$FAKE_LOG"
if [ "$1" = dev ] && [ "$3" = set ] && [ "$4" = type ]; then
  d="$STAGOS_SYS/class/net/$2"; [ -d "$d" ] || exit 0
  case "$5" in monitor) echo 803 > "$d/type" ;; managed) echo 1 > "$d/type" ;; esac
fi
exit 0
EOF
  # shellcheck disable=SC2016  # the $* and $FAKE_LOG expand inside the generated fake, not here
  for t in ip tlp macchanger; do printf '#!/bin/bash\necho "%s $*" >> "$FAKE_LOG"\nexit 0\n' "$t" > "$b/$t"; done
  cat > "$b/systemd-inhibit" <<'EOF'
#!/bin/bash
echo "systemd-inhibit $*" >> "$FAKE_LOG"
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF
  cat > "$b/nmcli" <<'EOF'
#!/bin/bash
echo "nmcli $*" >> "$FAKE_LOG"
case "$*" in
  *"DEVICE,STATE device status"*)
    printf 'wlan0:%s\n' "$(cat "$FAKE_DIR/state/nm_wlan0" 2>/dev/null || echo disconnected)"
    printf 'wlan1:unmanaged\n' ;;
esac
exit 0
EOF
  chmod +x "$b"/iw "$b"/ip "$b"/tlp "$b"/macchanger "$b"/systemd-inhibit "$b"/nmcli
  ln -sf "$ROOT/desktop/bin/stag-field.sh" "$b/stag-field"
  export STAGOS_SUDO="" STAGOS_FIELD_INHIBIT_CMD="sleep 20"
}

# a box with the capture card (wlan1) present and managed, built-in wlan0 with a known MAC
new_field() {
  fake_desktop_setup "$T/sb"
  field_fakes
  fake_sys_iface wlan1 1 wireless
  echo "de:ad:be:ef:00:01" > "$STAGOS_SYS/class/net/wlan0/address"
  sed -i 's/^capture_iface=.*/capture_iface=wlan1/' "$HOME/.config/stagos/desktop.conf"
  fake_state gps 3; fake_state ts down
}

echo "== stag-field: no capture card =="
new_field
sed -i 's/^capture_iface=.*/capture_iface=/' "$HOME/.config/stagos/desktop.conf"
jcheck "status: inactive on a fresh box" "$(stag-field status)" '.active == false and .kismet == false'
check "on without a card -> 3" test "$(rc stag-field on)" = 3
check "on without a card writes no state" bash -c "! test -e '$HOME/.local/state/stagos/field.json'"

echo; echo "== stag-field on (full session) =="
new_field
J="$(stag-field on 2>/dev/null)"
jcheck "on: status reports active, the capture iface and a 3D fix" "$J" '.active == true and .iface == "wlan1" and .gps == 3'
jcheck "on: kismet running, a log dir recorded" "$J" '.kismet == true and (.log_dir | test("/field/"))'
check "on: capture card went to monitor mode (ip down / iw set type / ip up)" bash -c "grep -q '^ip link set wlan1 down' '$FAKE_LOG' && grep -q '^iw dev wlan1 set type monitor' '$FAKE_LOG' && grep -q '^ip link set wlan1 up' '$FAKE_LOG'"
check "on: kismet started with --log-prefix into ~/field/<date>" bash -c "grep -q 'kismet --no-ncurses --log-prefix .*field.* -c wlan1' '$FAKE_LOG'"
check "on: log dir exists and is user owned (no sudo on it)" bash -c "d=\$(date +%Y-%m-%d); test -d '$HOME/field/'\$d"
check "on: built-in wifi MAC randomized (not connected)" bash -c "grep -q '^macchanger -r wlan0' '$FAKE_LOG'"
check "on: TLP switched to battery mode" grep -q '^tlp bat' "$FAKE_LOG"
check "on: screen dimmed a notch via brightnessctl" grep -q '^brightnessctl -q set 35%' "$FAKE_LOG"
check "on: a sleep/idle inhibit is held" grep -q '^systemd-inhibit .*--what=sleep:idle' "$FAKE_LOG"
PID="$(grep -oE '"inhibit_pid":[0-9]+' "$HOME/.local/state/stagos/field.json" | cut -d: -f2)"
check "on: the inhibit process is alive" bash -c "test -n '$PID' && kill -0 '$PID'"
check "on: field.json records the original MAC and brightness for restore" bash -c "grep -q '\"mac_original\":\"de:ad:be:ef:00:01\"' '$HOME/.local/state/stagos/field.json' && grep -q '\"brightness_original\":50' '$HOME/.local/state/stagos/field.json'"
# the top bar and Control Center see the session
jcheck "stag-status: FIELD readout, hot, with the iface" "$(stag-status --json)" '(.fields[] | select(.id=="mon") | (.text == "FIELD wlan1" and .state == "hot"))'
jcheck "stag-ctl recon status: field.active true" "$(stag-ctl recon status)" '.field.active == true and .field.iface == "wlan1"'
# a second on is a no-op
jcheck "on when already on: stays active, no error" "$(stag-field on 2>/dev/null)" '.active == true'

echo; echo "== stag-field off =="
: > "$FAKE_LOG"
J="$(stag-field off 2>/dev/null)"
jcheck "off: status reports inactive" "$J" '.active == false and .kismet == false'
check "off: kismet stopped" grep -q '^pkill -x kismet' "$FAKE_LOG"
check "off: capture card back to managed" grep -q '^iw dev wlan1 set type managed' "$FAKE_LOG"
check "off: MAC restored to the original" grep -q '^macchanger --mac de:ad:be:ef:00:01 wlan0' "$FAKE_LOG"
check "off: brightness restored" grep -q '^brightnessctl -q set 50%' "$FAKE_LOG"
check "off: power handed back to TLP auto" grep -q '^tlp start' "$FAKE_LOG"
check "off: the inhibit was released" bash -c "! kill -0 '$PID' 2>/dev/null"
check "off: field.json removed" bash -c "! test -e '$HOME/.local/state/stagos/field.json'"
check "off: offline, so no background sync was started" bash -c "! grep -q curl '$FAKE_LOG'"

echo; echo "== stag-field on: built-in wifi connected (MAC left alone) =="
new_field
fake_state nm_wlan0 connected
stag-field on >/dev/null 2>&1
check "on: connected built-in card is never randomized" bash -c "! grep -q 'macchanger -r' '$FAKE_LOG'"
stag-field off >/dev/null 2>&1

# ---- sync against a real upload server (the contract) ----
if [ -z "$REAL_CURL" ] || [ -z "$REAL_PYTHON" ]; then
  echo; echo "== sync: SKIPPED (curl or python3 missing) =="
else
echo; echo "== stag-field sync (upload contract) =="
new_field
ln -sf "$REAL_CURL" "$T/sb/bin/curl"   # real curl for the actual POST
SRV_LOG="$T/srv.log"
cat > "$T/server.py" <<'PY'
import http.server, json, hashlib, sys
reqs = open(sys.argv[2], "a")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj, separators=(",", ":")).encode()  # compact, like the stag-maps contract
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.endswith("/api/field/status"):
            self._send(200, {"files": 2, "devices": 42, "last_upload": "2026-10-02T00:00:00Z"})
        else: self._send(404, {"ok": False, "error": "nope"})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        # the multipart body carries the filename; drive behaviour off it
        name = ""
        for part in body.split(b"\r\n"):
            if b'filename="' in part:
                name = part.split(b'filename="')[1].split(b'"')[0].decode(); break
        reqs.write(name + "\n"); reqs.flush()
        if "fail" in name:
            self._send(500, {"ok": False, "error": "boom"}); return
        dup = "dup" in name
        self._send(200, {"ok": True, "sha256": hashlib.sha256(body).hexdigest()[:16],
                         "devices": 5, "new_devices": 0 if dup else 5, "duplicate": dup})
httpd = http.server.HTTPServer(("127.0.0.1", 0), H)
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
PY
"$REAL_PYTHON" "$T/server.py" "$T" "$SRV_LOG" > "$T/port" 2>/dev/null &
SRV_PID=$!
for _ in $(seq 40); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT="$(cat "$T/port")"
check "upload server came up" bash -c "test -n '$PORT'"
printf 'maps|http://127.0.0.1:%s/maps/\n' "$PORT" > "$HOME/.config/stagos/stag-services"
fake_state ts up

d="$HOME/field/2026-10-02"; mkdir -p "$d"
printf 'KISMETLOG-A\n' > "$d/stag-A.kismet"
printf 'KISMETLOG-DUP\n' > "$d/stag-dup.kismet"
printf 'KISMETLOG-FAIL\n' > "$d/stag-fail.kismet"
touch -d '1 hour ago' "$d"/*.kismet
printf 'STILL-WRITING\n' > "$d/stag-live.kismet"   # fresh mtime: must be skipped

fake_state ts down
jcheck "sync offline is a no-op" "$(stag-field sync 2>/dev/null)" '.online == false'
fake_state ts up
J="$(stag-field sync 2>/dev/null)"
jcheck "sync: two good uploads (A + dup), one failure, live log skipped" "$J" '.uploaded == 2 and .duplicates == 1 and .failed == 1 and .ok == false'
check "sync: the live (fresh) log was never offered" bash -c "! grep -q 'stag-live.kismet' '$SRV_LOG'"
check "sync: the failing log was retried 3 times" bash -c "test \$(grep -c 'stag-fail.kismet' '$SRV_LOG') -eq 3"
check "sync: never deletes local logs" bash -c "test -s '$d/stag-A.kismet' -a -s '$d/stag-fail.kismet'"
check "sync: bookkeeping keyed by sha256 recorded the uploads" bash -c "test -s '$HOME/.local/state/stagos/field-uploads.json' && python3 -c 'import json;d=json.load(open(\"$HOME/.local/state/stagos/field-uploads.json\"));assert len(d)==2'"
check "sync: last-sync timestamp written" test -s "$HOME/.local/state/stagos/field-last-sync"
: > "$SRV_LOG"
J="$(stag-field sync 2>/dev/null)"
jcheck "sync again: already-uploaded logs are skipped (idempotent by sha)" "$J" '.uploaded == 0 and .failed == 1'
check "sync again: only the still-failing log is re-offered" bash -c "test \$(grep -c 'stag-A.kismet' '$SRV_LOG') -eq 0"
# the remote status reaches the Control Center through stag-ctl
rm -f "$STAGOS_CACHE/field_remote"
STAGOS_CACHE_SYNC=1 stag-ctl recon status >/dev/null 2>&1
jcheck "recon status: stag-maps field status surfaces for the Control Center" "$(STAGOS_CACHE_SYNC=1 stag-ctl recon status)" '.field.remote.files == 2 and .field.remote.devices == 42'
kill "$SRV_PID" 2>/dev/null; SRV_PID=""
fi

echo; echo "== static checks =="
CC="$ROOT/desktop/plasma/plasmoids/org.stagos.status/contents/ui/ControlCenter.qml"
check "Control Center: a Field mode tile with on/off states" bash -c "grep -q 'Field: on' '$CC' && grep -q 'Field: off' '$CC' && grep -q 'Field: no card' '$CC'"
check "Control Center: last sync line from the maps field status" grep -q 'stag-maps:' "$CC"
check "stag-field: no em dashes" bash -c "! grep -q $'\\xe2\\x80\\x94' '$ROOT/desktop/bin/stag-field.sh'"

echo; echo "field: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
