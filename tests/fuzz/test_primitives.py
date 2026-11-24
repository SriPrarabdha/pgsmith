"""Differential tests of the Python-compatibility primitives against Python itself."""
from __future__ import annotations

import math
import os
import re
import struct

import pytest
import semver
from flag_engine.utils.hashing import get_hashed_percentage_for_object_ids
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

N = int(os.environ.get("PGFS_FUZZ_EXAMPLES", "300"))
SETTINGS = settings(max_examples=N, deadline=None, suppress_health_check=list(HealthCheck))

pg_text = st.text(alphabet=st.characters(blacklist_categories=("Cs",), blacklist_characters="\x00"), max_size=30)


def _py_int(s):
    try:
        return int(s)
    except ValueError:
        return None


def _py_float(s):
    try:
        return float(s)
    except ValueError:
        return None


numberish = st.one_of(
    pg_text,
    st.from_regex(r"\s*[-+]?[0-9_]{0,6}(\.[0-9_]{0,6})?([eE][-+]?[0-9_]{0,4})?\s*", fullmatch=True),
    st.sampled_from(["inf", "-Infinity", "nan", "+NaN", " 1_000 ", "1__0", "_1", "1_", "0x10", "١٢٣",
                     "1e400", "-1e-400", "4.9e-324", "2.4703282292062328e-324", "1.7976931348623158e308",
                     "1.7976931348623159e308", "00", "-0", "+0.0", ".5", "5.", ".", "e5", "1e", "   7 　"]),
)


@SETTINGS
@given(st.lists(numberish, min_size=1, max_size=40))
def test_py_int_and_float(cur, xs):
    cur.execute("SELECT flagsmith.py_int(x)::text, flagsmith.py_float(x) FROM unnest(%s::text[]) x", (xs,))
    for x, (i, f) in zip(xs, cur.fetchall()):
        pi = _py_int(x)
        assert (None if pi is None else str(pi)) == i, x
        pf = _py_float(x)
        if pf is None or f is None:
            assert pf is f is None or (pf is None and f is None), (x, pf, f)
        elif math.isnan(pf):
            assert math.isnan(f), x
        else:
            assert struct.pack(">d", pf) == struct.pack(">d", f), (x, pf, f)


finite = st.floats(allow_nan=True, allow_infinity=True)


@SETTINGS
@given(st.lists(finite, min_size=1, max_size=50))
def test_py_float_repr(cur, xs):
    cur.execute("SELECT flagsmith.py_float_repr(x) FROM unnest(%s::float8[]) x", (xs,))
    assert [r[0] for r in cur.fetchall()] == [repr(x) for x in xs]


@SETTINGS
@given(st.lists(st.tuples(st.floats(allow_nan=False, allow_infinity=True),
                          st.floats(allow_nan=False, allow_infinity=True)), min_size=1, max_size=30))
def test_py_fmod(cur, pairs):
    pairs = [(x, d) for x, d in pairs if d != 0]
    if not pairs:
        return
    cur.execute("SELECT flagsmith.py_fmod(x, d) FROM unnest(%s::float8[], %s::float8[]) t(x, d)",
                ([p[0] for p in pairs], [p[1] for p in pairs]))
    for (x, d), (got,) in zip(pairs, cur.fetchall()):
        want = x % d
        if math.isnan(want):
            assert math.isnan(got), (x, d)
        else:
            assert struct.pack(">d", want) == struct.pack(">d", got), (x, d, want, got)


ids = st.text(alphabet=st.characters(blacklist_categories=("Cs",), blacklist_characters="\x00"), max_size=12)


@SETTINGS
@given(st.lists(st.tuples(ids, ids), min_size=1, max_size=50))
def test_hash_pct(cur, pairs):
    cur.execute("SELECT flagsmith.hash_pct(a, b) FROM unnest(%s::text[], %s::text[]) t(a, b)",
                ([p[0] for p in pairs], [p[1] for p in pairs]))
    for (a, b), (got,) in zip(pairs, cur.fetchall()):
        assert got == get_hashed_percentage_for_object_ids([a, b]), (a, b)


def test_hash_rehash_path(cur):
    # brute-force an id pair whose digest reduces to 9998 (the engine hashes again)
    import hashlib
    for i in range(10**6):
        a, b = "seg", f"user-{i}"
        if int(hashlib.md5(f"{a},{b}".encode()).hexdigest(), 16) % 9999 == 9998:
            break
    else:
        pytest.fail("no rehash input found")
    cur.execute("SELECT flagsmith.hash_pct(%s, %s), flagsmith.hash_pct(ARRAY[%s, %s])", (a, b, a, b))
    two, arr = cur.fetchone()
    want = get_hashed_percentage_for_object_ids([a, b])
    assert two == arr == want and want != 100


def test_hash_exact_50_boundary(cur):
    import hashlib
    for i in range(10**6):
        a, b = "seg", f"u{i}"
        if int(hashlib.md5(f"{a},{b}".encode()).hexdigest(), 16) % 9999 == 4999:
            break
    cur.execute("SELECT flagsmith.hash_pct(%s, %s)", (a, b))
    assert cur.fetchone()[0] == 50.0 == get_hashed_percentage_for_object_ids([a, b])


semver_ids = st.from_regex(r"(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})"
                           r"(-[0-9A-Za-z-]{1,4}(\.[0-9A-Za-z-]{1,4}){0,2})?(\+[0-9A-Za-z-]{1,3})?", fullmatch=True)


@SETTINGS
@given(st.lists(st.tuples(st.one_of(semver_ids, pg_text), st.one_of(semver_ids, pg_text)), min_size=1, max_size=40))
def test_semver(cur, pairs):
    cur.execute("""SELECT (flagsmith.semver_parse(a)).major IS NOT NULL, (flagsmith.semver_parse(b)).major IS NOT NULL,
                          flagsmith.semver_cmp(flagsmith.semver_parse(a), flagsmith.semver_parse(b))
                   FROM unnest(%s::text[], %s::text[]) t(a, b)""",
                ([p[0] for p in pairs], [p[1] for p in pairs]))
    for (a, b), (pa, pb, c) in zip(pairs, cur.fetchall()):
        def ok(s):
            try:
                semver.Version.parse(s)
                return True
            except (ValueError, TypeError):
                return False
        assert (pa, pb) == (ok(a), ok(b)), (a, b)
        if pa and pb:
            assert c == semver.Version.parse(a).compare(b), (a, b)
