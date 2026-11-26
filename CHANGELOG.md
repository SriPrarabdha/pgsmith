# Changelog

## 0.1.0 (unreleased)

The first release.

**Evaluation**
- Flagsmith flag evaluation inside PostgreSQL, matching `flag_engine.get_evaluation_result` (flagsmith-flag-engine
  11.1.2): every operator, splits, multivariate variants, segment and identity overrides, flag dependencies.
- Two tiers: a PL/pgSQL interpreter, and a compiler that turns each snapshot into an inlinable, parallel-safe
  SQL-standard function.
- Atomic, deduplicated snapshot loads; pin and unpin; health; garbage collection.

**Sync**
- `pgsmith sync` / `pgsmith serve`: the sync service, with signed webhooks and polling, using the official SDK's
  mapper.
- In-database sync for Supabase: a SQL port of the SDK's mapper, the http or pg_net transport, Vault-held keys,
  pg_cron scheduling.

**Experiments**
- An exposure and event queue (`track_exposure`, `track_event`, `track_variant`), delivered to Flagsmith's events API
  from the database or by `pgsmith events`.

**FlagShift**
- `flagshift plan / apply / pin / unpin / history`, plans in SQL, and a GitHub Action that comments plans on pull
  requests.

**Packaging**
- A plain extension (PGXS), a pg_tle installer (Supabase, Amazon RDS / Aurora) and a database.dev package.
- Least-privilege roles: `flagsmith_reader`, `flagsmith_tracker`, `flagsmith_planner`, `flagsmith_loader`.

**Verification**
- 230/230 engine-test-data cases; differential fuzzing against the official engine and the official SDK mapper; live
  parity against self-hosted Flagsmith 2.295.2; PostgreSQL 14–18 and Supabase in CI.
