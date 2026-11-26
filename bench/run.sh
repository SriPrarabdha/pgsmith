#!/usr/bin/env bash
# Run the benchmarks in a dedicated Postgres 17 container (port 55499).
set -euo pipefail
cd "$(dirname "$0")/.."
dock() { if docker info >/dev/null 2>&1; then bash -c "$*"; else sg docker -c "$*"; fi; }
python3 extension/build.py >/dev/null
dock "docker rm -f pgsmith-bench" >/dev/null 2>&1 || true
dock "docker run -d --name pgsmith-bench --shm-size=4g -e POSTGRES_PASSWORD=pgfs -e POSTGRES_DB=pgfs -p 127.0.0.1:55499:5432 postgres:17 \
  -c shared_buffers=4GB -c work_mem=64MB -c max_worker_processes=24 -c max_parallel_workers=16 -c max_parallel_workers_per_gather=8" >/dev/null
for i in $(seq 1 60); do dock "docker exec pgsmith-bench pg_isready -U postgres -h 127.0.0.1" >/dev/null 2>&1 && break; sleep 1; done; sleep 2
S=$(dock "docker exec pgsmith-bench pg_config --sharedir")
dock "docker cp extension/dist/pgsmith--$(cat extension/VERSION).sql pgsmith-bench:$S/extension/ && docker cp extension/dist/pgsmith.control pgsmith-bench:$S/extension/"
dock "docker exec pgsmith-bench psql -qX -U postgres -d pgfs -c 'CREATE EXTENSION pgsmith'"
PGSMITH_BENCH_DSN=postgresql://postgres:pgfs@127.0.0.1:55499/pgfs .venv/bin/python bench/run.py "$@"
