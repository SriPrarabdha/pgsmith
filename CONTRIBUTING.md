# Contributing to pgsmith

Thank you for helping. pgsmith makes one promise: **the same answers as Flagsmith's engine**. Every change keeps it,
and the test suite is how we know.

## Set up

You need Docker and Python 3.10+ ([uv](https://github.com/astral-sh/uv) is used if present).

```bash
make venv          # .venv with the tools and test dependencies
make db            # a disposable PostgreSQL 17 with the extension, on 127.0.0.1:55417
make test          # the engine corpus (both tiers), properties, security, mapper, queue, tools
```

`scripts/reinstall` rebuilds the extension and reinstalls it in the dev database after you edit `extension/sql/`.

For the parts that talk to Flagsmith (sync, events, FlagShift apply, live parity):

```bash
make quickstart    # self-hosted Flagsmith + Supabase Postgres + demo data
make test-remote   # in-database sync, event delivery and the database.dev install, end to end
```

## Before you open a pull request

| Command | Checks |
|---|---|
| `make test` | conformance on both tiers, security properties, mapper, queue, tools |
| `make fuzz` (`PGSMITH_FUZZ_EXAMPLES=2000`) | differential fuzzing against the official engine |
| `make matrix` | PostgreSQL 14–18, Supabase through pg_tle, a non-C locale |
| `make audit` | dependency vulnerabilities and static checks of the Python tools |

CI runs the first and third on every push.

## Rules the code keeps

- **Parity with the reference engine.** When Python and Postgres disagree, Python wins, and the corpus or a fuzz
  case proves it. If a behaviour cannot be matched, list it under *Known divergences* in
  [docs/how-it-works.md](docs/how-it-works.md) and record a warning at load time.
- **No name resolution through the caller's `search_path`.** SQL functions use `BEGIN ATOMIC` bodies; every other
  routine sets `search_path = pg_catalog, flagsmith, pg_temp`. `tests/sql/test_security.py` enforces this.
- **Configuration is data.** Values from Flagsmith reach generated SQL only through `%L` / `quote_literal` (or as
  numbers), and identifiers only through `%I` or a validated alias.
- **Least privilege.** A new SECURITY DEFINER function is granted by name in `extension/sql/90_grants.sql`, and the
  expected grant matrix in `test_security.py` is updated with it.
- **Pure SQL and PL/pgSQL**, so the extension keeps installing through pg_tle on Supabase and RDS.

## Layout

```
extension/sql/    the extension in load order        tests/conformance  Flagsmith's engine-test-data corpus
extension/build.py  plain / pg_tle / database.dev    tests/fuzz         Hypothesis against the official engine
tools/pgsmith/    pgsmith and flagshift (Python)     tests/sql          properties, security, mapper, queue
bench/            benchmarks                         tests/remote       Supabase end to end
```

## Reporting bugs and vulnerabilities

Open an issue with the smallest context that reproduces it; a failing engine-test-data style case is ideal. Report
vulnerabilities privately, as [SECURITY.md](SECURITY.md) describes.

By contributing you agree that your contributions are licensed under the project's [BSD-3-Clause](LICENSE) licence.
