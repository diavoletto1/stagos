# fixture: synthetic unplug histories for stag-charge (desktop/bin/stag-charge.py), in the format of
# /var/lib/stagos/battery-history.json "unplugs". Local time, so set TZ (and time.tzset()) first.
#   event(date, "07:15")                    one unplug after an overnight charge, seen at once
#   event(date, "07:15", precise=False)     seen only after a resume (time unknown, not learned)
#   history_on([dates], ["07:15", ...])     one event per date
#   python3 charge_history.py NOW_EPOCH     prints a history.json: 7 weekdays at ~07:15 before NOW
import datetime as dt
import json
import sys


def event(day, hhmm, precise=True, session_min=8 * 60):
    h, m = map(int, hhmm.split(":"))
    t = int(dt.datetime.combine(day, dt.time(h, m)).timestamp())
    return {"t": t, "plugged": t - session_min * 60, "precise": precise}


def history_on(days, times):
    return [event(d, t) for d, t in zip(days, times)]


if __name__ == "__main__":
    now = dt.datetime.fromtimestamp(int(sys.argv[1])).date()
    days, d = [], now - dt.timedelta(days=1)
    while len(days) < 7:
        if d.weekday() < 5:
            days.append(d)
        d -= dt.timedelta(days=1)
    times = ["07:10", "07:20", "07:15", "07:05", "07:25", "07:15", "07:12"]
    print(json.dumps({"v": 1, "unplugs": history_on(days, times)}))
