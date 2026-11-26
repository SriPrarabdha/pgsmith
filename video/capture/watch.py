"""Poll Postgres while a UI shot records: log (wall-clock ms, value, snapshot) every 50 ms until killed."""
import json, sys, time, signal, psycopg
out, feature, ident = sys.argv[1], sys.argv[2], sys.argv[3]
stop = False
signal.signal(signal.SIGTERM, lambda *a: globals().__setitem__('stop', True))
rows = []
with psycopg.connect("postgresql://postgres:pgfs@127.0.0.1:55433/postgres", autocommit=True) as c:
    while not stop:
        v, snap = c.execute("SELECT f.value::text, (SELECT snapshot_id FROM flagsmith.health() WHERE is_default) "
                            "FROM flagsmith.flag(%s, %s) f", (feature, ident)).fetchone()
        rows.append({"t": time.time() * 1000, "value": v, "snapshot": snap})
        time.sleep(0.05)
json.dump(rows, open(out, "w"))
