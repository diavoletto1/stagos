#!/usr/bin/env python3
"""stag-krunner: StagOS commands in KRunner (Meta+Space), a Plasma 6 D-Bus runner (org.kde.krunner1).

  t <text>      add a task to stag-tasks (stag-ctl task add), the new task id comes back as a notification
  ask <text>    hand the question to Stagbot, exactly like `stag-ctl stagbot open <text>`
  stag [name]   open a stag-* app from ~/.config/stagos/stag-services (stag-ctl app open)

Installed per user by the module link: the plugin metadata in ~/.local/share/krunner/dbusplugins/, D-Bus
activation in ~/.local/share/dbus-1/services/, the unit stagos-krunner.service. KRunner starts it on demand.
Every action goes through stag-ctl, so the shell and KRunner do the same thing.
Test overrides: STAGOS_STAG_CTL, STAGOS_NOTIFY_SEND, STAGOS_STAG_LIST.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading

BUS_NAME = "org.stagos.krunner"
OBJ_PATH = "/runner"
IFACE = "org.kde.krunner1"
# KRunner category relevance (KRunner::QueryMatch::CategoryRelevance): Highest = 100, Moderate = 50
EXACT, MODERATE = 100, 50
MAX_TEXT = 500   # stag-tasks title limit


def services_file() -> str:
    cfg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.environ.get("STAGOS_STAG_LIST") or os.path.join(cfg, "stagos", "stag-services")


def services() -> list:
    """Names from stag-services ("name|url" per line), in file order."""
    out = []
    try:
        with open(services_file(), encoding="utf-8") as f:
            for line in f:
                name, sep, url = line.strip().partition("|")
                if sep and name and url and name not in out:
                    out.append(name)
    except OSError:
        pass
    return out


def split(query: str):
    """'t buy milk' -> ('t', 'buy milk'). The keyword is case-insensitive and needs a space after it,
    except a bare 'stag' (it lists every app)."""
    q = query.strip()
    head, _, rest = q.partition(" ")
    kw = head.lower()
    if kw in ("t", "ask") and rest.strip():
        return kw, rest.strip()
    if kw == "stag":
        return kw, rest.strip()
    return "", ""


def match(query: str) -> list:
    """KRunner matches: (id, text, icon, category relevance, relevance, properties)."""
    kw, arg = split(query)
    if kw == "t":
        title = arg[:MAX_TEXT]
        return [("task:" + title, f"Add task: {title}", "stag-tasks", EXACT, 1.0,
                 {"subtext": "stag-tasks, new task (not started)"})]
    if kw == "ask":
        return [("ask:" + arg, f"Ask Stagbot: {arg}", "stag-control", EXACT, 1.0,
                 {"subtext": "opens the Stagbot chat, the question is on the clipboard"})]
    if kw == "stag":
        names = services()
        want = arg.lower()
        hits = [n for n in names if n.lower().startswith(want)] + \
               [n for n in names if want and want in n.lower() and not n.lower().startswith(want)]
        res = []
        for i, n in enumerate(hits):
            exact = n.lower() == want
            res.append(("app:" + n, f"Stag {n[:1].upper()}{n[1:]}", f"stag-{n}",
                        EXACT if exact or want else MODERATE, 1.0 if exact else max(0.5, 0.9 - i * 0.05),
                        {"subtext": f"open stag-{n}"}))
        return res
    return []


def ctl(*args: str, timeout: float = 20) -> tuple:
    """Run stag-ctl, return (rc, parsed JSON or {})."""
    exe = os.environ.get("STAGOS_STAG_CTL") or "stag-ctl"
    try:
        p = subprocess.run([exe, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return 1, {"error": str(e)}
    try:
        data = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else {}
    except ValueError:
        data = {}
    return p.returncode, data if isinstance(data, dict) else {}


def notify(title: str, body: str, icon: str, urgency: str = "normal") -> None:
    exe = os.environ.get("STAGOS_NOTIFY_SEND") or "notify-send"
    try:
        subprocess.run([exe, "--app-name", "StagOS", "--icon", icon, "--urgency", urgency, "--", title, body],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass


def add_task(text: str) -> None:
    rc, data = ctl("task", "add", text)
    if rc == 0 and isinstance(data.get("id"), int):
        notify(f"Task #{data['id']} added", text, "stag-tasks")
    else:
        notify("Task not added", str(data.get("error") or f"stag-ctl exited {rc}"), "stag-tasks", "critical")


def run(match_id: str, action_id: str = "") -> threading.Thread | None:
    """Do what a match says. Slow work (the task POST) runs in a thread so KRunner never waits on it."""
    kind, _, arg = match_id.partition(":")
    if not arg:
        return None
    if kind == "task":
        t = threading.Thread(target=add_task, args=(arg[:MAX_TEXT],), daemon=True)
    elif kind == "ask":
        t = threading.Thread(target=ctl, args=("stagbot", "open", arg), daemon=True)
    elif kind == "app" and arg in services():
        t = threading.Thread(target=ctl, args=("app", "open", arg), daemon=True)
    else:
        return None
    t.start()
    return t


def serve() -> int:
    import dbus
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib

    class Runner(dbus.service.Object):
        @dbus.service.method(IFACE, in_signature="s", out_signature="a(sssida{sv})")
        def Match(self, query):
            return dbus.Array([(i, t, ic, dbus.Int32(c), dbus.Double(r), dbus.Dictionary(p, signature="sv"))
                               for i, t, ic, c, r, p in match(str(query))], signature="(sssida{sv})")

        @dbus.service.method(IFACE, in_signature="", out_signature="a(sss)")
        def Actions(self):
            return dbus.Array([], signature="(sss)")

        @dbus.service.method(IFACE, in_signature="ss", out_signature="")
        def Run(self, match_id, action_id):
            run(str(match_id), str(action_id))

        @dbus.service.method(IFACE, in_signature="", out_signature="")
        def Teardown(self):
            pass

    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName(BUS_NAME, bus, do_not_queue=True)
    Runner(bus, OBJ_PATH)
    _keep = name  # noqa: F841  the name is released when this goes away
    GLib.MainLoop().run()
    return 0


def main(argv: list) -> int:
    if argv[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    if argv[:1] == ["--match"]:   # debugging: what KRunner would show for a query
        for m in match(" ".join(argv[1:])):
            print(json.dumps({"id": m[0], "text": m[1], "icon": m[2]}))
        return 0
    return serve()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
