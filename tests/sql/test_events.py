"""The exposure queue and the CLI sender (pg-flagsmith events), against an
in-process stand-in for the events API."""
from __future__ import annotations

import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
import pytest

from tests.conftest import DSN
from tools.pgflagsmith.events import Sender


@pytest.fixture()
def ek(cur):
    key = "ev_" + uuid.uuid4().hex[:10]
    cur.execute("SELECT flagsmith.load_context(%s::json)",
                (json.dumps({"environment": {"key": key, "name": key}, "features": {
                    "mv": {"key": "1", "name": "mv", "enabled": True, "value": "control",
                           "variants": [{"value": "a", "weight": 50, "priority": 1, "key": "arm_a"}]}},
                            "segments": {}}),))
    yield key
    cur.execute("DELETE FROM flagsmith.event_queue WHERE env_key = %s", (key,))


class Api:
    """Answers POSTs with the next scripted status; records bodies and headers."""

    def __init__(self):
        self.statuses: list[int] = []
        self.received: list[dict] = []
        api = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                api.received.append({"headers": dict(self.headers), "body": json.loads(body)})
                st = api.statuses.pop(0) if api.statuses else 202
                self.send_response(st)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/api/v1/events"

    def close(self):
        self.httpd.shutdown()


@pytest.fixture()
def api():
    a = Api()
    yield a
    a.close()


def sender(api, ek) -> Sender:
    s = Sender(DSN, "http://127.0.0.1:1/api/v1/", ["ser.test"], events_url=api.url, batch_size=100)
    s.env_keys = {ek: "ser.test"}
    return s


def queued(cur, ek) -> int:
    return cur.execute("SELECT count(*) FROM flagsmith.event_queue WHERE env_key = %s", (ek,)).fetchone()[0]


def test_claim_dedupes_exposures_and_rolls_back(cur, ek):
    for i in range(10):
        cur.execute("SELECT flagsmith.track_exposure('mv', %s, 'arm_a', env => %s)", (f"u{i % 4}", ek))
    cur.execute("SELECT flagsmith.track_event('add_to_cart', 'u1', '12.5', env => %s)", (ek,))
    cur.execute("SELECT flagsmith.track_event('add_to_cart', 'u1', '12.5', env => %s)", (ek,))
    cur.execute("BEGIN")
    n, sent, payload = cur.execute("SELECT * FROM flagsmith.events_claim(%s, 1000)", (ek,)).fetchone()
    events = json.loads(payload)["events"]
    assert (n, sent) == (12, 6)                      # 4 distinct exposures + 2 custom events (never deduped)
    assert [e["identifier"] for e in events[:4]] == ["u0", "u1", "u2", "u3"]
    assert events[-1] == {**events[-1], "event": "add_to_cart", "value": "12.5", "feature_name": None}
    assert queued(cur, ek) == 0
    cur.execute("ROLLBACK")                          # not delivered: everything is back
    assert queued(cur, ek) == 12


def test_track_variant_records_what_was_served(cur, ek):
    arms = [cur.execute("SELECT flagsmith.track_variant('mv', %s, '{}', %s)", (f"user-{i}", ek)).fetchone()[0]
            for i in range(40)]
    assert set(arms) == {"arm_a", "control"}
    cur.execute("SELECT identifier, value FROM flagsmith.event_queue WHERE env_key = %s ORDER BY event_id", (ek,))
    assert [v for _, v in cur.fetchall()] == arms


def test_queue_is_capped_by_dropping_the_oldest(cur, ek):
    cur.execute("DELETE FROM flagsmith.event_queue")     # the cap is global: start from an empty queue
    cur.execute("INSERT INTO flagsmith.settings (events_max_queued) VALUES (1000) "
                "ON CONFLICT (id) DO UPDATE SET events_max_queued = excluded.events_max_queued")
    try:
        cur.execute("SELECT flagsmith.track_event('e', 'u' || g, env => %s) FROM generate_series(1, 5000) g", (ek,))
        q = queued(cur, ek)
        assert 1000 <= q <= 1000 + 1024
        # the newest events are the ones kept
        newest = cur.execute("SELECT max(identifier::int) FROM (SELECT substr(identifier, 2) AS identifier "
                             "FROM flagsmith.event_queue WHERE env_key = %s) x", (ek,)).fetchone()[0]
        assert newest == 5000
        st = cur.execute("SELECT queued, dropped_overflow FROM flagsmith.event_status() WHERE env_key = %s",
                         (ek,)).fetchone()
        assert st[0] == q and st[1] == 5000 - q
    finally:
        cur.execute("DELETE FROM flagsmith.settings")


def test_inputs_are_validated(cur, ek):
    for args in [("", "u", ek), ("e" * 201, "u", ek)]:
        with pytest.raises(psycopg.errors.RaiseException):
            cur.execute("SELECT flagsmith.track_event(%s, %s, env => %s)", args)
    with pytest.raises(psycopg.errors.RaiseException, match="64 kB"):
        cur.execute("SELECT flagsmith.track_event('e', 'u', traits => %s::jsonb, env => %s)",
                    (json.dumps({"x": "y" * 70000}), ek))
    with pytest.raises(psycopg.errors.RaiseException, match="JSON objects"):
        cur.execute("SELECT flagsmith.track_event('e', 'u', traits => '[1]', env => %s)", (ek,))
    with pytest.raises(psycopg.errors.RaiseException, match="unknown environment"):
        cur.execute("SELECT flagsmith.track_event('e', 'u', env => 'no-such-env')")


def test_sender_delivers_retries_drops_and_stops(conn, cur, ek, api):
    s = sender(api, ek)
    for i in range(250):
        cur.execute("SELECT flagsmith.track_exposure('mv', %s, 'arm_a', '{\"plan\": \"pro\"}', env => %s)",
                    (f"u{i}", ek))
    res = s.drain_once(conn)[ek]
    assert res["delivered"] == 250 and res["batches"] == 3 and queued(cur, ek) == 0
    first = api.received[0]
    assert first["headers"]["X-Environment-Key"] == "ser.test"
    e = first["body"]["events"][0]
    assert e["event"] == "$flag_exposure" and e["traits"] == {"plan": "pro"} and e["value"] == "arm_a"
    # 429 three times: the SDK's retries, then the batch goes back to the queue
    cur.execute("SELECT flagsmith.track_event('click', 'u1', env => %s)", (ek,))
    api.statuses = [429, 429, 429]
    res = s.drain_once(conn)[ek]
    assert "retry_later" in res and queued(cur, ek) == 1
    # a transient failure, then success within one send
    api.statuses = [503]
    assert s.drain_once(conn)[ek]["delivered"] == 1 and queued(cur, ek) == 0
    # 400: dropped and counted
    cur.execute("SELECT flagsmith.track_event('click', 'u1', env => %s)", (ek,))
    api.statuses = [400]
    assert s.drain_once(conn)[ek]["rejected"] == 1 and queued(cur, ek) == 0
    # 401: stop sending for this environment, keep the events
    cur.execute("SELECT flagsmith.track_event('click', 'u1', env => %s)", (ek,))
    api.statuses = [401]
    s.drain_once(conn)
    n_before = len(api.received)
    assert queued(cur, ek) == 1
    s.drain_once(conn)
    assert len(api.received) == n_before and queued(cur, ek) == 1
    st = cur.execute("SELECT delivered, rejected FROM flagsmith.event_status() WHERE env_key = %s", (ek,)).fetchone()
    assert st == (251, 1)


def test_two_senders_never_send_an_event_twice(cur, ek, api):
    cur.execute("SELECT flagsmith.track_event('e', 'u' || g, env => %s) FROM generate_series(1, 3000) g", (ek,))
    results = []

    def run():
        with psycopg.connect(DSN, autocommit=True) as c:
            results.append(sender(api, ek).drain_once(c)[ek])
    threads = [threading.Thread(target=run) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    sent = [e["identifier"] for r in api.received for e in r["body"]["events"]]
    assert len(sent) == 3000 and len(set(sent)) == 3000
    assert sum(r["delivered"] for r in results) == 3000 and queued(cur, ek) == 0


def test_a_claim_never_takes_more_than_its_limit(cur, ek):
    # DELETE ... WHERE id IN (SELECT ... LIMIT n FOR UPDATE SKIP LOCKED) can take more than n
    # when the planner rescans the subquery; with fresh statistics it does
    cur.execute("SELECT flagsmith.track_event('e', 'u' || g, env => %s) FROM generate_series(1, 2500) g", (ek,))
    cur.execute("ANALYZE flagsmith.event_queue")
    cur.execute("BEGIN")
    try:
        for want in (1, 100, 1000):
            n, sent, _ = cur.execute("SELECT * FROM flagsmith.events_claim(%s, %s)", (ek, want)).fetchone()
            assert n == sent == want
    finally:
        cur.execute("ROLLBACK")
