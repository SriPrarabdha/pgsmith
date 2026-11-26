"""Differential fuzzing: random EvaluationContexts, evaluated by the official
engine (flag_engine.get_evaluation_result) and by pgsmith, must give the
same flags (enabled, value, variant, reason, metadata) and segments.

    PGSMITH_FUZZ_EXAMPLES=5000 pytest tests/fuzz/test_engine.py

Counterexamples are written to tests/fuzz/regressions/ in engine-test-data format.
"""
from __future__ import annotations

import json
import math
import os
import pathlib
import warnings

import psycopg
import pytest
from flag_engine.engine import get_evaluation_result
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from tests.strict import diff

N = int(os.environ.get("PGSMITH_FUZZ_EXAMPLES", "300"))
REGRESSIONS = pathlib.Path(__file__).resolve().parent / "regressions"

FEATURES = ["f1", "f2", "f3", "checkout"]
TRAITS = ["age", "plan", "email", "version", "score", "n", "$.identity.identifier", "x.y"]
PROPERTIES = TRAITS + [
    "$.identity.identifier", "$.identity.key", "$.identity.traits.age", "$.identity.traits['plan']",
    "$.environment.name", "$.environment.key", "$.flags.f1.enabled", "$.flags.f2.value",
    "$.flags['f3'].enabled", "$.flags.f1.variant", "$.flags.nope.enabled", "$.identity",
    "$.features.f1.value", "$.bad[", "", "$.identity.traits.age.x",
    "$.flags.checkout.metadata.id", "$['identity']",
]
OPERATORS = ["EQUAL", "NOT_EQUAL", "GREATER_THAN", "GREATER_THAN_INCLUSIVE", "LESS_THAN", "LESS_THAN_INCLUSIVE",
             "CONTAINS", "NOT_CONTAINS", "IN", "REGEX", "MODULO", "PERCENTAGE_SPLIT", "IS_SET", "IS_NOT_SET",
             "UNKNOWN_OP"]
CMP_VALUES = ["30", "30.5", "-1", "1e3", " 7 ", "1_000", "true", "False", "abc", "", "1.2.3:semver",
              "1.0.0-beta:semver", "2.0.0:semver", "1.0.0-beta.11:semver", "None", "inf", "nan", "٣", "0",
              "1.50", "007", "a@x.com", "True", "beta:semver", "é", "12345678901234567890123"]
IN_VALUES = ["a,b,c", "1,2,3", '["a",1,true,null]', "[1.0, 2]", "[bad", "x", ["a", "1"], [1, 2.5],
             "a, b", "alice,007,7", "", ["alice", "bob"], "True,1.5"]
REGEX_VALUES = ["^a", ".*@x\\.com$", "\\d+", "(?i)ABC", "a$", "[0-9]{2}", "", "(?P<n>a)(?P=n)", "\\w+",
                "x|y", "\\bfoo\\b", "1\\.5", "Tru", "(?s).*", "é"]
MOD_VALUES = ["2|0", "3|1", "2.5|0.5", "a|b", "2|", "|", "2|1|1", "-3|1", "0.1|0.1", "7|-1", "1e20|0"]
SPLIT_VALUES = ["0", "50", "100", "33.3", "x", "-1", "100.0", "0.1", "99.99"]

trait_value = st.one_of(
    st.integers(min_value=-(2**70), max_value=2**70),
    st.sampled_from([0, 1, -1, 7, 30, 2**63, 10**25]),
    st.sampled_from([0.1, 1.5, -2.5, 1e20, 1.0, 30.5, -0.0, 1e-7, 2.5e16]),
    st.booleans(),
    st.sampled_from(["30", "007", "1.50", "abc", "1.2.3", "1.0.0-beta", "", "é", "a@x.com", "True",
                     "line\nbreak", "-0", "12.0", "alice", "x,y", "1.0.0-beta.2", "2.0.0+build"]),
    st.none(),
)
priority = st.one_of(st.none(), st.integers(-3, 3), st.sampled_from([1.5, 2**64, -(2**64), 0.0, 340282366920938463463374607431768211455]))


@st.composite
def condition(draw, features):
    op = draw(st.sampled_from(OPERATORS))
    prop = draw(st.sampled_from(PROPERTIES))
    if op == "IN":
        value = draw(st.sampled_from(IN_VALUES))
    elif op == "REGEX":
        value = draw(st.sampled_from(REGEX_VALUES))
    elif op == "MODULO":
        value = draw(st.sampled_from(MOD_VALUES))
    elif op == "PERCENTAGE_SPLIT":
        value = draw(st.sampled_from(SPLIT_VALUES))
        if draw(st.booleans()):
            prop = ""
    elif op in ("IS_SET", "IS_NOT_SET"):
        value = ""
    else:
        value = draw(st.sampled_from(CMP_VALUES))
    return {"operator": op, "property": prop, "value": value}


@st.composite
def rule(draw, features, depth=0):
    r = {"type": draw(st.sampled_from(["ALL", "ANY", "NONE"])),
         "conditions": draw(st.lists(condition(features), max_size=3))}
    if depth < 2 and draw(st.booleans()):
        r["rules"] = draw(st.lists(rule(features, depth + 1), max_size=2))
    return r


@st.composite
def feature_context(draw, name, key=None, with_priority=False):
    fc = {
        "key": key or draw(st.sampled_from(["78982", "1", "f1", "seg1", "k9Tz", "x"])),
        "name": name,
        "enabled": draw(st.booleans()),
        "value": draw(st.one_of(st.none(), st.booleans(), st.sampled_from(["on", "", "12.34", 1234, 1.5]))),
    }
    if draw(st.integers(0, 3)) == 0:
        vs = []
        for _ in range(draw(st.integers(1, 3))):
            v = {"value": draw(st.sampled_from(["a", "b", 1, True, None])),
                 "weight": draw(st.sampled_from([0, 30, 50, 33.3, 100, -10, 50.5, 25])),
                 "priority": draw(st.sampled_from([1, 2, 3, 2**64, 0.5, 1]))}
            if draw(st.booleans()):
                v["key"] = draw(st.sampled_from(["control", "boosted", "v1", "v2"]))
            vs.append(v)
        fc["variants"] = vs
    if with_priority:
        p = draw(priority)
        if p is not None:
            fc["priority"] = p
    if draw(st.booleans()):
        fc["metadata"] = draw(st.sampled_from([{"id": 1}, {}, {"id": 2, "experiment": {"id": 7, "name": "e", "in_experiment": True}}]))
    return fc


@st.composite
def context(draw):
    feats = draw(st.lists(st.sampled_from(FEATURES), min_size=1, max_size=4, unique=True))
    ctx = {
        "environment": {"key": draw(st.sampled_from(["n9fbf9h3", "env", "123", "é"])),
                        "name": draw(st.sampled_from(["Test Environment", "prod", "30"]))},
        "features": {f: draw(feature_context(f)) for f in feats},
    }
    segs = {}
    for i in range(draw(st.integers(0, 4))):
        key = draw(st.sampled_from(["1", "2", "seg", "f1", "78982", "3", "4"]))
        seg = {"key": key, "name": draw(st.sampled_from(["beta", "enterprise", "seg_" + key, "s"])),
               "rules": draw(st.lists(rule(feats), max_size=2))}
        ovs = draw(st.lists(st.sampled_from(FEATURES + ["missing"]), max_size=3))
        if ovs:
            seg["overrides"] = [draw(feature_context(o, with_priority=True)) for o in ovs]
        if draw(st.booleans()):
            seg["metadata"] = draw(st.sampled_from([{"id": i, "source": "api"}, {}]))
        segs[str(i) if draw(st.booleans()) else key + str(i)] = seg
    if segs or draw(st.booleans()):
        ctx["segments"] = segs
    if draw(st.integers(0, 5)) > 0:
        ident = {"identifier": draw(st.sampled_from(["alice", "007", "123", "1.5", "é", "a b", "bob", "", "True"]))}
        if draw(st.booleans()):
            ident["key"] = draw(st.sampled_from(["k1", "", "123", "env_alice"]))
        traits = {t: draw(trait_value) for t in draw(st.lists(st.sampled_from(TRAITS), max_size=5, unique=True))}
        if traits or draw(st.booleans()):
            ident["traits"] = traits
        ctx["identity"] = ident
    return ctx


def _reference(ctx):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            res = get_evaluation_result(json.loads(json.dumps(ctx)))
        except Exception:  # the reference raises (ZeroDivisionError, re.error, ...): no parity defined
            return None
    return {"flags": res["flags"], "segments": res["segments"]}


def _has_nonfinite(o):
    if isinstance(o, float):
        return not math.isfinite(o)
    if isinstance(o, dict):
        return any(_has_nonfinite(v) for v in o.values())
    if isinstance(o, list):
        return any(_has_nonfinite(v) for v in o)
    return False


def _save(ctx, want, problems):
    REGRESSIONS.mkdir(exist_ok=True)
    body = json.dumps({"context": ctx, "result": want}, indent=2, sort_keys=False)
    name = f"test_fuzz_{abs(hash(body)) % 10**10}.jsonc"
    (REGRESSIONS / name).write_text("// " + "\n// ".join(problems[:5]) + "\n" + body)


STATS = pathlib.Path(__file__).resolve().parent / ".last_run.json"


@pytest.mark.parametrize("tier", ["interpreter", "compiled"])
def test_engine_parity(conn, tier):
    counts = {"generated": 0, "reference_raised": 0, "not_compiled": 0, "compared": 0, "flags_compared": 0}
    @settings(max_examples=N, deadline=None, suppress_health_check=list(HealthCheck), derandomize=False)
    @given(context())
    def check(ctx):
        counts["generated"] += 1
        if _has_nonfinite(ctx):
            return
        want = _reference(ctx)
        if want is None:
            counts["reference_raised"] += 1
            return
        with conn.cursor() as cur:
            try:
                cur.execute("SELECT flagsmith.evaluate_context(%s::json, %s)", (json.dumps(ctx), tier == "compiled"))
            except psycopg.errors.RaiseException as e:
                if "has no compiled code" in str(e):
                    counts["not_compiled"] += 1
                    return  # flag dependencies: served by the interpreter, fuzzed there
                raise
            got = cur.fetchone()[0]
        counts["compared"] += 1
        counts["flags_compared"] += len(want["flags"])
        problems = diff(want, got)
        if problems:
            _save(ctx, want, problems)
        assert problems == [], "\n".join(problems)

    if tier == "compiled":
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM pg_proc WHERE proname = 'compile_snapshot' AND prosrc LIKE '%%not available%%'")
            if cur.fetchone()[0]:
                pytest.skip("compiler not built")
    check()
    stats = json.loads(STATS.read_text()) if STATS.exists() else {}
    stats[tier] = counts
    STATS.write_text(json.dumps(stats, indent=2))
