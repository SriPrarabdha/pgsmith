"""The SQL mapper (flagsmith.map_environment_document) against the official
Python SDK's mapper, and against the mapper test case of engine-test-data.

  * differential: random environment documents, valid and damaged, through both
    mappers: both must fail, or both must give the same context, key order and
    JSON types included;
  * engine-test-data's mapper case (pinned commit): same context up to the
    documented SDK-version differences, and the same evaluation;
  * the live documents of the local Flagsmith (when demos/.env is present).

    PGSMITH_MAPPER_EXAMPLES=2000 pytest tests/sql/test_mapper.py
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import pathlib
import urllib.request
import uuid

import json5
import pytest
from flag_engine.engine import get_evaluation_result
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from tools.pgsmith.sync import document_to_load_args, dumps

N = int(os.environ.get("PGSMITH_MAPPER_EXAMPLES", "300"))
ROOT = pathlib.Path(__file__).resolve().parents[2]

# engine-test-data: "Add mapper test cases for environment document to evaluation context conversion"
MAPPER_COMMIT = "c2748d4bafe9a7fbbaed454e9362185f20b20e8b"
MAPPER_CASE = "mapper_test_cases/test_mapper__complete_environment__expected_context.jsonc"
MAPPER_PIN = ROOT / "tests" / "mapper_case.sha256"


def ordered(v):
    """Order- and type-strict form of a JSON value (json.loads semantics for duplicate keys)."""
    if isinstance(v, bool):
        return ("bool", v)
    if isinstance(v, int):
        return ("int", v)
    if isinstance(v, float):
        return ("float", v)
    if isinstance(v, str):
        return ("str", v)
    if v is None:
        return ("null",)
    if isinstance(v, list):
        return ("list", tuple(ordered(x) for x in v))
    return ("dict", tuple((k, ordered(x)) for k, x in v.items()))


def sql_map(cur, doc_text: str):
    cur.execute("SELECT context::text, identity_overrides::text, source_rev "
                "FROM flagsmith.map_environment_document(%s::json)", (doc_text,))
    c, i, r = cur.fetchone()
    return json.loads(c), json.loads(i), r


def py_map(doc: dict):
    c, i, r = document_to_load_args(doc)
    return json.loads(c), json.loads(i), r


# ---------------------------------------------------------------------------
# documents
# ---------------------------------------------------------------------------

text = st.text(st.characters(blacklist_categories=("Cs",), blacklist_characters="\x00"), max_size=6)
scalar = st.one_of(st.none(), st.booleans(), st.integers(-5, 2**70), text,
                   st.sampled_from([0.5, 33.3, 1e16, -0.0, 2.5, 100.0, 1e-7]))
names = st.sampled_from(["f1", "f2", "f3", "é ü", "7", "true", "null", 7, 42, 2.5, True, None])


def uuid_spelling(draw) -> str:
    u = uuid.UUID(int=draw(st.integers(0, 2**128 - 1)))
    form = draw(st.sampled_from(["plain", "upper", "braces", "urn", "hex"]))
    return {"plain": str(u), "upper": str(u).upper(), "braces": "{" + str(u) + "}",
            "urn": "urn:uuid:" + str(u), "hex": u.hex}[form]


@st.composite
def mv_value(draw):
    d = {"multivariate_feature_option": {"value": draw(scalar)},
         "percentage_allocation": draw(st.sampled_from([30.0, 70, 0, 33.3, 50.0, 25.0, 100]))}
    if draw(st.booleans()):
        d["multivariate_feature_option"]["key"] = draw(st.one_of(st.none(), text))
    idc = draw(st.sampled_from(["int", "zero", "none", "missing"]))
    if idc == "int":
        d["id"] = draw(st.integers(1, 10**6))
    elif idc == "zero":
        d["id"] = 0
    elif idc == "none":
        d["id"] = None
    if idc != "int" or draw(st.booleans()):
        d["mv_fs_value_uuid"] = uuid_spelling(draw)
    return d


@st.composite
def feature_state(draw, identity=False):
    d = {"feature": {"id": draw(st.integers(1, 9)), "name": draw(names), "type": "STANDARD"},
         "enabled": draw(st.booleans()), "feature_state_value": draw(scalar),
         "featurestate_uuid": str(uuid.UUID(int=draw(st.integers(0, 2**128 - 1))))}
    dj = draw(st.sampled_from(["int", "zero", "none", "missing"]))
    if dj != "missing":
        d["django_id"] = {"int": draw(st.integers(1, 999)), "zero": 0, "none": None}[dj]
    if not identity:
        fsg = draw(st.sampled_from(["none", "prio", "missing", "empty"]))
        if fsg != "missing":
            d["feature_segment"] = {"none": None, "prio": {"priority": draw(st.integers(-2, 5))}, "empty": {}}[fsg]
        mv = draw(st.sampled_from(["empty", "some", "missing"]))
        if mv != "missing":
            d["multivariate_feature_state_values"] = draw(st.lists(mv_value(), max_size=3)) if mv == "some" else []
        md = draw(st.sampled_from(["missing", "none", "empty", "exp", "expnull", "other"]))
        if md != "missing":
            d["metadata"] = {"none": None, "empty": {}, "exp": {"experiment": {"id": 3, "name": "x"}},
                             "expnull": {"experiment": None}, "other": {"k": 1}}[md]
    return d


@st.composite
def rules(draw, depth=0):
    out = []
    for _ in range(draw(st.integers(0, 2 if depth else 3))):
        r = {"type": draw(st.sampled_from(["ALL", "ANY", "NONE"]))}
        if draw(st.integers(0, 4)):
            conds = []
            for _ in range(draw(st.integers(0, 3))):
                c = {"operator": draw(st.sampled_from(["EQUAL", "IN", "REGEX", "PERCENTAGE_SPLIT"])),
                     "value": draw(scalar)}
                p = draw(st.sampled_from(["missing", "none", "empty", "trait", "path"]))
                if p != "missing":
                    c["property_"] = {"none": None, "empty": "", "trait": "plan", "path": "$.identity.key"}[p]
                conds.append(c)
            r["conditions"] = conds
        if depth < 2 and draw(st.integers(0, 3)):
            r["rules"] = draw(rules(depth + 1))
        out.append(r)
    return out


@st.composite
def document(draw):
    segs = []
    for _ in range(draw(st.integers(0, 3))):
        s = {"id": draw(st.one_of(st.integers(1, 5), st.sampled_from(["s1", 2.5]))), "name": draw(text),
             "rules": draw(rules())}
        fs = draw(st.sampled_from(["missing", "none", "empty", "some"]))
        if fs != "missing":
            s["feature_states"] = draw(st.lists(feature_state(), max_size=3)) if fs == "some" else \
                {"none": None, "empty": []}[fs]
        segs.append(s)
    doc = {"api_key": draw(text), "name": draw(text),
           "project": {"id": 1, "name": "p", "segments": segs},
           "feature_states": draw(st.lists(feature_state(), max_size=4))}
    io = draw(st.sampled_from(["missing", "none", "empty", "some"]))
    if io != "missing":
        doc["identity_overrides"] = {"none": None, "empty": []}.get(io) if io != "some" else [
            {"identifier": draw(st.one_of(text, st.sampled_from(["user42", "007", 7]))),
             "identity_features": draw(st.lists(feature_state(identity=True), max_size=2))}
            for _ in range(draw(st.integers(1, 3)))]
    ua = draw(st.sampled_from(["missing", "none", "empty", "iso", "int"]))
    if ua != "missing":
        doc["updated_at"] = {"none": None, "empty": "", "iso": "2026-11-23T19:10:40.553950+00:00", "int": 5}[ua]
    return doc


def _slots(v, out):
    """Every (container, key) in a JSON value."""
    if isinstance(v, dict):
        for k in list(v):
            out.append((v, k))
            _slots(v[k], out)
    elif isinstance(v, list):
        for i in range(len(v)):
            out.append((v, i))
            _slots(v[i], out)
    return out


@st.composite
def damaged_document(draw):
    """A document with one random structural change: a key removed or a value of another type."""
    doc = draw(document())
    slots = _slots(doc, [])
    if slots:
        container, k = slots[draw(st.integers(0, len(slots) - 1))]
        if isinstance(container, dict) and draw(st.booleans()):
            del container[k]
        else:
            container[k] = draw(st.sampled_from([None, 5, "abc", "", {}, {"k": 1}, [1], [], True, 0]))
    return doc


def _compare(cur, doc):
    doc_text = json.dumps(doc, ensure_ascii=False)
    try:
        want = py_map(json.loads(doc_text))
        py_err = None
    except Exception as e:  # noqa: BLE001 - any exception means "the SDK cannot load this"
        want, py_err = None, e
    cur.execute("SAVEPOINT m")
    try:
        got = sql_map(cur, doc_text)
        sql_err = None
        cur.execute("RELEASE SAVEPOINT m")
    except Exception as e:  # noqa: BLE001
        cur.execute("ROLLBACK TO SAVEPOINT m")
        got, sql_err = None, e
    assert (py_err is None) == (sql_err is None), \
        f"python: {py_err!r}\nsql: {sql_err!r}\ndocument: {doc_text}"
    if py_err is None:
        for part, w, g in zip(("context", "identity_overrides", "source_rev"), want, got):
            assert ordered(w) == ordered(g), f"{part} differs\npython: {w}\nsql:    {g}\ndocument: {doc_text}"


@pytest.fixture()
def tx(conn):
    """A cursor inside a transaction (savepoints isolate expected errors)."""
    with conn.cursor() as cur:
        cur.execute("BEGIN")
        yield cur
        cur.execute("ROLLBACK")


@settings(max_examples=N, deadline=None, suppress_health_check=list(HealthCheck), derandomize=True)
@given(doc=document())
def test_mapper_matches_sdk(tx, doc):
    _compare(tx, doc)


@settings(max_examples=N, deadline=None, suppress_health_check=list(HealthCheck), derandomize=True)
@given(doc=damaged_document())
def test_mapper_fails_where_sdk_fails(tx, doc):
    _compare(tx, doc)


# ---------------------------------------------------------------------------
# engine-test-data's mapper test case
# ---------------------------------------------------------------------------

def _mapper_case() -> dict:
    cache = ROOT / "tests" / ".cache" / f"mapper-{MAPPER_COMMIT[:12]}.jsonc"
    if not cache.exists():
        url = f"https://raw.githubusercontent.com/Flagsmith/engine-test-data/{MAPPER_COMMIT}/{MAPPER_CASE}"
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_bytes(urllib.request.urlopen(url, timeout=60).read())
    data = cache.read_bytes()
    assert hashlib.sha256(data).hexdigest() == MAPPER_PIN.read_text().strip(), "mapper case changed upstream"
    return json.loads(json.dumps(json5.loads(data.decode())))


# The case predates SDK 6.7 and was written for a draft mapper; these are the
# documented, evaluation-neutral differences, normalised away below:
#   * its mv_fs_value_uuid values ("xxxxxxxx-...") are not hexadecimal: the SDK
#     raises on them; they are replaced by valid UUIDs in the same order;
#   * variant priorities: the case numbers id-less variants by UUID order, the SDK
#     uses the UUID's integer value: compared as ranks;
#   * the identity-override segment: the case keeps it in "segments" (key "",
#     source "identity_override", priority "-INF"); the SDK keeps it apart, keyed by
#     identifier (key "identity_overrides", source "identity_overrides", -inf);
#   * optional fields: the case writes "priority": null, "variants": [],
#     "rules": null, "identity": null where the SDK leaves the key out;
#   * segment dict keys: the case uses positions, the SDK str(segment id).
UUID_FIX = {"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx": "33333333-3333-3333-3333-333333333333",
            "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy": "44444444-4444-4444-4444-444444444444",
            "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz": "55555555-5555-5555-5555-555555555555"}


def _fix_doc(doc: dict) -> dict:
    s = json.dumps(doc)
    for a, b in UUID_FIX.items():
        s = s.replace(a, b)
    return json.loads(s)


def _norm_fc(fc: dict) -> dict:
    fc = dict(fc)
    fc.setdefault("priority", None)
    vs = fc.get("variants") or []
    order = sorted(range(len(vs)), key=lambda i: vs[i]["priority"])
    fc["variants"] = [dict(v, priority=order.index(i)) for i, v in enumerate(vs)]
    if fc.get("priority") in ("-INF", "-Infinity"):
        fc["priority"] = "-inf"
    return fc


def _norm_rules(rs):
    return [{"type": r["type"], "conditions": r.get("conditions") or [], "rules": _norm_rules(r.get("rules") or [])}
            for r in rs or []]


def _norm_api_segment(s: dict) -> dict:
    return {"key": s["key"], "name": s["name"], "rules": _norm_rules(s["rules"]),
            "overrides": [_norm_fc(o) for o in s["overrides"]], "metadata": s.get("metadata")}


def test_engine_test_data_mapper_case(conn):
    case = _mapper_case()
    doc = _fix_doc(case["environment_document"])
    exp = case["expected_evaluation_context"]
    with conn.cursor() as cur:
        ctx, io, _ = sql_map(cur, json.dumps(doc))
    # the SDK's own mapper agrees with the SQL one exactly
    py = py_map(doc)
    assert ordered(py[0]) == ordered(ctx) and ordered(py[1]) == ordered(io)

    assert ctx["environment"] == exp["environment"]
    assert {k: _norm_fc(v) for k, v in ctx["features"].items()} == \
           {k: _norm_fc(v) for k, v in exp["features"].items()}
    exp_api = [s for s in exp["segments"].values() if (s.get("metadata") or {}).get("source") == "api"]
    exp_io = [s for s in exp["segments"].values() if (s.get("metadata") or {}).get("source") != "api"]
    assert [_norm_api_segment(s) for s in ctx["segments"].values()] == [_norm_api_segment(s) for s in exp_api]
    assert len(exp_io) == len(io) == 1
    (identifier, got_io), = io.items()
    assert got_io["rules"][0]["conditions"] == exp_io[0]["rules"][0]["conditions"] == [
        {"property": "$.identity.identifier", "operator": "IN", "value": [identifier]}]
    assert [_norm_fc(o) for o in got_io["overrides"]] == [_norm_fc(o) for o in exp_io[0]["overrides"]]


def _engine_ctx(exp: dict, identifier: str, traits: dict) -> dict:
    """The case's expected context as the Python engine takes it, for one identity."""
    ctx = copy.deepcopy(exp)
    ctx.pop("identity", None)
    segs = {}
    for k, s in ctx["segments"].items():
        if (s.get("metadata") or {}).get("source") != "api":
            ids = s["rules"][0]["conditions"][0]["value"]
            if identifier not in ids:
                continue
            for o in s["overrides"]:
                o["priority"] = float("-inf")
        for r in s["rules"]:
            if r.get("rules") is None:
                r["rules"] = []
        segs[k] = s
    ctx["segments"] = segs
    for f in ctx["features"].values():
        if f.get("priority") is None:
            f.pop("priority", None)
    ctx["identity"] = {"identifier": identifier, "key": f"{ctx['environment']['key']}_{identifier}", "traits": traits}
    return ctx


def test_engine_test_data_mapper_case_evaluates_the_same(conn):
    """Loaded through the SQL mapper, the case's document evaluates as the
    reference engine evaluates the case's expected context."""
    case = _mapper_case()
    doc = _fix_doc(case["environment_document"])
    exp = case["expected_evaluation_context"]
    with conn.cursor() as cur:
        cur.execute("BEGIN")
        try:
            cur.execute("SELECT snapshot_id FROM flagsmith.load_document(%s::json, 'test')", (json.dumps(doc),))
            sid = cur.fetchone()[0]
            for identifier in ["overridden-id", "user-1", "user-2", "alice", "007", "x" * 40] + \
                              [f"u{i}" for i in range(200)]:
                traits = {"foo": "bar"} if identifier.endswith("1") else {}
                want = get_evaluation_result(_engine_ctx(exp, identifier, traits))["flags"]
                cur.execute("SELECT feature, enabled, value, variant, reason "
                            "FROM flagsmith.get_flags(%s, %s::jsonb, snapshot_id => %s)",
                            (identifier, json.dumps(traits), sid))
                got = {r[0]: r[1:] for r in cur.fetchall()}
                for name, f in want.items():
                    assert got[name] == (f["enabled"], f["value"], f.get("variant"), f["reason"]), (identifier, name)
        finally:
            cur.execute("ROLLBACK")


# ---------------------------------------------------------------------------
# the live documents of the local Flagsmith
# ---------------------------------------------------------------------------

def _local_docs() -> list[dict]:
    env = ROOT / "demos" / ".env"
    if not env.exists():
        return []
    vals = dict(line.split("=", 1) for line in env.read_text().splitlines() if "=" in line and not line.startswith("#"))
    from tools.pgsmith.sync import fetch_document
    docs = []
    for k in ("PROD_SERVER_KEY", "STAGING_SERVER_KEY"):
        try:
            docs.append(fetch_document(vals["FLAGSMITH_API_URL"], vals[k], timeout=5))
        except Exception:  # noqa: BLE001 - the stack is optional
            return []
    return docs


def test_live_documents_map_and_load_like_the_pusher(conn):
    docs = _local_docs()
    if not docs:
        pytest.skip("local Flagsmith not running (demos/.env)")
    with conn.cursor() as cur:
        cur.execute("BEGIN")
        try:
            for doc in docs:
                _compare(cur, doc)
                # SQL-mapped and SDK-mapped loads evaluate identically
                ctx, io, rev = document_to_load_args(doc)
                cur.execute("SELECT flagsmith.load_context(%s::json, kind => 'test', identity_overrides => %s::json)",
                            (ctx, io))
                py_sid = cur.fetchone()[0]
                m = sql_map(cur, json.dumps(doc))
                cur.execute("SELECT flagsmith.load_context(%s::json, kind => 'test', identity_overrides => %s::json)",
                            (dumps(m[0]) + " ", dumps(m[1])))
                sql_sid = cur.fetchone()[0]
                assert sql_sid != py_sid
                for i in range(300):
                    ident = ["user42", "vip-1", "007"][i] if i < 3 else f"user-{i}"
                    traits = json.dumps({"plan": ["pro", "free", "team"][i % 3], "country": ["IN", "US"][i % 2],
                                         "app_version": "3.1.0", "beta": i % 5 == 0})
                    q = ("SELECT feature, enabled, value, variant, reason FROM flagsmith.get_flags(%s, %s, "
                         "snapshot_id => %s) ORDER BY feature")
                    a = cur.execute(q, (ident, traits, py_sid)).fetchall()
                    b = cur.execute(q, (ident, traits, sql_sid)).fetchall()
                    assert a == b
        finally:
            cur.execute("ROLLBACK")
