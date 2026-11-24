# PGXS build for self-managed Postgres:  make && sudo make install
VERSION := $(shell cat VERSION)
EXTENSION = pg_flagsmith
DATA = dist/pg_flagsmith--$(VERSION).sql
EXTRA_CLEAN = dist

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

all: dist/pg_flagsmith--$(VERSION).sql

dist/pg_flagsmith--$(VERSION).sql: build.py VERSION $(wildcard sql/*.sql)
	python3 build.py

include $(PGXS)
