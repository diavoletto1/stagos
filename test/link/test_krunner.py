"""stag-krunner (desktop/link/stag-krunner.py): query parsing, matches and what Run does, with a fake
stag-ctl and notify-send (test/fixtures/bin/fake-cmd). No network, no D-Bus; the D-Bus side runs in
test/link/krunner_dbus.py (./test/link.sh starts it in a private dbus-run-session).
Run: ./test/link.sh (or: uv run --no-project --with pytest pytest -q test/link)"""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load():
    spec = importlib.util.spec_from_file_location("stag_krunner", ROOT / "desktop/link/stag-krunner.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


K = load()


@pytest.fixture
def sb(tmp_path, monkeypatch):
    for k in list(os.environ):
        if k.startswith("STAGOS_") or k == "XDG_CONFIG_HOME":
            monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / ".config/stagos").mkdir(parents=True)
    (tmp_path / ".config/stagos/stag-services").write_text(
        "tasks|https://stag.example/tasks/\nmaps|https://stag.example/maps/\ncontrol|https://stag.example/control/\n"
        "media|https://stag.example/media/\n\nbroken line\n")
    fake, bindir = tmp_path / "fake", tmp_path / "bin"
    fake.mkdir()
    bindir.mkdir()
    for t in ("notify-send", "stag-ctl"):
        (bindir / t).symlink_to(ROOT / "test/fixtures/bin/fake-cmd")
    monkeypatch.setenv("PATH", f"{bindir}:{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_DIR", str(fake))
    monkeypatch.setenv("FAKE_LOG", str(fake / "log"))
    (fake / "log").write_text("")
    return tmp_path


def log(sb) -> list:
    return (sb / "fake/log").read_text().splitlines()


def ids(q):
    return [m[0] for m in K.match(q)]


@pytest.mark.parametrize("q,want", [
    ("t buy milk", ("t", "buy milk")), ("T  buy milk  ", ("t", "buy milk")), ("ask is maps up?", ("ask", "is maps up?")),
    ("ASK x", ("ask", "x")), ("stag", ("stag", "")), ("stag ma", ("stag", "ma")),
    ("t", ("", "")), ("t ", ("", "")), ("tea", ("", "")), ("task x", ("", "")), ("asking x", ("", "")),
    ("stagbot", ("", "")), ("", ("", "")), ("ask", ("", "")),
])
def test_split(q, want):
    assert K.split(q) == want


def test_task_match(sb):
    (m,) = K.match("t buy milk")
    mid, text, icon, cat, rel, props = m
    assert (mid, text, icon, cat, rel) == ("task:buy milk", "Add task: buy milk", "stag-tasks", K.EXACT, 1.0)
    assert "stag-tasks" in props["subtext"]


def test_task_title_capped_at_500(sb):
    assert len(K.match("t " + "x" * 900)[0][0]) == len("task:") + 500


def test_ask_match(sb):
    assert ids("ask what broke?") == ["ask:what broke?"]


def test_stag_lists_every_app_in_file_order(sb):
    assert ids("stag") == ["app:tasks", "app:maps", "app:control", "app:media"]
    assert [m[3] for m in K.match("stag")] == [K.MODERATE] * 4


def test_stag_prefix_then_substring(sb):
    assert ids("stag m") == ["app:maps", "app:media"]
    assert ids("stag a") == ["app:tasks", "app:maps", "app:media"]
    assert ids("stag MAPS") == ["app:maps"]
    (m,) = K.match("stag maps")
    assert m[1:4] == ("Stag Maps", "stag-maps", K.EXACT) and m[4] == 1.0
    assert ids("stag nope") == []


def test_no_services_file_no_apps(sb):
    (sb / ".config/stagos/stag-services").unlink()
    assert ids("stag") == []


def test_unrelated_queries_match_nothing(sb):
    for q in ("firefox", "t", "time", "stagos", "ask"):
        assert K.match(q) == []


def test_run_task_notifies_the_new_id(sb):
    (sb / "fake/stag-ctl.out").write_text('{"created":true,"id":42,"title":"buy milk"}\n')
    K.run("task:buy milk").join(5)
    lg = log(sb)
    assert lg[0] == "stag-ctl task add buy milk"
    assert lg[1] == "notify-send --app-name StagOS --icon stag-tasks --urgency normal -- Task #42 added buy milk"


def test_run_task_failure_is_a_critical_notification(sb):
    (sb / "fake/stag-ctl.out").write_text('{"error":"stag-tasks: HTTP 403 not_owner"}\n')
    (sb / "fake/stag-ctl.rc").write_text("1")
    K.run("task:x").join(5)
    assert log(sb)[1] == ("notify-send --app-name StagOS --icon stag-tasks --urgency critical -- Task not added "
                          "stag-tasks: HTTP 403 not_owner")


def test_run_task_without_stag_ctl(sb, monkeypatch):
    monkeypatch.setenv("STAGOS_STAG_CTL", str(sb / "missing"))
    K.run("task:x").join(5)
    assert log(sb)[0].startswith("notify-send --app-name StagOS --icon stag-tasks --urgency critical -- Task not added")


def test_run_ask_is_stagbot_open_with_the_exact_text(sb):
    (sb / "fake/stag-ctl.out").write_text('{"opened":true,"prefill":false,"copied":true}\n')
    K.run('ask:why is "maps" slow?  ').join(5)
    assert log(sb) == ['stag-ctl stagbot open why is "maps" slow?  ']


def test_run_app_only_for_known_names(sb):
    K.run("app:maps").join(5)
    assert K.run("app:../../etc") is None
    assert K.run("app:") is None and K.run("bogus:x") is None and K.run("") is None
    assert log(sb) == ["stag-ctl app open maps"]


def test_cli_match_debug(sb, capsys):
    assert K.main(["--match", "t", "hello"]) == 0
    assert '"id": "task:hello"' in capsys.readouterr().out


def test_plugin_metadata_points_at_the_service():
    meta = (ROOT / "desktop/link/stagos-krunner.desktop").read_text()
    act = (ROOT / "desktop/link/org.stagos.krunner.service.in").read_text()
    unit = (ROOT / "desktop/link/stagos-krunner.service").read_text()
    assert f"X-Plasma-DBusRunner-Service={K.BUS_NAME}" in meta
    assert f"X-Plasma-DBusRunner-Path={K.OBJ_PATH}" in meta
    assert "X-Plasma-API=DBus" in meta and "X-Plasma-API-Minimum-Version=2.0" in meta
    assert f"Name={K.BUS_NAME}" in act and "SystemdService=stagos-krunner.service" in act
    assert f"BusName={K.BUS_NAME}" in unit and "Type=dbus" in unit
