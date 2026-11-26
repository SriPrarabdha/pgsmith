"""Simulated traffic for Demo 2 (the numbers are simulated, and say so).

Each simulated user searches; Postgres picks the arm with flagsmith.variant() and
ranks with that arm's formula in the same query; the application then records the
exposure with the official SDK (track_exposure_event, value = the arm Postgres
chose) and sends search_result_clicked / add_to_cart / search_latency_ms with
track_event. A click model with position bias makes popular items more clickable,
so the sales-boosted ranking has a modest real advantage to find.

    python demos/search_ab/simulate.py --users 3000
    python demos/search_ab/simulate.py --users 3000 --via-queue   # record in SQL (flagsmith.track_*),
                                                                  # delivered by the database or pg-flagsmith events
"""
from __future__ import annotations

import argparse
import math
import os
import random
import time

import psycopg
from flagsmith import Flagsmith
from flagsmith.analytics import EventProcessorConfig
from psycopg.types.json import Jsonb

QUERIES = ["wireless headphones", "organic mug", "smart watch", "portable speaker", "leather backpack", "camera",
           "eco bottle", "retro lamp", "steel kettle", "mini drone", "pro keyboard", "solar charger", "cotton jacket",
           "ceramic mug", "bamboo notebook", "vintage guitar", "compact tent", "silk sofa", "premium sneakers",
           "ultra helmet", "classic watch", "travel backpack", "kitchen blender", "outdoor tent", "music speaker"]


def attractiveness(sales: int) -> float:
    return 0.04 + 0.16 * min(1.0, math.log1p(sales) / math.log1p(1800))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", default=os.environ.get("PGFS_DSN"))
    ap.add_argument("--users", type=int, default=3000)
    ap.add_argument("--searches-per-user", type=int, default=3)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--events-url", default=os.environ.get("FLAGSMITH_EVENTS_URL", "http://localhost:8000/api/"))
    ap.add_argument("--server-key", default=os.environ.get("PROD_SERVER_KEY"))
    ap.add_argument("--api", default=os.environ.get("FLAGSMITH_API_URL"))
    ap.add_argument("--via-queue", action="store_true",
                    help="record exposures and events with flagsmith.track_exposure/track_event (the exposure "
                         "queue) instead of the SDK")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    client = None if a.via_queue else Flagsmith(
        environment_key=a.server_key, api_url=a.api, enable_events=True,
        event_processor_config=EventProcessorConfig(events_api_url=a.events_url, flush_interval_seconds=2))
    with psycopg.connect(a.dsn, autocommit=True) as conn:
        def exposure(ident, arm, meta):
            if client:
                client.track_exposure_event(feature_name="search_ranking", identifier=ident, value=arm, metadata=meta)
            else:
                conn.execute("SELECT flagsmith.track_exposure('search_ranking', %s, %s, metadata => %s)",
                             (ident, arm, Jsonb(meta)))

        def event(name, ident, value):
            if client:
                client.track_event(name, identifier=ident, value=value)
            else:   # sent as text, as the SDK sends str(value)
                conn.execute("SELECT flagsmith.track_event(%s, %s, %s)", (name, ident, str(value)))

        users = conn.execute("SELECT identifier, traits FROM app.users ORDER BY md5(identifier || %s) LIMIT %s",
                             (str(a.seed), a.users)).fetchall()
        exp_id = conn.execute(
            "SELECT (f.metadata -> 'experiment' ->> 'id')::int FROM flagsmith.flags('x', '{}') f WHERE f.feature = 'search_ranking'"
        ).fetchone()[0]
        sales = dict(conn.execute("SELECT id, sales_30d FROM shop.products").fetchall())
        counts = {"searches": 0, "clicks": 0, "carts": 0}
        t0 = time.perf_counter()
        for i, (ident, traits) in enumerate(users):
            exposed = False
            for _ in range(a.searches_per_user):
                q = rng.choice(QUERIES)
                ts = time.perf_counter()
                rows = conn.execute("SELECT product_id, arm FROM shop.search(%s, %s::jsonb, %s, 20)",
                                    (ident, psycopg.types.json.Jsonb(traits), q)).fetchall()
                latency_ms = (time.perf_counter() - ts) * 1000
                if not rows:
                    continue
                arm = rows[0][1]
                counts["searches"] += 1
                if not exposed:
                    exposure(ident, arm, {"experiment_id": exp_id})
                    conn.execute("INSERT INTO shop.events (identifier, event, arm, query) VALUES (%s, '$flag_exposure', %s, %s)",
                                 (ident, arm, q))
                    exposed = True
                event("search_latency_ms", ident, round(latency_ms, 3))
                conn.execute("INSERT INTO shop.events (identifier, event, arm, value) VALUES (%s, 'search_latency_ms', %s, %s)",
                             (ident, arm, latency_ms))
                # click model: position bias times item attractiveness, first click wins
                for pos, (pid, _) in enumerate(rows[:10]):
                    if rng.random() < attractiveness(sales[pid]) / (pos + 1) ** 0.8:
                        counts["clicks"] += 1
                        event("search_result_clicked", ident, pos + 1)
                        conn.execute("INSERT INTO shop.events (identifier, event, arm, value, query) "
                                     "VALUES (%s, 'search_result_clicked', %s, %s, %s)", (ident, arm, pos + 1, q))
                        if rng.random() < 0.15 + 0.5 * attractiveness(sales[pid]):
                            counts["carts"] += 1
                            event("add_to_cart", ident, pid)
                            conn.execute("INSERT INTO shop.events (identifier, event, arm, value) VALUES (%s, 'add_to_cart', %s, %s)",
                                         (ident, arm, pid))
                        break
            if (i + 1) % 500 == 0:
                print(f"  {i + 1} users, {counts['searches']} searches, {counts['clicks']} clicks, "
                      f"{counts['carts']} add-to-carts ({time.perf_counter() - t0:.0f}s)", flush=True)
        if client:
            client.flush_events()
            client.close()
        else:
            queued = conn.execute("SELECT coalesce(sum(queued), 0) FROM flagsmith.event_status()").fetchone()[0]
            print(f"{queued} events queued: delivered by flagsmith.events_tick() (schedule_events) or "
                  "`pg-flagsmith events --once`")
    print(f"simulated {len(users)} users: {counts}  (SIMULATED TRAFFIC)")


if __name__ == "__main__":
    main()
