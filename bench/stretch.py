"""Benchmarks for the stretch tier: the SQL mapper, in-database sync, and the
exposure queue. Writes bench/STRETCH.md and bench/stretch_results.json.

    bench/run.sh                     # first: the bench container with the profile loaded
    python bench/stretch.py          # mapper + queue on the bench container,
                                     # in-database sync on the compose stack (if running)
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import platform
import random
import shutil
import statistics
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "bench"))

from profile import build as build_profile  # noqa: E402

from tools.pgflagsmith.events import Sender  # noqa: E402
from tools.pgflagsmith.sync import document_to_load_args  # noqa: E402

BENCH_DSN = os.environ.get("PGFS_BENCH_DSN", "postgresql://postgres:pgfs@127.0.0.1:55499/pgfs")
APPDB_DSN = os.environ.get("PGFS_APPDB_DSN", "postgresql://postgres:pgfs@127.0.0.1:55433/postgres")


def docker(args: str) -> subprocess.CompletedProcess:
    if shutil.which("docker") and subprocess.run("docker info", shell=True, capture_output=True).returncode == 0:
        return subprocess.run("docker " + args, shell=True, capture_output=True, text=True)
    return subprocess.run(["sg", "docker", "-c", "docker " + args], capture_output=True, text=True)


def med(xs: list[float]) -> float:
    return statistics.median(xs)


# ---------------------------------------------------------------------------
# documents of the benchmark profile's shape
# ---------------------------------------------------------------------------

def _doc_rules(rules: list[dict]) -> list[dict]:
    return [{"type": r["type"],
             "conditions": [{"operator": c["operator"], "property_": c["property"], "value": c["value"]}
                            for c in r.get("conditions", [])],
             "rules": _doc_rules(r.get("rules", []))} for r in rules]


def _fs(fc: dict, fid: int, priority: int | None = None) -> dict:
    d = {"feature": {"id": fid, "name": fc["name"], "type": "STANDARD"}, "enabled": fc["enabled"],
         "feature_state_value": fc.get("value"), "django_id": int(fc["key"]),
         "featurestate_uuid": str(uuid.UUID(int=int(fc["key"]))),
         "feature_segment": {"priority": priority} if priority is not None else None,
         "multivariate_feature_state_values": [
             {"id": v["priority"], "percentage_allocation": v["weight"],
              "multivariate_feature_option": {"value": v["value"], **({"key": v["key"]} if "key" in v else {})}}
             for v in fc.get("variants", [])]}
    return d


def profile_document(n_identity_overrides: int = 0) -> dict:
    """The Edge Proxy profile as an environment document (+ identity overrides)."""
    ctx = build_profile()
    ids = {name: 500 + i for i, name in enumerate(ctx["features"])}
    rng = random.Random(7)
    return {
        "api_key": ctx["environment"]["key"], "name": ctx["environment"]["name"], "id": 1,
        "updated_at": "2026-11-25T00:00:00+00:00",
        "project": {"id": 1, "name": "bench", "segments": [
            {"id": int(s["key"]), "name": s["name"], "rules": _doc_rules(s["rules"]),
             "feature_states": [_fs(o, ids[o["name"]], o.get("priority")) for o in s["overrides"]]}
            for s in ctx["segments"].values()]},
        "feature_states": [_fs(fc, ids[name]) for name, fc in ctx["features"].items()],
        "identity_overrides": [
            {"identifier": f"user{i}", "identity_features": [
                {"feature": {"id": ids[f"feature_{j:02d}"], "name": f"feature_{j:02d}"}, "enabled": rng.random() < .5,
                 "feature_state_value": f"io{i}", "django_id": 10**6 + i * 3 + k,
                 "featurestate_uuid": str(uuid.UUID(int=10**6 + i * 3 + k))}
                for k, j in enumerate(rng.sample(range(50), 3))]}
            for i in range(n_identity_overrides)],
    }


# ---------------------------------------------------------------------------
# 1. mapper and load
# ---------------------------------------------------------------------------

def bench_mapper(conn, real_doc: dict | None) -> list[dict]:
    from flagsmith.mappers import map_environment_document_to_context, \
        map_environment_document_to_identity_overrides_segments
    docs = []
    if real_doc:
        docs.append(("local Flagsmith Production (5 features, 5 segments)", real_doc))
    docs += [("Edge Proxy profile (50 features, 15 segments, 750 overrides)", profile_document()),
             ("profile + 10,000 identity overrides", profile_document(10_000)),
             ("profile + 100,000 identity overrides", profile_document(100_000))]
    out = []
    for label, doc in docs:
        text = json.dumps(doc)
        reps = 3 if len(text) > 5_000_000 else 7
        py, sql, py_load, sql_load, sha = [], [], [], [], []
        for _ in range(reps):
            t = time.perf_counter()
            d = json.loads(text)
            map_environment_document_to_context(d)
            map_environment_document_to_identity_overrides_segments(d)
            py.append(time.perf_counter() - t)
            t = time.perf_counter()
            conn.execute("SELECT length(context::text) FROM flagsmith.map_environment_document(%s::json)", (text,))
            sql.append(time.perf_counter() - t)
            t = time.perf_counter()
            conn.execute("SELECT length(encode(sha256(convert_to(%s, 'UTF8')), 'hex'))", (text,))
            sha.append(time.perf_counter() - t)
        for i in range(1 if len(text) > 5_000_000 else 3):
            # a new environment each time: full loads, never deduplicated
            d = json.loads(text)
            d["api_key"] = f"bench_map_{uuid.uuid4().hex[:8]}"
            t = time.perf_counter()
            ctx, io, rev = document_to_load_args(d)
            with conn.transaction():
                conn.execute("SELECT * FROM flagsmith.apply_context(%s::json, %s::json, 'bench', %s)", (ctx, io, rev))
            py_load.append(time.perf_counter() - t)
            conn.execute("SELECT flagsmith.remove_environment(%s)", (d["api_key"],))
            d["api_key"] = f"bench_map_{uuid.uuid4().hex[:8]}"
            t = time.perf_counter()
            with conn.transaction():
                conn.execute("SELECT * FROM flagsmith.load_document(%s::json, 'bench')", (json.dumps(d),))
            sql_load.append(time.perf_counter() - t)
            conn.execute("SELECT flagsmith.remove_environment(%s)", (d["api_key"],))
        out.append({"document": label, "bytes": len(text.encode()), "python_map_ms": med(py) * 1000,
                    "sql_map_ms": med(sql) * 1000, "unchanged_poll_hash_ms": med(sha) * 1000,
                    "pusher_load_ms": med(py_load) * 1000, "in_db_load_ms": med(sql_load) * 1000})
        print(out[-1], flush=True)
    return out


# ---------------------------------------------------------------------------
# 2. the exposure queue
# ---------------------------------------------------------------------------

def pgbench(script: str, clients: int, seconds: int = 15, options: str = "") -> dict:
    docker(f"exec -i pgfs-bench sh -c 'cat > /tmp/b.sql' <<'EOF'\n{script}\nEOF")
    env = f"-e PGOPTIONS='{options}' " if options else ""
    r = docker(f"exec {env}pgfs-bench pgbench -n -M prepared -c {clients} -j {min(clients, 16)} -T {seconds} "
               f"-f /tmp/b.sql -U postgres pgfs")
    tps = lat = None
    for line in r.stdout.splitlines():
        if line.startswith("tps ="):
            tps = float(line.split()[2])
        if "latency average" in line:
            lat = float(line.split("=")[1].split()[0])
    if tps is None:
        raise RuntimeError(r.stdout + r.stderr)
    return {"tps": tps, "latency_ms": lat}


def bench_queue(conn, env_key: str) -> dict:
    conn.execute("TRUNCATE flagsmith.event_queue")    # start from a clean table every time
    conn.execute("DROP TABLE IF EXISTS bench_plain_queue")
    conn.execute("""CREATE TABLE bench_plain_queue (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, env_key text,
                    event text, feature_name text, identifier text, value text, traits jsonb, metadata jsonb, ts_ms bigint)""")
    res: dict = {"enqueue": []}
    track = (f"\\set id random(1, 1000000)\n"
             f"SELECT flagsmith.track_exposure('feature_00', 'user' || :id, 'a', env => '{env_key}');")
    plain = ("\\set id random(1, 1000000)\n"
             "INSERT INTO bench_plain_queue (env_key, event, feature_name, identifier, value, ts_ms) "
             f"VALUES ('{env_key}', '$flag_exposure', 'feature_00', 'user' || :id, 'a', 0);")
    variant = (f"\\set id random(1, 1000000)\n"
               f"SELECT flagsmith.variant('feature_00', 'user' || :id, '{{}}', '{env_key}');")
    track_variant = (f"\\set id random(1, 1000000)\n"
                     f"SELECT flagsmith.track_variant('feature_00', 'user' || :id, '{{}}', '{env_key}');")
    for clients in (1, 8, 32):
        row = {"clients": clients,
               "track_exposure": pgbench(track, clients),
               "plain_insert": pgbench(plain, clients),
               "variant": pgbench(variant, clients),
               "track_variant": pgbench(track_variant, clients),
               "track_exposure_async_commit": pgbench(track, clients, options="-c synchronous_commit=off")}
        res["enqueue"].append(row)
        print(row, flush=True)
    # drain: claim + payload in the database (no network), then end to end through the CLI sender
    conn.execute("TRUNCATE flagsmith.event_queue")    # start from a clean table every time
    n = 1_000_000
    t = time.perf_counter()
    conn.execute("SELECT flagsmith.track_exposure('feature_00', 'user' || g, 'a', env => %s) "
                 "FROM generate_series(1, %s) g", (env_key, n))
    res["bulk_enqueue_per_s"] = n / (time.perf_counter() - t)
    res["queue_bytes_1m"] = conn.execute("SELECT pg_total_relation_size('flagsmith.event_queue')").fetchone()[0]
    t = time.perf_counter()
    claimed = 0
    while True:
        with conn.transaction():
            k = conn.execute("SELECT n_claimed FROM flagsmith.events_claim(%s, 1000)", (env_key,)).fetchone()[0]
        if not k:
            break
        claimed += k
        if claimed >= 300_000:
            break
    res["claim_events_per_s"] = claimed / (time.perf_counter() - t)

    received = [0]

    class Sink(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            received[0] += 1
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Sink)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{httpd.server_address[1]}/v1/events"
    remaining = conn.execute("SELECT count(*) FROM flagsmith.event_queue WHERE env_key = %s", (env_key,)).fetchone()[0]

    def drain(results):
        with psycopg.connect(BENCH_DSN, autocommit=True) as c:
            s = Sender(BENCH_DSN, "http://127.0.0.1:1/api/v1/", ["ser.bench"], events_url=url, batch_size=1000)
            s.env_keys = {env_key: "ser.bench"}
            results.append(s.drain_once(c, max_batches=10_000)[env_key]["delivered"])
    for senders in (1, 4):
        if senders == 4:
            conn.execute("SELECT flagsmith.track_exposure('feature_00', 'user' || g, 'a', env => %s) "
                         "FROM generate_series(1, %s) g", (env_key, remaining))
        results: list[int] = []
        t = time.perf_counter()
        threads = [threading.Thread(target=drain, args=(results,)) for _ in range(senders)]
        for th in threads:
            th.start()
        for th in threads:
            th.join()
        res[f"cli_sender_events_per_s_{senders}"] = sum(results) / (time.perf_counter() - t)
        res[f"cli_sender_events_{senders}"] = sum(results)
    httpd.shutdown()
    conn.execute("VACUUM flagsmith.event_queue")
    res["queue_bytes_after_drain_vacuum"] = conn.execute(
        "SELECT pg_total_relation_size('flagsmith.event_queue')").fetchone()[0]
    conn.execute("DROP TABLE bench_plain_queue")
    print({k: v for k, v in res.items() if k != "enqueue"}, flush=True)
    return res


# ---------------------------------------------------------------------------
# 3. in-database sync on the Supabase stack
# ---------------------------------------------------------------------------

def bench_in_db_sync() -> dict | None:
    envf = ROOT / "demos" / ".env"
    if not envf.exists():
        return None
    env = dict(line.split("=", 1) for line in envf.read_text().splitlines() if "=" in line)
    try:
        db = psycopg.connect(APPDB_DSN, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        return None
    from tools.pgflagsmith.admin import FlagsmithAdmin
    fs = FlagsmithAdmin(env["FLAGSMITH_API_URL"], token=env["FLAGSMITH_TOKEN"])
    feat = {f["name"]: f for f in fs.features(int(env["FLAGSMITH_PROJECT_ID"]))}["max_upload_mb"]
    out = {}
    secret = "pgfs_bench_" + uuid.uuid4().hex[:6]
    db.execute("SELECT vault.create_secret(%s, %s)", (env["PROD_SERVER_KEY"], secret))
    db.execute("UPDATE flagsmith.remote_source SET enabled = false")
    try:
        for transport in ("http", "pg_net"):
            name = f"bench_{transport}"
            db.execute("SELECT flagsmith.add_remote_source(%s, 'http://flagsmith:8000/api/v1/', %s, transport => %s, "
                       "allow_insecure_http => true)", (name, secret, transport))
            db.execute("CALL flagsmith.sync_run()")
            unchanged, change = [], []
            for _ in range(10):
                t = time.perf_counter()
                db.execute("CALL flagsmith.sync_run()")
                unchanged.append(time.perf_counter() - t)
                assert db.execute("SELECT last_outcome FROM flagsmith.sync_status() WHERE name = %s",
                                  (name,)).fetchone()[0] == "unchanged"
            q = "SELECT value FROM flagsmith.get_flags('nobody', '{}', %s) WHERE feature = 'max_upload_mb'"
            before = db.execute(q, (env["PROD_CLIENT_KEY"],)).fetchone()[0]
            for i in range(5):
                marker = f"bench-{uuid.uuid4().hex[:6]}"
                fs.set_default(env["PROD_CLIENT_KEY"], feat["id"], value=marker)
                t = time.perf_counter()
                db.execute("CALL flagsmith.sync_run()")
                change.append(time.perf_counter() - t)
                v = db.execute("SELECT value FROM flagsmith.get_flags('nobody', '{}', %s) WHERE feature = 'max_upload_mb'",
                               (env["PROD_CLIENT_KEY"],)).fetchone()[0]
                assert v == marker, (v, marker)
            fs.set_default(env["PROD_CLIENT_KEY"], feat["id"], value=before)
            db.execute("CALL flagsmith.sync_run()")
            out[transport] = {"unchanged_run_ms": med(unchanged) * 1000, "change_run_ms": med(change) * 1000}
            db.execute("SELECT flagsmith.remove_remote_source(%s)", (name,))
            print(transport, out[transport], flush=True)
    finally:
        db.execute("DELETE FROM vault.secrets WHERE name = %s", (secret,))
        db.execute("UPDATE flagsmith.remote_source SET enabled = true")
    return out


def render(r: dict) -> str:
    L = ["# pg_flagsmith stretch-tier benchmarks", "",
         f"Machine: {r['machine']}. Mapper and queue on the benchmark container (PostgreSQL 17, the same "
         "settings as RESULTS.md); in-database sync on the compose stack (Supabase Postgres 17 + self-hosted "
         "Flagsmith 2.295.2, same host). Reproduce: `bench/run.sh && python bench/stretch.py`.", "",
         "## Mapping environment documents", "",
         "| Document | Size | Python SDK mapper | SQL mapper | Pusher load (SDK map + load) | In-database load (SQL map + load) | Unchanged poll (body hash) |",
         "|---|---:|---:|---:|---:|---:|---:|"]
    for m in r["mapper"]:
        L.append(f"| {m['document']} | {m['bytes'] / 1e6:.2f} MB | {m['python_map_ms']:.1f} ms | {m['sql_map_ms']:.1f} ms "
                 f"| {m['pusher_load_ms']:.0f} ms | {m['in_db_load_ms']:.0f} ms | {m['unchanged_poll_hash_ms']:.2f} ms |")
    L += ["", "Loads include normalisation, compilation and publishing (and, for the pusher, sending the context "
          "over the connection). An unchanged document costs one hash of its body: it is never parsed.", ""]
    if r.get("in_db_sync"):
        L += ["## In-database sync (Supabase, pg_cron entry point `CALL flagsmith.sync_run()`)", "",
              "| Transport | Unchanged environment | A flag changed in Flagsmith → served by Postgres |", "|---|---:|---:|"]
        for t, v in r["in_db_sync"].items():
            L.append(f"| {t} | {v['unchanged_run_ms']:.1f} ms | {v['change_run_ms']:.0f} ms |")
        L += ["", "One run fetches, maps, loads and publishes. With `schedule_sync('30 seconds')` a change is served "
              "within 30 s plus this; `pg-flagsmith serve` (webhook) serves it within about a second. pg_net hands "
              "the request to its background worker, which adds about a second per run; `http` is synchronous.", ""]
    q = r["queue"]
    L += ["## Exposure queue", "", "Calls per second (pgbench, prepared, random identities):", "",
          "| Clients | track_exposure() | plain INSERT (same row) | track_exposure(), synchronous_commit = off | variant() | track_variant() (evaluate + record) |",
          "|---:|---:|---:|---:|---:|---:|"]
    for e in q["enqueue"]:
        L.append(f"| {e['clients']} | {e['track_exposure']['tps']:,.0f} ({e['track_exposure']['latency_ms']:.3f} ms) "
                 f"| {e['plain_insert']['tps']:,.0f} | {e['track_exposure_async_commit']['tps']:,.0f} "
                 f"| {e['variant']['tps']:,.0f} | {e['track_variant']['tps']:,.0f} |")
    L += ["", "Recording costs the same as a plain INSERT: throughput is bound by commits (WAL flushes). Sessions that "
          "only record analytics can trade the last few milliseconds of events on a crash for throughput with "
          "`SET synchronous_commit = off`.", ""]
    L += ["", f"- Bulk enqueue (one statement): {q['bulk_enqueue_per_s']:,.0f} events/s; 1M queued events take "
          f"{q['queue_bytes_1m'] / 1e6:.0f} MB.",
          f"- Claiming in the database (DELETE ... SKIP LOCKED, dedupe, payload JSON): {q['claim_events_per_s']:,.0f} events/s.",
          f"- End to end through `pg-flagsmith events` to a local HTTP sink: {q['cli_sender_events_per_s_1']:,.0f} events/s "
          f"with one sender, {q['cli_sender_events_per_s_4']:,.0f} events/s with four (no event sent twice).",
          f"- After draining and VACUUM the queue's {q['queue_bytes_after_drain_vacuum'] / 1e6:.0f} MB of pages are free "
          "for new events (the table does not grow while it is drained).", ""]
    return "\n".join(L)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-queue", action="store_true")
    ap.add_argument("--mapper-results", help="reuse mapper results (JSON) instead of measuring again")
    a = ap.parse_args()
    r: dict = {"machine": f"{platform.processor() or platform.machine()}, {os.cpu_count()} cores"}
    try:
        cpu = [l for l in open("/proc/cpuinfo") if l.startswith("model name")][0].split(":")[1].strip()
        r["machine"] = f"{cpu}, {os.cpu_count()} cores"
    except OSError:
        pass
    real = None
    envf = ROOT / "demos" / ".env"
    if envf.exists():
        env = dict(line.split("=", 1) for line in envf.read_text().splitlines() if "=" in line)
        try:
            from tools.pgflagsmith.sync import fetch_document
            real = fetch_document(env["FLAGSMITH_API_URL"], env["PROD_SERVER_KEY"], timeout=5)
        except Exception:  # noqa: BLE001
            real = None
    with psycopg.connect(BENCH_DSN, autocommit=True) as conn:
        conn.execute("SET jit = off")
        r["mapper"] = (json.loads(pathlib.Path(a.mapper_results).read_text()) if a.mapper_results
                       else bench_mapper(conn, real))
        (ROOT / "bench" / "stretch_mapper.json").write_text(json.dumps(r["mapper"], indent=2))
        env_key = conn.execute("SELECT env_key FROM flagsmith.environments() WHERE is_default").fetchone()[0]
        if not a.skip_queue:
            r["queue"] = bench_queue(conn, env_key)
    r["in_db_sync"] = bench_in_db_sync()
    (ROOT / "bench" / "stretch_results.json").write_text(json.dumps(r, indent=2, default=str))
    if "queue" in r:
        (ROOT / "bench" / "STRETCH.md").write_text(render(r) + "\n")
    print(render(r) if "queue" in r else json.dumps(r, indent=2, default=str))


if __name__ == "__main__":
    main()
