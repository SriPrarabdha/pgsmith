# PGXS build for self-managed Postgres:  make && sudo make install
VERSION := $(shell cat VERSION)
EXTENSION = pgsmith
DATA = dist/pgsmith--$(VERSION).sql
EXTRA_CLEAN = dist

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

all: dist/pgsmith--$(VERSION).sql

dist/pgsmith--$(VERSION).sql: build.py VERSION $(wildcard sql/*.sql)
	python3 build.py

include $(PGXS)
