"""Fake ntfy server for tests (loopback only, port 0 = any free port). Speaks the bit of the ntfy JSON
API stag-ntfy-notify uses: GET /<topic,topic>/json[?since=<id|unix time>][&poll=1].

    srv = FakeNtfy(token="tk_test")          # or user="stagpad", password="pw"
    srv.url                                  # http://127.0.0.1:PORT
    srv.publish("stag-alerts", "disk full", title="stagmini", priority=5, click="https://x/")
    srv.drop()                               # end the open stream(s), like a lost connection
    srv.requests                             # [(path, query dict, Authorization header)]
    srv.close()

Streams start with an "open" event, then every published message (live), and a keepalive every
`keepalive` seconds. A poll (poll=1) returns the cached messages after `since` and closes. A wrong or
missing Authorization gets 401 (`status` forces another code for every request).
"""

from __future__ import annotations

import base64
import json
import queue
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeNtfy:
    def __init__(self, token: str = "", user: str = "", password: str = "", keepalive: float = 0.3):
        self.token, self.user, self.password, self.keepalive = token, user, password, keepalive
        self.messages: list = []
        self.requests: list = []
        self.status = 0
        self._streams: list = []
        self._lock = threading.Lock()
        self._n = 0
        fake = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_GET(self):
                fake._handle(self)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def _authorized(self, header: str) -> bool:
        if self.token and header == f"Bearer {self.token}":
            return True
        if self.user and header == "Basic " + base64.b64encode(f"{self.user}:{self.password}".encode()).decode():
            return True
        return False

    def publish(self, topic: str, message: str, **extra) -> dict:
        with self._lock:
            self._n += 1
            msg = {"id": f"m{self._n:04d}", "time": int(time.time()), "event": "message", "topic": topic,
                   "message": message, **extra}
            self.messages.append(msg)
            for topics, q in self._streams:
                if topic in topics:
                    q.put(msg)
        return msg

    def drop(self) -> None:
        with self._lock:
            for _, q in self._streams:
                q.put(None)

    def connected(self) -> int:
        with self._lock:
            return len(self._streams)

    def _after(self, topics: list, since: str) -> list:
        msgs = [m for m in self.messages if m["topic"] in topics]
        if not since:
            return []
        if since.isdigit():
            return [m for m in msgs if m["time"] >= int(since)]
        ids = [m["id"] for m in msgs]
        return msgs[ids.index(since) + 1:] if since in ids else msgs

    def _handle(self, h: BaseHTTPRequestHandler) -> None:
        u = urllib.parse.urlsplit(h.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        auth = h.headers.get("Authorization", "")
        self.requests.append((u.path, q, auth))
        parts = u.path.strip("/").split("/")
        if self.status or not self._authorized(auth):
            code = self.status or 401
            body = json.dumps({"code": code * 100 + 1, "http": code, "error": "unauthorized"}).encode()
            h.send_response(code)
            h.send_header("Content-Type", "application/json")
            h.send_header("Content-Length", str(len(body)))
            h.end_headers()
            h.wfile.write(body)
            return
        if len(parts) != 2 or parts[1] != "json":
            h.send_error(404)
            return
        topics = parts[0].split(",")
        if q.get("poll") == "1":
            body = b"".join(json.dumps(m).encode() + b"\n" for m in self._after(topics, q.get("since", "")))
            h.send_response(200)
            h.send_header("Content-Type", "application/x-ndjson")
            h.send_header("Content-Length", str(len(body)))
            h.end_headers()
            h.wfile.write(body)
            return
        h.send_response(200)
        h.send_header("Content-Type", "application/x-ndjson")
        h.send_header("Connection", "close")
        h.end_headers()
        mq: queue.Queue = queue.Queue()
        with self._lock:
            backlog = self._after(topics, q.get("since", ""))
            self._streams.append((topics, mq))
        try:
            self._line(h, {"id": "open", "time": int(time.time()), "event": "open", "topic": parts[0]})
            for m in backlog:
                self._line(h, m)
            while True:
                try:
                    m = mq.get(timeout=self.keepalive)
                except queue.Empty:
                    self._line(h, {"id": "ka", "time": int(time.time()), "event": "keepalive", "topic": parts[0]})
                    continue
                if m is None:
                    break
                self._line(h, m)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with self._lock:
                self._streams = [s for s in self._streams if s[1] is not mq]
            h.close_connection = True

    @staticmethod
    def _line(h, obj) -> None:
        h.wfile.write(json.dumps(obj).encode() + b"\n")
        h.wfile.flush()

    def close(self) -> None:
        self.drop()
        self.httpd.shutdown()
        self.httpd.server_close()
