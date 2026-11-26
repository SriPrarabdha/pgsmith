# Experiments: exposures and events from SQL

Flagsmith Experimentation compares arms of a multivariate flag using **exposures** (who saw which arm) and
**events** (conversions and measurements). pgsmith picks arms with the SDKs' exact bucketing, so an exposure
recorded from SQL is attributed to the arm Flagsmith would have chosen. The live parity check proves it.

Evaluation stays read-only: `flags()`, `variant()` and friends never write, so they keep working on replicas.
Recording is an explicit write to a queue:

```sql
SELECT flagsmith.track_variant('search_ranking', $1, $2);          -- evaluate, record the exposure, return the arm
SELECT flagsmith.track_exposure('search_ranking', $1, 'boosted');   -- record an arm you already know
SELECT flagsmith.track_event('add_to_cart', $1);                   -- a conversion
SELECT flagsmith.track_event('search_latency_ms', $1, '42');        -- with a value
```

## Delivery

The queue is delivered to Flagsmith's events API (`<api>/events` when self-hosted,
`events.api.flagsmith.com` on Flagsmith SaaS), in the format of the Python SDK's event processor:

- **From the database (Supabase):** with a [remote source](sync.md#in-the-database-supabase) for the environment, run
  `SELECT * FROM flagsmith.events_tick()` or schedule it with `SELECT flagsmith.schedule_events('10 seconds')`.
- **From anywhere:** run `pgsmith events --poll 10` with the server-side keys (`FLAGSMITH_SERVER_KEYS`).

Both can run at once.

Delivery follows the SDK's rules:

- Identical exposures (same feature, identity and value) in a batch are sent once.
- 408, 429 and 5xx responses are retried with backoff; the events stay queued meanwhile.
- 401 and 403 stop delivery for that environment, and the events are kept. `flagsmith.events_retry_failed()`
  resumes delivery once the key is fixed.
- Any other 4xx drops the batch and counts it as rejected.

A batch is claimed with `DELETE ... FOR UPDATE SKIP LOCKED` and committed only once Flagsmith accepted it. An event is
never lost to a failed request, and no event is sent twice by concurrent senders.

## Capacity

Recording costs the same as a plain `INSERT` into an append-only table with one index: about 30,000 calls/s from 32
clients on the benchmark machine. That is bound by commits; sessions that only record analytics can
`SET synchronous_commit = off` for about 110,000/s, trading the last few milliseconds of events on a crash. One sender
delivers about 130,000 events/s, and four deliver about 270,000/s.

The backlog is capped at `events_max_queued` (default 1,000,000). Beyond it the oldest events are dropped and counted,
as the SDK drops the oldest when its buffer is full. Change the cap as the owner:

```sql
INSERT INTO flagsmith.settings (events_max_queued) VALUES (5000000)
ON CONFLICT (id) DO UPDATE SET events_max_queued = excluded.events_max_queued;
```

## Walkthrough

[demos/README.md](../demos/README.md#demo-2-ab-testing-a-sql-ranking-query) runs a complete experiment: a SQL ranking
query with two arms, simulated traffic recorded through the queue, and Flagsmith's results page.
