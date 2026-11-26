"""pgsmith: keep Postgres in sync with Flagsmith and prove they agree.

  pgsmith sync    --once | --poll SECONDS      mirror environments into Postgres
  pgsmith serve   [--port 8080] [--poll 30]    webhook receiver + polling backstop
  pgsmith events  --once | --poll SECONDS      deliver queued exposures/events to Flagsmith
  pgsmith parity  --population SQL [--sample N] live check against the official SDK
  pgsmith install [--tle]                      install the extension into a database
  pgsmith health                               flagsmith.health() as a table

Configuration comes from flags or the environment: PGSMITH_DSN, FLAGSMITH_API_URL,
FLAGSMITH_SERVER_KEYS (comma-separated server-side environment keys),
FLAGSMITH_WEBHOOK_SECRET, FLAGSMITH_EVENTS_URL.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import pathlib
import sys
import time


def _common(ap: argparse.ArgumentParser) -> None:
    ap.add_argument("--dsn", default=os.environ.get("PGSMITH_DSN"), help="Postgres connection string (PGSMITH_DSN)")
    ap.add_argument("--api", default=os.environ.get("FLAGSMITH_API_URL", "https://edge.api.flagsmith.com/api/v1/"),
                    help="Flagsmith API URL (FLAGSMITH_API_URL)")
    ap.add_argument("--server-key", action="append", default=None,
                    help="server-side environment key; repeatable (FLAGSMITH_SERVER_KEYS)")


def _keys(a) -> list[str]:
    keys = a.server_key or [k for k in os.environ.get("FLAGSMITH_SERVER_KEYS", "").split(",") if k]
    if not keys:
        sys.exit("no server-side keys: pass --server-key or set FLAGSMITH_SERVER_KEYS")
    return keys


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="pgsmith", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-v", "--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sync", help="mirror environments into Postgres")
    _common(s)
    g = s.add_mutually_exclusive_group()
    g.add_argument("--once", action="store_true", default=True)
    g.add_argument("--poll", type=float, metavar="SECONDS")

    s = sub.add_parser("serve", help="webhook receiver with a polling backstop")
    _common(s)
    s.add_argument("--host", default=os.environ.get("HOST", "127.0.0.1"),
                   help="address to listen on (0.0.0.0 in a container)")
    s.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8080")))
    s.add_argument("--poll", type=float, default=30)
    s.add_argument("--webhook-secret", default=os.environ.get("FLAGSMITH_WEBHOOK_SECRET", ""))
    s.add_argument("--allow-unsigned-webhooks", action="store_true",
                   help="accept webhook calls without a signature (they only trigger a sync)")

    s = sub.add_parser("events", help="deliver queued exposures and events to Flagsmith")
    _common(s)
    g = s.add_mutually_exclusive_group()
    g.add_argument("--once", action="store_true", default=True)
    g.add_argument("--poll", type=float, metavar="SECONDS")
    s.add_argument("--events-url", default=os.environ.get("FLAGSMITH_EVENTS_URL"),
                   help="events endpoint (default: <api>/events, or events.api.flagsmith.com for Flagsmith SaaS)")
    s.add_argument("--batch-size", type=int, default=1000)

    s = sub.add_parser("parity", help="compare pgsmith with the official SDK on real identities")
    _common(s)
    s.add_argument("--population", required=True,
                   help="SQL returning (identifier, traits jsonb), e.g. 'SELECT id::text, traits FROM app.users'")
    s.add_argument("--sample", type=int, default=1000)
    s.add_argument("--json", action="store_true", help="print the full result as JSON")

    s = sub.add_parser("install", help="install pgsmith into a database")
    s.add_argument("--dsn", default=os.environ.get("PGSMITH_DSN"))
    s.add_argument("--tle", action="store_true", help="install as a Trusted Language Extension (Supabase, RDS)")

    s = sub.add_parser("health", help="print flagsmith.health()")
    s.add_argument("--dsn", default=os.environ.get("PGSMITH_DSN"))

    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    if not getattr(a, "dsn", None):
        sys.exit("no database: pass --dsn or set PGSMITH_DSN")

    if a.cmd == "sync":
        from .sync import Syncer
        syncer = Syncer(a.dsn, a.api, _keys(a))
        while True:
            res = syncer.sync_all()
            print(json.dumps(res))
            if not a.poll:
                return 0 if all("error" not in r for r in res) else 1
            time.sleep(a.poll)
    if a.cmd == "serve":
        from .sync import Syncer, serve
        serve(Syncer(a.dsn, a.api, _keys(a)), a.port, a.poll, a.webhook_secret, host=a.host,
              allow_unsigned=a.allow_unsigned_webhooks)
        return 0
    if a.cmd == "events":
        from . import events
        return events.run(a.dsn, a.api, _keys(a), a.poll, events_url=a.events_url, batch_size=a.batch_size)
    if a.cmd == "parity":
        from . import parity
        rc = 0
        for key in _keys(a):
            res = parity.run(a.dsn, a.api, key, a.population, a.sample)
            print(res.summary())
            for m in res.mismatches[:20]:
                print("  ", json.dumps(m, default=str))
            if a.json:
                print(json.dumps(res.__dict__, default=str))
            rc = rc or (1 if res.mismatches else 0)
        return rc
    if a.cmd == "install":
        return _install(a.dsn, a.tle)
    if a.cmd == "health":
        import psycopg
        with psycopg.connect(a.dsn) as c:
            cur = c.execute("SELECT * FROM flagsmith.health()")
            cols = [d.name for d in cur.description]
            for row in cur.fetchall():
                print(json.dumps(dict(zip(cols, row)), default=str))
        return 0
    return 2


def _install(dsn: str, tle: bool) -> int:
    import psycopg
    dist = pathlib.Path(__file__).resolve().parents[2] / "extension" / "dist"
    files = sorted(dist.glob("pgsmith--*.pgtle.sql" if tle else "pgsmith--*.sql"))
    files = [f for f in files if tle or not f.name.endswith(".pgtle.sql")]
    if not files:
        sys.exit("build the extension first: python extension/build.py")
    with psycopg.connect(dsn, autocommit=True) as c:
        if tle:
            c.execute(files[-1].read_text())
        else:
            avail = c.execute("SELECT count(*) FROM pg_available_extensions WHERE name = 'pgsmith'").fetchone()[0]
            if not avail:
                sys.exit("pgsmith is not installed on the server: run `make install` there, or use --tle")
            c.execute("CREATE EXTENSION IF NOT EXISTS pgsmith")
        print(c.execute("SELECT extversion FROM pg_extension WHERE extname = 'pgsmith'").fetchone()[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
