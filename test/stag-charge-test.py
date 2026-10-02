#!/usr/bin/env python3
# Unit tests for desktop/bin/stag-charge.py (optimized battery charging): prediction from synthetic unplug
# histories (consistent, scattered, too few, weekday vs weekend, DST), the threshold write order, and the
# tick state machine against a fake sysfs, a fake clock and fake systemctl/systemd-run.
# Run: python3 test/stag-charge-test.py   (part of ./test/safety.sh)
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ["TZ"] = "America/New_York"   # US DST ends Sun 2026-11-01 02:00 (EDT -> EST)
time.tzset()
_loader = importlib.machinery.SourceFileLoader("stag_charge", os.path.join(ROOT, "desktop/bin/stag-charge.py"))
_spec = importlib.util.spec_from_loader("stag_charge", _loader)
sc = importlib.util.module_from_spec(_spec)
_loader.exec_module(sc)
sys.path.insert(0, os.path.join(ROOT, "test/fixtures"))
from charge_history import event, history_on  # noqa: E402

C = dict(sc.CONF_DEFAULTS)
D = dt.date


def ts(y, mo, d, h, mi):
    return dt.datetime(y, mo, d, h, mi).timestamp()


def weekdays_before(day, n):
    out, d = [], day - dt.timedelta(days=1)
    while len(out) < n:
        if d.weekday() < 5:
            out.append(d)
        d -= dt.timedelta(days=1)
    return out


class Predict(unittest.TestCase):
    MON = D(2026, 10, 12)

    def test_consistent_weekdays(self):
        h = history_on(weekdays_before(self.MON, 7), ["07:10", "07:20", "07:15", "07:05", "07:25", "07:15", "07:12"])
        m, info = sc.predict(h, self.MON, C)
        self.assertEqual(info["reason"], "ok")
        self.assertEqual(sc.hm(sc.at(self.MON, m)), "07:15")
        self.assertEqual((info["days"], info["consistent"]), (7, 7))

    def test_too_few_samples(self):
        h = history_on(weekdays_before(self.MON, 4), ["07:15"] * 4)
        m, info = sc.predict(h, self.MON, C)
        self.assertIsNone(m)
        self.assertEqual((info["reason"], info["days"], info["need"]), ("learning", 4, 5))

    def test_inconsistent(self):
        h = history_on(weekdays_before(self.MON, 6), ["06:00", "07:15", "09:30", "11:00", "13:00", "08:10"])
        m, info = sc.predict(h, self.MON, C)
        self.assertIsNone(m)
        self.assertEqual(info["reason"], "inconsistent")

    def test_one_outlier_is_tolerated(self):
        h = history_on(weekdays_before(self.MON, 6), ["07:15", "07:10", "07:20", "07:15", "07:18", "11:40"])
        m, info = sc.predict(h, self.MON, C)
        self.assertEqual(sc.hm(sc.at(self.MON, m)), "07:15")
        self.assertEqual((info["days"], info["consistent"]), (6, 5))

    def test_weekend_apart_from_weekdays(self):
        sat = D(2026, 10, 17)
        days = [d for d in (sat - dt.timedelta(days=i) for i in range(1, 15))]
        h = history_on([d for d in days if d.weekday() < 5], ["07:15"] * 10)
        h += history_on([d for d in days if d.weekday() >= 5], ["10:30", "10:45", "10:20", "10:35"])
        self.assertEqual(sc.hm(sc.at(sat, sc.predict(h, sat, C)[0])), "10:32")   # median of 10:20 10:30 10:35 10:45
        mon = D(2026, 10, 19)
        self.assertEqual(sc.hm(sc.at(mon, sc.predict(h, mon, C)[0])), "07:15")
        h2 = history_on([d for d in days if d.weekday() < 5], ["07:15"] * 10)
        h2 += history_on([D(2026, 10, 11), D(2026, 10, 10)], ["10:30", "10:30"])
        m, info = sc.predict(h2, sat, C)
        self.assertIsNone(m)
        self.assertEqual((info["kind"], info["days"], info["need"]), ("weekend", 2, 3))

    def test_dst_end_keeps_wall_clock(self):
        # five weekdays on EDT at 07:15, predicted for Monday 2026-11-02 on EST: still 07:15 local
        h = history_on([D(2026, 10, d) for d in (26, 27, 28, 29, 30)], ["07:15"] * 5)
        mon = D(2026, 11, 2)
        m, _ = sc.predict(h, mon, C)
        unplug = sc.at(mon, m)
        self.assertEqual(sc.hm(unplug), "07:15")
        self.assertEqual(dt.datetime.fromtimestamp(unplug, dt.timezone.utc).hour, 12)   # 07:15 EST = 12:15 UTC
        self.assertEqual(dt.datetime.fromtimestamp(h[0]["t"], dt.timezone.utc).hour, 11)  # 07:15 EDT = 11:15 UTC

    def test_dst_start_keeps_wall_clock(self):
        h = history_on([D(2027, 3, d) for d in (8, 9, 10, 11, 12)], ["07:15"] * 5)   # EST
        mon = D(2027, 3, 15)                                                        # EDT since Sun 14 March
        self.assertEqual(sc.hm(sc.at(mon, sc.predict(h, mon, C)[0])), "07:15")

    def test_only_trustworthy_overnight_unplugs_count(self):
        days = weekdays_before(self.MON, 6)
        h = history_on(days[:4], ["07:15"] * 4)
        h.append(event(days[4], "07:15", precise=False))          # seen after a suspend: time unknown
        h.append(event(days[5], "07:15", session_min=30))         # short plug-in, not the overnight charge
        self.assertEqual(sc.predict(h, self.MON, C)[1]["days"], 4)
        old = history_on([self.MON - dt.timedelta(days=15)], ["07:15"])  # outside the 14-day window
        self.assertEqual(sc.predict(h + old, self.MON, C)[1]["days"], 4)

    def test_first_unplug_of_the_day_wins(self):
        days = weekdays_before(self.MON, 5)
        h = history_on(days, ["07:15"] * 5) + history_on(days, ["16:30"] * 5)
        self.assertEqual(sc.hm(sc.at(self.MON, sc.predict(h, self.MON, C)[0])), "07:15")

    def test_late_night_unplug_belongs_to_the_evening_before(self):
        self.assertEqual(sc.day_of(ts(2026, 10, 13, 1, 30)), (D(2026, 10, 12), 22 * 60 + 30))

    def test_windows_lead_and_grace(self):
        h = history_on(weekdays_before(self.MON, 5), ["07:15"] * 5)
        now = ts(2026, 10, 12, 0, 30)    # Sunday night after midnight: still the 11th's day, next is Monday
        w = sc.windows(h, now, C)
        self.assertEqual([sc.hm(x) for x in w[0]], ["05:45", "07:15", "09:15"])
        self.assertEqual(sc.local(w[0][1]).date(), self.MON)


class Writes(unittest.TestCase):
    def test_order_keeps_start_below_stop(self):
        self.assertEqual(sc.writes((75, 80), (99, 100)), [("end", 100), ("start", 99)])
        self.assertEqual(sc.writes((99, 100), (75, 80)), [("start", 75), ("end", 80)])
        self.assertEqual(sc.writes((96, 100), (99, 100)), [("start", 99)])
        self.assertEqual(sc.writes((75, 80), (75, 80)), [])
        self.assertEqual(sc.writes((None, 80), (99, 100)), [("end", 100)])
        self.assertEqual(sc.writes((None, None), (99, 100)), [])
        for cur, tgt in [((40, 60), (75, 80)), ((75, 80), (40, 60)), ((99, 100), (0, 1)), ((0, 1), (99, 100))]:
            s, e = cur
            for k, v in sc.writes(cur, tgt):
                s, e = (v, e) if k == "start" else (s, v)
                self.assertLessEqual(s, e, (cur, tgt))


class Tick(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        os.makedirs(f"{t}/sys/class/power_supply/BAT0")
        os.makedirs(f"{t}/sys/class/power_supply/AC")
        self.w("BAT0/type", "Battery")
        self.w("AC/type", "Mains")
        self.w("BAT0/charge_control_start_threshold", "75")
        self.w("BAT0/charge_control_end_threshold", "80")
        os.makedirs(f"{t}/bin")
        self.log = f"{t}/fake.log"
        for name in ("systemctl", "systemd-run"):
            with open(f"{t}/bin/{name}", "w") as f:
                f.write(f'#!/bin/sh\necho "{name} $*" >> "{self.log}"\n')
            os.chmod(f"{t}/bin/{name}", 0o755)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = f"{t}/bin:{self.old_path}"
        self.p = sc.Paths({"STAGOS_SYS": f"{t}/sys", "STAGOS_CHARGE_STATE_DIR": f"{t}/state",
                           "STAGOS_CHARGE_NOTE": f"{t}/run/charge-note"})
        self.c = dict(C)
        self.st, self.hist = {}, history_on(weekdays_before(D(2026, 10, 12), 6), ["07:15"] * 6)

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        self.tmp.cleanup()

    def w(self, rel, val):
        with open(f"{self.tmp.name}/sys/class/power_supply/{rel}", "w") as f:
            f.write(f"{val}\n")

    def thr(self):
        return sc.thresholds(self.p)

    def note(self):
        return sc.read(self.p.note)

    def fakelog(self):
        if not os.path.exists(self.log):
            return ""
        with open(self.log) as f:
            return f.read()

    def tick(self, when, ac, action=None):
        self.w("AC/online", "1" if ac else "0")
        return sc.tick(self.p, self.c, self.st, self.hist, when, action)

    def test_night_hold_topoff_unplug_replug(self):
        self.assertEqual(self.tick(ts(2026, 10, 11, 22, 0), True), "hold")   # Sunday night on AC
        self.assertEqual(self.thr(), (75, 80))
        self.assertEqual(self.note(), "charging on hold at 80%, full by 07:15")
        self.assertIn("--on-calendar=2026-10-12 09:45:00 UTC", self.fakelog())   # 05:45 EDT, wakes the laptop
        self.assertIn("--timer-property=WakeSystem=true", self.fakelog())
        n = self.fakelog().count("systemd-run")
        self.tick(ts(2026, 10, 12, 3, 0), True)
        self.assertEqual(self.fakelog().count("systemd-run"), n, "armed once, not on every tick")
        self.assertEqual(self.tick(ts(2026, 10, 12, 5, 50), True), "topoff")
        self.assertEqual(self.thr(), (99, 100))
        self.assertIn("systemctl stop stagos-charge-wake.timer", self.fakelog())
        self.tick(ts(2026, 10, 12, 7, 15), True)                            # the 5 min timer
        self.assertEqual(self.tick(ts(2026, 10, 12, 7, 20), False), "hold")  # unplugged
        self.assertEqual(self.thr(), (75, 80))
        self.assertEqual(self.note(), "")
        last = self.hist[-1]
        self.assertTrue(last["precise"])
        self.assertEqual(last["t"] - last["plugged"], int(ts(2026, 10, 12, 7, 20) - ts(2026, 10, 11, 22, 0)))
        self.assertEqual(self.tick(ts(2026, 10, 12, 8, 0), True), "hold")   # plugged in at school: no second top-off
        self.assertEqual(self.thr(), (75, 80))

    def test_window_passes_by_two_hours(self):
        self.tick(ts(2026, 10, 11, 22, 0), True)
        self.assertEqual(self.tick(ts(2026, 10, 12, 9, 10), True), "topoff")
        self.assertEqual(self.tick(ts(2026, 10, 12, 9, 16), True), "hold")
        self.assertEqual(self.thr(), (75, 80))

    def test_full_until_next_unplug(self):
        self.tick(ts(2026, 10, 12, 13, 0), True, "full")
        self.assertEqual(self.thr(), (99, 100))
        self.assertIn("stag-battery full", self.note())
        self.assertEqual(self.tick(ts(2026, 10, 12, 18, 0), True), "full")
        self.assertEqual(self.tick(ts(2026, 10, 12, 18, 5), False), "hold")
        self.assertNotIn("override", self.st)
        self.assertEqual(self.thr(), (75, 80))

    def test_hold_ends_a_topoff(self):
        self.tick(ts(2026, 10, 11, 22, 0), True)
        self.tick(ts(2026, 10, 12, 6, 0), True)
        self.assertEqual(self.tick(ts(2026, 10, 12, 6, 5), True, "hold"), "hold")
        self.assertEqual(self.thr(), (75, 80))
        self.assertEqual(self.tick(ts(2026, 10, 12, 6, 10), True), "hold")
        self.assertEqual(self.tick(ts(2026, 10, 13, 6, 0), True), "topoff", "only today's top-off was skipped")

    def test_unplug_while_asleep_is_not_learned(self):
        self.tick(ts(2026, 10, 11, 23, 0), True)
        self.tick(ts(2026, 10, 12, 9, 0), False)    # next tick after resume, long gap
        self.assertFalse(self.hist[-1]["precise"])

    def test_no_pattern_stays_at_hold(self):
        self.hist[:] = history_on(weekdays_before(D(2026, 10, 12), 3), ["07:15"] * 3)
        self.tick(ts(2026, 10, 11, 22, 0), True)
        self.assertEqual(self.tick(ts(2026, 10, 12, 6, 30), True), "hold")
        self.assertEqual(self.note(), "charging on hold at 80%")
        self.assertNotIn("systemd-run", self.fakelog())

    def test_wake_off(self):
        self.c["WAKE"] = 0
        self.tick(ts(2026, 10, 11, 22, 0), True)
        self.assertNotIn("systemd-run", self.fakelog())

    def test_on_battery_disarms_the_wake(self):
        self.tick(ts(2026, 10, 11, 22, 0), True)
        self.tick(ts(2026, 10, 11, 22, 3), False)
        self.assertNotIn("wake_at", self.st)
        self.assertTrue(self.fakelog().rstrip().endswith("systemctl stop stagos-charge-wake.timer"))

    def test_optimized_off_restores_once_then_leaves_alone(self):
        self.tick(ts(2026, 10, 12, 6, 0), True, "full")
        self.c["OPTIMIZED"] = 0
        self.assertEqual(self.tick(ts(2026, 10, 12, 6, 5), True), "off")
        self.assertEqual(self.thr(), (75, 80))
        self.w("BAT0/charge_control_start_threshold", "40")
        self.w("BAT0/charge_control_end_threshold", "60")
        self.tick(ts(2026, 10, 12, 6, 10), True)
        self.assertEqual(self.thr(), (40, 60))
        self.assertEqual(self.note(), "")

    def test_history_trimmed(self):
        self.hist.append({"t": int(ts(2026, 7, 1, 7, 0)), "plugged": 0, "precise": True})
        self.tick(ts(2026, 10, 12, 12, 0), True)
        self.assertTrue(all(e["t"] > ts(2026, 8, 1, 0, 0) for e in self.hist))


class Conf(unittest.TestCase):
    def test_file_and_fallbacks(self):
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write("# c\nOPTIMIZED=0\nSTART=85\nSTOP=80\nLEAD_MIN=60\nWAKE=x\n")
        c = sc.conf(f.name)
        os.unlink(f.name)
        self.assertEqual((c["OPTIMIZED"], c["START"], c["STOP"], c["LEAD_MIN"], c["WAKE"]), (0, 75, 80, 60, 1))
        self.assertEqual(sc.conf("/nonexistent")["STOP"], 80)


class Status(unittest.TestCase):
    def test_text_and_json(self):
        import contextlib
        import io
        h = history_on(weekdays_before(D(2026, 10, 12), 6), ["07:15"] * 6)
        p = sc.Paths({"STAGOS_SYS": "/nonexistent"})
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            sc.status(p, dict(C), {}, h, ts(2026, 10, 11, 22, 0), False)
        out = buf.getvalue()
        self.assertIn("next:       top-off Mon 05:45, full by 07:15", out)
        self.assertIn("weekdays:   usually unplugged around 07:15 (6 of 6 days)", out)
        self.assertIn("weekends:   learning (0 of 3 days needed)", out)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            sc.status(p, dict(C), {}, h, ts(2026, 10, 11, 22, 0), True)
        j = json.loads(buf.getvalue())
        self.assertEqual(j["schedule"]["weekday"]["unplug"], "07:15")
        self.assertEqual(sc.hm(j["next_topoff"]["start"]), "05:45")


if __name__ == "__main__":
    unittest.main(verbosity=1)
