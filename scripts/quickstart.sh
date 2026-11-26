#!/usr/bin/env bash
# pgsmith quickstart: from a fresh clone to Flagsmith flags evaluated inside Postgres.
#
#   make quickstart          (or: scripts/quickstart.sh)
#
# Starts self-hosted Flagsmith and a Supabase Postgres (docker compose), seeds a
# demo project (two environments, segments, identity overrides), installs pgsmith
# through pg_tle as Supabase would, loads 100k demo users, and syncs Flagsmith into
# Postgres. Every step is idempotent: run it again at any time.
#
# Needs: docker with compose, Python 3.10+ (uv if available). Local development
# credentials only; every port is bound to 127.0.0.1.
set -euo pipefail
cd "$(dirname "$0")/.."

say()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

dock() { if docker info >/dev/null 2>&1; then "$@"; else sg docker -c "$(printf '%q ' "$@")"; fi; }
COMPOSE=(docker compose -f infra/docker-compose.yml)
APPDB=${APPDB:-postgresql://postgres:pgfs@127.0.0.1:55433/postgres}
PY=.venv/bin/python

command -v docker >/dev/null || die "docker is not installed"
dock docker compose version >/dev/null 2>&1 || die "docker compose is not available"

say "Python tools"
if [ ! -x "$PY" ]; then
  if command -v uv >/dev/null; then uv venv -q --python 3.12 .venv && uv pip install -q --python "$PY" -e '.[dev]'
  else python3 -m venv .venv && "$PY" -m pip install -q -e '.[dev]'; fi
fi
ok "$($PY -c 'import sys; print("Python", sys.version.split()[0])'), pgsmith and flagshift in .venv/bin"

say "Build the extension"
python3 extension/build.py >/dev/null
ok "extension/dist: plain extension, pg_tle installer, database.dev package"

say "Start self-hosted Flagsmith and a Supabase Postgres"
dock "${COMPOSE[@]}" up -d flagsmith appdb >/dev/null 2>&1 || dock "${COMPOSE[@]}" up -d flagsmith appdb
for i in $(seq 1 120); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/health || true)" = 200 ] && break
  [ "$i" = 120 ] && die "Flagsmith did not become healthy (docker compose -f infra/docker-compose.yml logs flagsmith)"
  sleep 2
done
ok "Flagsmith on http://localhost:8000 (API, UI, experimentation)"
for i in $(seq 1 60); do
  "$PY" -c "import psycopg,sys; psycopg.connect(sys.argv[1], connect_timeout=2).close()" "$APPDB" 2>/dev/null && break
  [ "$i" = 60 ] && die "the Supabase Postgres did not start"
  sleep 2
done
ok "Supabase Postgres on 127.0.0.1:55433"

say "Seed the demo project in Flagsmith"
if [ -f demos/.env ]; then ok "already seeded (demos/.env)"; else "$PY" demos/seed_flagsmith.py >/dev/null; ok "keys written to demos/.env"; fi
set -a; . demos/.env; set +a

say "Install pgsmith (pg_tle, as on Supabase) and load demo data"
installed=$("$PY" -c "import psycopg,sys; print(psycopg.connect(sys.argv[1]).execute(\"select count(*) from pg_extension where extname = 'pgsmith'\").fetchone()[0])" "$APPDB")
if [ "$installed" = 0 ]; then .venv/bin/pgsmith install --tle --dsn "$APPDB" >/dev/null; ok "CREATE EXTENSION pgsmith"; else ok "already installed"; fi
"$PY" - "$APPDB" <<'PY'
import pathlib, sys, psycopg
with psycopg.connect(sys.argv[1], autocommit=True) as c:
    for table, script in [("app.users", "demos/sql/app_users.sql"), ("shop.products", "demos/search_ab/schema.sql")]:
        if c.execute("SELECT to_regclass(%s)", (table,)).fetchone()[0] is None:
            c.execute(pathlib.Path(script).read_text())
PY
ok "app.users (100,000 users with traits), shop.products (200,000 products)"

say "Sync Flagsmith into Postgres"
PGSMITH_DSN=$APPDB .venv/bin/pgsmith sync --once --api "$FLAGSMITH_API_URL" \
  --server-key "$PROD_SERVER_KEY" --server-key "$STAGING_SERVER_KEY" 2>/dev/null \
  | "$PY" -c "import json,sys; [print('    \033[32m✓\033[0m', r.get('name'), '->', r.get('outcome'), 'snapshot', r.get('snapshot_id')) for r in json.loads(sys.stdin.read())]"

say "Try it"
"$PY" - "$APPDB" <<'PY'
import sys, psycopg
with psycopg.connect(sys.argv[1]) as c:
    rows = c.execute("SELECT feature, enabled, value, reason FROM flagsmith.flags('user42', '{\"plan\": \"pro\"}') ORDER BY 1").fetchall()
    print("    SELECT * FROM flagsmith.flags('user42', '{\"plan\": \"pro\"}');")
    for f, e, v, r in rows:
        print(f"      {f:<16} {'on ' if e else 'off'}  {str(v):<16} {r}")
PY
cat <<EOF

  Next:
    psql "$APPDB"                                   # flagsmith.flags(), flag(), variant(), health() ...
    PGSMITH_DSN=$APPDB .venv/bin/flagshift plan --env production --promote-from staging --population app.users
    open http://localhost:8000                      # Flagsmith UI (login: see FLAGSMITH_ADMIN_* in demos/seed_flagsmith.py)
    docs/README.md                                  # everything else

EOF
