# pg_flagsmith stretch-tier benchmarks

Machine: AMD Ryzen 9 9950X3D 16-Core Processor, 32 cores. Mapper and queue on the benchmark container (PostgreSQL 17, the same settings as RESULTS.md); in-database sync on the compose stack (Supabase Postgres 17 + self-hosted Flagsmith 2.295.2, same host). Reproduce: `bench/run.sh && python bench/stretch.py`.

## Mapping environment documents

| Document | Size | Python SDK mapper | SQL mapper | Pusher load (SDK map + load) | In-database load (SQL map + load) | Unchanged poll (body hash) |
|---|---:|---:|---:|---:|---:|---:|
| local Flagsmith Production (5 features, 5 segments) | 0.01 MB | 0.1 ms | 4.6 ms | 11 ms | 15 ms | 0.08 ms |
| Edge Proxy profile (50 features, 15 segments, 750 overrides) | 0.24 MB | 1.9 ms | 45.9 ms | 102 ms | 148 ms | 0.29 ms |
| profile + 10,000 identity overrides | 6.19 MB | 253.4 ms | 946.5 ms | 2530 ms | 3602 ms | 5.11 ms |
| profile + 100,000 identity overrides | 60.15 MB | 1720.7 ms | 9328.1 ms | 28423 ms | 35151 ms | 77.80 ms |

Loads include normalisation, compilation and publishing (and, for the pusher, sending the context over the connection). An unchanged document costs one hash of its body: it is never parsed.

## In-database sync (Supabase, pg_cron entry point `CALL flagsmith.sync_run()`)

| Transport | Unchanged environment | A flag changed in Flagsmith → served by Postgres |
|---|---:|---:|
| http | 22.1 ms | 39 ms |
| pg_net | 1031.5 ms | 1021 ms |

One run fetches, maps, loads and publishes. With `schedule_sync('30 seconds')` a change is served within 30 s plus this; `pg-flagsmith serve` (webhook) serves it within about a second. pg_net hands the request to its background worker, which adds about a second per run; `http` is synchronous.

## Exposure queue

Calls per second (pgbench, prepared, random identities):

| Clients | track_exposure() | plain INSERT (same row) | track_exposure(), synchronous_commit = off | variant() | track_variant() (evaluate + record) |
|---:|---:|---:|---:|---:|---:|
| 1 | 2,026 (0.494 ms) | 2,033 | 43,201 | 1,297 | 763 |
| 8 | 8,120 (0.985 ms) | 8,123 | 94,242 | 9,453 | 4,930 |
| 32 | 29,804 (1.074 ms) | 32,262 | 113,037 | 20,298 | 13,517 |

Recording costs the same as a plain INSERT: throughput is bound by commits (WAL flushes). Sessions that only record analytics can trade the last few milliseconds of events on a crash for throughput with `SET synchronous_commit = off`.


- Bulk enqueue (one statement): 188,768 events/s; 1M queued events take 132 MB.
- Claiming in the database (DELETE ... SKIP LOCKED, dedupe, payload JSON): 186,240 events/s.
- End to end through `pg-flagsmith events` to a local HTTP sink: 131,187 events/s with one sender, 268,473 events/s with four (no event sent twice).
- After draining and VACUUM the queue's 38 MB of pages are free for new events (the table does not grow while it is drained).

