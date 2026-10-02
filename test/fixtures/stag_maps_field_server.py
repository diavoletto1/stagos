#!/usr/bin/env python3
"""The real stag-maps app (a local checkout) on 127.0.0.1, set up the way Caddy serves it, for the
field upload contract test (test/field-maps-contract.sh). Dev/test only.

    STAG_MAPS_DIR=~/repos/stag-maps  $STAG_MAPS_DIR/.venv-dev/bin/python stag_maps_field_server.py WORKDIR

- a temp DB and field dir under WORKDIR, the repo's own fake `tailscale whois` and a temp owner list
  (backend/tests/fixtures/fake_whois.py), so nothing live is read or written
- mounted under /maps like Caddy's handle_path, and every request gets the X-Forwarded-For Caddy would add:
  the laptop's tailnet address (an owner node), or, while WORKDIR/as-stranger exists, a node on no list
- prints the port on stdout, then serves until killed. Bind is 127.0.0.1 only.
"""

import os
import sys
import tempfile
from pathlib import Path

MAPS = Path(os.environ["STAG_MAPS_DIR"]).expanduser().resolve()
BACKEND = MAPS / "backend"
WORK = Path(sys.argv[1]).resolve()
sys.path[:0] = [str(BACKEND), str(BACKEND / "tests" / "fixtures")]
os.chdir(BACKEND)
for k, v in {"STAG_DISABLE_AVIATION_POLLER": "1", "STAG_CCTV_SWEEP": "0", "STAG_CCTV_ICONS": "0",
             "STAG_INTERNAL_TOKEN": "contract-test-token"}.items():
    os.environ.setdefault(k, v)
os.environ["STAG_MAPS_LOG_DIR"] = tempfile.mkdtemp(dir=WORK)
for k in ("STAG_MAPS_OWNER_NODES", "STAG_MAPS_OWNER_LOGIN", "STAG_MAPS_BLOCKED_NODE"):
    os.environ.pop(k, None)

from werkzeug.middleware.dispatcher import DispatcherMiddleware  # noqa: E402
from werkzeug.serving import make_server  # noqa: E402
from werkzeug.wrappers import Response  # noqa: E402

from stag_maps_core import db, identity, owners  # noqa: E402
import fake_whois  # noqa: E402
import routes.field as rf  # noqa: E402

db.DB_PATH = WORK / "maps.db"
rf.FIELD_DIR = WORK / "field"
db.init_db()
fake_whois.install(identity)
fake_whois.write_owners(WORK / "owners.conf")
os.environ[owners.PATH_ENV] = str(WORK / "owners.conf")
owners.reset_cache()

import server  # noqa: E402

inner = DispatcherMiddleware(Response("not here", status=404), {"/maps": server.app.wsgi_app})


def caddy(environ, start_response):
    stranger = (WORK / "as-stranger").exists()
    environ["HTTP_X_FORWARDED_FOR"] = fake_whois.STRANGER if stranger else fake_whois.PAD
    return inner(environ, start_response)


httpd = make_server("127.0.0.1", 0, caddy, threaded=True)
print(httpd.server_port, flush=True)
httpd.serve_forever()
