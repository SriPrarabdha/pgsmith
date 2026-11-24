"""pg_flagsmith benchmarks on the Edge Proxy profile (bench/profile.py).

    bench/run.sh            # starts a dedicated Postgres container and runs this
    PGFS_BENCH_DSN=... python bench/run.py [--users 1000000]

Writes bench/RESULTS.md and bench/results.json. Publishes what it measures;
no targets are set in advance.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import platform
import random
import statistics
import sys
import time
import warnings

import psycopg
from psycopg.types.json import Jsonb

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import profile as prof  # noqa: E402


def server_ms(cur, q, params=None) -> tuple[float, float, list[str]]:
    rows = [r[0] for r in cur.execute("EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON) " + q, params).fetchall()]
    ex = float([r for r in rows if r.startswith("Execution Time")][0].split()[2])
    pl = float([r for r in rows if r.startswith("Planning Time")][0].split()[2])
    return ex, pl, rows


def lookups(conn, q, users, n=2000, warm=200) -> dict:
    lat = []
    with conn.cursor() as cur:
        for i in range(n + warm):
            ident, traits = users[i % len(users)]
            t = time.perf_counter_ns()
            cur.execute(q, (ident, Jsonb(traits)), prepare=True)
            cur.fetchall()
            if i >= warm:
                lat.append((time.perf_counter_ns() - t) / 1000)
    lat.sort()
    return {"p50_us": round(lat[len(lat) // 2], 1), "p99_us": round(lat[int(len(lat) * 0.99)], 1),
            "mean_us": round(statistics.fmean(lat), 1), "n": n}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=os.environ.get("PGFS_BENCH_DSN", "postgresql://postgres:pgfs@127.0.0.1:55499/pgfs"))
    ap.add_argument("--users", type=int, default=1_000_000)
    a = ap.parse_args()
    res: dict = {"profile": {"features": prof.N_FEATURES, "segments": prof.N_SEGMENTS,
                             "overrides": prof.N_FEATURES * prof.N_SEGMENTS, "conditions_per_segment": 15,
                             "users": a.users}}
    conn = psycopg.connect(a.dsn, autocommit=True)
    cur = conn.cursor()
    res["env"] = {"postgres": cur.execute("SELECT version()").fetchone()[0].split(",")[0],
                  "cpu": _cpu(), "cores": os.cpu_count(), "python": platform.python_version(),
                  "settings": dict(cur.execute("""SELECT name, setting FROM pg_settings WHERE name IN
                      ('shared_buffers','max_parallel_workers_per_gather','max_parallel_workers','jit','work_mem')""").fetchall())}

    # JIT compiling the generated expression trees costs ~1.8 s per query on this profile
    # and saves nothing (measured below), so measurements run with jit = off
    cur.execute("SET jit = off")

    # load and compile
    ctx = prof.build()
    t = time.perf_counter()
    sid = cur.execute("SELECT flagsmith.load_context(%s::json, source => 'bench')", (json.dumps(ctx),)).fetchone()[0]
    res["load"] = {"wall_ms": round((time.perf_counter() - t) * 1000, 1)}
    r = cur.execute("SELECT load_ms, compiled, compile_ms, compile_bytes FROM flagsmith.snapshot WHERE snapshot_id = %s",
                    (sid,)).fetchone()
    res["load"].update({"normalise_ms": float(r[0]), "compiled": r[1], "compile_ms": float(r[2]), "generated_bytes": r[3]})
    print("load", res["load"], flush=True)

    n_existing = cur.execute("SELECT count(*) FROM pg_tables WHERE tablename = 'bench_users'").fetchone()[0]
    if not n_existing or cur.execute("SELECT count(*) FROM bench_users").fetchone()[0] != a.users:
        cur.execute(prof.USERS_SQL.replace("@@N@@", str(a.users)))
    cur.execute("DROP TABLE IF EXISTS bench_users_20k; CREATE TABLE bench_users_20k AS SELECT * FROM bench_users ORDER BY md5(identifier) LIMIT 20000; ANALYZE bench_users_20k")
    users = cur.execute("SELECT identifier, traits FROM bench_users_20k LIMIT 5000").fetchall()
    random.Random(1).shuffle(users)

    # point lookups (client-side, localhost, prepared statements)
    res["point_lookup"] = {
        "interpreter, all 50 flags": lookups(conn, "SELECT * FROM flagsmith.get_flags(%s, %s)", users, n=1000),
        "compiled flags(), all 50 flags": lookups(conn, "SELECT * FROM flagsmith.flags(%s, %s)", users),
        "compiled flag(), one flag": lookups(conn, "SELECT * FROM flagsmith.flag('feature_07', %s, %s)", users),
        "variant() helper, one MV flag": lookups(conn, "SELECT flagsmith.variant('feature_05', %s, %s)", users),
        "baseline: SELECT 1 round trip": lookups(conn, "SELECT %s::text, %s::jsonb", users),
    }
    for k, v in res["point_lookup"].items():
        print(f"{k:34s} {v}", flush=True)

    # batch throughput (server-side)
    batch = {}
    cur.execute("SET parallel_setup_cost = 10; SET parallel_tuple_cost = 0.01")
    for label, workers, q in [
        ("all 50 flags, serial", 0, "SELECT count(*) FILTER (WHERE f.enabled) FROM bench_users u, LATERAL flagsmith.flags(u.identifier, u.traits) f"),
        ("all 50 flags, parallel", 8, "SELECT count(*) FILTER (WHERE f.enabled) FROM bench_users u, LATERAL flagsmith.flags(u.identifier, u.traits) f"),
        ("one flag via flags() WHERE feature, parallel", 8, "SELECT count(*) FILTER (WHERE f.enabled) FROM bench_users u, LATERAL flagsmith.flags(u.identifier, u.traits) f WHERE f.feature = 'feature_07'"),
        ("one flag via flag(), serial", 0, "SELECT count(*) FILTER (WHERE f.enabled) FROM bench_users u, LATERAL flagsmith.flag('feature_07', u.identifier, u.traits) f"),
    ]:
        cur.execute(f"SET max_parallel_workers_per_gather = {workers}")
        ex, pl, rows = server_ms(cur, q)
        launched = [r for r in rows if "Workers Launched" in r]
        flags = a.users * (50 if "all 50" in label else 1)
        batch[label] = {"seconds": round(ex / 1000, 2), "planning_ms": pl, "identities_per_s": round(a.users / ex * 1000),
                        "flag_evaluations_per_s": round(flags / ex * 1000),
                        "workers": int(launched[0].split()[-1]) if launched else 0}
        print(label, batch[label], flush=True)
    cur.execute("SET max_parallel_workers_per_gather = 0")
    ex, pl, _ = server_ms(cur, "SELECT count(*) FROM bench_users_20k u, LATERAL flagsmith.get_flags(u.identifier, u.traits) f")
    batch["interpreter, all 50 flags, serial (20k users)"] = {"seconds": round(ex / 1000, 2), "identities_per_s": round(20000 / ex * 1000),
                                                              "flag_evaluations_per_s": round(20000 * 50 / ex * 1000)}
    cur.execute("ALTER TABLE bench_users SET (parallel_workers = 8); SET max_parallel_workers_per_gather = 8")
    ex, pl, rows = server_ms(cur, "SELECT count(*) FILTER (WHERE f.enabled) FROM bench_users u, LATERAL flagsmith.flags(u.identifier, u.traits) f")
    launched = [r for r in rows if "Workers Launched" in r]
    batch["all 50 flags, parallel_workers = 8"] = {"seconds": round(ex / 1000, 2), "planning_ms": pl,
        "identities_per_s": round(a.users / ex * 1000), "flag_evaluations_per_s": round(a.users * 50 / ex * 1000),
        "workers": int(launched[0].split()[-1]) if launched else 0}
    print("8 workers", batch["all 50 flags, parallel_workers = 8"], flush=True)
    cur.execute("ALTER TABLE bench_users RESET (parallel_workers); SET max_parallel_workers_per_gather = 0")
    res["batch"] = batch

    # JIT on vs off (1M users, all flags, serial)
    jit = {}
    cur.execute("DROP TABLE IF EXISTS bench_users_200k; CREATE TABLE bench_users_200k AS SELECT * FROM bench_users LIMIT 200000; ANALYZE bench_users_200k")
    for setting in ["off", "on (Postgres defaults)", "on (forced: jit_above_cost = 0)"]:
        cur.execute("RESET jit_above_cost; RESET jit_inline_above_cost; RESET jit_optimize_above_cost")
        cur.execute("SET jit = " + ("off" if setting == "off" else "on"))
        if "forced" in setting:
            cur.execute("SET jit_above_cost = 0; SET jit_inline_above_cost = 0; SET jit_optimize_above_cost = 0")
        ex, _, rows = server_ms(cur, "SELECT count(*) FILTER (WHERE f.enabled) FROM bench_users_200k u, LATERAL flagsmith.flags(u.identifier, u.traits) f")
        jit[setting] = {"seconds_200k_users": round(ex / 1000, 2)}
    cur.execute("SET jit = off; RESET jit_above_cost; RESET jit_inline_above_cost; RESET jit_optimize_above_cost")
    res["jit"] = jit
    print("jit", jit, flush=True)

    # planner checks (the acceptance checks of PLAN.md)
    checks = {}
    plan = "\n".join(r[0] for r in cur.execute("EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM bench_users u, LATERAL flagsmith.flags(u.identifier, u.traits) f").fetchall())
    checks["inlined: no Function Scan of the compiled function"] = "Function Scan on flags_s" not in plan and "flagsmith_c.flags_s" not in plan
    plan = "\n".join(r[0] for r in cur.execute("EXPLAIN (COSTS OFF) SELECT * FROM flagsmith.flag('feature_07', 'u1', '{}')").fetchall())
    checks["arm pruning: a one-feature query keeps 1 of 50 arms"] = plan.count("Subquery Scan on x") == 1
    plan = "\n".join(r[0] for r in cur.execute(
        "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) WITH v AS MATERIALIZED (SELECT flagsmith.variant('feature_05', 'user1', '{}') AS arm) "
        "SELECT count(*) FROM bench_users_20k b, v WHERE v.arm IS NOT NULL").fetchall())
    checks["evaluate once per request: the variant is computed once, not per row"] = "CTE Scan on v (actual rows=1 loops=1)" in plan
    cur.execute("SET max_parallel_workers_per_gather = 8")
    plan = "\n".join(r[0] for r in cur.execute("EXPLAIN (COSTS OFF) SELECT count(*) FROM bench_users u, LATERAL flagsmith.flags(u.identifier, u.traits) f").fetchall())
    checks["parallel: a 1M-row scan runs under Gather with workers"] = "Gather" in plan and "Workers Planned" in plan
    res["planner_checks"] = checks
    print("checks", checks, flush=True)

    # constant IN lists are hashed (PG 14+): cost must not grow with list length
    hashed = {}
    for n_ids in [10, 10_000]:
        c2 = json.loads(json.dumps(ctx))
        c2["environment"]["key"] = f"bench_in_{n_ids}"
        c2["segments"]["900"] = {"key": "900", "name": "allowlist", "rules": [{"type": "ALL", "conditions": [
            {"operator": "IN", "property": "email", "value": ",".join(f"x{i}@corp.com" for i in range(n_ids))}]}],
            "overrides": [{"key": "9", "name": "feature_01", "enabled": True, "value": "allow", "priority": -1}]}
        s2 = cur.execute("SELECT flagsmith.load_context(%s::json, source => 'bench', kind => 'candidate', compile => true)",
                         (json.dumps(c2),)).fetchone()[0]
        cur.execute("SET max_parallel_workers_per_gather = 0")
        ex, _, _ = server_ms(cur, f"SELECT count(*) FROM bench_users_20k u, LATERAL flagsmith_c.flag_s{s2}('feature_01', u.identifier, u.traits) f")
        hashed[f"IN list of {n_ids:,}"] = {"us_per_identity": round(ex * 1000 / 20000, 2)}
    res["hashed_in_lists"] = hashed
    print("hashed IN", hashed, flush=True)

    # the official Python engine on the same data (single core)
    from flag_engine.engine import get_evaluation_result
    warnings.simplefilter("ignore")
    t = time.perf_counter()
    for ident, traits in users[:3000]:
        get_evaluation_result({**ctx, "identity": {"identifier": ident, "traits": traits}})
    el = time.perf_counter() - t
    res["python_engine"] = {"us_per_identity_all_flags": round(el / 3000 * 1e6, 1), "identities_per_s": round(3000 / el)}
    print("python", res["python_engine"], flush=True)

    # spot parity on the benchmark data
    bad = 0
    for ident, traits in users[:500]:
        want = get_evaluation_result({**ctx, "identity": {"identifier": ident, "traits": traits}})["flags"]
        got = {r[0]: r for r in cur.execute("SELECT * FROM flagsmith.flags(%s, %s)", (ident, Jsonb(traits))).fetchall()}
        bad += sum((f["enabled"], f["value"], f["variant"], f["reason"]) != got[n][1:5] for n, f in want.items())
    res["parity_spot_check"] = {"identities": 500, "flags": 500 * 50, "mismatches": bad}

    (HERE / "results.json").write_text(json.dumps(res, indent=2))
    (HERE / "RESULTS.md").write_text(render(res))
    print(render(res))


def _cpu() -> str:
    try:
        for line in open("/proc/cpuinfo"):
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor()


def render(r: dict) -> str:
    p, e = r["profile"], r["env"]
    out = [
        "# pg_flagsmith benchmark results", "",
        f"Profile: Flagsmith's Edge Proxy benchmark shape: {p['features']} features, {p['segments']} segments, "
        f"{p['overrides']} overrides (every feature overridden by every segment), {p['conditions_per_segment']} "
        f"conditions per segment, {p['users']:,} synthetic users. Generated by `bench/profile.py` (seeded).", "",
        f"Machine: {e['cpu']}, {e['cores']} cores; {e['postgres']} in Docker; settings {e['settings']}.", "",
        "## Load", "",
        f"Normalise {r['load']['normalise_ms']} ms, compile {r['load']['compile_ms']} ms "
        f"({r['load']['generated_bytes']:,} bytes of generated SQL); whole load_context() call {r['load']['wall_ms']} ms.", "",
        "## Point lookups (client round trip on localhost, prepared statements)", "",
        "| Call | p50 | p99 | mean |", "|---|---:|---:|---:|"]
    for k, v in r["point_lookup"].items():
        out.append(f"| {k} | {v['p50_us']} µs | {v['p99_us']} µs | {v['mean_us']} µs |")
    out += ["", f"## Batch throughput ({p['users']:,} users, server time)", "",
            "| Query | Workers | Time | Identities/s | Flag evaluations/s | Planning |", "|---|---:|---:|---:|---:|---:|"]
    for k, v in r["batch"].items():
        out.append(f"| {k} | {v.get('workers', 0)} | {v['seconds']} s | {v['identities_per_s']:,} | "
                   f"{v.get('flag_evaluations_per_s', 0):,} | {v.get('planning_ms', '')} ms |")
    pe = r["python_engine"]
    out += ["", "## Baseline: the official Python engine (flagsmith-flag-engine 11.1.2, one core)", "",
            f"{pe['us_per_identity_all_flags']} µs per identity for all 50 flags ({pe['identities_per_s']:,} identities/s).", "",
            "## JIT (200k users, all 50 flags, serial)", "",
            *[f"- jit {k}: {v['seconds_200k_users']} s" for k, v in r['jit'].items()], "",
            "Postgres's default `jit_above_cost` triggers on population scans, and compiling the generated expression "
            "trees costs about two seconds per query while saving nothing, so turn JIT off for sessions that evaluate "
            "flags over many rows (`SET jit = off`, or `ALTER ROLE ... SET jit = off`). All other numbers here are with "
            "jit = off; FlagShift's functions set it themselves.", "",
            "## Constant IN lists are hashed (Postgres 14+)", ""]
    for k, v in r["hashed_in_lists"].items():
        out.append(f"- {k}: {v['us_per_identity']} µs per identity")
    out += ["", "Point lookups pay executor start-up for the whole inlined plan on every execution (thousands of "
                "expression nodes on this profile, where every feature is overridden by every segment); the evaluation "
                "itself is a small part. flag() prunes to one feature and costs less.", "",
            "## Planner acceptance checks (PLAN.md)", ""]
    for k, v in r["planner_checks"].items():
        out.append(f"- [{'x' if v else ' '}] {k}")
    sc = r["parity_spot_check"]
    out += ["", f"Parity spot check on this data: {sc['identities']} identities × 50 flags against the Python engine: "
                f"{sc['mismatches']} mismatches.", "", "Reproduce: `bench/run.sh`."]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
