#!/usr/bin/env python3
# stag-charge: StagOS optimized battery charging, the macOS idea on ThinkPad charge thresholds.
# ThinkPads cannot slow the charge, so this delays it like Apple does: on AC the battery waits at the hold
# threshold (75/80 from config/stagos.conf); the unplug times are learned, and about 90 min before the
# usual unplug the thresholds go to 99/100 so it is full just in time. After the unplug, or 2 h past the
# predicted time, it goes back to 80. No steady pattern (fewer than 5 days, or scattered times): stays at 80.
# Runs as root from stagos-charge.service (timer every 5 min, udev on an AC change, after resume).
#   stag-charge tick             record AC changes, pick the thresholds, apply them (root)
#   stag-charge full             charge to 100% now, until the next unplug (root: stag-battery full)
#   stag-charge hold             back to the hold threshold, also ends a top-off in progress (root: stag-battery hold)
#   stag-charge status [--json]  learned schedule, next top-off, thresholds (any user)
# Files: /etc/stagos/battery.conf (written by stagos-desktop power), /var/lib/stagos/battery-history.json
# (unplug events), /var/lib/stagos/battery-state.json, /run/stagos/charge-note (one line, bar tooltip).
# Test overrides: STAGOS_SYS, STAGOS_BAT, STAGOS_CHARGE_CONF, STAGOS_CHARGE_STATE_DIR, STAGOS_CHARGE_NOTE,
# STAGOS_NOW (epoch seconds), TZ.
import datetime as dt
import fcntl
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

DAY_START = 3             # local hour a day starts: an unplug at 01:00 belongs to the evening before
PRECISE_GAP = 20 * 60     # an unplug seen within this long of the last tick on AC has a trustworthy time
KEEP_DAYS = 60
TOPOFF = (99, 100)        # start 99, not 96: a battery resting at 80 only charges when below the start value
WAKE_UNIT = "stagos-charge-wake"
CONF_DEFAULTS = {
    "OPTIMIZED": 1, "START": 75, "STOP": 80, "LEAD_MIN": 90, "GRACE_MIN": 120, "WINDOW_DAYS": 14,
    "MIN_WEEKDAY": 5, "MIN_WEEKEND": 3, "TOLERANCE_MIN": 45, "MIN_SESSION_MIN": 120, "WAKE": 1,
}


class Paths:
    def __init__(self, env=os.environ):
        self.sys = env.get("STAGOS_SYS", "/sys")
        self.bat = os.path.join(self.sys, "class/power_supply", env.get("STAGOS_BAT", "BAT0"))
        self.conf = env.get("STAGOS_CHARGE_CONF", "/etc/stagos/battery.conf")
        self.state_dir = env.get("STAGOS_CHARGE_STATE_DIR", "/var/lib/stagos")
        self.history = os.path.join(self.state_dir, "battery-history.json")
        self.state = os.path.join(self.state_dir, "battery-state.json")
        self.note = env.get("STAGOS_CHARGE_NOTE", "/run/stagos/charge-note")


def log(msg):
    print(f"stag-charge: {msg}", file=sys.stderr)


def conf(path):
    """KEY=VALUE integers from battery.conf over CONF_DEFAULTS; a bad hold pair falls back to 75/80"""
    c = dict(CONF_DEFAULTS)
    try:
        with open(path) as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                v = v.strip().strip('"')
                if sep and k in c and v.isdigit():
                    c[k] = int(v)
    except OSError:
        pass
    if not (0 <= c["START"] <= 99 and 1 <= c["STOP"] <= 100 and c["START"] < c["STOP"]):
        c["START"], c["STOP"] = 75, 80
    return c


# ---- local days (wall clock, so 07:15 stays 07:15 across a DST change) ----
def local(ts):
    return dt.datetime.fromtimestamp(ts)


def day_of(ts):
    """(day, minutes past DAY_START) of a timestamp, local time"""
    s = local(ts) - dt.timedelta(hours=DAY_START)
    return s.date(), s.hour * 60 + s.minute


def at(day, minute):
    """epoch of `minute` past DAY_START on `day`, local time (DST aware through mktime)"""
    return (dt.datetime.combine(day, dt.time(DAY_START)) + dt.timedelta(minutes=minute)).timestamp()


def kind(day):
    return "weekend" if day.weekday() >= 5 else "weekday"


def hm(ts):
    return local(ts).strftime("%H:%M")


# ---- prediction ----
def samples(history, day, c):
    """per past day of day's kind within the window: minutes past DAY_START of its first unplug that
    ended a long AC session (the overnight charge) and was seen right away (not asleep, not off)"""
    first = {}
    lo = day - dt.timedelta(days=c["WINDOW_DAYS"])
    for e in history:
        try:
            t = float(e["t"])
            plugged = float(e.get("plugged", t))
        except (KeyError, TypeError, ValueError):
            continue
        if not e.get("precise") or t - plugged < c["MIN_SESSION_MIN"] * 60:
            continue
        d, m = day_of(t)
        if lo <= d < day and kind(d) == kind(day) and m < first.get(d, 10**9):
            first[d] = m
    return sorted(first.values())


def predict(history, day, c):
    """(minutes past DAY_START of the expected unplug on day, or None, info)"""
    s = samples(history, day, c)
    need = c["MIN_WEEKEND"] if kind(day) == "weekend" else c["MIN_WEEKDAY"]
    info = {"kind": kind(day), "days": len(s), "need": need, "consistent": 0}
    if len(s) < need:
        return None, dict(info, reason="learning")
    med = statistics.median(s)
    near = [m for m in s if abs(m - med) <= c["TOLERANCE_MIN"]]
    info["consistent"] = len(near)
    if len(near) < need or 3 * len(near) < 2 * len(s):
        return None, dict(info, reason="inconsistent")
    return round(statistics.median(near)), dict(info, reason="ok")


def windows(history, now, c):
    """top-off windows (start, unplug, end) for today and tomorrow that have not ended yet"""
    today = day_of(now)[0]
    out = []
    for d in (today, today + dt.timedelta(days=1)):
        m, _ = predict(history, d, c)
        if m is None:
            continue
        unplug = at(d, m)
        w = (unplug - c["LEAD_MIN"] * 60, unplug, unplug + c["GRACE_MIN"] * 60)
        if w[2] > now:
            out.append(w)
    return out


def open_windows(st, history, now, c):
    skip = max(st.get("consumed_until", 0), st.get("suppress_until", 0))
    return [w for w in windows(history, now, c) if w[2] > skip]


def decide(st, history, now, ac, c):
    """(mode, (start, stop), note, wake_at) for this moment"""
    hold = (c["START"], c["STOP"])
    if not c["OPTIMIZED"]:
        return "off", hold, "", None
    if st.get("override") == "full":
        return "full", TOPOFF, "charging to 100% (stag-battery full) until unplugged", None
    ws = open_windows(st, history, now, c)
    if ac and ws and ws[0][0] <= now:
        return "topoff", TOPOFF, f"topping off to 100% for the usual {hm(ws[0][1])} unplug", None
    if not ac:
        return "hold", hold, "", None
    if ws:
        return "hold", hold, f"charging on hold at {hold[1]}%, full by {hm(ws[0][1])}", ws[0][0]
    return "hold", hold, f"charging on hold at {hold[1]}%", None


# ---- hardware ----
def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def on_ac(p):
    """any mains supply online, or no battery at all"""
    base = os.path.join(p.sys, "class/power_supply")
    seen = False
    try:
        names = sorted(os.listdir(base))
    except OSError:
        names = []
    for n in names:
        t = read(os.path.join(base, n, "type"))
        if t == "Mains" and read(os.path.join(base, n, "online")) == "1":
            return True
        seen = seen or t == "Battery"
    return not seen


def thresholds(p):
    s, e = (read(os.path.join(p.bat, f"charge_control_{k}_threshold")) for k in ("start", "end"))
    return (int(s) if s.isdigit() else None, int(e) if e.isdigit() else None)


def writes(cur, target):
    """[(file key, value)] in an order that keeps start <= stop after every write (thinkpad_acpi refuses
    otherwise): raising writes stop first, lowering writes start first"""
    if cur[1] is None:
        return []
    out = [("end", target[1])] if cur[1] != target[1] else []
    if cur[0] is not None and cur[0] != target[0]:
        start = [("start", target[0])]
        out = out + start if target[1] >= cur[1] else start + out
    return out


def apply(p, target):
    """set the thresholds; True when something changed"""
    todo = writes(thresholds(p), target)
    for k, v in todo:
        try:
            with open(os.path.join(p.bat, f"charge_control_{k}_threshold"), "w") as f:
                f.write(f"{v}\n")
        except OSError as e:
            log(f"could not set the {k} threshold to {v}: {e}")
            return False
    return bool(todo)


def wake(st, at_ts, c):
    """a transient timer that wakes a suspended laptop for the top-off (only armed while on AC)"""
    want = int(at_ts) if (at_ts and c["WAKE"]) else None
    if st.get("wake_at") == want:
        return
    if not (shutil.which("systemd-run") and shutil.which("systemctl")):
        return
    subprocess.run(["systemctl", "stop", f"{WAKE_UNIT}.timer"], capture_output=True)
    st.pop("wake_at", None)
    if want is None:
        return
    utc = dt.datetime.fromtimestamp(want, dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    r = subprocess.run(["systemd-run", "--quiet", "--collect", f"--unit={WAKE_UNIT}", f"--on-calendar={utc}",
                        "--timer-property=WakeSystem=true", "--timer-property=AccuracySec=1min",
                        os.path.abspath(sys.argv[0]), "tick"], capture_output=True, text=True)
    if r.returncode == 0:
        st["wake_at"] = want
    else:
        log(f"could not arm the wake timer: {r.stderr.strip()}")


# ---- files ----
def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except (OSError, ValueError) as e:
        log(f"{path} unreadable ({e}), starting fresh")
        return default


def save(path, data):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def write_note(path, note):
    if read(path) == note:
        return
    if not note:
        try:
            os.remove(path)
        except OSError:
            pass
        return
    try:
        os.makedirs(os.path.dirname(path), 0o755, exist_ok=True)
        with open(f"{path}.tmp", "w") as f:
            f.write(note + "\n")
        os.chmod(f"{path}.tmp", 0o644)
        os.replace(f"{path}.tmp", path)
    except OSError as e:
        log(f"could not write {path}: {e}")


# ---- commands ----
def active_window(st, hist, now, c):
    return next((w for w in open_windows(st, hist, now, c) if w[0] <= now < w[2]), None)


def tick(p, c, st, hist, now, action=None):
    """one step: notice an unplug or plug-in, apply an override, set the thresholds. Mutates st and hist."""
    ac = on_ac(p)
    prev = st.get("ac")
    if prev is True and not ac:
        precise = now - st.get("last_tick", 0) <= PRECISE_GAP
        w = active_window(st, hist, now, c)
        hist.append({"t": int(now), "plugged": int(st.get("since", now)), "precise": precise})
        if w:
            st["consumed_until"] = int(w[2])
        if st.get("override") == "full":
            del st["override"]
    if ac != prev:
        st["since"] = int(now)
    st["ac"], st["last_tick"] = ac, int(now)
    if action == "full":
        st["override"] = "full"
    elif action == "hold":
        st.pop("override", None)
        w = active_window(st, hist, now, c)
        if w:
            st["suppress_until"] = int(w[2])
    hist[:] = [e for e in hist if e.get("t", 0) > now - KEEP_DAYS * 86400]
    mode, target, note, wake_at = decide(st, hist, now, ac, c)
    if mode != "off" or st.get("mode") not in (None, "off"):
        if apply(p, target):
            log(f"{mode}: thresholds {target[0]}/{target[1]}")
    st["mode"] = mode
    wake(st, wake_at if ac else None, c)
    write_note(p.note, note)
    return mode


def schedule(hist, now, c):
    """per kind: the next day of that kind from today and its prediction"""
    today = day_of(now)[0]
    out = {}
    for i in range(8):
        d = today + dt.timedelta(days=i)
        if kind(d) not in out:
            m, info = predict(hist, d, c)
            out[kind(d)] = dict(info, unplug=None if m is None else hm(at(d, m)))
    return out


def status(p, c, st, hist, now, as_json):
    ac = on_ac(p)
    mode, target, note, _ = decide(st, hist, now, ac, c)
    ws = open_windows(st, hist, now, c) if c["OPTIMIZED"] else []
    nxt = next((w for w in ws if w[0] > now), None)
    sched = schedule(hist, now, c)
    asleep = sum(1 for e in hist if not e.get("precise"))
    cur = thresholds(p)
    if as_json:
        print(json.dumps({
            "optimized": bool(c["OPTIMIZED"]), "ac": ac, "mode": mode, "note": note,
            "thresholds": {"start": cur[0], "stop": cur[1]}, "hold": {"start": c["START"], "stop": c["STOP"]},
            "next_topoff": None if not nxt else {"start": int(nxt[0]), "unplug": int(nxt[1])},
            "schedule": sched, "unplugs": len(hist), "unplugs_asleep": asleep,
        }, sort_keys=True))
        return
    if not c["OPTIMIZED"]:
        print(f"optimized:  off (plain {c['START']}/{c['STOP']} thresholds, STAGOS_BAT_OPTIMIZED=0)")
    else:
        print(f"optimized:  on (holds at {c['STOP']}%, tops off {c['LEAD_MIN']} min before the usual unplug)")
        print(f"now:        {note or 'on battery'}")
        if nxt:
            print(f"next:       top-off {local(nxt[0]).strftime('%a %H:%M')}, full by {hm(nxt[1])}")
        else:
            print("next:       no top-off planned (stays at the hold threshold)")
    for k in ("weekday", "weekend"):
        s = sched[k]
        if s["reason"] == "ok":
            txt = f"usually unplugged around {s['unplug']} ({s['consistent']} of {s['days']} days)"
        elif s["reason"] == "learning":
            txt = f"learning ({s['days']} of {s['need']} days needed)"
        else:
            txt = f"no steady pattern ({s['days']} days, only {s['consistent']} close together)"
        print(f"{k + 's:':<11} {txt}")
    print(f"history:    {len(hist)} unplugs recorded" + (f", {asleep} while asleep or off (not used)" if asleep else ""))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    p = Paths()
    c = conf(p.conf)
    now = float(os.environ.get("STAGOS_NOW") or time.time())
    if cmd in ("-h", "--help"):
        with open(__file__) as f:
            print("".join(line[2:] for line in f.readlines()[1:16]), end="")
        return 0
    if cmd == "status":
        hist = load(p.history, {}).get("unplugs", [])
        status(p, c, load(p.state, {}), hist, now, "--json" in argv[2:])
        return 0
    if cmd not in ("tick", "full", "hold"):
        log(f"unknown command {cmd} (see --help)")
        return 2
    try:
        os.makedirs(p.state_dir, 0o755, exist_ok=True)
        with open(os.path.join(p.state_dir, "battery.lock"), "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            st = load(p.state, {})
            data = load(p.history, {})
            hist = data.get("unplugs", []) if isinstance(data, dict) else []
            tick(p, c, st, hist, now, None if cmd == "tick" else cmd)
            save(p.state, st)
            save(p.history, {"v": 1, "unplugs": hist})
    except PermissionError as e:
        log(f"{e}: run as root (stag-battery {cmd} goes through systemd)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
