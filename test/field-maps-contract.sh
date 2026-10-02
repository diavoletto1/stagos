#!/usr/bin/env bash
# The field upload contract end to end: the real `stag-field sync` (this repo) against the real stag-maps app
# (a local checkout: its routes, owner auth, Kismet parser and DB code), served on 127.0.0.1 behind a /maps prefix
# with the forwarded tailnet address Caddy would add, a temp DB and stag-maps' own fake whois. No network, nothing live.
#   STAG_MAPS_DIR=~/repos/stag-maps ./test/field-maps-contract.sh     (needs $STAG_MAPS_DIR/.venv-dev; skips without it)
set -uo pipefail
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
MAPS="${STAG_MAPS_DIR:-$HOME/repos/stag-maps}"
MPY="$MAPS/.venv-dev/bin/python"
if [ ! -x "$MPY" ] || [ ! -f "$MAPS/backend/routes/field.py" ]; then
  echo "field-maps-contract: SKIPPED (no stag-maps checkout with backend/routes/field.py and .venv-dev at $MAPS)"; exit 0
fi
REAL_CURL="$(command -v curl)" || { echo "field-maps-contract: SKIPPED (no curl)"; exit 0; }
T="$(mktemp -d)"; SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null && wait "$SRV_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
# shellcheck source=test/fixtures/fake-desktop.sh
. "$ROOT/test/fixtures/fake-desktop.sh"
pass=0; fail=0
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi; }
jt() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if eval(sys.argv[2], {}, {"d": d}) else 1)' "$1" "$2"; }

mkdir -p "$T/srv"
STAG_MAPS_DIR="$MAPS" "$MPY" "$ROOT/test/fixtures/stag_maps_field_server.py" "$T/srv" > "$T/port" 2> "$T/srv.err" &
SRV_PID=$!
for _ in $(seq 100); do [ -s "$T/port" ] && break; sleep 0.2; done
PORT="$(cat "$T/port")"
check "stag-maps came up on 127.0.0.1" test -n "$PORT"
[ -n "$PORT" ] || { tail -20 "$T/srv.err"; exit 1; }

# two Kismet logs from stag-maps' own fixture builder, plus one that is not a Kismet log
d="$T/logs"; mkdir -p "$d"
STAG_MAPS_DIR="$MAPS" "$MPY" - "$d" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["STAG_MAPS_DIR"], "backend", "tests", "fixtures"))
import kismet_log
kismet_log.build(os.path.join(sys.argv[1], "Kismet-20260921-14-00-00-1.kismet"), kismet_log.SESSION_1)
kismet_log.build(os.path.join(sys.argv[1], "Kismet-20260922-09-00-00-1.kismet"), kismet_log.SESSION_2)
PY

declare -A HOSTBIN; for t in chmod seq find sha256sum; do HOSTBIN[$t]="$(command -v "$t")"; done
fake_desktop_setup "$T/sb"
ln -sf "$ROOT/desktop/bin/stag-field.sh" "$T/sb/bin/stag-field"
for t in "${!HOSTBIN[@]}"; do ln -sf "${HOSTBIN[$t]}" "$T/sb/sysbin/$t"; done
ln -sf "$REAL_CURL" "$T/sb/bin/curl"
fake_state ts up
printf 'maps|http://127.0.0.1:%s/maps/\n' "$PORT" > "$HOME/.config/stagos/stag-services"
F="$HOME/field/2026-09-21"; mkdir -p "$F" "$HOME/field/2026-09-22"
cp "$d/Kismet-20260921-14-00-00-1.kismet" "$F/"
cp "$d/Kismet-20260922-09-00-00-1.kismet" "$HOME/field/2026-09-22/"
touch -d '1 hour ago' "$HOME"/field/*/*.kismet
UP="$HOME/.local/state/stagos/field-uploads.json"
api() { "$REAL_CURL" -sS "http://127.0.0.1:$PORT/maps/api/field/$1"; }

echo "== owner device: upload, duplicate, status =="
J="$(stag-field sync 2>"$T/sync.err")"
check "sync: both logs accepted by stag-maps" jt "$J" 'd["ok"] and d["uploaded"] == 2 and d["duplicates"] == 0 and d["failed"] == 0'
check "bookkeeping: two sha256 keys, each matching the file" python3 - "$UP" "$F/Kismet-20260921-14-00-00-1.kismet" <<'PY'
import hashlib, json, sys
d = json.load(open(sys.argv[1])); sha = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
assert len(d) == 2 and sha in d and d[sha]["duplicate"] is False and d[sha]["devices"] == 9, d
PY
S="$(api status)"
check "GET status: exactly files/devices/last_upload, 2 files" jt "$S" 'sorted(d) == ["devices", "files", "last_upload"] and d["files"] == 2 and d["devices"] >= 9 and d["last_upload"]'
J="$(stag-field sync 2>/dev/null)"
check "sync again: nothing offered (local bookkeeping)" jt "$J" 'd["uploaded"] == 0 and d["failed"] == 0'
rm -f "$UP"
J="$(stag-field sync 2>/dev/null)"
check "bookkeeping lost: the server answers duplicate for both, the client records them" jt "$J" 'd["uploaded"] == 2 and d["duplicates"] == 2'
check "duplicates are recorded as such" python3 -c "import json,sys; d=json.load(open('$UP')); sys.exit(0 if all(v['duplicate'] for v in d.values()) else 1)"
check "server still holds 2 files after the duplicates" jt "$(api status)" 'd["files"] == 2'
STAGOS_CACHE_SYNC=1 stag-ctl recon status >/dev/null 2>&1
check "Control Center feed: stag-ctl recon status carries the server's counts" jt "$(STAGOS_CACHE_SYNC=1 stag-ctl recon status)" 'd["field"]["remote"]["files"] == 2'

echo; echo "== errors: JSON {ok:false,error} =="
G="$HOME/field/2026-09-23"; mkdir -p "$G"; printf 'not a kismet log\n' > "$G/broken.kismet"; touch -d '1 hour ago' "$G/broken.kismet"
R="$("$REAL_CURL" -sS -F "file=@$G/broken.kismet" "http://127.0.0.1:$PORT/maps/api/field/kismet")"
check "corrupt log: 400 body is {ok:false, error}" jt "$R" 'd["ok"] is False and isinstance(d["error"], str)'
: > "$T/sync.err"
J="$(stag-field sync 2>"$T/sync.err")"
check "sync: the corrupt log fails, nothing else is offered" jt "$J" 'd["uploaded"] == 0 and d["failed"] == 1'
check "sync: a 4xx is not retried and its error is shown" bash -c "grep -q 'not a valid Kismet log' '$T/sync.err'"
rm -rf "$G"

echo; echo "== a device that is not an owner =="
touch "$T/srv/as-stranger"
cp "$d/Kismet-20260921-14-00-00-1.kismet" "$HOME/field/2026-09-22/copy.kismet"; printf 'x' >> "$HOME/field/2026-09-22/copy.kismet"
touch -d '1 hour ago' "$HOME/field/2026-09-22/copy.kismet"
R="$("$REAL_CURL" -sS -o /dev/null -w '%{http_code}' -F "file=@$HOME/field/2026-09-22/copy.kismet" "http://127.0.0.1:$PORT/maps/api/field/kismet")"
check "non-owner upload: 403" test "$R" = 403
check "non-owner status: 403 not_owner" jt "$(api status)" 'd["ok"] is False and d["error"] == "not_owner"'
J="$(stag-field sync 2>"$T/sync.err")"
check "sync as a non-owner: refused, nothing recorded" jt "$J" 'd["uploaded"] == 0 and d["failed"] == 1'
check "sync as a non-owner: says not_owner" grep -q not_owner "$T/sync.err"
rm -f "$STAGOS_CACHE/field_remote"
check "Control Center feed: a 403 body is not shown as counts" jt "$(STAGOS_CACHE_SYNC=1 stag-ctl recon status)" 'd["field"]["remote"] is None'
rm -f "$T/srv/as-stranger"
check "server: still 2 files (the refused upload stored nothing)" jt "$(api status)" 'd["files"] == 2'

echo; echo "field-maps-contract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
