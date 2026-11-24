"""Flagsmith's engine-test-data corpus, pinned to a release by commit.

    python -m tests.corpus   # download into tests/.cache and print the case count
"""
from __future__ import annotations

import io
import json
import pathlib
import tarfile
import urllib.request

import json5

TAG = "v3.13.2"
COMMIT = "da82e780a5a662ded227fd1f6f63307166b4cebe"
CACHE = pathlib.Path(__file__).resolve().parent / ".cache" / f"engine-test-data-{TAG}"


def ensure() -> pathlib.Path:
    cases = CACHE / "test_cases"
    if cases.is_dir() and any(cases.iterdir()):
        return cases
    url = f"https://codeload.github.com/Flagsmith/engine-test-data/tar.gz/{COMMIT}"
    data = urllib.request.urlopen(url, timeout=60).read()
    cases.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        for m in tf.getmembers():
            if "/test_cases/" in m.name and m.isfile() and m.name.endswith((".json", ".jsonc")):
                name = pathlib.PurePosixPath(m.name).name
                (cases / name).write_bytes(tf.extractfile(m).read())
    return cases


def load_case(path: pathlib.Path) -> dict:
    # JSON5 for the comments; then normalise through the stdlib so key order and
    # number types are exactly what json.loads gives the reference engine.
    obj = json5.loads(path.read_text())
    return json.loads(json.dumps(obj))


def cases() -> list[pathlib.Path]:
    return sorted(ensure().iterdir())


if __name__ == "__main__":
    cs = cases()
    print(len(cs), "cases in", CACHE)
