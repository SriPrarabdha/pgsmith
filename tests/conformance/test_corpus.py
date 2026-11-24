"""engine-test-data conformance: every case, against the reference engine and
against both pg_flagsmith tiers."""
from __future__ import annotations

import json
import os

import psycopg
import pytest
from flag_engine.engine import get_evaluation_result

from tests import corpus
from tests.strict import diff

CASES = corpus.cases()
IDS = [p.name for p in CASES]

# case name -> reason, for cases a tier is known not to pass
EXPECTED_FAIL: dict[str, dict[str, str]] = {
    "interpreter": {},
    "compiled": {},
}


def _result(case: dict) -> dict:
    return {"flags": case["result"]["flags"], "segments": case["result"]["segments"]}


@pytest.mark.parametrize("path", CASES, ids=IDS)
def test_reference_engine_agrees_with_corpus(path):
    case = corpus.load_case(path)
    got = get_evaluation_result(case["context"])
    assert diff(_result(case), {"flags": got["flags"], "segments": got["segments"]}) == []


@pytest.mark.parametrize("tier", ["interpreter", "compiled"])
@pytest.mark.parametrize("path", CASES, ids=IDS)
def test_pg_flagsmith(cur, path, tier):
    reason = EXPECTED_FAIL[tier].get(path.name)
    if reason:
        pytest.xfail(reason)
    case = corpus.load_case(path)
    try:
        cur.execute("SELECT flagsmith.evaluate_context(%s::json, %s)",
                    (json.dumps(case["context"]), tier == "compiled"))
    except psycopg.errors.RaiseException as e:
        if "has no compiled code" in str(e):
            pytest.xfail("not compiled by design: " + str(e).split("compiled code", 1)[1].strip(" ()"))
        raise
    got = cur.fetchone()[0]
    problems = diff(_result(case), got)
    assert problems == [], "\n".join(problems)
