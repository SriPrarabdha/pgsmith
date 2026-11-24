"""Shared fixtures: a psycopg connection to a database with pg_flagsmith installed.

Set PGFS_DSN (default: the dev container started by `make db`).
"""
from __future__ import annotations

import os

import psycopg
import pytest

DSN = os.environ.get("PGFS_DSN", "postgresql://postgres:pgfs@127.0.0.1:55417/pgfs")


@pytest.fixture(scope="session")
def conn():
    with psycopg.connect(DSN, autocommit=True) as c:
        yield c


@pytest.fixture()
def cur(conn):
    with conn.cursor() as cur:
        yield cur
