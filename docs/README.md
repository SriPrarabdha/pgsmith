# pgsmith documentation

| Guide | What it covers |
|---|---|
| [Install](install.md) | Supabase and Amazon RDS (pg_tle), database.dev, any PostgreSQL 14–18, uninstalling |
| [Sync](sync.md) | Keeping Postgres in sync with Flagsmith: the sync service, or the database itself (pg_cron) |
| [SQL reference](sql-reference.md) | Every function, the roles, query patterns, Supabase end users |
| [Experiments](experiments.md) | Recording exposures and conversions in SQL; delivery to Flagsmith Experimentation |
| [FlagShift](flagshift.md) | `terraform plan` for flag changes: plan, pull-request comments, apply, pin |
| [Operations](operations.md) | Monitoring, backups, garbage collection, scaling, upgrades |
| [How it works](how-it-works.md) | Snapshots, the compiler and the interpreter, how parity is proven, known divergences |

Also: [SECURITY.md](../SECURITY.md) (threat model and tests), [bench/RESULTS.md](../bench/RESULTS.md) and
[bench/STRETCH.md](../bench/STRETCH.md) (benchmarks), [demos/README.md](../demos/README.md) (walkthroughs).
