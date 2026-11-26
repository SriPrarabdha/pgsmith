"""Security properties of the installed extension.

  * no pg_flagsmith routine resolves a name through its caller's search_path
    (SQL-standard bodies bind at creation; everything else pins search_path),
    checked in the catalog and by planting trojans that must never run;
  * SECURITY DEFINER routines pin search_path with pg_temp last;
  * nothing is granted to PUBLIC; each role can do what it is for and no more;
  * configuration values never become code (hostile names and values everywhere,
    evaluated like the reference engine);
  * routines with a SET clause work inside parallel workers.
"""
from __future__ import annotations

import json
import pathlib
import re
import uuid

import psycopg
import pytest
from psycopg import sql as psql
from flag_engine.engine import get_evaluation_result

from tests.strict import diff

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEMAS = ("flagsmith", "flagsmith_c")
PINNED = "pg_catalog, flagsmith, pg_temp"


def ctx_all_operators(env_key: str, name: str = "security") -> dict:
    """A context using every operator, splits, variants and segment overrides."""
    conds = [
        ("EQUAL", "plan", "pro"), ("NOT_EQUAL", "plan", "free"), ("GREATER_THAN", "age", "18"),
        ("GREATER_THAN_INCLUSIVE", "score", "1.5"), ("LESS_THAN", "age", "65"),
        ("LESS_THAN_INCLUSIVE", "version", "2.0.0:semver"), ("CONTAINS", "email", "@x.com"),
        ("NOT_CONTAINS", "email", "spam"), ("IN", "country", "IN,US,DE"), ("IN", "$.identity.identifier", '["u1","u2"]'),
        ("REGEX", "email", r"^[a-z]+@x\.com$"), ("MODULO", "age", "2|0"), ("PERCENTAGE_SPLIT", "", "50"),
        ("IS_SET", "beta", ""), ("IS_NOT_SET", "nope", ""), ("EQUAL", "$.identity.key", "x"),
        ("EQUAL", "$.environment.name", name), ("GREATER_THAN", "$.identity.traits.age", "10"),
    ]
    segments = {}
    for i, (op, prop, val) in enumerate(conds, start=1):
        segments[str(i)] = {
            "key": str(i), "name": f"seg_{i}",
            "rules": [{"type": ["ALL", "ANY", "NONE"][i % 3] if i % 3 else "ALL",
                       "conditions": [{"operator": op, "property": prop, "value": val}],
                       "rules": [{"type": "ANY", "conditions": [
                           {"operator": "EQUAL", "property": "plan", "value": "pro"},
                           {"operator": "PERCENTAGE_SPLIT", "property": "$.identity.identifier", "value": "30"}]}]
                       if i % 4 == 0 else []}],
            "overrides": [{"key": str(1000 + i), "name": f"f{i % 5}", "enabled": bool(i % 2), "value": f"v{i}",
                           "priority": i % 3}],
        }
    features = {f"f{i}": {"key": str(100 + i), "name": f"f{i}", "enabled": i % 2 == 0, "value": i,
                          "metadata": {"id": i}} for i in range(5)}
    features["mv"] = {"key": "200", "name": "mv", "enabled": True, "value": "control",
                      "variants": [{"value": "a", "weight": 30, "priority": 1, "key": "va"},
                                   {"value": "b", "weight": 33.3, "priority": 2}]}
    return {"environment": {"key": env_key, "name": name}, "features": features, "segments": segments}


IDENTITIES = [("u1", {"plan": "pro", "age": 30, "score": 1.5, "version": "1.2.3", "email": "ab@x.com",
                      "country": "IN", "beta": True}),
              ("u2", {"plan": "free", "age": 70, "email": "spam@y.org", "country": "FR"}),
              ("someone", {}), ("007", {"age": "18", "plan": "pro"})]


@pytest.fixture()
def env(cur):
    key = "sec_" + uuid.uuid4().hex[:10]
    cur.execute("SELECT flagsmith.load_context(%s::json)", (json.dumps(ctx_all_operators(key)),))
    sid = cur.fetchone()[0]
    alias = cur.execute("SELECT alias FROM flagsmith.environments() WHERE env_key = %s", (key,)).fetchone()[0]
    return {"key": key, "sid": sid, "alias": alias}


def routines(cur):
    cur.execute("""
      SELECT p.oid::regprocedure::text, n.nspname, l.lanname, p.prosecdef, p.prokind, p.proconfig,
             p.prosqlbody IS NOT NULL, p.prosrc
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
      WHERE n.nspname = ANY (%s)""", (list(SCHEMAS),))
    return cur.fetchall()


def _search_path(config) -> str | None:
    for c in config or []:
        if c.startswith("search_path="):
            return c.split("=", 1)[1]
    return None


def test_no_routine_resolves_names_through_the_callers_search_path(cur, env):
    bad = []
    for sig, nsp, lang, secdef, kind, config, atomic, src in routines(cur):
        sp = _search_path(config)
        if atomic or sp == PINNED:
            continue
        if sig == "flagsmith._fx(anyelement)" and src.strip() == "SELECT $1":
            continue  # no names at all (polymorphic: cannot be SQL-standard)
        if sig == "flagsmith.sync_run()" and kind == "p":
            # a committing procedure cannot carry SET; it may only call qualified pg_flagsmith routines
            body = re.sub(r"--[^\n]*", "", src)
            calls = re.findall(r"PERFORM\s+([\w.]+)\(\)", body)
            assert calls == ["flagsmith.sync_tick", "flagsmith._sync_await"], body
            assert re.sub(r"\s+", " ", body).strip() == \
                "BEGIN PERFORM flagsmith.sync_tick(); COMMIT; PERFORM flagsmith._sync_await(); END", body
            continue
        bad.append((sig, lang, sp))
    assert not bad, f"routines resolving names at call time: {bad}"


def test_security_definer_routines_pin_search_path(cur, env):
    for sig, nsp, lang, secdef, kind, config, atomic, src in routines(cur):
        if secdef:
            assert _search_path(config) == PINNED, sig


def test_generated_code_is_sql_standard(cur, env):
    cur.execute("""SELECT p.oid::regprocedure::text FROM pg_proc p
                   WHERE p.pronamespace = 'flagsmith_c'::regnamespace AND p.prosqlbody IS NULL""")
    assert cur.fetchall() == []
    cur.execute("SELECT count(*) FROM pg_proc WHERE pronamespace = 'flagsmith_c'::regnamespace")
    assert cur.fetchone()[0] >= 4


def test_nothing_is_granted_to_public(cur, env):
    cur.execute("""SELECT p.oid::regprocedure::text FROM pg_proc p
                   WHERE p.pronamespace = ANY (ARRAY['flagsmith', 'flagsmith_c']::regnamespace[])
                     AND has_function_privilege('public', p.oid, 'EXECUTE')""")
    assert cur.fetchall() == []
    cur.execute("""SELECT c.oid::regclass::text FROM pg_class c
                   WHERE c.relnamespace = ANY (ARRAY['flagsmith', 'flagsmith_c']::regnamespace[])
                     AND (SELECT bool_or(a.grantee = 0) FROM aclexplode(c.relacl) a)""")
    assert cur.fetchall() == []
    for s in SCHEMAS:
        cur.execute("SELECT has_schema_privilege('public', %s, 'USAGE')", (s,))
        assert cur.fetchone()[0] is False


EXPECTED_DEFINER_GRANTS = {
    "flagsmith_reader": {"_interp", "_snapshot_for", "_io_matched", "_io_segment", "health", "environments"},
    "flagsmith_tracker": {"_enqueue"},
    "flagsmith_planner": {"live_context", "snapshot_context", "load_candidate", "_eval_sql"},
    "flagsmith_loader": {"load_context", "apply_context", "evaluate_context", "mark_checked", "pin", "unpin", "gc",
                         "remove_environment",
                         "recompile", "drop_test_snapshots", "record_parity", "load_history", "sync_tick",
                         "_sync_await", "sync_status", "events_claim", "events_record", "events_pending",
                         "events_tick", "event_status", "events_retry_failed"},
}


def test_security_definer_grants_are_exactly_the_intended_ones(cur, env):
    cur.execute("""
      SELECT r.rolname, p.proname
      FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a JOIN pg_roles r ON r.oid = a.grantee
      WHERE p.pronamespace = 'flagsmith'::regnamespace AND p.prosecdef AND a.privilege_type = 'EXECUTE'
        AND r.rolname LIKE 'flagsmith\\_%%'""")
    got: dict[str, set] = {}
    for role, name in cur.fetchall():
        got.setdefault(role, set()).add(name)
    assert got == EXPECTED_DEFINER_GRANTS
    # no role (owner aside) holds any privilege on a pg_flagsmith table
    cur.execute("""
      SELECT c.oid::regclass::text, r.rolname FROM pg_class c
      CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid = a.grantee
      WHERE c.relnamespace = 'flagsmith'::regnamespace AND c.relkind IN ('r', 'p') AND a.grantee <> c.relowner""")
    assert cur.fetchall() == []


class Roles:
    """Login-less test roles, one per pg_flagsmith role, usable with SET ROLE."""

    def __init__(self, cur):
        self.cur = cur
        self.names = {}
        sfx = uuid.uuid4().hex[:6]
        for base in ("reader", "tracker", "planner", "loader"):
            r = f"pgfs_t_{base}_{sfx}"
            cur.execute(f"CREATE ROLE {r} NOLOGIN IN ROLE flagsmith_{base}")
            cur.execute(f"GRANT {r} TO CURRENT_USER")  # PG 16+: CREATEROLE alone does not allow SET ROLE
            self.names[base] = r

    def drop(self):
        self.cur.execute("RESET ROLE")
        for r in self.names.values():
            self.cur.execute(f"DROP OWNED BY {r}")
            self.cur.execute(f"DROP ROLE {r}")


def _can(cur, role, sql, params=None) -> bool:
    cur.execute("SAVEPOINT p")
    cur.execute(f"SET LOCAL ROLE {role}")
    try:
        cur.execute(sql, params)
        if cur.description:
            cur.fetchall()
        cur.execute("RELEASE SAVEPOINT p")
        return True
    except psycopg.errors.InsufficientPrivilege:
        cur.execute("ROLLBACK TO SAVEPOINT p")
        return False
    finally:
        cur.execute("RESET ROLE")


@pytest.fixture()
def roles(conn):
    with conn.cursor() as cur:
        rs = Roles(cur)
        yield rs
        rs.drop()


def test_each_role_can_do_its_job_and_nothing_more(conn, env, roles):
    r = roles.names
    k, a, sid = env["key"], env["alias"], env["sid"]
    ctx = json.dumps(ctx_all_operators(k))
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE IF NOT EXISTS public.pgfs_sec_users (identifier text, traits jsonb)")
        cur.execute("TRUNCATE public.pgfs_sec_users")
        cur.execute("INSERT INTO public.pgfs_sec_users SELECT 'u' || g, '{}' FROM generate_series(1, 50) g")
        cur.execute(f"GRANT SELECT ON public.pgfs_sec_users TO {r['planner']}")
        cur.execute("BEGIN")
        try:
            P1, PC, PCK = (k,), (ctx,), (ctx, k)
            checks = [
                # what each role is for
                ("reader", f"SELECT * FROM flagsmith_c.flags_{a}('u1', '{{}}')", None, True),
                ("reader", f"SELECT * FROM flagsmith_c.flag_{a}('mv', 'u1', '{{}}')", None, True),
                ("reader", "SELECT * FROM flagsmith.get_flags('u1', '{}', %s)", P1, True),
                ("reader", "SELECT * FROM flagsmith.get_segments('u1', '{}', %s)", P1, True),
                ("reader", "SELECT flagsmith.variant('mv', 'u1', '{}', %s)", P1, True),
                ("reader", "SELECT flagsmith.is_enabled('f0', 'u1', '{}', %s)", P1, True),
                ("reader", "SELECT * FROM flagsmith.health()", None, True),
                ("tracker", "SELECT flagsmith.track_exposure('mv', 'u1', 'a', env => %s)", P1, True),
                ("tracker", "SELECT flagsmith.track_event('click', 'u1', env => %s)", P1, True),
                ("planner", "SELECT * FROM flagsmith.live_context(%s)", P1, True),
                ("planner", f"SELECT * FROM flagsmith.plan(%s, {sid}, 'public.pgfs_sec_users')", P1, True),
                ("planner", "SELECT flagsmith.load_candidate(%s::json, %s)", PCK, True),
                ("loader", "SELECT flagsmith.load_context(%s::json)", PC, True),
                ("loader", "SELECT * FROM flagsmith.sync_tick()", None, True),
                ("loader", "SELECT * FROM flagsmith.events_claim(%s, 10)", P1, True),
                ("loader", f"SELECT flagsmith.pin(%s, {sid})", P1, True),
                # and what it is not for
                ("reader", "SELECT * FROM flagsmith.snapshot", None, False),
                ("reader", "SELECT * FROM flagsmith.live_context(%s)", P1, False),
                ("reader", "SELECT flagsmith.track_exposure('mv', 'u1', 'a', env => %s)", P1, False),
                ("reader", "SELECT flagsmith.load_context(%s::json)", PC, False),
                ("reader", "SELECT flagsmith.evaluate_context(%s::json)", PC, False),
                ("reader", "SELECT * FROM flagsmith.events_claim(%s, 10)", P1, False),
                ("reader", f"SELECT flagsmith.pin(%s, {sid})", P1, False),
                ("tracker", "SELECT * FROM flagsmith.event_queue", None, False),
                ("tracker", "SELECT * FROM flagsmith.get_flags('u1', '{}', %s)", P1, False),
                ("planner", "SELECT flagsmith.load_context(%s::json)", PC, False),
                ("planner", f"SELECT flagsmith.pin(%s, {sid})", P1, False),
                ("planner", "SELECT * FROM flagsmith.sync_tick()", None, False),
                ("planner", "SELECT * FROM flagsmith.remote_source", None, False),
                ("loader", "SELECT flagsmith.add_remote_source('x', 'https://e.example/api/v1/', 'k')", None, False),
                ("loader", "SELECT flagsmith._remote_key('k')", None, False),
                ("loader", "SELECT flagsmith._publish(%s)", P1, False),
                ("loader", f"SELECT flagsmith.compile_snapshot({sid})", None, False),
                ("loader", "SELECT * FROM flagsmith.snapshot", None, False),
                ("loader", "UPDATE flagsmith.settings SET events_max_queued = 1000", None, False),
            ]
            failures = []
            for who, sql, params, allowed in checks:
                if _can(cur, r[who], sql, params) != allowed:
                    failures.append((who, sql, "should be allowed" if allowed else "should be denied"))
            assert not failures, failures
        finally:
            cur.execute("ROLLBACK")
            cur.execute("DROP TABLE public.pgfs_sec_users")


# ---------------------------------------------------------------------------
# trojans: lookalikes of every built-in function and operator pg_flagsmith uses,
# placed before pg_catalog in search_path, that raise if they are ever called
# ---------------------------------------------------------------------------

OPERATORS = ["=", "<>", "<", ">", "<=", ">=", "||", "->", "->>", "#>", "#>>", "~", "!~", "~*", "+", "-", "*",
             "/", "%", "?", "@>", "<@", "~~", "!~~", "&&", "^", "#"]


def _plant_trojans(cur) -> int:
    script = (ROOT / "extension" / "dist" / "pg_flagsmith--0.1.0.sql").read_text()
    used = set(m.lower() for m in re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", script))
    cur.execute("CREATE SCHEMA pgfs_trojan")
    cur.execute("""
      SELECT p.proname, pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid), p.proretset
      FROM pg_proc p
      WHERE p.pronamespace = 'pg_catalog'::regnamespace AND p.prokind = 'f' AND p.proname = ANY (%s)
        AND p.proargmodes IS NULL
        AND NOT EXISTS (SELECT 1 FROM unnest(p.proargtypes::oid[] || p.prorettype) t
                        JOIN pg_type ty ON ty.oid = t
                        WHERE ty.typtype = 'p' AND ty.typname NOT IN
                          ('anyelement', 'anyarray', 'anynonarray', 'anycompatible', 'anycompatiblearray', 'record',
                           'void'))
        """, (sorted(used),))
    n = 0
    for name, args, result, retset in cur.fetchall():
        cur.execute("SAVEPOINT t")
        try:
            cur.execute(psql.SQL("CREATE FUNCTION pgfs_trojan.{}({}) RETURNS {} LANGUAGE plpgsql AS {}").format(
                psql.Identifier(name), psql.SQL(args), psql.SQL(result),
                psql.Literal(f"BEGIN RAISE EXCEPTION 'trojan function {name}'; END")))
            cur.execute("RELEASE SAVEPOINT t")
            n += 1
        except psycopg.Error:
            cur.execute("ROLLBACK TO SAVEPOINT t")
    cur.execute("""
      SELECT o.oprname, format_type(o.oprleft, NULL), format_type(o.oprright, NULL), format_type(o.oprresult, NULL)
      FROM pg_operator o
      WHERE o.oprnamespace = 'pg_catalog'::regnamespace AND o.oprname = ANY (%s) AND o.oprleft <> 0
        AND NOT EXISTS (SELECT 1 FROM pg_type ty WHERE ty.oid IN (o.oprleft, o.oprright, o.oprresult)
                        AND ty.typtype = 'p' AND ty.typname NOT IN ('anyelement', 'anyarray', 'anycompatible',
                                                                    'anycompatiblearray', 'anynonarray'))""",
                (OPERATORS,))
    for i, (op, left, right, res) in enumerate(cur.fetchall()):
        cur.execute("SAVEPOINT t")
        try:
            cur.execute(psql.SQL("CREATE FUNCTION pgfs_trojan.{}(l {}, r {}) RETURNS {} LANGUAGE plpgsql AS {}").format(
                psql.Identifier(f"op_{i}"), psql.SQL(left), psql.SQL(right), psql.SQL(res),
                psql.Literal("BEGIN RAISE EXCEPTION 'trojan operator " + op.replace("%", "%%") + "'; END")))
            cur.execute(f"CREATE OPERATOR pgfs_trojan.{op} (LEFTARG = {left}, RIGHTARG = {right}, "
                        f"FUNCTION = pgfs_trojan.op_{i})")
            cur.execute("RELEASE SAVEPOINT t")
            n += 1
        except psycopg.Error:
            cur.execute("ROLLBACK TO SAVEPOINT t")
    return n


def test_search_path_trojans_never_run(conn, roles):
    key = "sec_tro_" + uuid.uuid4().hex[:8]
    ctx = ctx_all_operators(key)
    doc = {"api_key": key + "_doc", "name": "doc", "project": {"segments": [
              {"id": 1, "name": "s", "rules": [{"type": "ALL", "conditions": [
                  {"operator": "EQUAL", "property_": "plan", "value": "pro"}], "rules": []}]}]},
           "feature_states": [{"feature": {"id": 1, "name": "f"}, "enabled": True, "feature_state_value": 1,
                               "django_id": 1, "multivariate_feature_state_values": [
                                   {"id": 5, "multivariate_feature_option": {"value": "a"}, "percentage_allocation": 50}]}],
           "identity_overrides": [{"identifier": "u1", "identity_features": [
               {"feature": {"id": 1, "name": "f"}, "enabled": False, "feature_state_value": 2}]}]}
    with conn.cursor() as cur:
        cur.execute("BEGIN")
        try:
            cur.execute("SELECT flagsmith.load_context(%s::json)", (json.dumps(ctx),))
            sid = cur.fetchone()[0]
            alias = dict(cur.execute("SELECT env_key, alias FROM flagsmith.environments()").fetchall())[key]
            planted = _plant_trojans(cur)
            assert planted > 300
            cur.execute("CREATE TABLE pgfs_trojan.users AS SELECT 'u' || g AS identifier, '{}'::jsonb AS traits "
                        "FROM generate_series(1, 20) g")
            cur.execute(f"GRANT USAGE ON SCHEMA pgfs_trojan TO {roles.names['reader']}, {roles.names['planner']}")
            cur.execute(f"GRANT SELECT ON pgfs_trojan.users TO {roles.names['planner']}")
            cur.execute("SET LOCAL search_path = pgfs_trojan, pg_catalog, public")
            # the planted operators do capture unqualified SQL here: the test is live
            cur.execute("SAVEPOINT s")
            with pytest.raises(psycopg.errors.RaiseException, match="trojan"):
                cur.execute("SELECT 'a'::text = 'b'::text")
            cur.execute("ROLLBACK TO SAVEPOINT s")
            # everything pg_flagsmith does, as the owner (the context changes, so this compiles anew)
            ctx["features"]["f0"]["value"] = "reloaded"
            cur.execute("SELECT flagsmith.load_context(%s::json)", (json.dumps(ctx),))
            sid = cur.fetchone()[0]
            cur.execute("SELECT * FROM flagsmith.load_document(%s::json)", (json.dumps(doc),))
            cur.execute("SELECT flagsmith.evaluate_context(%s::json, true)",
                        (json.dumps(dict(ctx, identity={"identifier": "u1", "traits": {"plan": "pro"}})),))
            cur.execute("SELECT flagsmith.evaluate_context(%s::json, false)",
                        (json.dumps(dict(ctx, identity={"identifier": "u2", "traits": {"age": 70}})),))
            cand = ctx_all_operators(key)
            cand["features"]["f1"]["enabled"] = True
            cur.execute("SELECT flagsmith.load_candidate(%s::json, %s)", (json.dumps(cand), key))
            cand_sid = cur.fetchone()[0]
            cur.execute("SELECT * FROM flagsmith.plan(%s, %s, 'pgfs_trojan.users')", (key, cand_sid))
            cur.execute("SELECT * FROM flagsmith.cohort_overlap(%s, %s, 'pgfs_trojan.users')", (sid, cand_sid))
            cur.execute("SELECT flagsmith.track_exposure('mv', 'u1', 'a', env => %s)", (key,))
            cur.execute("SELECT flagsmith.track_variant('mv', 'u1', '{}', %s)", (key,))
            cur.execute("SELECT * FROM flagsmith.events_claim(%s, 100)", (key,))
            cur.execute("SELECT * FROM flagsmith.health()")
            cur.execute("SELECT * FROM flagsmith.event_status()")
            cur.execute("SELECT * FROM flagsmith.sync_status()")
            cur.execute(f"SELECT flagsmith.pin(%s, {sid})", (key,))
            cur.execute("SELECT flagsmith.unpin(%s)", (key,))
            cur.execute("SELECT flagsmith.recompile(%s)", (key,))
            cur.execute("SELECT flagsmith.gc()")
            # and evaluation, as a reader
            cur.execute(f"SET LOCAL ROLE {roles.names['reader']}")
            for ident, traits in IDENTITIES:
                t = json.dumps(traits)
                cur.execute(f"SELECT * FROM flagsmith_c.flags_{alias}(%s, %s::jsonb)", (ident, t))
                cur.execute(f"SELECT * FROM flagsmith_c.flag_{alias}('mv', %s, %s::jsonb)", (ident, t))
                cur.execute("SELECT * FROM flagsmith.get_flags(%s, %s::jsonb, %s)", (ident, t, key))
                cur.execute("SELECT * FROM flagsmith.get_segments(%s, %s::jsonb, %s)", (ident, t, key))
                cur.execute("SELECT flagsmith.variant('mv', %s, %s::jsonb, %s)", (ident, t, key))
                cur.execute("SELECT flagsmith.value('f1', %s, %s::jsonb, %s)", (ident, t, key))
            cur.execute("RESET ROLE")
            cur.execute(f"SET LOCAL ROLE {roles.names['planner']}")
            cur.execute("SELECT * FROM flagsmith.plan(%s, %s, 'pgfs_trojan.users')", (key, cand_sid))
        finally:
            cur.execute("ROLLBACK")


# ---------------------------------------------------------------------------
# hostile configuration: names and values that look like SQL never become SQL
# ---------------------------------------------------------------------------

HOSTILE = ["'; DROP TABLE public.pgfs_canary; --", "$$", "$f$ $q$ $t$", "a\\b\\'c", "é\"q ",
           "-- comment", "/* open", "*/", "'@@ENVKEY@@'", "@@ENVKEY@@", "%s %L %I %%", "line\nbreak",
           "x" * 200, "E'\\x41'", "); END; DROP TABLE public.pgfs_canary; BEGIN ATOMIC SELECT (", "\t"]


def hostile_context() -> dict:
    # an environment key with a backslash and a quote: quote_literal renders it as E'...'
    env_key = "env\\'k$$"
    segments, features = {}, {}
    for i, h in enumerate(HOSTILE):
        features[h] = {"key": h, "name": h, "enabled": i % 2 == 0, "value": h, "metadata": {h: h},
                       "variants": [{"value": h, "weight": 50, "priority": 1, "key": h},
                                    {"value": {"k": h}, "weight": 25, "priority": 2}] if i % 3 == 0 else []}
        segments[h] = {"key": h, "name": h, "rules": [{"type": "ANY", "conditions": [
            {"operator": "EQUAL", "property": h, "value": h},
            {"operator": "IN", "property": "plan", "value": f"{h},pro"},
            {"operator": "EQUAL", "property": "$.identity.key", "value": h},
            {"operator": "CONTAINS", "property": "$.identity.identifier", "value": h[:3] or "x"},
            {"operator": "PERCENTAGE_SPLIT", "property": h, "value": "40"},
        ]}], "overrides": [{"key": h, "name": HOSTILE[(i + 1) % len(HOSTILE)], "enabled": True,
                            "value": h, "priority": i % 4}]}
    return {"environment": {"key": env_key, "name": "hostile'; --"}, "features": features, "segments": segments}


def test_hostile_configuration_is_data_not_code(conn):
    ctx = hostile_context()
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE IF NOT EXISTS public.pgfs_canary (x int)")
        cur.execute("""SELECT count(*) FROM pg_proc WHERE pronamespace NOT IN
                       ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)""")
        procs_before = cur.fetchone()[0]
        try:
            for ident, traits in [("u1", {}), ("'; --", {"plan": "pro"}), (HOSTILE[0], {h: h for h in HOSTILE}),
                                  ("@@ENVKEY@@", {HOSTILE[3]: HOSTILE[3], "plan": HOSTILE[8]}),
                                  ("someone", {"plan": "pro"})]:
                full = dict(ctx, identity={"identifier": ident, "traits": traits})
                want = get_evaluation_result(json.loads(json.dumps(full)))
                for compiled in (True, False):
                    cur.execute("SELECT flagsmith.evaluate_context(%s::json, %s)::text", (json.dumps(full), compiled))
                    got = json.loads(cur.fetchone()[0])
                    d = diff(want, got)
                    assert not d, (ident, compiled, d[:5])
            # the compiled tier really was used
            cur.execute("""SELECT bool_or(compiled) FROM flagsmith.snapshot s
                           WHERE s.env_key = '__pg_flagsmith_test__' AND s.ctx_env_key = %s""",
                        (ctx["environment"]["key"],))
            assert cur.fetchone()[0] is True
            cur.execute("SELECT to_regclass('public.pgfs_canary') IS NOT NULL")
            assert cur.fetchone()[0]
            cur.execute("""SELECT count(*) FROM pg_proc WHERE pronamespace NOT IN
                           ('pg_catalog'::regnamespace, 'information_schema'::regnamespace, 'flagsmith_c'::regnamespace)""")
            assert cur.fetchone()[0] <= procs_before
        finally:
            cur.execute("SELECT flagsmith.drop_test_snapshots()")
            cur.execute("DROP TABLE IF EXISTS public.pgfs_canary")


def test_pinned_routines_run_inside_parallel_workers(conn, env):
    with conn.cursor() as cur:
        v = int(cur.execute("SHOW server_version_num").fetchone()[0])
        guc = "debug_parallel_query" if v >= 160000 else "force_parallel_mode"
        cur.execute("BEGIN")
        try:
            cur.execute(f"SET LOCAL {guc} = on")
            cur.execute("SET LOCAL max_parallel_workers_per_gather = 2")
            cur.execute(f"""SELECT count(*), count(*) FILTER (WHERE f.variant IS NOT NULL)
                            FROM generate_series(1, 500) g,
                                 LATERAL flagsmith_c.flags_{env['alias']}('u' || g, '{{"age": 30, "plan": "pro"}}') f""")
            total, variants = cur.fetchone()
            assert total == 500 * 6 and variants > 0
            cur.execute(f"EXPLAIN SELECT count(*) FROM generate_series(1, 500) g, "
                        f"LATERAL flagsmith_c.flags_{env['alias']}('u' || g, '{{}}') f")
            assert any("Gather" in r[0] for r in cur.fetchall())
        finally:
            cur.execute("ROLLBACK")
