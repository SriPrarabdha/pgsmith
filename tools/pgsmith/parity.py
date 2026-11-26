"""Live parity check: the official SDK in local-evaluation mode against
pgsmith, for real identities from your database.

Both sides read the same environment document: the SDK fetches it itself, and
pgsmith is synced from it first (same `updated_at`). Every flag of every
sampled identity is compared on enabled, value, variant and reason, through
both the interpreter (get_flags) and the published compiled function.
"""
from __future__ import annotations

import json
import random
import time
from dataclasses import dataclass

import psycopg
from flagsmith import Flagsmith
from psycopg import sql

from .sync import fetch_document, load_document


@dataclass
class ParityResult:
    environment: str
    snapshot_id: int
    identities: int
    flags_compared: int
    mismatches: list[dict]
    seconds: float

    def summary(self) -> str:
        status = "OK" if not self.mismatches else f"{len(self.mismatches)} MISMATCHES"
        return (f"parity {status}: {self.identities} identities x flags = {self.flags_compared} comparisons "
                f"(environment {self.environment}, snapshot {self.snapshot_id}, {self.seconds:.1f}s)")


def _sdk_client(api_url: str, server_key: str, updated_at: str) -> Flagsmith:
    """The official SDK in local-evaluation mode, holding the same document version."""
    for _ in range(10):
        client = Flagsmith(environment_key=server_key, api_url=api_url, enable_local_evaluation=True,
                           environment_refresh_interval_seconds=3600, enable_analytics=False)
        if client._environment_updated_at and client._environment_updated_at.isoformat().startswith(updated_at[:19]):
            return client
        client.close()
        time.sleep(1)
    raise RuntimeError("the SDK and pgsmith did not see the same environment document version")


def _sdk_flags(client: Flagsmith, features: list[str], identifier: str, traits: dict) -> dict:
    """What an application gets: get_identity_flags() then get_flag() per feature."""
    flags = client.get_identity_flags(identifier, traits)
    out = {}
    for name in features:
        f = flags.get_flag(name)
        out[name] = {"enabled": f.enabled, "value": f.value, "variant": getattr(f, "variant", None),
                     "reason": getattr(f, "reason", None)}
    return out


def run(dsn: str, api_url: str, server_key: str, population_sql: str, sample: int = 1000,
        seed: int = 0, record: bool = True) -> ParityResult:
    t0 = time.perf_counter()
    doc = fetch_document(api_url, server_key)
    client = _sdk_client(api_url, server_key, str(doc.get("updated_at") or ""))
    features = [fs["feature"]["name"] for fs in doc["feature_states"]]
    with psycopg.connect(dsn, autocommit=True) as conn:
        sid, _ = load_document(conn, doc, source="parity")
        env_key = doc["api_key"]
        alias = conn.execute("SELECT alias FROM flagsmith.environments() WHERE env_key = %s", (env_key,)).fetchone()[0]
        # the population query is the operator's own SQL: run it read-only
        with conn.transaction():
            conn.execute("SET TRANSACTION READ ONLY")
            rows = conn.execute(sql.SQL("SELECT identifier::text, traits::jsonb FROM ({}) p").format(
                sql.SQL(population_sql))).fetchall()
        rng = random.Random(seed)
        if len(rows) > sample:
            rows = rng.sample(rows, sample)
        mismatches: list[dict] = []
        compared = 0
        q_interp = "SELECT feature, enabled, value, variant, reason FROM flagsmith.get_flags(%s, %s, snapshot_id => %s)"
        q_comp = sql.SQL("SELECT feature, enabled, value, variant, reason FROM flagsmith_c.{}(%s, %s)").format(
            sql.Identifier(f"flags_{alias}"))
        for identifier, traits in rows:
            traits = traits or {}
            want = _sdk_flags(client, features, identifier, traits)
            for tier, q, args in (("interpreter", q_interp, (identifier, json.dumps(traits), sid)),
                                  ("compiled", q_comp, (identifier, json.dumps(traits)))):
                got = {r[0]: r for r in conn.execute(q, args).fetchall()}
                for name, f in want.items():
                    compared += 1
                    g = got.get(name)
                    exp = (f["enabled"], f["value"], f.get("variant"), f["reason"])
                    act = (g[1], g[2], g[3], g[4]) if g else None
                    if act != exp:
                        mismatches.append({"tier": tier, "identifier": identifier, "feature": name,
                                           "expected": exp, "actual": act})
        client.close()
        res = ParityResult(env_key, sid, len(rows), compared, mismatches, time.perf_counter() - t0)
        if record:
            conn.execute("SELECT flagsmith.record_parity(%s, %s, 'sdk', %s, %s, %s, %s::jsonb)",
                         (env_key, sid, res.identities, res.flags_compared, len(mismatches),
                          json.dumps(mismatches[:100], default=str)))
    return res
