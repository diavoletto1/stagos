#!/usr/bin/env python3
"""stag-ntfy-notify: stag-ntfy topics -> native Plasma notifications.

Subscribes to the ntfy JSON stream (GET <url>/<topic,topic>/json) and shows every
message with notify-send: app name and icon, urgency from the ntfy priority, and a
click that opens the message's click URL (http/https only). Reconnects with
backoff and stays quiet while offline (one log line per state change, never a
notification about itself). Plasma Do Not Disturb: popups are Plasma's call, and
while DND is on a priority 5 message is sent as normal so it cannot break through.

Run by the systemd --user unit stagos-ntfy.service (module link). Toggle:
[link] ntfy=true|false in ~/.config/stagos/desktop.conf, read live.

Config (written by the module, no secrets): ~/.config/stagos/link.env
  NTFY_URL=https://host:port   NTFY_USER=name   NTFY_TOPICS=stag-alerts,stag-agents
Credentials (Jack fills it, mode 600, owned by you, never sourced or printed):
  ~/.config/stagos/ntfy.credentials   NTFY_PASSWORD=...  or  NTFY_TOKEN=tk_...
Test overrides: STAGOS_LINK_ENV, STAGOS_NTFY_CREDENTIALS, STAGOS_DESKTOP_CONF,
STAGOS_PLASMA_DATA, STAGOS_STAG_CTL, STAGOS_NOTIFY_SEND, STAGOS_XDG_OPEN,
STAGOS_NTFY_BACKOFF_MAX, STAGOS_NTFY_IDLE.
Stdlib only: runs under the system python3.
"""

from __future__ import annotations

import base64
import html
import http.client
import json
import os
import re
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

APP = "StagOS"
ICON = "stag-ntfy"
TOPIC_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
ENV_KEYS = {"NTFY_URL", "NTFY_USER", "NTFY_TOPICS"}
CRED_KEYS = {"NTFY_PASSWORD", "NTFY_TOKEN"}
LOOPBACK = {"127.0.0.1", "localhost", "::1"}
MAX_TITLE, MAX_BODY = 200, 1000
READ_TIMEOUT = 120      # ntfy sends a keepalive every 45 s: two missed = the link is dead (suspend, wifi gone)
MAX_WAITERS = 16        # notify-send --wait processes kept for click actions
WAIT_SECS = 600         # a click action stays live this long
MAX_CATCHUP = 5         # after a reconnect, at most this many missed messages pop up, then one summary


def home(*parts: str) -> str:
    return os.path.join(os.path.expanduser("~"), *parts)


def cfg_dir() -> str:
    return os.environ.get("XDG_CONFIG_HOME") or home(".config")


def log(msg: str) -> None:
    print(f"stag-ntfy-notify: {msg}", file=sys.stderr, flush=True)


class ConfigError(Exception):
    pass


# ---- files ----

def parse_kv(text: str, keys: set, where: str) -> dict:
    """Strict KEY=VALUE (comments and blank lines allowed). Unknown keys are an error."""
    out: dict = {}
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^([A-Z_]+)=(.*)$", s)
        if not m or m.group(1) not in keys:
            raise ConfigError(f"{where}:{n}: not a known KEY=VALUE line")
        v = m.group(2).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        out[m.group(1)] = v
    return out


def read_private(path: str) -> str:
    """Read a secrets file: regular, owned by us, no group/other bits, no symlink."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        raise ConfigError(f"no credentials file {path}") from None
    except OSError as e:
        raise ConfigError(f"cannot open {path}: {e.strerror} (symlinks are refused)") from None
    with os.fdopen(fd, "r", encoding="utf-8") as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise ConfigError(f"{path} is not a regular file")
        if st.st_uid != os.getuid():
            raise ConfigError(f"{path} must be owned by you")
        if st.st_mode & 0o077:
            raise ConfigError(f"{path} is mode {stat.S_IMODE(st.st_mode):o}; run: chmod 600 {path}")
        return f.read(8192)


def env_path() -> str:
    return os.environ.get("STAGOS_LINK_ENV") or os.path.join(cfg_dir(), "stagos", "link.env")


def creds_path() -> str:
    return os.environ.get("STAGOS_NTFY_CREDENTIALS") or os.path.join(cfg_dir(), "stagos", "ntfy.credentials")


def load_settings() -> dict:
    """link.env + credentials -> {url, topics, auth}. Raises ConfigError with a message safe to log."""
    p = env_path()
    try:
        with open(p, encoding="utf-8") as f:
            env = parse_kv(f.read(8192), ENV_KEYS, p)
    except FileNotFoundError:
        raise ConfigError(f"no {p} (run: stagos-desktop link)") from None
    url = env.get("NTFY_URL", "")
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("https", "http") or not u.hostname:
        raise ConfigError("NTFY_URL must be https://host[:port]")
    if u.scheme == "http" and u.hostname not in LOOPBACK:
        raise ConfigError("NTFY_URL must be https:// (plain http only for loopback)")
    if u.username or u.password or u.query or u.fragment or u.path not in ("", "/"):
        raise ConfigError("NTFY_URL must be just scheme://host[:port] (ntfy has no sub-path)")
    topics = [t.strip() for t in re.split(r"[,\s]+", env.get("NTFY_TOPICS", "")) if t.strip()]
    if not topics or not all(TOPIC_RE.match(t) for t in topics):
        raise ConfigError("NTFY_TOPICS must be topic names separated by commas")
    cp = creds_path()
    creds = parse_kv(read_private(cp), CRED_KEYS, cp)
    user = env.get("NTFY_USER", "")
    if creds.get("NTFY_TOKEN"):
        auth = "Bearer " + creds["NTFY_TOKEN"]
    elif user and creds.get("NTFY_PASSWORD"):
        auth = "Basic " + base64.b64encode(f"{user}:{creds['NTFY_PASSWORD']}".encode()).decode()
    else:
        raise ConfigError(f"{cp} is empty: fill in NTFY_PASSWORD (for user {user or '?'}) or NTFY_TOKEN")
    return {"url": f"{u.scheme}://{u.netloc}", "topics": topics, "auth": auth}


def ini_get(section: str, key: str, default: str) -> str:
    """desktop.conf semantics (stag-lib): desktop.conf.default, then desktop.conf; the file wins."""
    data = os.environ.get("STAGOS_PLASMA_DATA") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or home(".local", "share"), "stagos", "plasma")
    conf = os.environ.get("STAGOS_DESKTOP_CONF") or os.path.join(cfg_dir(), "stagos", "desktop.conf")
    val = default
    for path in (os.path.join(data, "desktop.conf.default"), conf):
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        sec = ""
        for line in lines:
            s = line.strip()
            if not s or s[0] in "#;":
                continue
            if s.startswith("[") and "]" in s:
                sec = s[1:s.index("]")]
            elif "=" in s and sec == section:
                k, v = s.split("=", 1)
                if k.strip() == key:
                    val = v.strip()
    return val


def enabled() -> bool:
    return ini_get("link", "ntfy", "true") in ("true", "1", "yes", "on", "True", "TRUE")


# ---- notifications ----

def dnd_on() -> bool:
    """Plasma Do Not Disturb, from stag-ctl (the same check as the Control Center toggle)."""
    ctl = os.environ.get("STAGOS_STAG_CTL") or "stag-ctl"
    try:
        out = subprocess.run([ctl, "dnd", "status"], capture_output=True, text=True, timeout=5).stdout
        return bool(json.loads(out or "{}").get("on"))
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def urgency(priority, dnd: bool) -> str:
    try:
        p = int(priority)
    except (TypeError, ValueError):
        p = 3
    if p <= 2:
        return "low"
    if p >= 5 and not dnd:
        return "critical"
    return "normal"


def safe_click(url) -> str:
    if not isinstance(url, str) or len(url) > 2048:
        return ""
    u = urllib.parse.urlsplit(url)
    return url if u.scheme in ("http", "https") and u.hostname else ""


def clip(s, n: int) -> str:
    s = "" if s is None else str(s)
    s = "".join(c for c in s if c in "\n\t" or ord(c) >= 32)
    return s if len(s) <= n else s[: n - 3] + "..."


def build_notify(msg: dict, dnd: bool, with_action: bool) -> list:
    """notify-send argv for one ntfy message. Body is escaped: Plasma renders a markup subset."""
    topic = clip(msg.get("topic"), 64)
    title = clip(msg.get("title") or topic or "stag-ntfy", MAX_TITLE)
    body = html.escape(clip(msg.get("message"), MAX_BODY), quote=False)
    argv = [os.environ.get("STAGOS_NOTIFY_SEND") or "notify-send",
            "--app-name", APP, "--icon", ICON, "--urgency", urgency(msg.get("priority"), dnd),
            "--hint", "string:desktop-entry:stag-ntfy",
            "--hint", f"string:x-stagos-topic:{topic}"]
    if with_action:
        argv += ["--action", "default=Open", "--wait"]
    return argv + ["--", title, body]


class Notifier:
    def __init__(self):
        self.waiters = 0
        self.lock = threading.Lock()

    def show(self, msg: dict) -> None:
        dnd = dnd_on()
        click = safe_click(msg.get("click"))
        with self.lock:
            wait = bool(click) and self.waiters < MAX_WAITERS
            if wait:
                self.waiters += 1
        argv = build_notify(msg, dnd, wait)
        if not wait:
            try:
                subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            except (OSError, subprocess.SubprocessError) as e:
                log(f"notify-send failed: {e}")
            return
        threading.Thread(target=self._wait, args=(argv, click), daemon=True).start()

    def _wait(self, argv: list, click: str) -> None:
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            try:
                out, _ = p.communicate(timeout=WAIT_SECS)
            except subprocess.TimeoutExpired:
                p.kill()
                p.communicate()
                return
            if out.strip().splitlines()[-1:] == ["default"]:
                opener = os.environ.get("STAGOS_XDG_OPEN") or "xdg-open"
                subprocess.Popen([opener, click], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
        except OSError as e:
            log(f"notify-send failed: {e}")
        finally:
            with self.lock:
                self.waiters -= 1


# ---- the stream ----

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a 3xx: urllib would re-send the Authorization header to the Location."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def stream_url(settings: dict, since: str, poll: bool = False) -> str:
    q = {"since": since} if since else {}
    if poll:
        q["poll"] = "1"
    return f"{settings['url']}/{','.join(settings['topics'])}/json" + (f"?{urllib.parse.urlencode(q)}" if q else "")


def open_stream(settings: dict, since: str, poll: bool = False):
    req = urllib.request.Request(stream_url(settings, since, poll), headers={
        "Authorization": settings["auth"], "User-Agent": "stag-ntfy-notify"})
    return _OPENER.open(req, timeout=READ_TIMEOUT)


class Subscriber:
    """One process: connect, read lines, show messages, reconnect with backoff."""

    def __init__(self, notifier=None, sleep=time.sleep, opener=open_stream):
        self.notifier = notifier or Notifier()
        self.sleep = sleep
        self.opener = opener
        self.last_id = ""
        self.last_time = 0
        self.seen: list = []
        self.state = ""
        self.backoff_max = float(os.environ.get("STAGOS_NTFY_BACKOFF_MAX", "300"))
        self.idle = float(os.environ.get("STAGOS_NTFY_IDLE", "30"))

    def set_state(self, state: str, detail: str = "") -> None:
        if state != self.state:
            log(f"{state}{': ' + detail if detail else ''}")
            self.state = state

    def handle(self, line: bytes, catchup: list) -> None:
        try:
            ev = json.loads(line)
        except ValueError:
            return
        if not isinstance(ev, dict) or ev.get("event") != "message":
            return
        mid = str(ev.get("id", ""))
        if mid and mid in self.seen:
            return
        if mid:
            self.seen = (self.seen + [mid])[-200:]
            self.last_id = mid
        if isinstance(ev.get("time"), int):
            self.last_time = max(self.last_time, ev["time"])
        if catchup is not None:
            catchup.append(ev)
            return
        self.notifier.show(ev)

    def flush_catchup(self, catchup: list) -> None:
        for ev in catchup[-MAX_CATCHUP:]:
            self.notifier.show(ev)
        extra = len(catchup) - MAX_CATCHUP
        if extra > 0:
            self.notifier.show({"topic": "stag-ntfy", "title": "stag-ntfy",
                                "message": f"{extra} more while offline", "priority": 2})

    def since(self) -> str:
        if self.last_id:
            return self.last_id
        return str(self.last_time) if self.last_time else ""

    def run_once(self, settings: dict) -> None:
        """One connection. After a gap (offline, suspend, restart of the stream) the missed messages
        come first from a poll request (since= the last id or time), capped at MAX_CATCHUP; then the
        live stream continues from the newest id seen."""
        since = self.since()
        if since:
            catchup: list = []
            resp = self.opener(settings, since, True)
            try:
                for raw in resp:
                    if raw.strip():
                        self.handle(raw.strip(), catchup)
            finally:
                resp.close()
            self.flush_catchup(catchup)
        resp = self.opener(settings, self.since(), False)
        self.set_state("connected", ",".join(settings["topics"]))
        try:
            for raw in resp:
                if raw.strip():
                    self.handle(raw.strip(), None)
                if not enabled():
                    self.set_state("disabled", "[link] ntfy=false")
                    break
        finally:
            resp.close()

    def loop(self, stop=lambda: False) -> None:
        delay = 2.0
        while not stop():
            if not enabled():
                self.set_state("disabled", "[link] ntfy=false")
                self.sleep(self.idle)
                continue
            try:
                settings = load_settings()
            except ConfigError as e:
                self.set_state("waiting for config", str(e))
                self.sleep(self.idle)
                continue
            started = time.monotonic()
            try:
                self.run_once(settings)
                if not self.last_time:
                    self.last_time = int(time.time())
            except urllib.error.HTTPError as e:
                hint = " (check NTFY_USER, the credentials and the topic ACL)" if e.code in (401, 403) else ""
                self.set_state("refused", f"HTTP {e.code}{hint}")
            except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as e:
                self.set_state("offline", str(getattr(e, "reason", e)))
            if stop():
                break
            if time.monotonic() - started > 60:
                delay = 2.0
            if not self.last_time:
                self.last_time = int(time.time())
            self.sleep(delay)
            delay = min(delay * 2, self.backoff_max)


def main(argv: list) -> int:
    if argv[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    if argv[:1] == ["--check"]:
        try:
            s = load_settings()
        except ConfigError as e:
            print(f"stag-ntfy-notify: {e}", file=sys.stderr)
            return 3
        print(f"ok: {s['url']} topics {','.join(s['topics'])}, ntfy={'on' if enabled() else 'off'}")
        return 0
    try:
        Subscriber().loop()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
