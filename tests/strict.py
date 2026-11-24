"""Type-strict JSON equality: Python's == treats True == 1 == 1.0, which would
hide exactly the bugs parity testing is for."""
from __future__ import annotations

import math
from typing import Any


def norm(v: Any) -> Any:
    if isinstance(v, bool):
        return ("bool", v)
    if isinstance(v, int):
        return ("int", v)
    if isinstance(v, float):
        return ("float", "nan" if math.isnan(v) else v)
    if isinstance(v, str):
        return ("str", v)
    if v is None:
        return ("null",)
    if isinstance(v, list):
        return ("list", tuple(norm(x) for x in v))
    if isinstance(v, dict):
        return ("dict", tuple(sorted((k, norm(x)) for k, x in v.items())))
    raise TypeError(type(v))


def diff(expected: Any, actual: Any, path: str = "$") -> list[str]:
    """Human-readable differences between two JSON values."""
    if norm(expected) == norm(actual):
        return []
    if isinstance(expected, dict) and isinstance(actual, dict):
        out = []
        for k in sorted(set(expected) | set(actual)):
            if k not in actual:
                out.append(f"{path}.{k}: missing (expected {expected[k]!r})")
            elif k not in expected:
                out.append(f"{path}.{k}: unexpected {actual[k]!r}")
            else:
                out += diff(expected[k], actual[k], f"{path}.{k}")
        return out
    return [f"{path}: expected {expected!r}, got {actual!r}"]
