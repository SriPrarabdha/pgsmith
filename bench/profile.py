"""The benchmark profile Flagsmith uses for its Edge Proxy: 50 features, 15
segments, every feature overridden by every segment (750 overrides), each
segment matching on 15 trait conditions. Deterministic (seeded).

    python bench/profile.py > bench/profile_context.json
"""
from __future__ import annotations

import json
import random

ENV_KEY = "bench_env_9fKx2"
N_FEATURES = 50
N_SEGMENTS = 15
PLANS = ["free", "pro", "team", "enterprise"]
COUNTRIES = ["IN", "US", "GB", "DE", "FR", "BR", "JP", "SG", "AU", "CA"]
DEVICES = ["ios", "android", "web"]


def conditions(rng: random.Random, i: int) -> list[dict]:
    """15 conditions in three ANY groups of five: a broad mix of operators."""
    pool = [
        {"operator": "EQUAL", "property": "plan", "value": rng.choice(PLANS)},
        {"operator": "GREATER_THAN", "property": "age", "value": str(rng.randint(18, 60))},
        {"operator": "IN", "property": "country", "value": ",".join(rng.sample(COUNTRIES, 3))},
        {"operator": "CONTAINS", "property": "email", "value": rng.choice(["@gmail", "@corp", ".io", "a"])},
        {"operator": "PERCENTAGE_SPLIT", "property": "", "value": str(rng.choice([5, 10, 25, 50]))},
        {"operator": "IS_SET", "property": "beta", "value": ""},
        {"operator": "REGEX", "property": "email", "value": rng.choice([r"^[a-m].*", r".*@corp\.com$", r"\d"])},
        {"operator": "GREATER_THAN_INCLUSIVE", "property": "version", "value": rng.choice(["2.1.0:semver", "3.0.0:semver"])},
        {"operator": "LESS_THAN", "property": "score", "value": str(round(rng.uniform(0.1, 0.9), 2))},
        {"operator": "NOT_EQUAL", "property": "device", "value": rng.choice(DEVICES)},
        {"operator": "MODULO", "property": "signup_days", "value": f"{rng.randint(3, 9)}|0"},
        {"operator": "EQUAL", "property": "beta", "value": "true"},
        {"operator": "LESS_THAN_INCLUSIVE", "property": "signup_days", "value": str(rng.randint(10, 300))},
        {"operator": "NOT_CONTAINS", "property": "locale", "value": rng.choice(["en", "de", "pt"])},
        {"operator": "IN", "property": "$.identity.identifier", "value": ",".join(f"user{rng.randint(0, 999999)}" for _ in range(20))},
    ]
    rng.shuffle(pool)
    return pool


def build() -> dict:
    rng = random.Random(42)
    features = {}
    for f in range(N_FEATURES):
        name = f"feature_{f:02d}"
        fc = {"key": str(10000 + f), "name": name, "enabled": rng.random() < 0.5,
              "value": rng.choice(["off", "", None, 1, "v1"]), "metadata": {"id": 500 + f}}
        if f % 5 == 0:
            fc["variants"] = [
                {"value": "a", "weight": 30, "priority": 1, "key": "a"},
                {"value": "b", "weight": 30, "priority": 2, "key": "b"},
            ]
        features[name] = fc
    segments = {}
    for s in range(N_SEGMENTS):
        conds = conditions(rng, s)
        segments[str(100 + s)] = {
            "key": str(100 + s),
            "name": f"segment_{s:02d}",
            "rules": [{"type": "ALL", "conditions": [], "rules": [
                {"type": "ANY", "conditions": conds[0:5]},
                {"type": "ANY", "conditions": conds[5:10]},
                {"type": "ANY", "conditions": conds[10:15]},
            ]}],
            "overrides": [
                {"key": str(20000 + s * 100 + f), "name": f"feature_{f:02d}", "enabled": rng.random() < 0.5,
                 "value": f"seg{s}", "priority": s, "metadata": {"id": 500 + f}}
                for f in range(N_FEATURES)
            ],
            "metadata": {"id": 100 + s, "source": "api"},
        }
    return {"environment": {"key": ENV_KEY, "name": "Benchmark"}, "features": features, "segments": segments}


# Users are generated in SQL (bench/users.sql) with the same trait shapes.
USERS_SQL = """
DROP TABLE IF EXISTS bench_users;
CREATE TABLE bench_users AS
SELECT 'user' || g AS identifier,
       jsonb_build_object(
         'plan', (ARRAY['free','pro','team','enterprise'])[1 + (hashint4(g) & 3)],
         'age', 16 + abs(hashint4(g + 1)) % 60,
         'country', (ARRAY['IN','US','GB','DE','FR','BR','JP','SG','AU','CA'])[1 + abs(hashint4(g + 2)) % 10],
         'email', chr(97 + abs(hashint4(g + 3)) % 26) || g || (ARRAY['@gmail.com','@corp.com','@mail.io'])[1 + abs(hashint4(g + 4)) % 3],
         'version', (1 + abs(hashint4(g + 5)) % 4) || '.' || (abs(hashint4(g + 6)) % 5) || '.0',
         'score', round((abs(hashint4(g + 7)) % 1000) / 1000.0, 3),
         'device', (ARRAY['ios','android','web'])[1 + abs(hashint4(g + 8)) % 3],
         'signup_days', abs(hashint4(g + 9)) % 400,
         'locale', (ARRAY['en-GB','de-DE','pt-BR','hi-IN'])[1 + abs(hashint4(g + 10)) % 4]
       ) || CASE WHEN hashint4(g + 11) % 3 = 0 THEN '{"beta": true}'::jsonb ELSE '{}'::jsonb END AS traits
FROM generate_series(0, @@N@@ - 1) g;
ALTER TABLE bench_users ADD PRIMARY KEY (identifier);
ANALYZE bench_users;
"""

if __name__ == "__main__":
    print(json.dumps(build()))
