"""stag-ntfy-notify (desktop/link/stag-ntfy-notify.py): config and credentials handling, the notify-send
call, and the subscriber against a fake ntfy server on loopback (test/fixtures/fake_ntfy.py).
Run: ./test/link.sh (or: uv run --no-project --with pytest pytest -q test/link)"""

from __future__ import annotations

import importlib.util
import os
import sys
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "test" / "fixtures"))
from fake_ntfy import FakeNtfy  # noqa: E402


def load():
    spec = importlib.util.spec_from_file_location("stag_ntfy_notify", ROOT / "desktop/link/stag-ntfy-notify.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


N = load()
TOKEN = "tk_secret_do_not_print"


@pytest.fixture
def home(tmp_path, monkeypatch):
    """A sandbox HOME with link.env, credentials (600) and desktop.conf; fake tools on PATH."""
    cfg = tmp_path / "config" / "stagos"
    cfg.mkdir(parents=True)
    for k in list(os.environ):
        if k.startswith("STAGOS_") or k in ("XDG_CONFIG_HOME", "XDG_DATA_HOME"):
            monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    fake = tmp_path / "fake"
    fake.mkdir()
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for t in ("notify-send", "xdg-open", "stag-ctl"):
        (bindir / t).symlink_to(ROOT / "test/fixtures/bin/fake-cmd")
    monkeypatch.setenv("PATH", f"{bindir}:{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_DIR", str(fake))
    monkeypatch.setenv("FAKE_LOG", str(fake / "log"))
    (fake / "log").write_text("")
    (fake / "stag-ctl.out").write_text('{"on":false,"until":""}\n')
    return tmp_path


def write_env(home, url, user="stagpad", topics="stag-alerts,stag-agents"):
    (home / "config/stagos/link.env").write_text(f"# test\nNTFY_URL={url}\nNTFY_USER={user}\nNTFY_TOPICS={topics}\n")


def write_creds(home, text=f"NTFY_TOKEN={TOKEN}\n", mode=0o600):
    p = home / "config/stagos/ntfy.credentials"
    p.write_text(text)
    p.chmod(mode)
    return p


def fake_log(home) -> list:
    return (home / "fake/log").read_text().splitlines()


# ---- settings and credentials ----

def test_settings_token_is_bearer(home):
    write_env(home, "https://ntfy.example:8443")
    write_creds(home)
    s = N.load_settings()
    assert s == {"url": "https://ntfy.example:8443", "topics": ["stag-alerts", "stag-agents"],
                 "auth": f"Bearer {TOKEN}"}


def test_settings_password_is_basic_for_the_env_user(home):
    write_env(home, "https://ntfy.example:8443")
    write_creds(home, "NTFY_PASSWORD=pw\nNTFY_TOKEN=\n")
    assert N.load_settings()["auth"] == "Basic c3RhZ3BhZDpwdw=="   # stagpad:pw


@pytest.mark.parametrize("mode", [0o644, 0o640, 0o604])
def test_credentials_readable_by_others_refused(home, mode):
    write_env(home, "https://ntfy.example:8443")
    write_creds(home, mode=mode)
    with pytest.raises(N.ConfigError, match="chmod 600"):
        N.load_settings()


def test_credentials_symlink_refused(home, tmp_path):
    write_env(home, "https://ntfy.example:8443")
    real = tmp_path / "real"
    real.write_text(f"NTFY_TOKEN={TOKEN}\n")
    real.chmod(0o600)
    (home / "config/stagos/ntfy.credentials").symlink_to(real)
    with pytest.raises(N.ConfigError, match="symlink"):
        N.load_settings()


def test_credentials_empty_template_is_a_clear_error(home):
    write_env(home, "https://ntfy.example:8443")
    write_creds(home, (ROOT / "desktop/link/ntfy.credentials.example").read_text())
    with pytest.raises(N.ConfigError, match="fill in NTFY_PASSWORD"):
        N.load_settings()


def test_credentials_unknown_key_refused_without_echoing_it(home):
    write_env(home, "https://ntfy.example:8443")
    write_creds(home, "PASSWORD=hunter2\n")
    with pytest.raises(N.ConfigError) as e:
        N.load_settings()
    assert "hunter2" not in str(e.value)


@pytest.mark.parametrize("url,why", [
    ("http://ntfy.example:8443", "https"),
    ("https://ntfy.example:8443/ntfy", "sub-path"),
    ("https://u:p@ntfy.example", "sub-path"),
    ("ftp://ntfy.example", "https"),
])
def test_bad_urls_refused(home, url, why):
    write_env(home, url)
    write_creds(home)
    with pytest.raises(N.ConfigError, match=why):
        N.load_settings()


def test_bad_topics_refused(home):
    write_env(home, "https://ntfy.example", topics="stag-alerts,../x")
    write_creds(home)
    with pytest.raises(N.ConfigError, match="NTFY_TOPICS"):
        N.load_settings()


def test_toggle_from_desktop_conf_and_defaults(home):
    assert N.enabled()                                   # no file at all: on
    data = home / "data/stagos/plasma"
    data.mkdir(parents=True)
    (data / "desktop.conf.default").write_text((ROOT / "desktop/plasma/desktop.conf.default").read_text())
    assert N.enabled()                                   # the shipped default is on
    (home / "config/stagos/desktop.conf").write_text("[bar]\nntfy=false\n[link]\n# c\n  ntfy = false \n")
    assert not N.enabled()
    (home / "config/stagos/desktop.conf").write_text("[link]\nntfy=true\n")
    assert N.enabled()


# ---- the notification ----

@pytest.mark.parametrize("prio,dnd,want", [
    (1, False, "low"), (2, False, "low"), (3, False, "normal"), (None, False, "normal"), ("x", False, "normal"),
    (4, False, "normal"), (5, False, "critical"), (5, True, "normal"), (1, True, "low"),
])
def test_urgency_from_priority_and_dnd(prio, dnd, want):
    assert N.urgency(prio, dnd) == want


@pytest.mark.parametrize("url,ok", [
    ("https://stag.example/lab/", True), ("http://10.0.0.1/x", True), ("file:///etc/passwd", False),
    ("javascript:alert(1)", False), ("", False), (None, False), (5, False), ("https://" + "a" * 3000, False),
])
def test_click_urls_only_http(url, ok):
    assert N.safe_click(url) == (url if ok else "")


def test_notify_argv_escapes_markup_and_names_the_app():
    argv = N.build_notify({"topic": "stag-alerts", "title": "disk", "message": "<b>95%</b> & rising",
                           "priority": 5}, dnd=False, with_action=False)
    assert argv[0] == "notify-send"
    assert argv[argv.index("--app-name") + 1] == "StagOS"
    assert argv[argv.index("--icon") + 1] == "stag-ntfy"
    assert argv[argv.index("--urgency") + 1] == "critical"
    assert argv[-3:] == ["--", "disk", "&lt;b&gt;95%&lt;/b&gt; &amp; rising"]
    assert "--wait" not in argv


def test_notify_title_falls_back_to_topic_and_is_clipped():
    argv = N.build_notify({"topic": "stag-agents", "message": "x" * 5000}, dnd=False, with_action=True)
    assert argv[-2] == "stag-agents"
    assert len(argv[-1]) == N.MAX_BODY
    assert argv[argv.index("--action") + 1] == "default=Open" and "--wait" in argv


def test_dnd_read_from_stag_ctl(home):
    assert N.dnd_on() is False
    (home / "fake/stag-ctl.out").write_text('{"on":true,"until":"2999,1,1,0,0,0"}\n')
    assert N.dnd_on() is True
    assert "stag-ctl dnd status" in fake_log(home)
    (home / "fake/stag-ctl.out").write_text("not json")
    assert N.dnd_on() is False


def test_dnd_caps_urgent_at_normal(home):
    (home / "fake/stag-ctl.out").write_text('{"on":true}\n')
    N.Notifier().show({"topic": "stag-alerts", "title": "t", "message": "m", "priority": 5})
    line = [x for x in fake_log(home) if x.startswith("notify-send")][-1]
    assert "--urgency normal" in line


def test_click_opens_url_when_the_notification_is_clicked(home):
    (home / "fake/notify-send.out").write_text("default\n")
    n = N.Notifier()
    n.show({"topic": "stag-alerts", "title": "t", "message": "m", "click": "https://stag.example/lab/"})
    for _ in range(50):
        if any(x.startswith("xdg-open") for x in fake_log(home)):
            break
        time.sleep(0.05)
    assert "xdg-open https://stag.example/lab/" in fake_log(home)
    assert any("--action default=Open --wait" in x for x in fake_log(home))


def test_no_click_when_dismissed_and_bad_click_urls_get_no_action(home):
    (home / "fake/notify-send.out").write_text("\n")
    n = N.Notifier()
    n.show({"topic": "a", "message": "m", "click": "https://stag.example/"})
    n.show({"topic": "a", "message": "m", "click": "file:///etc/shadow"})
    time.sleep(0.5)
    log = fake_log(home)
    assert not any(x.startswith("xdg-open") for x in log)
    assert sum("--wait" in x for x in log) == 1


# ---- the subscriber against a fake server ----

class Recorder:
    def __init__(self):
        self.shown: list = []

    def show(self, msg):
        self.shown.append(msg)


def run_sub(sub, stop_when, timeout=8.0):
    done = threading.Event()
    t = threading.Thread(target=sub.loop, kwargs={"stop": lambda: done.is_set()}, daemon=True)
    t.start()
    end = time.monotonic() + timeout
    while time.monotonic() < end and not stop_when():
        time.sleep(0.02)
    ok = stop_when()
    done.set()
    return ok, t


def wait(cond, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


@pytest.fixture
def ntfy():
    srv = FakeNtfy(token=TOKEN)
    yield srv
    srv.close()


def test_live_messages_shown_in_order_with_auth(home, ntfy, monkeypatch, capsys):
    write_env(home, ntfy.url)
    write_creds(home)
    rec = Recorder()
    sub = N.Subscriber(notifier=rec, sleep=lambda s: time.sleep(0.01))
    done = threading.Event()
    t = threading.Thread(target=sub.loop, kwargs={"stop": done.is_set}, daemon=True)
    t.start()
    assert wait(lambda: ntfy.connected() == 1)
    ntfy.publish("stag-alerts", "disk full", title="stagmini", priority=5)
    ntfy.publish("stag-agents", "agent s4 exited rc=0")
    ntfy.publish("other-topic", "not ours")
    assert wait(lambda: len(rec.shown) == 2)
    done.set()
    ntfy.drop()
    t.join(3)
    assert [m["message"] for m in rec.shown] == ["disk full", "agent s4 exited rc=0"]
    path, q, auth = ntfy.requests[0]
    assert path == "/stag-alerts,stag-agents/json" and q == {} and auth == f"Bearer {TOKEN}"
    assert TOKEN not in capsys.readouterr().err


def test_reconnect_catches_up_from_the_last_id(home, ntfy):
    write_env(home, ntfy.url)
    write_creds(home)
    rec = Recorder()
    sub = N.Subscriber(notifier=rec, sleep=lambda s: time.sleep(0.05))
    done = threading.Event()
    t = threading.Thread(target=sub.loop, kwargs={"stop": done.is_set}, daemon=True)
    t.start()
    assert wait(lambda: ntfy.connected() == 1)
    first = ntfy.publish("stag-alerts", "one")
    assert wait(lambda: len(rec.shown) == 1)
    ntfy.status = 503                     # the server goes away for a moment
    ntfy.drop()
    assert wait(lambda: ntfy.connected() == 0)
    ntfy.publish("stag-alerts", "two")    # missed while offline
    ntfy.publish("stag-agents", "three")
    time.sleep(0.2)
    ntfy.status = 0
    assert wait(lambda: ntfy.connected() == 1)
    assert wait(lambda: len(rec.shown) == 3)
    ntfy.publish("stag-alerts", "four")
    assert wait(lambda: len(rec.shown) == 4)
    done.set()
    ntfy.drop()
    t.join(3)
    assert [m["message"] for m in rec.shown] == ["one", "two", "three", "four"]
    polls = [r for r in ntfy.requests if r[1].get("poll") == "1" and r[2]]
    assert polls and polls[-1][1]["since"] == first["id"]
    # the live stream after the catch-up continues from the newest id: nothing shown twice
    streams = [r for r in ntfy.requests if "poll" not in r[1]]
    assert streams[-1][1].get("since") not in (None, first["id"])


def test_catch_up_is_capped_with_a_summary(home, ntfy):
    write_env(home, ntfy.url)
    write_creds(home)
    rec = Recorder()
    sub = N.Subscriber(notifier=rec, sleep=lambda s: time.sleep(0.05))
    sub.last_id = "m0000"                 # as if a message was seen before the gap
    for i in range(8):
        ntfy.publish("stag-alerts", f"missed {i}")
    ok, t = run_sub(sub, lambda: ntfy.connected() == 1 and len(rec.shown) >= 6)
    ntfy.drop()
    t.join(3)
    assert ok
    assert [m["message"] for m in rec.shown[:5]] == [f"missed {i}" for i in range(3, 8)]
    assert rec.shown[5]["message"] == "3 more while offline"


def test_wrong_credentials_back_off_quietly(home, ntfy, capsys):
    write_env(home, ntfy.url)
    write_creds(home, "NTFY_TOKEN=tk_wrong_secret\n")
    rec, sleeps = Recorder(), []
    sub = N.Subscriber(notifier=rec, sleep=lambda s: (sleeps.append(s), time.sleep(0.005)))
    ok, t = run_sub(sub, lambda: len(sleeps) >= 6)
    t.join(3)
    assert ok and rec.shown == []
    assert sleeps[:6] == [2.0, 4.0, 8.0, 16.0, 32.0, 64.0]
    err = capsys.readouterr().err
    assert err.count("refused: HTTP 401") == 1 and "tk_wrong_secret" not in err


def test_offline_backoff_is_capped_and_logged_once(home, monkeypatch, capsys):
    srv = FakeNtfy(token=TOKEN)
    url = srv.url
    srv.close()                           # nothing listens there now: connection refused
    write_env(home, url)
    write_creds(home)
    monkeypatch.setenv("STAGOS_NTFY_BACKOFF_MAX", "10")
    rec, sleeps = Recorder(), []
    sub = N.Subscriber(notifier=rec, sleep=lambda s: sleeps.append(s))
    ok, t = run_sub(sub, lambda: len(sleeps) >= 6)
    t.join(3)
    assert ok and rec.shown == []
    assert sleeps[:6] == [2.0, 4.0, 8.0, 10.0, 10.0, 10.0]
    assert capsys.readouterr().err.count("offline") == 1


def test_disabled_never_connects(home, ntfy, monkeypatch):
    write_env(home, ntfy.url)
    write_creds(home)
    (home / "config/stagos/desktop.conf").write_text("[link]\nntfy=false\n")
    sleeps = []
    sub = N.Subscriber(notifier=Recorder(), sleep=lambda s: sleeps.append(s))
    ok, t = run_sub(sub, lambda: len(sleeps) >= 3)
    t.join(3)
    assert ok and ntfy.requests == [] and sleeps[0] == 30.0


def test_turning_it_off_closes_the_stream(home, ntfy):
    write_env(home, ntfy.url)
    write_creds(home)
    sub = N.Subscriber(notifier=Recorder(), sleep=lambda s: time.sleep(0.02))
    done = threading.Event()
    t = threading.Thread(target=sub.loop, kwargs={"stop": done.is_set}, daemon=True)
    t.start()
    assert wait(lambda: ntfy.connected() == 1)
    (home / "config/stagos/desktop.conf").write_text("[link]\nntfy=false\n")
    assert wait(lambda: ntfy.connected() == 0)      # at the next keepalive
    done.set()
    t.join(3)
    assert sub.state == "disabled"


def test_missing_config_waits_without_connecting(home):
    sleeps = []
    sub = N.Subscriber(notifier=Recorder(), sleep=lambda s: sleeps.append(s))
    ok, t = run_sub(sub, lambda: len(sleeps) >= 2)
    t.join(3)
    assert ok and sub.state == "waiting for config"


def test_check_mode_never_prints_the_secret(home, capsys):
    write_env(home, "https://ntfy.example:8443")
    write_creds(home)
    assert N.main(["--check"]) == 0
    out = capsys.readouterr()
    assert "ntfy.example:8443" in out.out and TOKEN not in out.out + out.err
    write_creds(home, mode=0o644)
    assert N.main(["--check"]) == 3
