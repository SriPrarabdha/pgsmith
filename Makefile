# pg_flagsmith developer tasks
PY ?= .venv/bin/python
PGFS_DSN ?= postgresql://postgres:pgfs@127.0.0.1:55417/pgfs

.PHONY: build install venv db test fuzz matrix bench up seed sync parity demo-flagshift demo-search clean

build:                       ## build dist/: plain SQL, pg_tle installer, database.dev package
	python3 extension/build.py

install: build               ## install into the local Postgres (PGXS; needs pg_config)
	$(MAKE) -C extension install

venv:                        ## Python tools and test dependencies
	uv venv --python 3.12 .venv && uv pip install -e '.[dev]'

db:                          ## a disposable Postgres 17 with the extension (port 55417)
	docker run -d --name pgfs-dev -e POSTGRES_PASSWORD=pgfs -e POSTGRES_DB=pgfs -p 127.0.0.1:55417:5432 postgres:17
	sleep 5 && scripts/reinstall

test: build                  ## conformance corpus (both tiers) + properties
	PGFS_DSN=$(PGFS_DSN) $(PY) -m pytest tests/conformance tests/sql -p no:warnings

fuzz:                        ## differential fuzzing against the official engine (PGFS_FUZZ_EXAMPLES=...)
	PGFS_DSN=$(PGFS_DSN) $(PY) -m pytest tests/fuzz -p no:warnings --hypothesis-show-statistics

matrix:                      ## PG 14-18 + Supabase pg_tle + non-C locale
	scripts/matrix.sh

bench:                       ## Edge Proxy profile benchmark -> bench/RESULTS.md
	bench/run.sh

up:                          ## local Flagsmith + Supabase app database
	docker compose -f infra/docker-compose.yml up -d flagsmith appdb

seed:                        ## demo project in the local Flagsmith -> demos/.env
	$(PY) demos/seed_flagsmith.py

clean:
	rm -rf extension/dist .pytest_cache .hypothesis
