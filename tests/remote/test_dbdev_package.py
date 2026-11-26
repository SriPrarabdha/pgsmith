"""The database.dev package: valid by dbdev's own rules (cli/src/models.rs), and
installable the way dbdev.install() installs it: pgtle.install_extension under
the package name '<handle>@pgsmith', then CREATE EXTENSION with that name."""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import uuid

import psycopg
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PKG = ROOT / "extension" / "dist" / "dbdev"
APPDB = os.environ.get("PGSMITH_APPDB_DSN", "postgresql://postgres:pgfs@127.0.0.1:55433/postgres")


@pytest.fixture(scope="module", autouse=True)
def built():
    subprocess.run(["python3", str(ROOT / "extension" / "build.py")], check=True, capture_output=True)


def test_package_follows_dbdev_rules():
    controls = list(PKG.glob("*.control"))
    assert len(controls) == 1
    name = controls[0].name.removesuffix(".control")
    assert re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{1,31}", name)
    lines = {}
    for line in controls[0].read_text().splitlines():
        parts = line.split("=")
        assert len(parts) == 2, f"dbdev splits control lines on '=': {line!r}"
        lines[parts[0].strip()] = parts[1].strip().strip("'")
    assert re.fullmatch(r"\d+\.\d+\.\d+", lines["default_version"])
    assert lines.get("relocatable") == "false" and "requires" not in lines
    scripts = [p.name for p in PKG.glob("*.sql")]
    assert scripts == [f"{name}--{lines['default_version']}.sql"]
    body = (PKG / scripts[0]).read_text()
    top_level = re.sub(r"\$(\w*)\$.*?\$\1\$", "", body, flags=re.S)              # outside quoted bodies
    assert not re.search(r"^\s*(BEGIN|COMMIT|ROLLBACK|START TRANSACTION)\s*;", top_level, re.M | re.I)
    assert "\\quit" not in body and (PKG / "README.md").exists()


def test_installs_like_dbdev_install():
    try:
        admin = psycopg.connect(APPDB, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        pytest.skip("compose appdb not running")
    db = "pgsmith_dbdev_" + uuid.uuid4().hex[:6]
    admin.execute(f"CREATE DATABASE {db}")
    try:
        with psycopg.connect(APPDB.rsplit("/", 1)[0] + "/" + db, autocommit=True) as c:
            c.execute("CREATE EXTENSION pg_tle")
            lines = dict(l.split("=", 1) for l in (PKG / "pgsmith.control").read_text().splitlines())
            c.execute("SELECT pgtle.install_extension(%s, %s, %s, %s, '{}'::text[])",
                      ("pgsmith_test@pgsmith", lines["default_version "].strip().strip("'"),
                       lines["comment "].strip().strip("'"), (PKG / "pgsmith--0.1.0.sql").read_text()))
            c.execute('CREATE EXTENSION "pgsmith_test@pgsmith"')
            ctx = {"environment": {"key": "dbdev_env", "name": "dbdev"},
                   "features": {"f": {"key": "1", "name": "f", "enabled": True, "value": "v"}}, "segments": {}}
            c.execute("SELECT flagsmith.load_context(%s::json)", (json.dumps(ctx),))
            assert c.execute("SELECT enabled, value FROM flagsmith.flags('u1', '{}')").fetchone() == (True, "v")
            assert c.execute("SELECT compiled FROM flagsmith.environments()").fetchone() == (True,)
            c.execute('DROP EXTENSION "pgsmith_test@pgsmith" CASCADE')
    finally:
        admin.execute(f"DROP DATABASE {db} WITH (FORCE)")
        admin.close()
