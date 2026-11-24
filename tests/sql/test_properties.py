"""Properties that must always hold: idempotent loads, atomic reloads, prepared
statements following reloads, monotone splits, the pin, policies, security."""
from __future__ import annotations

import copy
import json
import threading
import uuid

import psycopg
import pytest

from tests.conftest import DSN


def ctx_with(env_key: str, enabled: bool, n_features: int = 20, split: str = "50") -> dict:
    return {
        "environment": {"key": env_key, "name": f"props {env_key}"},
        "features": {
            f"f{i}": {"key": str(100 + i), "name": f"f{i}", "enabled": enabled,
                      "value": "on" if enabled else "off"}
            for i in range(n_features)
        },
        "segments": {
            "1": {"key": "1", "name": "split", "rules": [{"type": "ALL", "conditions": [
                {"operator": "PERCENTAGE_SPLIT", "property": "", "value": split}]}],
                  "overrides": [{"key": "900", "name": "f0", "enabled": True, "value": "split", "priority": 0}]},
        },
    }


@pytest.fixture()
def env_key():
    return "props_" + uuid.uuid4().hex[:10]


def load(cur, ctx, **kw):
    args = ", ".join(f"{k} => %({k})s" for k in kw)
    cur.execute(f"SELECT flagsmith.load_context(%(ctx)s::json{', ' + args if args else ''})",
                {"ctx": json.dumps(ctx), **kw})
    return cur.fetchone()[0]


def test_idempotent_load(cur, env_key):
    a = load(cur, ctx_with(env_key, True))
    b = load(cur, ctx_with(env_key, True))
    assert a == b
    cur.execute("SELECT outcome FROM flagsmith.load_log WHERE env_key = %s ORDER BY load_id", (env_key,))
    assert [r[0] for r in cur.fetchall()] == ["loaded", "unchanged"]


def test_reload_back_to_previous_content_reuses_snapshot(cur, env_key):
    a = load(cur, ctx_with(env_key, True))
    b = load(cur, ctx_with(env_key, False))
    c = load(cur, ctx_with(env_key, True))
    assert a == c != b
    cur.execute("SELECT current_snapshot FROM flagsmith.environment WHERE env_key = %s", (env_key,))
    assert cur.fetchone()[0] == a


@pytest.mark.parametrize("tier", ["interpreter", "compiled"])
def test_atomic_reloads(env_key, tier):
    """A reader looping during 200 reloads never sees flags from two snapshots in one call."""
    with psycopg.connect(DSN, autocommit=True) as w:
        load(w.cursor(), ctx_with(env_key, True))
        w.execute("SELECT alias FROM flagsmith.environment WHERE env_key = %s", (env_key,))
        alias = w.execute("SELECT alias FROM flagsmith.environment WHERE env_key = %s", (env_key,)).fetchone()[0]
    stop = threading.Event()
    seen, errors = set(), []
    q = (f"SELECT array_agg(f.enabled) FROM flagsmith.get_flags('u1', '{{}}', %s) f" if tier == "interpreter"
         else f"SELECT array_agg(f.enabled) FROM flagsmith_c.flags_{alias}('u1', '{{}}') f")

    def reader():
        with psycopg.connect(DSN, autocommit=True) as r:
            while not stop.is_set():
                try:
                    row = r.execute(q, (env_key,) if tier == "interpreter" else None).fetchone()[0]
                except psycopg.errors.UndefinedFunction:
                    continue
                states = set(row[1:])  # f0 has a split override
                if len(states) != 1:
                    errors.append(row)
                seen.update(states)

    t = threading.Thread(target=reader)
    t.start()
    with psycopg.connect(DSN, autocommit=True) as w:
        cur = w.cursor()
        for i in range(200):
            load(cur, ctx_with(env_key, i % 2 == 1))
    stop.set()
    t.join()
    assert errors == []
    assert seen == {True, False}


def test_prepared_statement_follows_reload(env_key):
    with psycopg.connect(DSN, autocommit=True) as c:
        cur = c.cursor()
        load(cur, ctx_with(env_key, True))
        alias = cur.execute("SELECT alias FROM flagsmith.environment WHERE env_key = %s", (env_key,)).fetchone()[0]
        c.execute(f"PREPARE p AS SELECT f.enabled FROM flagsmith_c.flag_{alias}('f5', 'u1', '{{}}') f")
        for _ in range(6):  # past the plan cache's custom-plan threshold
            assert c.execute("EXECUTE p").fetchone()[0] is True
        load(cur, ctx_with(env_key, False))
        assert c.execute("EXECUTE p").fetchone()[0] is False
        c.execute("DEALLOCATE p")


def test_monotone_splits(cur, env_key):
    """Raising a split threshold never removes a member (Flagsmith documents this)."""
    members = {}
    for thr in ["10", "33.3", "50", "50.5", "99"]:
        load(cur, ctx_with(env_key, True, split=thr))
        cur.execute("""SELECT array_agg(i) FROM generate_series(1, 3000) i,
                         LATERAL flagsmith.get_flags('id' || i, '{}', %s) f
                       WHERE f.feature = 'f0' AND f.reason LIKE 'TARGETING%%'""", (env_key,))
        members[thr] = set(cur.fetchone()[0] or [])
    ordered = [members[t] for t in ["10", "33.3", "50", "50.5", "99"]]
    for small, big in zip(ordered, ordered[1:]):
        assert small <= big
    assert 0 < len(ordered[0]) < len(ordered[-1]) < 3000


def test_deterministic_across_sessions(env_key):
    with psycopg.connect(DSN, autocommit=True) as a, psycopg.connect(DSN, autocommit=True) as b:
        load(a.cursor(), ctx_with(env_key, True))
        q = "SELECT array_agg(row(f.*)::text ORDER BY f.feature) FROM flagsmith.get_flags('alice', '{}', %s) f"
        assert a.execute(q, (env_key,)).fetchone() == b.execute(q, (env_key,)).fetchone()


def test_pin_and_unpin(cur, env_key):
    a = load(cur, ctx_with(env_key, True))
    b = load(cur, ctx_with(env_key, False))
    cur.execute("SELECT flagsmith.pin(%s, %s)", (env_key, a))
    cur.execute("SELECT status FROM flagsmith.health() WHERE env_key = %s", (env_key,))
    assert cur.fetchone()[0] == "pinned"
    # a sync load while pinned is stored but not served
    c = load(cur, ctx_with(env_key, False, n_features=3))
    cur.execute("SELECT count(*) FILTER (WHERE enabled), count(*) FROM flagsmith.get_flags('u', '{}', %s)", (env_key,))
    assert cur.fetchone() == (20, 20)
    cur.execute("SELECT flagsmith.unpin(%s)", (env_key,))
    assert cur.fetchone()[0] == c
    cur.execute("SELECT count(*) FROM flagsmith.get_flags('u', '{}', %s)", (env_key,))
    assert cur.fetchone()[0] == 3


def test_reject_policy_keeps_previous_snapshot(cur, env_key):
    good = load(cur, ctx_with(env_key, True))
    bad = ctx_with(env_key, False)
    bad["segments"]["2"] = {"key": "2", "name": "atomic", "rules": [{"type": "ALL", "conditions": [
        {"operator": "REGEX", "property": "email", "value": "(?>a+)b"}]}]}
    with pytest.raises(psycopg.errors.RaiseException, match="regex_policy"):
        load(cur, bad)
    cur.execute("SELECT current_snapshot FROM flagsmith.environment WHERE env_key = %s", (env_key,))
    assert cur.fetchone()[0] == good
    cur.execute("UPDATE flagsmith.environment SET regex_policy = 'approximate' WHERE env_key = %s", (env_key,))
    sid = load(cur, bad)
    cur.execute("SELECT code FROM flagsmith.snapshot_warning WHERE snapshot_id = %s", (sid,))
    assert ("regex_approximate",) in cur.fetchall()


def test_gc_keeps_recent_snapshots(cur, env_key):
    load(cur, ctx_with(env_key, True))
    cur.execute("UPDATE flagsmith.environment SET keep_snapshots = 3, gc_grace = '0 seconds' WHERE env_key = %s", (env_key,))
    for i in range(8):
        load(cur, ctx_with(env_key, i % 2 == 0, n_features=5 + i))
    cur.execute("SELECT count(*) FROM flagsmith.snapshot WHERE env_key = %s AND kind = 'live'", (env_key,))
    assert cur.fetchone()[0] == 3
    cur.execute("""SELECT count(*) FROM pg_proc p JOIN flagsmith.snapshot s ON p.proname = 'flags_s' || s.snapshot_id
                   WHERE s.env_key = %s""", (env_key,))
    assert cur.fetchone()[0] == 3


def test_hostile_values_compile_into_literals(cur, env_key):
    hostile = "'); DROP TABLE flagsmith.environment; --"
    ctx = ctx_with(env_key, True)
    ctx["segments"]["3"] = {"key": hostile, "name": hostile, "rules": [{"type": "ALL", "conditions": [
        {"operator": "EQUAL", "property": hostile, "value": hostile},
        {"operator": "IN", "property": "x", "value": hostile + ",$$,\\"}]}],
        "overrides": [{"key": hostile, "name": "f1", "enabled": False, "value": hostile, "priority": 1}]}
    ctx["features"]["f1"]["metadata"] = {"x": hostile}
    sid = load(cur, ctx)
    cur.execute("SELECT compiled FROM flagsmith.snapshot WHERE snapshot_id = %s", (sid,))
    assert cur.fetchone()[0] is True
    alias = cur.execute("SELECT alias FROM flagsmith.environment WHERE env_key = %s", (env_key,)).fetchone()[0]
    cur.execute(f"SELECT f.value, f.reason FROM flagsmith_c.flag_{alias}('f1', 'u', %s::jsonb) f",
                (json.dumps({hostile: hostile, "x": "$$"}),))
    assert cur.fetchone() == (hostile, f"TARGETING_MATCH; segment={hostile}")
    cur.execute("SELECT count(*) FROM flagsmith.environment")
    assert cur.fetchone()[0] >= 1


def test_reader_role_cannot_read_tables(cur, env_key):
    load(cur, ctx_with(env_key, True))
    alias = cur.execute("SELECT alias FROM flagsmith.environment WHERE env_key = %s", (env_key,)).fetchone()[0]
    role = "pgfs_app_" + uuid.uuid4().hex[:6]
    cur.execute(f"CREATE ROLE {role} LOGIN PASSWORD 'x' IN ROLE flagsmith_reader")
    cur.execute(f"GRANT {role} TO CURRENT_USER")  # PG 16+: CREATEROLE alone does not allow SET ROLE
    try:
        cur.execute(f"SET ROLE {role}")
        cur.execute(f"SELECT count(*) FROM flagsmith_c.flags_{alias}('u', '{{}}')")
        assert cur.fetchone()[0] == 20
        cur.execute("SELECT count(*) FROM flagsmith.get_flags('u', '{}', %s)", (env_key,))
        assert cur.fetchone()[0] == 20
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            cur.execute("SELECT * FROM flagsmith.snapshot")
        cur.execute("RESET ROLE")
        cur.execute(f"SET ROLE {role}")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            cur.execute("SELECT flagsmith.load_context('{}'::json, 'x')")
    finally:
        cur.execute("RESET ROLE")
        cur.execute(f"DROP ROLE {role}")


def test_identity_overrides_like_the_sdk(cur, env_key):
    """identity_overrides in the SDK's shape: present only for their identity, priority -inf."""
    from flag_engine.engine import get_evaluation_result

    ctx = ctx_with(env_key, False, n_features=4)
    # a segment everyone matches, overriding the same feature at priority 0: the identity
    # override (priority -inf) must still win
    ctx["segments"]["9"] = {"key": "9", "name": "everyone", "rules": [{"type": "ALL", "conditions": [
        {"operator": "IS_NOT_SET", "property": "zzz", "value": ""}]}],
        "overrides": [{"key": "901", "name": "f2", "enabled": False, "value": "segment", "priority": 0}]}
    io = {ident: {"key": "identity_overrides", "name": "identity_overrides",
                  "rules": [{"type": "ALL", "conditions": [
                      {"property": "$.identity.identifier", "operator": "IN", "value": [ident]}]}],
                  "overrides": [{"key": "", "name": "f2", "enabled": True, "value": f"for {ident}",
                                 "priority": float("-inf"), "metadata": {"id": 2}}],
                  "metadata": {"source": "identity_overrides"}}
          for ident in ["alice", "007", "bob"]}
    payload = json.loads(json.dumps(io).replace("-Infinity", '"-Infinity"'))
    cur.execute("SELECT flagsmith.load_context(%s::json, identity_overrides => %s::json)",
                (json.dumps(ctx), json.dumps(payload)))
    alias = cur.execute("SELECT alias FROM flagsmith.environment WHERE env_key = %s", (env_key,)).fetchone()[0]
    for ident in ["alice", "007", "bob", "carol"]:
        sdk_ctx = copy.deepcopy(ctx)
        if ident in io:
            sdk_ctx["segments"] = {**sdk_ctx["segments"], "identity_overrides": io[ident]}
        sdk_ctx["identity"] = {"identifier": ident, "traits": {}}
        want = get_evaluation_result(sdk_ctx)["flags"]
        for tier_q in [f"SELECT * FROM flagsmith.get_flags(%s, '{{}}', '{env_key}')",
                       f"SELECT * FROM flagsmith_c.flags_{alias}(%s, '{{}}')"]:
            got = {r[0]: r for r in cur.execute(tier_q, (ident,)).fetchall()}
            for name, f in want.items():
                assert (got[name][1], got[name][2], got[name][4]) == (f["enabled"], f["value"], f["reason"]), (ident, name, tier_q)


def test_flagshift_plan_and_overlap(cur, env_key):
    """plan() counts exactly the identities whose flag changes; cohort_overlap() shows that the
    same split rule in two environments selects different people."""
    live = load(cur, ctx_with(env_key, False, n_features=3, split="25"))
    cand_ctx = ctx_with(env_key, False, n_features=3, split="25")
    cand_ctx["features"]["f1"]["enabled"] = True
    cand = cur.execute("SELECT flagsmith.load_context(%s::json, kind => 'candidate', compile => true)",
                       (json.dumps(cand_ctx),)).fetchone()[0]
    other_env = ctx_with(env_key + "_stg", False, n_features=3, split="25")
    other = load(cur, other_env)
    cur.execute("CREATE TEMP TABLE pop AS SELECT 'id' || i AS identifier, '{}'::jsonb AS traits FROM generate_series(1, 4000) i")
    rows = {r[0]: r for r in cur.execute("SELECT * FROM flagsmith.plan(%s, %s, 'pop')", (env_key, cand)).fetchall()}
    assert rows["f1"][2] == 4000 and rows["f1"][3] == 4000      # everyone changes, all turned on
    assert rows["f0"][2] == 0 and rows["f2"][2] == 0
    ov = {r[0]: r for r in cur.execute("SELECT * FROM flagsmith.cohort_overlap(%s, %s, 'pop')", (other, live)).fetchall()}
    in_a, in_b, both, pct = ov["f0"][1:]
    assert 800 < in_a < 1200 and 800 < in_b < 1200                # 25% splits
    assert 10 < pct < 45                                           # different environment keys: ~25% overlap
    same = {r[0]: r for r in cur.execute("SELECT * FROM flagsmith.cohort_overlap(%s, %s, 'pop')", (live, cand)).fetchall()}
    assert same["f0"][4] == 100                                    # same keys: the same people
    cur.execute("DROP TABLE pop")
