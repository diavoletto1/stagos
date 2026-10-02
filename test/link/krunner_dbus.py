#!/usr/bin/python3
"""stag-krunner over D-Bus, the way KRunner talks to it: a private session bus whose service dir holds
the generated org.stagos.krunner.service, so the first Match call D-Bus-activates the installed runner.
Needs the system python3 with python-dbus + python-gobject (what the module installs).
Run by ./test/link.sh:  dbus-run-session --config-file=<conf> -- /usr/bin/python3 test/link/krunner_dbus.py HOME
(HOME is a sandbox with ~/.local/lib/stagos/stag-krunner, stag-services and fake stag-ctl/notify-send on PATH)."""

import json
import os
import sys
import time

import dbus

home = sys.argv[1]
fails = 0


def check(name, ok):
    global fails
    print(("ok   " if ok else "FAIL ") + name)
    fails += 0 if ok else 1


bus = dbus.SessionBus()
obj = bus.get_object("org.stagos.krunner", "/runner")   # activation happens on the first call
runner = dbus.Interface(obj, "org.kde.krunner1")

res = runner.Match("t buy milk", signature="s")
check("Match: activated through the .service file", bus.name_has_owner("org.stagos.krunner"))
check("Match: wire signature a(sssida{sv})", res.signature == "(sssida{sv})")
check("Match: task match", len(res) == 1 and str(res[0][0]) == "task:buy milk" and str(res[0][1]) == "Add task: buy milk"
      and int(res[0][3]) == 100 and float(res[0][4]) == 1.0 and "subtext" in res[0][5])
apps = runner.Match("stag m")
check("Match: stag apps from stag-services", [str(m[0]) for m in apps] == ["app:maps", "app:media"])
check("Match: no match is an empty array", len(runner.Match("firefox")) == 0)
acts = runner.Actions()
check("Actions: none, typed a(sss)", len(acts) == 0 and acts.signature == "(sss)")

log = os.path.join(home, "fake", "log")
open(os.path.join(home, "fake", "stag-ctl.out"), "w").write(json.dumps({"created": True, "id": 7}) + "\n")
runner.Run("task:buy milk", "")
for _ in range(100):
    if "Task #7 added" in open(log).read():
        break
    time.sleep(0.05)
lines = open(log).read().splitlines()
check("Run: stag-ctl task add, then the id as a notification",
      "stag-ctl task add buy milk" in lines and any("Task #7 added" in x for x in lines))
runner.Run("app:../x", "")
runner.Teardown()
check("Run: unknown app ignored, runner still answers", len(runner.Match("t x")) == 1)
print(f"krunner-dbus: {fails} failed")
sys.exit(1 if fails else 0)
