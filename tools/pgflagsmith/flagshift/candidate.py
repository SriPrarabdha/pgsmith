"""Building FlagShift candidates: promotion with re-keying, JSON patches, files."""
from __future__ import annotations

import copy
import json
from typing import Any

import psycopg

from ..sync import dumps


def live_context(conn: psycopg.Connection, env: str) -> dict:
    """The current snapshot of an environment: context, identity overrides, ids."""
    row = conn.execute(
        """SELECT e.env_key, e.name, e.alias, s.snapshot_id, s.context::text, s.identity_overrides::text, s.source_rev
           FROM flagsmith.environment e JOIN flagsmith.snapshot s ON s.snapshot_id = e.current_snapshot
           WHERE e.env_key = %(e)s OR e.alias = %(e)s OR lower(e.name) = lower(%(e)s)
           ORDER BY (e.env_key = %(e)s) DESC LIMIT 1""", {"e": env}).fetchone()
    if not row:
        raise SystemExit(f"flagshift: environment {env!r} has no live snapshot in this database (run pg-flagsmith sync)")
    return {"env_key": row[0], "name": row[1], "alias": row[2], "snapshot_id": row[3],
            "context": json.loads(row[4]), "identity_overrides": json.loads(row[5]) if row[5] else None,
            "source_rev": row[6]}


def _variant_id(v: dict) -> Any:
    return v.get("key") if v.get("key") is not None else json.dumps(v.get("value"))


def promote(source: dict, target: dict) -> tuple[dict, list[str]]:
    """Copy rules, overrides, weights, enabled states and values from `source`
    (e.g. staging) into `target` (e.g. production), keeping the target's
    environment key, feature keys, override keys and variant priorities. Hashing
    uses those keys, so keeping them means the candidate buckets users exactly as
    the target will after the change is applied."""
    warnings: list[str] = []
    src, tgt = source, target
    cand = {"environment": copy.deepcopy(tgt["environment"]), "features": {}, "segments": {}}

    def rekey_variants(src_vars: list | None, tgt_vars: list | None, where: str) -> list | None:
        if not src_vars:
            return None
        by_id = {_variant_id(v): v for v in (tgt_vars or [])}
        out = []
        for v in src_vars:
            t = by_id.get(_variant_id(v))
            nv = copy.deepcopy(v)
            if t is not None:
                nv["priority"] = t["priority"]
            else:
                warnings.append(f"{where}: variant {_variant_id(v)} is new; its priority is unknown until applied")
            out.append(nv)
        return out

    for name, sf in src.get("features", {}).items():
        tf = tgt.get("features", {}).get(name)
        if tf is None:
            warnings.append(f"feature {name} does not exist in the target environment")
            cand["features"][name] = copy.deepcopy(sf)
            continue
        cf = copy.deepcopy(tf)
        cf["enabled"], cf["value"] = sf["enabled"], sf.get("value")
        vs = rekey_variants(sf.get("variants"), tf.get("variants"), f"feature {name}")
        if vs is None:
            cf.pop("variants", None)
        else:
            cf["variants"] = vs
        cand["features"][name] = cf

    for skey, ss in src.get("segments", {}).items():
        ts = tgt.get("segments", {}).get(skey, {})
        cs = copy.deepcopy(ss)
        t_ov = {o["name"]: o for o in ts.get("overrides") or []}
        new_ovs = []
        for o in ss.get("overrides") or []:
            no = copy.deepcopy(o)
            t = t_ov.get(o["name"])
            if t is not None:
                no["key"] = t["key"]
                vs = rekey_variants(o.get("variants"), t.get("variants"), f"segment {ss['name']} / {o['name']}")
                if vs is not None:
                    no["variants"] = vs
            elif o.get("variants"):
                warnings.append(f"segment {ss['name']} / {o['name']}: new multivariate override; "
                                "its hashing salt is unknown until applied, so variant moves are estimates")
            new_ovs.append(no)
        if new_ovs:
            cs["overrides"] = new_ovs
        else:
            cs.pop("overrides", None)
        cand["segments"][skey] = cs
    return cand, warnings


def apply_patch(ctx: dict, ops: list[dict]) -> dict:
    """RFC 6902 JSON Patch (add, remove, replace, test, copy, move) on a context."""
    doc = copy.deepcopy(ctx)

    def parts(path: str) -> list[str]:
        if path == "":
            return []
        return [p.replace("~1", "/").replace("~0", "~") for p in path.lstrip("/").split("/")]

    def walk(path: str):
        ps = parts(path)
        cur = doc
        for p in ps[:-1]:
            cur = cur[int(p)] if isinstance(cur, list) else cur[p]
        return cur, ps[-1]

    def get(path: str):
        cur = doc
        for p in parts(path):
            cur = cur[int(p)] if isinstance(cur, list) else cur[p]
        return cur

    for op in ops:
        kind, path = op["op"], op["path"]
        if kind == "test":
            if get(path) != op["value"]:
                raise SystemExit(f"flagshift: patch test failed at {path}")
            continue
        if kind in ("copy", "move"):
            value = copy.deepcopy(get(op["from"]))
            if kind == "move":
                parent, last = walk(op["from"])
                parent.pop(int(last)) if isinstance(parent, list) else parent.pop(last)
            kind, op = "add", {"op": "add", "path": path, "value": value}
        parent, last = walk(path)
        if kind == "remove":
            parent.pop(int(last)) if isinstance(parent, list) else parent.pop(last)
        elif kind in ("add", "replace"):
            if isinstance(parent, list):
                if last == "-":
                    parent.append(op["value"])
                elif kind == "add":
                    parent.insert(int(last), op["value"])
                else:
                    parent[int(last)] = op["value"]
            else:
                if kind == "replace" and last not in parent:
                    raise SystemExit(f"flagshift: patch replace of missing {path}")
                parent[last] = op["value"]
        else:
            raise SystemExit(f"flagshift: unknown patch op {kind}")
    return doc


def load_candidate(conn: psycopg.Connection, ctx: dict, env_key: str, identity_overrides: dict | None) -> int:
    return conn.execute(
        """SELECT flagsmith.load_context(%s::json, env_key => %s, source => 'flagshift', kind => 'candidate',
                                         identity_overrides => %s::json, compile => true)""",
        (dumps(ctx), env_key, dumps(identity_overrides) if identity_overrides else None)).fetchone()[0]
