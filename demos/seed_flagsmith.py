"""Seed a local self-hosted Flagsmith with the demo project used by both demos.

    python demos/seed_flagsmith.py [--api http://localhost:8000/api/v1/]

Creates (idempotently) organisation "pgsmith demo", project "Shop" with
environments Staging and Production, five features, four segments, segment
overrides that differ between the environments, identity overrides, server-side
keys and the webhooks pointing at `pgsmith serve`. Writes the keys to
demos/.env (git-ignored), which the other demo scripts read.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from pgsmith.admin import FlagsmithAdmin  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent

EMAIL = os.environ.get("FLAGSMITH_ADMIN_EMAIL", "admin@pgsmith.local")
PASSWORD = os.environ.get("FLAGSMITH_ADMIN_PASSWORD", "Sup3r-Secret-Demo!")


def cond(prop, op, value):
    return {"property": prop, "operator": op, "value": value}


SEGMENTS = {
    "beta_testers": [{"type": "ALL", "rules": [{"type": "ANY", "conditions": [
        cond("plan", "IN", "pro,team"), cond("beta", "EQUAL", "true")]}]}],
    "enterprise": [{"type": "ALL", "rules": [{"type": "ALL", "conditions": [cond("plan", "EQUAL", "enterprise")]}]}],
    "india_mobile": [{"type": "ALL", "rules": [{"type": "ALL", "conditions": [
        cond("country", "EQUAL", "IN"), cond("device", "IN", "ios,android")]}]}],
    "quarter_rollout": [{"type": "ALL", "rules": [{"type": "ALL", "conditions": [
        cond("$.identity.key", "PERCENTAGE_SPLIT", "25")]}]}],
    "app_v3": [{"type": "ALL", "rules": [{"type": "ALL", "conditions": [
        cond("app_version", "GREATER_THAN_INCLUSIVE", "3.0.0:semver"), cond("email", "REGEX", r".*@(corp|acme)\.com$")]}]}],
}

FEATURES = {
    "new_checkout": {"type": "STANDARD", "default_enabled": False, "initial_value": "v1"},
    "pricing_banner": {"type": "STANDARD", "default_enabled": True, "initial_value": "summer"},
    "dark_mode": {"type": "STANDARD", "default_enabled": False},
    "max_upload_mb": {"type": "STANDARD", "default_enabled": True, "initial_value": "25"},
    "search_ranking": {"type": "MULTIVARIATE", "default_enabled": True, "initial_value": "control"},
}

# (feature, segment, enabled, value, priority) per environment
OVERRIDES = {
    "Production": [
        ("new_checkout", "beta_testers", True, "v2", 0),
        ("new_checkout", "enterprise", True, "v2-enterprise", 1),
        ("pricing_banner", "enterprise", True, "enterprise", 0),
        ("dark_mode", "quarter_rollout", True, "", 0),
        ("max_upload_mb", "app_v3", True, "100", 0),
    ],
    "Staging": [
        ("new_checkout", "beta_testers", True, "v2", 0),
        ("new_checkout", "quarter_rollout", True, "v2", 1),
        ("new_checkout", "enterprise", True, "v2-enterprise", 2),
        ("pricing_banner", "enterprise", True, "enterprise", 0),
        ("pricing_banner", "india_mobile", True, "diwali", 1),
        ("dark_mode", "quarter_rollout", True, "", 0),
        ("max_upload_mb", "app_v3", True, "250", 0),
    ],
}
IDENTITY_OVERRIDES = {
    "Production": [("user42", "dark_mode", True, ""), ("vip-1", "new_checkout", True, "v3-preview"),
                   ("007", "pricing_banner", False, "")],
}


def seed(api: str, webhook_url: str | None) -> dict:
    fs = FlagsmithAdmin.login(api, EMAIL, PASSWORD, register=True)
    org = fs.organisation("pgsmith demo")
    project = fs.project(org["id"], "Shop")
    envs = {name: fs.environment(project["id"], name) for name in ["Staging", "Production"]}
    for e in envs.values():
        fs.update_environment(e["api_key"], use_identity_overrides_in_local_eval=True)

    feats = {name: fs.feature(project["id"], name, **spec) for name, spec in FEATURES.items()}
    # search_ranking: two keyed variants, 50/50 (the control value is the feature value)
    fs.mv_option(project["id"], feats["search_ranking"]["id"], "boosted", "boosted", 50)
    fs.mv_option(project["id"], feats["search_ranking"]["id"], "relevance_v2", "relevance_v2", 0)

    segs = {name: fs.segment(project["id"], name, rules) for name, rules in SEGMENTS.items()}

    for env_name, overrides in OVERRIDES.items():
        env = envs[env_name]
        existing = {(o["segment"], o["feature"]) for f in feats.values()
                    for o in fs.segment_overrides(env["id"], f["id"])}
        for feature, segment, enabled, value, priority in overrides:
            if (segs[segment]["id"], feats[feature]["id"]) in existing:
                continue
            fs.segment_override(env["api_key"], feats[feature]["id"], segs[segment]["id"], enabled, value, priority)
    for env_name, ios in IDENTITY_OVERRIDES.items():
        for identifier, feature, enabled, value in ios:
            fs.identity_override(envs[env_name]["api_key"], identifier, feats[feature]["id"], enabled, value)

    keys = {name: {"client_key": e["api_key"], "server_key": fs.server_key(e["api_key"]), "id": e["id"]}
            for name, e in envs.items()}
    if webhook_url:
        for e in envs.values():
            fs.webhook(e["api_key"], webhook_url, os.environ.get("FLAGSMITH_WEBHOOK_SECRET", ""))

    out = {"api": api, "organisation": org["id"], "project": project["id"], "environments": keys,
           "features": {k: v["id"] for k, v in feats.items()}, "segments": {k: v["id"] for k, v in segs.items()},
           "token": fs.s.headers["Authorization"].split()[1]}
    env_lines = [
        f"FLAGSMITH_API_URL={api}",
        f"FLAGSMITH_TOKEN={out['token']}",
        f"FLAGSMITH_PROJECT_ID={project['id']}",
        f"PROD_CLIENT_KEY={keys['Production']['client_key']}",
        f"PROD_SERVER_KEY={keys['Production']['server_key']}",
        f"STAGING_CLIENT_KEY={keys['Staging']['client_key']}",
        f"STAGING_SERVER_KEY={keys['Staging']['server_key']}",
    ]
    (HERE / ".env").write_text("\n".join(env_lines) + "\n")
    (HERE / ".seed.json").write_text(json.dumps(out, indent=2))
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--api", default=os.environ.get("FLAGSMITH_API_URL", "http://localhost:8000/api/v1/"))
    ap.add_argument("--webhook-url", default=None, help="URL Flagsmith should call on every change")
    a = ap.parse_args()
    res = seed(a.api, a.webhook_url)
    print(json.dumps({k: v for k, v in res.items() if k != "token"}, indent=2))
    print(f"keys written to {HERE / '.env'}")
