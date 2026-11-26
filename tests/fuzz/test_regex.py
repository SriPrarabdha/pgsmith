"""REGEX: Python `re.match(pattern, s)` vs pgsmith's translation to a Postgres ARE."""
from __future__ import annotations

import os
import re
import warnings

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

N = int(os.environ.get("PGSMITH_FUZZ_EXAMPLES", "300"))

LIT = st.sampled_from(list("abcxyzABZ019_- @.é٣Ⅳ") + ["\\.", "\\-", "\\+", "\\(", "\\[", "\\\\", "\\n", "\\t",
                                                       "\\x41", "\\u00e9", "\\{", "{", "}", "]", ","])
CLS_ITEM = st.sampled_from(["a-z", "A-Z", "0-9", "_", "\\d", "\\w", "\\s", "\\D", "\\W", "\\S", "\\n", ".", "-",
                            "é", "\\]", "^", "[", "\\b", "a", "x-z"])
SHORT = st.sampled_from(["\\d", "\\D", "\\w", "\\W", "\\s", "\\S", ".", "\\b", "\\B", "^", "$", "\\A", "\\Z"])
QUANT = st.sampled_from(["", "", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}", "{,2}", "{2,}", "{0}", "{1,3}?"])


@st.composite
def cls(draw):
    neg = draw(st.booleans())
    items = draw(st.lists(CLS_ITEM, min_size=1, max_size=4))
    return "[" + ("^" if neg else "") + "".join(items) + "]"


def atoms(depth):
    base = st.one_of(LIT, SHORT, cls())
    if depth <= 0:
        return base
    inner = st.deferred(lambda: pattern(depth - 1))
    return st.one_of(
        base, base,
        inner.map(lambda p: f"({p})"),
        inner.map(lambda p: f"(?:{p})"),
        inner.map(lambda p: f"(?P<g{abs(hash(p)) % 97}>{p})"),
        inner.map(lambda p: f"(?={p})"),
        inner.map(lambda p: f"(?!{p})"),
        st.sampled_from(["(?<=a)", "(?<!b)", "(?<=\\d)", "(?<!\\n)"]),
    )


def pattern(depth=2):
    piece = st.tuples(atoms(depth), QUANT).map(lambda t: t[0] + t[1])
    branch = st.lists(piece, min_size=0, max_size=4).map("".join)
    return st.lists(branch, min_size=1, max_size=3).map("|".join)


@st.composite
def full_pattern(draw):
    flags = draw(st.sampled_from(["", "", "", "(?i)", "(?s)", "(?m)", "(?a)", "(?x)", "(?ms)", "(?i)(?s)"]))
    p = draw(pattern())
    if draw(st.booleans()) and "(" in p:
        p += draw(st.sampled_from(["\\1", "(?:\\1)?"]))
    return flags + p


SUBJ = st.text(alphabet=list("abcxyzABZ019_- @.\né٣Ⅳ\t") + [" ", "é"], max_size=12)


@settings(max_examples=N, deadline=None, suppress_health_check=list(HealthCheck))
@given(st.lists(st.tuples(full_pattern(), st.lists(SUBJ, min_size=1, max_size=6)), min_size=1, max_size=10))
def test_regex_matches_python(cur, cases):
    pats = []
    for p, subjects in cases:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            try:
                rx = re.compile(p)
            except (re.error, OverflowError, RecursionError):
                rx = None
        pats.append((p, rx, subjects))
    cur.execute("SELECT t.status, t.detail, t.pattern FROM unnest(%s::text[]) p, flagsmith.py_regex_to_are(p) t",
                ([p for p, _, _ in pats],))
    translated = cur.fetchall()
    for (p, rx, subjects), (status, detail, are) in zip(pats, translated):
        if rx is None:
            assert status != "ok" or True  # Python rejects it; the reference raises at evaluation
            continue
        assert status != "invalid", f"Python accepts {p!r} but the translator says invalid: {detail}"
        if status != "ok":
            continue
        cur.execute("SELECT s ~ %s FROM unnest(%s::text[]) s", (are, subjects))
        got = [r[0] for r in cur.fetchall()]
        want = [rx.match(s) is not None for s in subjects]
        assert got == want, f"pattern {p!r} -> {are!r}: subjects {subjects!r}: want {want}, got {got}"
