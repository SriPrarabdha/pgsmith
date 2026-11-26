"""In-database sync and event delivery, end to end, in the compose stack's
Supabase Postgres (pg_net, http, pg_cron, Vault) against the local Flagsmith
and a scriptable mock (tests/remote/mock_flagsmith.py).

    docker compose -f infra/docker-compose.yml up -d flagsmith appdb   # + demos/seed_flagsmith.py
    pytest tests/remote

Skipped when the stack is not running.
"""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import time
import urllib.request
import uuid

import psycopg
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
APPDB = os.environ.get("PGFS_APPDB_DSN", "postgresql://postgres:pgfs@127.0.0.1:55433/postgres")
MOCK_HOST = "http://127.0.0.1:18080"
MOCK_NET = "http://pgfs-mock:8080"
FLAGSMITH_NET = "http://flagsmith:8000/api/v1/"


def _env() -> dict:
    p = ROOT / "demos" / ".env"
    if not p.exists():
        return {}
    return dict(line.split("=", 1) for line in p.read_text().splitlines() if "=" in line and not line.startswith("#"))


def _docker(args: str) -> subprocess.CompletedProcess:
    if shutil.which("docker") and subprocess.run("docker info", shell=True, capture_output=True).returncode == 0:
        return subprocess.run("docker " + args, shell=True, capture_output=True, text=True)
    return subprocess.run(["sg", "docker", "-c", "docker " + args], capture_output=True, text=True)


@pytest.fixture(scope="module")
def env():
    e = _env()
    if not e.get("PROD_SERVER_KEY"):
        pytest.skip("demos/.env missing: seed the local Flagsmith first")
    return e


@pytest.fixture(scope="module")
def db(env):
    try:
        c = psycopg.connect(APPDB, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        pytest.skip("compose appdb not running")
    have = {r[0] for r in c.execute("SELECT extname FROM pg_extension").fetchall()}
    missing = {"pg_flagsmith", "http", "pg_net", "pg_cron", "supabase_vault"} - have
    if missing:
        pytest.skip(f"appdb lacks {missing}")
    yield c
    c.close()


class Mock:
    def _call(self, path, body=None):
        req = urllib.request.Request(MOCK_HOST + path, data=json.dumps(body).encode() if body is not None else None,
                                     method="POST" if body is not None or path != "/_requests" else "GET")
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read() or b"null")

    def reset(self):
        self._call("/_reset", {})

    def route(self, path, status=200, body="", headers=None):
        self._call("/_configure", {path: {"status": status, "body": body if isinstance(body, str) else json.dumps(body),
                                          "headers": headers or {}}})

    def requests(self, path=None):
        return [r for r in self._call("/_requests") if path is None or r["path"] == path]


@pytest.fixture(scope="module")
def mock(db):
    if _docker("inspect pgfs-mock").returncode != 0:
        r = _docker(f"run -d --rm --name pgfs-mock --network pgflagsmith_default -p 127.0.0.1:18080:8080 "
                    f"-v {ROOT / 'tests' / 'remote'}:/m:ro python:3.12-slim python /m/mock_flagsmith.py 8080")
        if r.returncode != 0:
            pytest.skip(f"cannot start the mock: {r.stderr}")
    m = Mock()
    for _ in range(50):
        try:
            m.reset()
            break
        except OSError:
            time.sleep(0.2)
    yield m


@pytest.fixture()
def secrets(db):
    made = []

    def make(value: str) -> str:
        name = "pgfs_it_" + uuid.uuid4().hex[:8]
        db.execute("SELECT vault.create_secret(%s, %s)", (value, name))
        made.append(name)
        return name
    yield make
    for n in made:
        db.execute("DELETE FROM vault.secrets WHERE name = %s", (n,))


@pytest.fixture()
def sources(db):
    made = []

    def add(name: str, api_url: str, secret: str, **kw) -> str:
        args = ", ".join(f"{k} => %({k})s" for k in kw)
        db.execute(f"SELECT flagsmith.add_remote_source(%(n)s, %(u)s, %(s)s{', ' + args if args else ''})",
                   {"n": name, "u": api_url, "s": secret, **kw})
        made.append(name)
        return name
    # only this test's sources take part in a pass
    db.execute("UPDATE flagsmith.remote_source SET enabled = false")
    yield add
    for n in made:
        db.execute("SELECT flagsmith.remove_remote_source(%s)", (n,))


def tick(db, name):
    rows = db.execute("SELECT source, outcome, snapshot_id, detail FROM flagsmith.sync_tick()").fetchall()
    return [r for r in rows if r[0] == name]


def status(db, name) -> dict:
    cur = db.execute("SELECT * FROM flagsmith.sync_status() WHERE name = %s", (name,))
    return dict(zip([d.name for d in cur.description], cur.fetchone()))


def current(db, env_key):
    return db.execute("SELECT snapshot_id FROM flagsmith.environments() WHERE env_key = %s", (env_key,)).fetchone()[0]


def test_sources_are_validated(db, secrets):
    s = secrets("ser.x")
    bad = [("http://flagsmith:8000/api/v1/", {}, "plain http"),
           ("https://user:pw@flagsmith.example/api/v1/", {}, "without credentials"),
           ("https://flagsmith.example/api/v1/?x=1", {}, "without credentials"),
           ("file:///etc/passwd", {}, "http"),
           ("https://flagsmith.example/api/v1/\nX-Injected: 1", {}, "http")]
    for url, kw, msg in bad:
        with pytest.raises(psycopg.errors.RaiseException, match=msg):
            db.execute("SELECT flagsmith.add_remote_source('it_bad', %s, %s)", (url, s))
    with pytest.raises(psycopg.errors.RaiseException, match="no Vault secret"):
        db.execute("SELECT flagsmith.add_remote_source('it_bad', 'https://flagsmith.example/api/v1/', 'nope_x')")
    assert db.execute("SELECT count(*) FROM flagsmith.remote_source WHERE name = 'it_bad'").fetchone()[0] == 0


def test_http_transport_loads_then_answers_304(db, env, secrets, sources):
    pusher_sid = current(db, env["PROD_CLIENT_KEY"])
    name = sources("it_prod_http", FLAGSMITH_NET, secrets(env["PROD_SERVER_KEY"]), allow_insecure_http=True)
    assert status(db, name)["transport"] == "http"
    (_, outcome, sid, _), = tick(db, name)
    assert outcome in ("loaded", "reused", "unchanged"), outcome
    sid = sid or current(db, env["PROD_CLIENT_KEY"])
    # the SQL mapper's snapshot evaluates exactly like the pusher's (official SDK mapper)
    rows = db.execute("SELECT identifier, traits FROM app.users ORDER BY identifier LIMIT 500").fetchall()
    q = "SELECT feature, enabled, value, variant, reason FROM flagsmith.get_flags(%s, %s, snapshot_id => %s) ORDER BY 1"
    for ident, traits in rows:
        t = json.dumps(traits)
        assert db.execute(q, (ident, t, pusher_sid)).fetchall() == db.execute(q, (ident, t, sid)).fetchall()
    # unchanged since: recognised by the body's hash, not parsed again
    (_, outcome, _, _), = tick(db, name)
    assert outcome == "unchanged"
    st = status(db, name)
    assert st["last_status"] == 200 and st["consecutive_failures"] == 0 and st["security_note"].startswith("plain http")


def test_pg_net_transport_and_sync_run(db, env, secrets, sources):
    name = sources("it_stg_net", FLAGSMITH_NET, secrets(env["STAGING_SERVER_KEY"]), transport="pg_net",
                   allow_insecure_http=True)
    db.execute("CALL flagsmith.sync_run()")
    st = status(db, name)
    assert st["last_outcome"] in ("loaded", "reused", "unchanged", "not_modified"), st
    assert not st["in_flight"]
    # Supabase grants anon/authenticated access to pg_net's tables: reported
    assert "anon" in (st["security_note"] or "")
    # our response did not stay in the shared table
    assert db.execute("SELECT count(*) FROM net._http_response WHERE content LIKE %s",
                      (f'%{env["STAGING_CLIENT_KEY"]}%',)).fetchone()[0] == 0


def test_a_flag_change_reaches_postgres(db, env, secrets, sources):
    from tools.pgflagsmith.admin import FlagsmithAdmin
    fs = FlagsmithAdmin(env["FLAGSMITH_API_URL"], token=env["FLAGSMITH_TOKEN"])
    feat = {f["name"]: f for f in fs.features(int(env["FLAGSMITH_PROJECT_ID"]))}["max_upload_mb"]
    name = sources("it_prod_change", FLAGSMITH_NET, secrets(env["PROD_SERVER_KEY"]), allow_insecure_http=True)
    tick(db, name)
    before = db.execute("SELECT value FROM flagsmith.get_flags('nobody', '{}', %s) WHERE feature = 'max_upload_mb'",
                        (env["PROD_CLIENT_KEY"],)).fetchone()[0]
    marker = f"it-{uuid.uuid4().hex[:6]}"
    fs.set_default(env["PROD_CLIENT_KEY"], feat["id"], value=marker)
    try:
        t0 = time.perf_counter()
        (_, outcome, sid, _), = tick(db, name)
        assert outcome == "loaded", outcome
        assert db.execute("SELECT value FROM flagsmith.get_flags('nobody', '{}', %s) WHERE feature = 'max_upload_mb'",
                          (env["PROD_CLIENT_KEY"],)).fetchone()[0] == marker
        assert time.perf_counter() - t0 < 5
    finally:
        fs.set_default(env["PROD_CLIENT_KEY"], feat["id"], value=before)
    (_, outcome, _, _), = tick(db, name)
    assert outcome in ("reused", "loaded")


def _doc(env, api_key="it_mock_env"):
    from tools.pgflagsmith.sync import fetch_document
    d = fetch_document(env["FLAGSMITH_API_URL"], env["PROD_SERVER_KEY"])
    d["api_key"] = api_key
    d["name"] = "it mock"
    return d


def test_failures_keep_the_last_snapshot_serving(db, env, mock, secrets, sources):
    mock.reset()
    key = "ser.mock-" + uuid.uuid4().hex[:6]
    name = sources("it_mock", MOCK_NET + "/a/", secrets(key), allow_insecure_http=True)
    path = "/a/environment-document/"
    good = json.dumps(_doc(env))
    mock.route(path, 200, good, {"Last-Modified": "Mon, 23 Nov 2026 19:10:40 GMT", "Content-Type": "application/json"})
    (_, outcome, sid, _), = tick(db, name)
    assert outcome == "loaded"
    req = mock.requests(path)[-1]
    assert req["headers"]["X-Environment-Key"] == key
    assert req["headers"]["User-Agent"].startswith("pg_flagsmith/")
    (_, outcome, _, _), = tick(db, name)
    assert outcome == "unchanged"                       # same body: recognised by its hash
    # never conditional (Flagsmith's Last-Modified can trail a change)
    assert all("If-Modified-Since" not in r["headers"] for r in mock.requests(path))
    for st, body, msg in [(200, "{not json", "invalid input syntax for type json"),
                          (500, "boom", "HTTP 500"), (401, "", "refused the server-side key"),
                          (200, json.dumps(_doc(env, "another_env")), "is for environment another_env"),
                          (200, json.dumps({"api_key": "it_mock_env"}), "missing")]:
        mock.route(path, st, body)
        (_, outcome, _, detail), = tick(db, name)
        assert outcome == "error" and msg in detail, (st, detail)
        assert current(db, "it_mock_env") == sid      # still serving the last good snapshot
    assert status(db, name)["consecutive_failures"] == 5
    db.execute("UPDATE flagsmith.remote_source SET max_document_bytes = 1000 WHERE name = %s", (name,))
    mock.route(path, 200, good)
    (_, outcome, _, detail), = tick(db, name)
    assert outcome == "error" and "max_document_bytes" in detail
    db.execute("UPDATE flagsmith.remote_source SET max_document_bytes = 67108864 WHERE name = %s", (name,))
    (_, outcome, _, _), = tick(db, name)
    assert outcome == "unchanged" and status(db, name)["consecutive_failures"] == 0
    db.execute("SELECT flagsmith.remove_environment('it_mock_env')")


def test_pg_cron_runs_the_sync(db, env, secrets, sources):
    name = sources("it_cron", FLAGSMITH_NET, secrets(env["PROD_SERVER_KEY"]), allow_insecure_http=True)
    jid = db.execute("SELECT flagsmith.schedule_sync('2 seconds')").fetchone()[0]
    try:
        t0 = time.time()
        ok = False
        while time.time() - t0 < 30 and not ok:
            time.sleep(1)
            ok = db.execute("""SELECT count(*) FROM cron.job_run_details
                               WHERE jobid = %s AND status = 'succeeded'""", (jid,)).fetchone()[0] > 0
        assert ok, db.execute("SELECT status, return_message FROM cron.job_run_details WHERE jobid = %s "
                              "ORDER BY runid DESC LIMIT 3", (jid,)).fetchall()
        assert status(db, name)["last_success_at"] is not None
    finally:
        assert db.execute("SELECT flagsmith.unschedule_sync()").fetchone()[0]


def test_events_reach_flagsmith(db, env, secrets, sources):
    name = sources("it_events", FLAGSMITH_NET, secrets(env["PROD_SERVER_KEY"]), allow_insecure_http=True)
    tick(db, name)
    ek = env["PROD_CLIENT_KEY"]
    db.execute("SELECT count(*) FROM flagsmith.events_tick()")          # drain anything older
    before = db.execute("SELECT delivered, deduplicated FROM flagsmith.event_status() WHERE env_key = %s",
                        (ek,)).fetchone() or (0, 0)
    for i in range(30):
        db.execute("SELECT flagsmith.track_exposure('search_ranking', %s, 'boosted', env => %s)", (f"it-{i % 20}", ek))
    db.execute("SELECT flagsmith.track_event('add_to_cart', 'it-1', env => %s)", (ek,))
    rows = db.execute("SELECT * FROM flagsmith.events_tick()").fetchall()
    assert [r[3] for r in rows if r[0] == ek] == ["delivered"], rows
    after = db.execute("SELECT delivered, deduplicated FROM flagsmith.event_status() WHERE env_key = %s",
                       (ek,)).fetchone()
    assert after[0] - before[0] == 21 and after[1] - before[1] == 10   # 20 exposures + 1 event; 10 repeats


@pytest.mark.parametrize("transport", ["http", "pg_net"])
def test_event_delivery_failures(db, env, mock, secrets, sources, transport):
    mock.reset()
    ek = "it_ev_" + uuid.uuid4().hex[:6]
    db.execute("SELECT flagsmith.load_context(%s::json)",
               (json.dumps({"environment": {"key": ek, "name": ek}, "features": {}, "segments": {}}),))
    key = "ser.ev-" + uuid.uuid4().hex[:6]
    name = sources("it_ev_" + transport, MOCK_NET + "/api/v1/", secrets(key), transport=transport,
                   events_url=MOCK_NET + "/ev", allow_insecure_http=True)
    db.execute("UPDATE flagsmith.remote_source SET env_key = %s WHERE name = %s", (ek, name))

    def run():
        db.execute("SELECT count(*) FROM flagsmith.events_tick()")
        if transport == "pg_net":   # responses arrive after commit
            for _ in range(100):
                if not db.execute("SELECT count(*) FROM flagsmith.event_batch WHERE env_key = %s AND state = 'in_flight'",
                                  (ek,)).fetchone()[0]:
                    break
                time.sleep(0.05)
                db.execute("SELECT count(*) FROM flagsmith.events_tick()")

    def batches():
        return db.execute("SELECT state, n_events FROM flagsmith.event_batch WHERE env_key = %s ORDER BY batch_id",
                          (ek,)).fetchall()

    def track(n):
        for i in range(n):
            db.execute("SELECT flagsmith.track_exposure('f', %s, 'a', '{\"plan\": \"pro\"}', env => %s)", (f"u{i}", ek))

    # 429: kept for a retry, then delivered
    mock.route("/ev", 429)
    track(5)
    run()
    assert batches() == [("retry", 5)]
    mock.route("/ev", 202)
    db.execute("UPDATE flagsmith.event_batch SET next_attempt_at = now() WHERE env_key = %s", (ek,))
    run()
    assert batches() == []
    sent = json.loads(mock.requests("/ev")[-1]["body"])["events"]
    assert len(sent) == 5 and sent[0]["event"] == "$flag_exposure" and sent[0]["feature_name"] == "f"
    assert sent[0]["value"] == "a" and sent[0]["traits"] == {"plan": "pro"}
    assert sent[0]["metadata"]["sdk_version"].startswith("pg_flagsmith/") and isinstance(sent[0]["timestamp"], int)
    assert mock.requests("/ev")[-1]["headers"]["X-Environment-Key"] == key
    # 400: dropped, counted as rejected
    mock.route("/ev", 400, "bad")
    track(3)
    run()
    assert batches() == [("rejected", 3)]
    # 401: refused; delivery stops (events stay queued) until the key is fixed
    mock.route("/ev", 401)
    track(2)
    run()
    assert ("refused", 2) in batches()
    track(4)
    run()
    assert db.execute("SELECT queued FROM flagsmith.event_status() WHERE env_key = %s", (ek,)).fetchone()[0] == 4
    mock.route("/ev", 200)
    assert db.execute("SELECT flagsmith.events_retry_failed(%s)", (ek,)).fetchone()[0] == 1
    run()
    run()
    assert db.execute("SELECT queued, delivered, rejected FROM flagsmith.event_status() WHERE env_key = %s",
                      (ek,)).fetchone() == (0, 11, 3)
    assert db.execute("SELECT flagsmith.remove_environment(%s)", (ek,)).fetchone()[0]
    assert db.execute("SELECT count(*) FROM flagsmith.event_status() WHERE env_key = %s", (ek,)).fetchone()[0] == 0
