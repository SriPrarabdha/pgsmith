"""flagshift: `terraform plan` for Flagsmith flag changes.

Evaluates the live configuration and a proposed one over your real users, in one
SQL statement inside Postgres, and shows who changes and why.

  flagshift plan --env production --promote-from staging --population app.users
  flagshift plan --env production --patch change.json --population app.users --format markdown
  flagshift apply --env production --promote-from staging --population app.users
  flagshift pin production 41 / flagshift unpin production

Exit codes (like terraform -detailed-exitcode): 0 no changes, 2 changes, 1 error.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import psycopg

from . import candidate as cand_mod
from .render import render_markdown, render_text


def build_candidate(conn, a) -> tuple[dict, int, list[str], dict | None]:
    live = cand_mod.live_context(conn, a.env)
    warnings: list[str] = []
    source = None
    if a.promote_from:
        source = cand_mod.live_context(conn, a.promote_from)
        ctx, warnings = cand_mod.promote(source["context"], live["context"])
    elif a.patch:
        with open(a.patch) as f:
            ops = json.load(f)
        ctx = cand_mod.apply_patch(live["context"], ops)
    elif a.candidate:
        with open(a.candidate) as f:
            ctx = json.load(f)
    else:
        sys.exit("flagshift: pass one of --promote-from, --patch or --candidate")
    sid = cand_mod.load_candidate(conn, ctx, live["env_key"], live["identity_overrides"])
    return live, sid, warnings, source


def plan(conn, a) -> tuple[dict, int]:
    live, cand_sid, warnings, source = build_candidate(conn, a)
    t0 = time.perf_counter()
    diff = conn.execute(
        "SELECT * FROM flagsmith.plan_diff(%s, %s, %s::regclass, %s)",
        (live["env_key"], cand_sid, a.population, live["snapshot_id"])).fetchall()
    cols = ["feature", "changed", "from_enabled", "to_enabled", "from_value", "to_value", "from_variant",
            "to_variant", "from_reason", "to_reason", "users", "sample"]
    rows = [dict(zip(cols, r)) for r in diff]
    overlap = {}
    if source is not None:
        for feat, in_src, in_cand, in_both, pct in conn.execute(
                "SELECT * FROM flagsmith.cohort_overlap(%s, %s, %s::regclass)",
                (source["snapshot_id"], cand_sid, a.population)).fetchall():
            if in_src:
                overlap[feat] = {"in_source": in_src, "in_candidate": in_cand, "in_both": in_both, "pct": float(pct or 0)}
    result = {
        "environment": live["name"], "env_key": live["env_key"], "live_snapshot": live["snapshot_id"],
        "candidate_snapshot": cand_sid, "source": source["name"] if source else (a.patch or a.candidate),
        "population": a.population, "rows": rows, "warnings": warnings, "overlap": overlap,
        "seconds": round(time.perf_counter() - t0, 2),
    }
    n_changed = sum(r["users"] for r in rows if r["changed"])
    return result, (2 if n_changed else 0)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="flagshift", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", default=os.environ.get("PGSMITH_DSN"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "apply"):
        p = sub.add_parser(name)
        p.add_argument("--env", required=True, help="target environment (key, alias or name)")
        g = p.add_mutually_exclusive_group(required=True)
        g.add_argument("--promote-from", help="source environment to promote")
        g.add_argument("--patch", help="RFC 6902 JSON patch against the target's live context")
        g.add_argument("--candidate", help="a full EvaluationContext JSON file")
        p.add_argument("--population", required=True, help="table or view with identifier text, traits jsonb")
        p.add_argument("--format", choices=["text", "markdown", "json"], default="text")
        p.add_argument("--no-color", action="store_true")
        if name == "apply":
            p.add_argument("--api", default=os.environ.get("FLAGSMITH_API_URL"))
            p.add_argument("--token", default=os.environ.get("FLAGSMITH_TOKEN"))
            p.add_argument("--server-key", default=None, help="target's server key, to re-sync after applying")
            p.add_argument("--yes", action="store_true", help="do not ask for confirmation")
    p = sub.add_parser("pin")
    p.add_argument("env")
    p.add_argument("snapshot_id", type=int)
    p = sub.add_parser("unpin")
    p.add_argument("env")
    p = sub.add_parser("history")
    p.add_argument("env")
    a = ap.parse_args(argv)
    if not a.dsn:
        sys.exit("flagshift: pass --dsn or set PGSMITH_DSN")

    with psycopg.connect(a.dsn, autocommit=True) as conn:
        if a.cmd == "pin":
            conn.execute("SELECT flagsmith.pin(%s, %s)", (a.env, a.snapshot_id))
            print(f"pinned {a.env} to snapshot {a.snapshot_id}; sync loads are held until `flagshift unpin {a.env}`")
            return 0
        if a.cmd == "unpin":
            sid = conn.execute("SELECT flagsmith.unpin(%s)", (a.env,)).fetchone()[0]
            print(f"unpinned {a.env}; serving snapshot {sid}")
            return 0
        if a.cmd == "history":
            for r in conn.execute(
                    "SELECT at, snapshot_id, outcome, source, source_rev FROM flagsmith.load_history(%s, 20)",
                    (a.env,)).fetchall():
                print(f"{r[0]:%Y-%m-%d %H:%M:%S}  snapshot {r[1]:>6}  {r[2]:<9} {r[3] or '':<9} {r[4] or ''}")
            return 0

        result, rc = plan(conn, a)
        if a.format == "json":
            print(json.dumps(result, default=str, indent=2))
        elif a.format == "markdown":
            print(render_markdown(result))
        else:
            print(render_text(result, color=not a.no_color and sys.stdout.isatty()))
        if a.cmd == "plan":
            return rc
        if rc == 0:
            print("Nothing to apply.")
            return 0
        from .apply import apply_candidate
        if not a.yes and input("Apply these changes to Flagsmith? [yes/no] ").strip() != "yes":
            print("Apply cancelled.")
            return 1
        apply_candidate(conn, a, result)
        return 0


if __name__ == "__main__":
    sys.exit(main())
