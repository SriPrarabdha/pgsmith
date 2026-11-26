# Operations

## Monitor

```sql
SELECT * FROM flagsmith.health();        -- one row per environment; alert on status <> 'ok'
SELECT * FROM flagsmith.sync_status();   -- in-database sync sources: last outcome, consecutive failures
SELECT * FROM flagsmith.event_status();  -- the exposure queue: queued, oldest, delivered, rejected
SELECT * FROM flagsmith.warnings;        -- what a load could not represent exactly (loader role)
```

`health().status` is one of the following:

| status | meaning |
|---|---|
| `ok` | serving a current configuration |
| `stale` | no successful sync for `stale_after` (default 5 minutes) |
| `pinned` | an operator pinned a snapshot |
| `error` | the snapshot carries error-level warnings |
| `parity_mismatch` | the last live parity check found differences |
| `no_snapshot` | the environment has never loaded |

`pgsmith parity --population "SELECT id::text AS identifier, traits FROM users" --sample 10000` compares pgsmith
with the official SDK on your own users and records the result for `health()`.

## Emergency brake

```sql
SELECT flagsmith.pin('production', 41);   -- every query serves snapshot 41 from the next statement on
SELECT flagsmith.unpin('production');
```

A pin holds until it is removed: syncs keep loading new snapshots but do not serve them. It works with Flagsmith down.

## Backups and restores

`pg_dump` keeps in-database sync sources and settings. Snapshots and compiled functions are data derived from
Flagsmith, so they are left out and the next sync rebuilds them: after a restore, run
`SELECT * FROM flagsmith.sync_tick()` or `pgsmith sync --once`.

## Garbage collection

`flagsmith.gc()` runs after every load. It keeps the last `keep_snapshots` (default 50) live snapshots per environment,
and keeps any snapshot younger than its successor's grace period (`gc_grace`, default 10 minutes), so a long query is
never pulled from under. Candidates go after 7 days, or beyond the 100 most recent per environment. The load log is
kept for 30 days. Per-environment settings live in `flagsmith.environment` (`keep_snapshots`, `gc_grace`,
`regex_policy`, `compile`, `max_compiled_bytes`).

`flagsmith.remove_environment(env)` stops mirroring an environment: its entry points, compiled code, snapshots and
queued events go.

## Scale

| | |
|---|---|
| Evaluation over a table | parallel: 1M users × 50 flags in 6 s with 8 workers |
| Point lookups | 0.3–0.5 ms, mostly executor start-up for the inlined plan |
| Loads | about 120 ms for the 750-override benchmark profile; identity overrides load set-based (10,000 in about 3 s, 100,000 in about 30 s) |
| Identity overrides at evaluation | one index probe, whatever their number |
| Replicas | physical replicas receive loads atomically, in WAL order; for logical replication, run the loader on the subscriber |

For large documents, loading takes a short `ANALYZE` of pgsmith's own tables so that the compiler's queries see the
new rows.

## Upgrades

Future versions will ship as update paths (`ALTER EXTENSION pgsmith UPDATE`; `pgtle.install_update_path` on pg_tle).
After an upgrade, `SELECT flagsmith.recompile();` rebuilds the compiled functions with the new compiler. Until then,
reinstall (`DROP EXTENSION pgsmith; CREATE EXTENSION pgsmith;`) and sync again.
