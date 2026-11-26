"""flagshift apply: write a planned change through Flagsmith's Admin API, re-sync,
and verify that the plan against the new live configuration is empty.

Supported changes: environment defaults (enabled, value, multivariate weights),
segment overrides (enabled, value, priority), new segment overrides and removed
ones. Segment rules are project-wide and are reported, not applied.
"""
from __future__ import annotations

import json
import os
import sys
import time

from ..admin import FlagsmithAdmin, _feature_state_value
from ..sync import fetch_document, load_document
from . import candidate as cand_mod


def _ops(live: dict, cand: dict) -> tuple[list[tuple], list[str]]:
    ops, notes = [], []
    lf, cf = live["features"], cand["features"]
    for name, c in cf.items():
        lv = lf.get(name)
        if lv is None:
            notes.append(f"feature {name}: does not exist in the target; create it in Flagsmith first")
            continue
        if (c["enabled"], c.get("value")) != (lv["enabled"], lv.get("value")):
            ops.append(("default", name, int(lv["key"]), c["enabled"], c.get("value")))
        lw = {v["priority"]: v["weight"] for v in lv.get("variants") or []}
        cw = {v["priority"]: v["weight"] for v in c.get("variants") or []}
        if lw != cw:
            ops.append(("weights", name, int(lv["key"]), cw))
    ls, cs = live.get("segments", {}), cand.get("segments", {})
    for skey, seg in cs.items():
        lseg = ls.get(skey, {})
        if json.dumps(lseg.get("rules"), sort_keys=True) != json.dumps(seg.get("rules"), sort_keys=True):
            notes.append(f"segment {seg['name']}: rules differ; segments are project-wide, edit them in Flagsmith")
        lov = {o["name"]: o for o in lseg.get("overrides") or []}
        cov = {o["name"]: o for o in seg.get("overrides") or []}
        for fname, o in cov.items():
            l = lov.get(fname)
            if l is None:
                ops.append(("create_override", fname, int(skey), o["enabled"], o.get("value"), o.get("priority")))
            else:
                if (o["enabled"], o.get("value")) != (l["enabled"], l.get("value")):
                    ops.append(("override", fname, int(l["key"]), o["enabled"], o.get("value")))
                if o.get("priority") != l.get("priority"):
                    ops.append(("priority", fname, int(skey), o.get("priority")))
        for fname in lov.keys() - cov.keys():
            ops.append(("delete_override", fname, int(skey)))
    return ops, notes


def apply_candidate(conn, a, result: dict) -> None:
    if not (a.api and a.token):
        sys.exit("flagshift apply: pass --api and --token (or FLAGSMITH_API_URL / FLAGSMITH_TOKEN)")
    fs = FlagsmithAdmin(a.api, token=a.token)
    live = cand_mod.live_context(conn, a.env)
    cand_ctx = json.loads(conn.execute("SELECT flagsmith.snapshot_context(%s)::text",
                                       (result["candidate_snapshot"],)).fetchone()[0])
    ops, notes = _ops(live["context"], cand_ctx)
    for n in notes:
        print("  !", n)
    env_key = live["env_key"]
    env = fs.get(f"environments/{env_key}/")
    features = {f["name"]: f for f in fs.features(env["project"])}
    for op in ops:
        kind, fname = op[0], op[1]
        feat = features[fname]
        if kind == "default":
            _, _, fs_id, enabled, value = op
            fs.patch(f"environments/{env_key}/featurestates/{fs_id}/", {"enabled": enabled, "feature_state_value": value})
        elif kind == "weights":
            _, _, fs_id, cw = op
            state = fs.get(f"environments/{env_key}/featurestates/{fs_id}/")
            mv = [{**m, "percentage_allocation": cw.get(m["id"], m["percentage_allocation"])}
                  for m in state.get("multivariate_feature_state_values", [])]
            fs.patch(f"environments/{env_key}/featurestates/{fs_id}/", {"multivariate_feature_state_values": mv})
        elif kind == "override":
            _, _, fs_id, enabled, value = op
            fs.patch(f"features/featurestates/{fs_id}/", {"enabled": enabled, "feature_state_value": _feature_state_value(value),
                                                          "environment": env["id"], "feature": feat["id"]})
        elif kind == "create_override":
            _, _, seg_id, enabled, value, priority = op
            fs.segment_override(env_key, feat["id"], seg_id, enabled, value, priority)
        elif kind == "priority":
            _, _, seg_id, priority = op
            fsegs = [s for s in fs.segment_overrides(env["id"], feat["id"]) if s["segment"] == seg_id]
            if fsegs:
                fs.post("features/feature-segments/update-priorities/", [{"id": fsegs[0]["id"], "priority": priority}])
        elif kind == "delete_override":
            _, _, seg_id = op
            for s in fs.segment_overrides(env["id"], feat["id"]):
                if s["segment"] == seg_id:
                    fs.request("DELETE", f"features/feature-segments/{s['id']}/")
        print(f"  applied {kind} {fname}")
    # re-sync and verify: the plan against the new live configuration must be empty
    server_key = a.server_key or os.environ.get("FLAGSMITH_SERVER_KEY")
    if server_key:
        for _ in range(10):
            doc = fetch_document(a.api, server_key)
            sid, outcome = load_document(conn, doc, source="flagshift")
            if outcome != "unchanged":
                break
            time.sleep(1)
    else:
        print("  (no --server-key: waiting for pg-flagsmith sync to pick up the change)")
        before = live["snapshot_id"]
        for _ in range(60):
            if cand_mod.live_context(conn, a.env)["snapshot_id"] != before:
                break
            time.sleep(1)
    after = cand_mod.live_context(conn, a.env)
    rem = conn.execute("SELECT coalesce(sum(users_changed), 0) FROM flagsmith.plan(%s, %s, %s::regclass, %s)",
                       (env_key, result["candidate_snapshot"], a.population, after["snapshot_id"])).fetchone()[0]
    if rem == 0:
        print(f"Verified: live snapshot {after['snapshot_id']} now matches the plan (re-plan shows no changes).")
    else:
        print(f"WARNING: re-plan still shows {rem} identity-flag changes; the change was only partly applied.")
