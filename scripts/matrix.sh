#!/usr/bin/env bash
# Install pgsmith on several Postgres versions (plain extension files) and on
# Supabase (pg_tle), then run the conformance suite and property tests on each.
#   scripts/matrix.sh            # all targets
#   scripts/matrix.sh 14 18      # some versions
set -uo pipefail
cd "$(dirname "$0")/.."
python3 extension/build.py >/dev/null
VER=$(cat extension/VERSION)
targets=("$@"); [ ${#targets[@]} -eq 0 ] && targets=(14 15 16 17 18 supabase locale)
dock() { if docker info >/dev/null 2>&1; then bash -c "$*"; else sg docker -c "$*"; fi; }
for t in "${targets[@]}"; do
  case $t in
    supabase) img=supabase/postgres:17.12.0.002; db=postgres ;;
    locale)   img=postgres:17; db=pgsmith_en ;;
    *)        img=postgres:$t; db=pgfs ;;
  esac
  name=pgsmith-m-$t; port=$((56000 + RANDOM % 900))
  dock "docker rm -f $name" >/dev/null 2>&1
  dock "docker run -d --name $name -e POSTGRES_PASSWORD=pgfs -e POSTGRES_DB=pgfs -p 127.0.0.1:$port:5432 $img" >/dev/null
  for i in $(seq 1 60); do dock "docker exec $name pg_isready -U postgres -h 127.0.0.1" >/dev/null 2>&1 && break; sleep 1; done
  sleep 3
  if [ "$t" = supabase ]; then
    dock "docker cp extension/dist/pgsmith--$VER.pgtle.sql $name:/tmp/i.sql"
    dock "docker exec $name psql -qX -v ON_ERROR_STOP=1 -U postgres -d $db -f /tmp/i.sql" >/dev/null 2>&1 || { echo "$t: INSTALL FAILED"; continue; }
  else
    share=$(dock "docker exec $name pg_config --sharedir")
    dock "docker cp extension/dist/pgsmith--$VER.sql $name:$share/extension/ && docker cp extension/dist/pgsmith.control $name:$share/extension/"
    if [ "$t" = locale ]; then
      dock "docker exec $name psql -qX -U postgres -c \"CREATE DATABASE pgsmith_en TEMPLATE template0 ENCODING 'UTF8' LOCALE 'en_US.utf8'\"" >/dev/null
    fi
    dock "docker exec $name psql -qX -v ON_ERROR_STOP=1 -U postgres -d $db -c 'CREATE EXTENSION pgsmith'" >/dev/null 2>&1 || { echo "$t: INSTALL FAILED"; continue; }
  fi
  v=$(dock "docker exec $name psql -AtX -U postgres -d $db -c 'select version()'" | cut -d' ' -f1-2)
  coll=$(dock "docker exec $name psql -AtX -U postgres -d $db -c 'select datcollate from pg_database where datname = current_database()'")
  res=$(PGSMITH_CONTAINER=$name PGSMITH_DSN=postgresql://postgres:pgfs@127.0.0.1:$port/$db timeout 1800 .venv/bin/python -m pytest tests/conformance tests/sql tests/tools -p no:warnings 2>&1 | grep -E "passed|failed|error" | tail -1)
  echo "$t | $v | collate=$coll | $res"
  [ "${KEEP:-0}" = 1 ] || dock "docker rm -f $name" >/dev/null 2>&1
done
