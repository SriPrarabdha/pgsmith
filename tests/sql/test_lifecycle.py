"""Lifecycle: generated code belongs to the extension (DROP EXTENSION needs no
CASCADE), and pg_dump/restore keeps configuration (remote sources, settings)
while derived data (snapshots, compiled functions) is rebuilt by the next sync."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import uuid

import psycopg
import pytest

from tests.conftest import DSN

CONTAINER = os.environ.get("PGFS_CONTAINER", "pgfs-dev")


def sh(cmd: str) -> subprocess.CompletedProcess:
    if shutil.which("docker") and subprocess.run("docker info", shell=True, capture_output=True).returncode == 0:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return subprocess.run(["sg", "docker", "-c", cmd], capture_output=True, text=True)


def dsn_for(db: str) -> str:
    return DSN.rsplit("/", 1)[0] + "/" + db


@pytest.fixture()
def dbs(conn):
    names = [f"pgfs_life_{uuid.uuid4().hex[:6]}" for _ in range(2)]
    for n in names:
        conn.execute(f"CREATE DATABASE {n}")
    yield names
    for n in names:
        conn.execute(f"DROP DATABASE IF EXISTS {n} WITH (FORCE)")


def test_drop_extension_needs_no_cascade_and_dump_keeps_configuration(dbs):
    if sh(f"docker inspect {CONTAINER}").returncode != 0:
        pytest.skip("needs docker access to the database container")
    src, dst = dbs
    ctx = {"environment": {"key": "life_env", "name": "life"},
           "features": {"f": {"key": "1", "name": "f", "enabled": True, "value": "v",
                              "variants": [{"value": "a", "weight": 50, "priority": 1}]}},
           "segments": {"1": {"key": "1", "name": "s", "rules": [{"type": "ALL", "conditions": [
               {"operator": "EQUAL", "property": "plan", "value": "pro"}]}],
                              "overrides": [{"key": "2", "name": "f", "enabled": False, "value": "o", "priority": 0}]}}}
    with psycopg.connect(dsn_for(src), autocommit=True) as c:
        if not c.execute("SELECT count(*) FROM pg_available_extensions WHERE name = 'pg_flagsmith'").fetchone()[0]:
            pytest.skip("pg_flagsmith is installed per database here (pg_tle)")
        c.execute("SET search_path = public, pg_temp")
        c.execute("CREATE EXTENSION pg_flagsmith")
        # the install script's own search_path does not leak into the session
        assert c.execute("SHOW search_path").fetchone()[0] == "public, pg_temp"
        c.execute("SELECT flagsmith.load_context(%s::json)", (json.dumps(ctx),))
        orphans = c.execute("""SELECT p.oid::regprocedure::text FROM pg_proc p
                               WHERE p.pronamespace = 'flagsmith_c'::regnamespace AND NOT EXISTS (
                                 SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
                                   AND d.objid = p.oid AND d.deptype = 'e')""").fetchall()
        assert orphans == []
        assert c.execute("SELECT count(*) FROM pg_proc WHERE pronamespace = 'flagsmith_c'::regnamespace").fetchone()[0] >= 4
        c.execute("""INSERT INTO flagsmith.remote_source (name, api_url, secret_name, transport)
                     VALUES ('prod', 'https://flagsmith.example.com/api/v1/', 'flagsmith_prod', 'http')""")
        c.execute("INSERT INTO flagsmith.settings (events_max_queued) VALUES (5000)")
    r = sh(f"docker exec {CONTAINER} sh -c 'pg_dump -U postgres -d {src} | psql -X -q -v ON_ERROR_STOP=1 -U postgres -d {dst}'")
    assert r.returncode == 0, r.stderr
    with psycopg.connect(dsn_for(dst), autocommit=True) as c:
        assert c.execute("SELECT name, api_url FROM flagsmith.remote_source").fetchall() == \
            [("prod", "https://flagsmith.example.com/api/v1/")]
        assert c.execute("SELECT (flagsmith._settings()).events_max_queued").fetchone()[0] == 5000
        assert c.execute("SELECT count(*) FROM pg_proc WHERE pronamespace = 'flagsmith_c'::regnamespace").fetchone()[0] == 0
        # the next sync rebuilds everything
        c.execute("SELECT flagsmith.load_context(%s::json)", (json.dumps(ctx),))
        assert c.execute("SELECT enabled, value FROM flagsmith.flags('u', '{\"plan\": \"pro\"}')").fetchone() == (False, "o")
    with psycopg.connect(dsn_for(src), autocommit=True) as c:
        # removing the (default) environment takes its code with it; flags() falls back
        assert c.execute("SELECT flagsmith.remove_environment('life_env')").fetchone()[0]
        assert c.execute("SELECT count(*) FROM pg_proc WHERE pronamespace = 'flagsmith_c'::regnamespace").fetchone()[0] == 0
        assert c.execute("SELECT count(*) FROM flagsmith.snapshot").fetchone()[0] == 0
        c.execute("SELECT flagsmith.load_context(%s::json)", (json.dumps(ctx),))
        assert c.execute("SELECT enabled FROM flagsmith.flags('u', '{\"plan\": \"pro\"}')").fetchone() == (False,)
        c.execute("DROP EXTENSION pg_flagsmith")          # no CASCADE needed
        assert c.execute("SELECT to_regnamespace('flagsmith_c')").fetchone()[0] is None
