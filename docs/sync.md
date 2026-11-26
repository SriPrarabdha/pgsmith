# Keep Postgres in sync with Flagsmith

pgsmith mirrors Flagsmith's **environment document**: what Flagsmith's server-side SDKs download for local
evaluation. There are two ways to fetch it. Both load each document in **one transaction**, so a query sees the whole
old configuration or the whole new one, never a mix. If Flagsmith is unreachable or a document is malformed, the last
configuration keeps serving and `flagsmith.health()` reports its age.

To mirror identity overrides, turn on *Environment Settings → SDK Settings → Use identity overrides in local
evaluation* in Flagsmith.

## The sync service (any Postgres)

The service maps each document with the **official Python SDK's own mapper**, so the mapping is correct by
construction.

```bash
pip install .                                     # the pgsmith and flagshift commands
export PGSMITH_DSN=postgresql://...               # a role with flagsmith_loader
export FLAGSMITH_API_URL=https://flagsmith.example.com/api/v1/
export FLAGSMITH_SERVER_KEYS=ser.xxxx,ser.yyyy    # server-side environment keys, one per environment

pgsmith sync --once                               # load now (or --poll 30)

export FLAGSMITH_WEBHOOK_SECRET=...               # the signing secret of the webhook in Flagsmith
pgsmith serve --host 0.0.0.0 --port 8080 --poll 30
```

`pgsmith serve` receives Flagsmith webhooks on `POST /webhook` and syncs at once; polling catches anything missed.
Webhooks must be signed (`X-Flagsmith-Signature`); their body is never used, only as a trigger. `GET /healthz`
answers 200 while syncs succeed. A container image is in `tools/Dockerfile`, and `infra/docker-compose.yml` runs it
next to Flagsmith.

## In the database (Supabase)

There is no service to run: pg_cron fetches the document, a SQL port of the SDK's mapper maps it, and it is loaded in
the same database. The mapper is checked against the official one on 10,000 generated documents.

```sql
create extension if not exists http with schema extensions;      -- or pg_net
create extension if not exists pg_cron;

select vault.create_secret('ser.your-server-side-key', 'flagsmith_production');
select flagsmith.add_remote_source('production', 'https://flagsmith.example.com/api/v1/', 'flagsmith_production');

select * from flagsmith.sync_tick();          -- once, now
select flagsmith.schedule_sync('30 seconds'); -- pg_cron job: CALL flagsmith.sync_run()
select * from flagsmith.sync_status();        -- per source: last outcome, errors, security notes
```

| | |
|---|---|
| Key storage | Supabase Vault; read only when a request is made, never stored in a pgsmith table |
| Who can add a source | only the extension's owner (a source decides where a key is sent) |
| URLs | `https` only, unless `allow_insecure_http => true` (local stacks) |
| Transports | `http` extension (default where installed: synchronous, about 25 ms per pass); `pg_net` (asynchronous, about 1 s per pass) |
| Unchanged document | recognised by its SHA-256 and never parsed |
| Failure | the error is recorded in `sync_status()`; the last snapshot keeps serving |

Syncs never send conditional requests: Flagsmith 2.295 caches `Last-Modified` per worker, and `If-Modified-Since` can
be answered 304 for seconds after a change.

On Supabase, prefer the `http` transport: pg_net keeps the request (key included) in `net.http_request_queue` until its
worker sends it, and Supabase grants that table to `anon` and `authenticated`. pgsmith deletes its responses as soon
as it reads them, and `sync_status()` names the roles that can read pg_net's tables. See
[SECURITY.md](../SECURITY.md).

`flagsmith.unschedule_sync()` stops the job; `flagsmith.remove_remote_source(name)` removes a source.

## Loading a context yourself

Anything that produces Flagsmith's `EvaluationContext` JSON can load it:

```sql
SELECT * FROM flagsmith.apply_context(ctx, identity_overrides, 'my-loader', 'rev-42');   -- (snapshot_id, outcome)
SELECT * FROM flagsmith.load_document(doc);   -- an environment document, mapped in SQL
```
