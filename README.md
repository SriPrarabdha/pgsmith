# pg_flagsmith

**Flagsmith feature flags, evaluated inside Postgres, with the same answers as Flagsmith's official engine.**

```sql
-- every flag for one user
SELECT * FROM flagsmith.flags('user-42', '{"plan": "pro", "country": "IN"}');

-- who in my user table gets the new checkout, and why
SELECT f.reason, count(*)
FROM app.users u, LATERAL flagsmith.flags(u.id::text, u.traits) f
WHERE f.feature = 'new_checkout' AND f.enabled
GROUP BY 1;

-- rank search results with the arm a user is bucketed into, in the same query
WITH v AS MATERIALIZED (SELECT flagsmith.variant('search_ranking', $1, $2) AS arm)
SELECT p.* FROM products p, v ORDER BY CASE v.arm WHEN 'boosted' THEN ... END;

-- record the exposure for Flagsmith Experimentation (delivered in batches)
SELECT flagsmith.track_exposure('search_ranking', $1, 'boosted');
```

pg_flagsmith keeps a read-only replica of your Flagsmith environments in Postgres and evaluates flags there:
segments, every condition operator, percentage splits, multivariate variants, segment and identity overrides, and
flag dependencies. It is pure SQL and PL/pgSQL, so it installs as a **Trusted Language Extension** on **Supabase** and
**Amazon RDS/Aurora**, from **database.dev**, and as a plain extension on any **PostgreSQL 14–18**.

It keeps itself in sync. Either a small service pushes changes on Flagsmith webhooks, or, on Supabase, the
**database fetches its own configuration** with pg_cron. Experiment **exposures and events recorded in SQL** are
delivered to Flagsmith in batches.

It ships with two tools built on it:

* **FlagShift**, a `terraform plan` for flag changes: shows, over your real users, who a proposed change (or a
  staging → production promotion) moves and why, as a CLI and a GitHub Action, then applies it and verifies it.
* **A/B testing a SQL ranking query**: Postgres picks each user's arm with the SDKs' exact bucketing and ranks with that
  arm's formula; Flagsmith Experimentation reads the exposures and conversions.

## How we know it is right

Parity means: for the same input, pg_flagsmith returns what `flag_engine.get_evaluation_result(context)` returns.
That is checked by independent oracles. This is strong evidence, not a formal proof.

| Oracle | Result |
|---|---|
| Flagsmith's [engine-test-data](https://github.com/Flagsmith/engine-test-data) v3.13.2 (230 cases) | **230/230** on the interpreter; **211/230** compiled, the other 19 (flag dependencies) are served by the interpreter by design |
| The official Python engine (flagsmith-flag-engine 11.1.2) on random contexts (Hypothesis) | **5,000** random contexts on the interpreter and **3,069** on the compiled tier, **0 differences**; nested ALL/ANY/NONE rules, every operator, big ints, Unicode, SemVer pre-releases, numeric-looking strings, flag-dependency cycles |
| The official Python SDK's mapper (flagsmith 6.7.0) against the SQL mapper used by in-database sync | **5,000** random environment documents and **5,000** damaged ones (keys removed, values of the wrong type): identical contexts, key order and JSON types included, and the SQL mapper fails exactly where the SDK fails; plus engine-test-data's mapper test case (pinned commit), evaluated identically |
| Your live Flagsmith, through the official Python SDK in local-evaluation mode | `pg-flagsmith parity`: 10,000 identities × every flag × both tiers, **0 mismatches** against a self-hosted Flagsmith 2.295.2 |

Plus differential fuzzing of the building blocks against Python itself (`int()`, `float()`, `repr(float)`, `%`,
`re.match`, python-semver, the hash), boundary tests, and property tests (atomic reloads, idempotent loads, monotone
splits, prepared statements following reloads). CI runs everything on PostgreSQL 14, 15, 16, 17 and 18, on Supabase's
image through pg_tle, and in a non-C-locale database.

## Install

**Supabase, Amazon RDS / Aurora (pg_tle)**: run the generated installer in the SQL editor or psql:

```bash
python extension/build.py                       # writes extension/dist/
psql "$DATABASE_URL" -f extension/dist/pg_flagsmith--0.1.0.pgtle.sql
# or: pg-flagsmith install --tle --dsn "$DATABASE_URL"
```

On RDS, add `pg_tle` to `shared_preload_libraries` first and run as a member of `pgtle_admin`. Supabase preloads it.
The database must be UTF-8.

**database.dev**: `extension/dist/dbdev/` is a package that passes dbdev's checks (`dbdev publish` from that
directory). Users then run `select dbdev.install('<handle>@pg_flagsmith'); create extension "<handle>@pg_flagsmith";`.

**Self-managed Postgres**: `make install` (PGXS), then `CREATE EXTENSION pg_flagsmith;`.

Uninstall with `DROP EXTENSION pg_flagsmith` (generated functions belong to the extension).

## Keep it in sync

### The sync service (any Postgres)

```bash
pip install ./                                  # the pg-flagsmith and flagshift commands
export PGFS_DSN=postgresql://...                # a role with flagsmith_loader
export FLAGSMITH_API_URL=https://your-flagsmith/api/v1/
export FLAGSMITH_SERVER_KEYS=ser.xxxx,ser.yyyy  # server-side environment keys
pg-flagsmith sync --once                        # or --poll 30
export FLAGSMITH_WEBHOOK_SECRET=...             # the webhook's signing secret in Flagsmith
pg-flagsmith serve --host 0.0.0.0 --port 8080 --poll 30   # signed webhooks (POST /webhook) + polling backstop
```

The service maps each environment document with the **official SDK's own mapper**, so the mapping is correct by
construction.

### In the database (Supabase)

No service to run: pg_cron fetches the document over the `http` extension (or pg_net), a SQL port of the SDK's
mapper maps it, and it is loaded in one transaction.

```sql
create extension if not exists http with schema extensions;   -- or pg_net
create extension if not exists pg_cron;
select vault.create_secret('ser.your-server-side-key', 'flagsmith_production');
select flagsmith.add_remote_source('production', 'https://flagsmith.example.com/api/v1/', 'flagsmith_production');
select flagsmith.schedule_sync('30 seconds');                -- pg_cron job: CALL flagsmith.sync_run()
select * from flagsmith.sync_status();                       -- per source: last outcome, errors, security notes
```

The key stays in Vault, and only the extension's owner can add a source. Plain `http://` URLs are refused unless
`allow_insecure_http => true` (for local stacks). Sync runs never send conditional requests: Flagsmith 2.295 caches
`Last-Modified` per worker, so `If-Modified-Since` can be answered 304 for seconds after a change. Instead an unchanged
document is recognised by its hash and never parsed. See [SECURITY.md](SECURITY.md) for why `http` is preferred
over pg_net on Supabase.

Either way, each load is **one transaction**: a statement sees the whole old configuration or the whole new one. If
Flagsmith is unreachable, or a document is malformed, the last snapshot keeps serving ("fail static") and
`flagsmith.health()` reports its age. To have identity overrides mirrored, turn on *Environment Settings → SDK
Settings → Use identity overrides in local evaluation* in Flagsmith.

`infra/docker-compose.yml` runs everything locally: self-hosted Flagsmith (with experimentation), a Supabase
Postgres with pg_flagsmith, and the sync service.

## Use it

| Function | What it does |
|---|---|
| `flagsmith.flags(identifier, traits jsonb)` | all flags of the default environment; compiled, inlined by the planner, parallel safe |
| `flagsmith.flag(feature, identifier, traits)` | one flag; the planner prunes every other feature |
| `flagsmith.is_enabled / value / variant(feature, identifier, traits [, env])` | scalar helpers |
| `flagsmith.get_flags(identifier, traits, env, snapshot_id, identity_key)` | any environment or snapshot (interpreter); `identifier => NULL` gives the SDKs' environment flags |
| `flagsmith.get_segments(identifier, traits, ...)` | the segments an identity is in |
| `flagsmith_c.flags_<env>(...)`, `flagsmith_c.flag_<env>(...)` | the compiled functions of every mirrored environment (alias from its name) |
| `flagsmith.track_exposure / track_event / track_variant(...)` | record exposures and events for Flagsmith Experimentation (see below) |
| `flagsmith.evaluate_context(context json)` | the engine's whole result for an EvaluationContext, as JSON |
| `flagsmith.map_environment_document(doc)` / `load_document(doc)` | the SDK mapper in SQL; map and load a document you fetched yourself |
| `flagsmith.plan(env, candidate, population)` / `plan_diff` / `cohort_overlap` | FlagShift in SQL |
| `flagsmith.health()`, `sync_status()`, `event_status()` | one row per environment / source / environment: alert on `status <> 'ok'` |
| `flagsmith.pin(env, snapshot_id)` / `unpin(env)` | emergency brake: serve a previous configuration everywhere, now |

Traits are a JSON object of `name: value` (strings, numbers, booleans, null). The identity key used for splits and
variants is `<environment key>_<identifier>` as in the SDKs; pass `identity_key` to override it.

**Per-request queries**: evaluate the flag once, not once per row: put it in a `MATERIALIZED` CTE (see the ranking
example above). **Population scans**: `flagsmith.flags()` is parallel safe. Turn JIT off for sessions that evaluate
flags over many rows (`SET jit = off`, or `ALTER ROLE ... SET jit = off`): Postgres's default `jit_above_cost`
triggers on these scans, and compiling the generated expressions costs about two seconds per query while saving
nothing. FlagShift's functions set it themselves.

## Roles

| Role | For | Can |
|---|---|---|
| `flagsmith_reader` | application roles | evaluate flags |
| `flagsmith_tracker` | application roles (primary) | record exposures and events |
| `flagsmith_planner` | FlagShift in CI | reader + read live configuration, load candidates that are never served |
| `flagsmith_loader` | the sync service, operators | planner + tracker + load and serve configuration, pin, run syncs, deliver events |
| owner | the extension's owner | everything, including adding in-database sync sources |

`GRANT flagsmith_reader, flagsmith_tracker TO app_user;`. Nothing is granted to `PUBLIC`, and no role can read
pg_flagsmith's tables directly.

**Supabase: flags for the signed-in user.** Do not grant `flagsmith_reader` to `anon` or `authenticated`: readers can
evaluate any identifier. Expose a wrapper bound to the caller instead:

```sql
create function public.my_flags() returns setof flagsmith.flag_result
language sql stable security definer set search_path = '' as $$
  select * from flagsmith.flags((select auth.uid())::text,
                                coalesce((select p.traits from public.profiles p where p.id = (select auth.uid())), '{}'))
$$;
revoke all on function public.my_flags() from public, anon;
grant execute on function public.my_flags() to authenticated;
```

## Experiments: the exposure queue

Evaluation stays read-only, so `flags()`, `variant()` and friends work on replicas. Recording is an explicit write to
a queue, which the database (or `pg-flagsmith events`) delivers to Flagsmith's events API in the SDK's format:

```sql
SELECT flagsmith.track_variant('search_ranking', $1, $2);          -- evaluate, record the exposure, return the arm
SELECT flagsmith.track_event('add_to_cart', $1);                   -- a conversion
SELECT flagsmith.track_event('search_latency_ms', $1, '42');        -- with a value
SELECT flagsmith.schedule_events('10 seconds');                     -- in-database delivery (a remote source per env)
```

Delivery follows the Python SDK's event processor:
* The batch format is the same.
* Identical exposures in a batch are sent once.
* 408, 429 and 5xx are retried with backoff.
* 401/403 stops delivery for that environment and keeps the events.
* Other 4xx drop the batch and count it.

Batches are claimed with `DELETE ... FOR UPDATE SKIP LOCKED` and committed only once delivered, so an event is never
lost to a failed request and senders can run side by side. The backlog is capped (`events_max_queued`, default 1M;
the oldest are dropped and counted, as the SDK does). The queue is append-only with one index: recording costs
the same as a plain `INSERT` (about 30,000/s from 32 clients here, commit-bound; sessions that only record analytics
can `SET synchronous_commit = off` for about 110,000/s).

## FlagShift

```console
$ flagshift plan --env production --promote-from staging --population app.users
flagshift plan  Staging → Production   population: app.users (100,000 identities)

~ new_checkout           12,922 users change (12.9%)
    enabled off → on, value "v1" → "v2"             8,496 users   reason DEFAULT → TARGETING_MATCH; segment=quarter_rollout
    value "v2-enterprise" → "v2"                    4,426 users   reason TARGETING_MATCH; segment=enterprise → ...=quarter_rollout
= dark_mode              no users change
  ! same rules, different people: only 25.0% of Staging's 25,023 targeted users are targeted in Production
    (splits hash environment-specific keys)
```

* `--promote-from ENV` re-keys the source configuration into the target (target's environment key, feature keys,
  override keys and variant priorities), so the candidate buckets users exactly as the target will after the change.
* `--patch change.json` applies an RFC 6902 JSON Patch to the target's live configuration; `--candidate ctx.json`
  takes a whole context.
* `--format markdown` for pull requests; `action/action.yml` is a GitHub Action that posts the plan as a comment
  (it needs a `flagsmith_planner` role, which cannot serve anything).
* `flagshift apply ...` writes the change through Flagsmith's Admin API, re-syncs, and verifies that the plan against the
  new live configuration is empty. `flagshift pin/unpin/history` manage snapshots.

Change Requests and Release Pipelines are Flagsmith Enterprise features; FlagShift gives open-source self-hosters a
review step.

## Performance

Measured on Flagsmith's Edge Proxy benchmark profile (50 features, 15 segments, 750 overrides, 15 conditions per
segment, 1M users), Postgres 17 in Docker on a Ryzen 9 9950X3D. Full tables and scripts:
[bench/RESULTS.md](bench/RESULTS.md) and [bench/STRETCH.md](bench/STRETCH.md).

| | |
|---|---|
| 1M users × 50 flags, 8 parallel workers | **5.95 s, ~8.4M flag evaluations/s** |
| 1M users × 50 flags, 4 parallel workers | 10.5 s, ~4.75M flag evaluations/s |
| per identity, all 50 flags, one core (compiled) | ~47 µs (the official Python engine: ~204 µs) |
| point lookup, prepared, localhost | one flag ~0.28 ms p50; all 50 flags ~0.47 ms p50 (mostly executor start-up for the inlined plan) |
| load + compile a snapshot | ~117 ms |
| in-database sync run (Supabase, `http` transport): unchanged / a flag changed | 22 ms / 39 ms |
| SQL mapper, Edge Proxy profile document (0.24 MB) / with 100,000 identity overrides (60 MB) | 46 ms / 9.3 s |
| record an exposure, 32 clients | 29,804/s (a plain INSERT: 32,262/s); 113,037/s with `synchronous_commit = off` |
| deliver events (`pg-flagsmith events`, four senders) | 268,473 events/s |

Two evaluation tiers share one contract: an **interpreter** (PL/pgSQL, any snapshot, flag dependencies, the
correctness baseline) and a **compiler** that turns each snapshot into a SQL-standard function. In that function:
* every condition value is parsed at load;
* segments are evaluated once per identity;
* overrides are picked from constant arrays;
* the cheapest conditions run first;
* split hashes are reduced in bigint arithmetic;
* constant IN lists are hashed.

Both tiers are checked against the corpus and against each other.

## Security

Every pg_flagsmith routine resolves names at creation or with a pinned `search_path`. Tests plant 727 lookalike
functions and operators ahead of `pg_catalog`, and none is ever called. Least-privilege roles are tested action by
action, configuration values never become code, and server-side keys stay in Vault. [SECURITY.md](SECURITY.md) has
the threat model, the tests behind each claim, and the decisions left to you (for example: compiled function bodies,
like all function bodies in Postgres, are readable by every role that can connect).

## Operations

* `flagsmith.health()`, `flagsmith.sync_status()`, `flagsmith.event_status()`: monitor these.
* **Backups:** `pg_dump` keeps in-database sync sources and settings; snapshots and compiled functions are derived
  data and are rebuilt by the next sync (`SELECT * FROM flagsmith.sync_tick()` or `pg-flagsmith sync --once` after a
  restore).
* `flagsmith.recompile()` rebuilds compiled functions (after an upgrade). `flagsmith.gc()` runs after every load
  (old snapshots past `keep_snapshots` and a grace period, candidates after 7 days or beyond 100, load log after 30
  days). `flagsmith.remove_environment(env)` stops mirroring an environment.
* **Identity overrides scale linearly**: they load set-based, and an identity's overrides are one index probe at
  evaluation time (a document with 10,000 identities loads in 2.5–3.6 s, 100,000 in about 30 s; evaluation stays
  about 1 ms; see bench/STRETCH.md).

## Known divergences

Where Python raises an exception, the SDK call fails; pg_flagsmith evaluates the condition as false and records an
`error` warning instead: MODULO with a zero divisor, a REGEX pattern Python rejects, an IN value that is neither a
string nor an array. Also:

* REGEX patterns Postgres cannot express (atomic groups, possessive quantifiers, conditional groups, scoped
  case-insensitivity, repeat counts over 255, backreferences to repeated groups) are reported as `regex_unportable`;
  the environment's `regex_policy` decides: `reject` (default: keep serving the previous snapshot), `false`, or
  `approximate`.
* Non-singular JSONPath properties (`$.identity.traits.*`, filters, descendants) are evaluated as not set, with a
  warning: Python picks the first match in dict insertion order, which a `jsonb` trait map does not keep.
* Traits passed as `jsonb` lose the difference between `1e5` and `100000` (Python reads the first as a float).
* Unicode tables (`\d`, `\w`, `int()` digits) are generated from Python 3.12 (Unicode 15.0).
* The SQL mapper accepts multivariate `mv_fs_value_uuid` values in the spellings Flagsmith writes (hex digits with
  optional hyphens, braces, `urn:uuid:`); Python's `int(x, 16)` also takes whitespace, `+`, `_` and `0x`, which
  Flagsmith never writes.

## Repository

```
extension/sql/      the extension, in load order (schema, Python compatibility, hash, SemVer, regex, JSONPath,
                    loader, interpreter, compiler, API, operations, FlagShift, mapper, in-database sync,
                    exposure queue, access functions, grants)
extension/build.py  builds dist/: the install script, the pg_tle installer, the database.dev package
tools/pgflagsmith/  pg-flagsmith (sync, serve, events, parity, install, health) and flagshift
tests/              conformance corpus, differential fuzzing, properties, security, mapper, Supabase end to end
bench/              benchmark profile, runners, RESULTS.md, STRETCH.md
demos/              Flagsmith seed, FlagShift and search A/B walkthroughs
infra/              docker compose: Flagsmith + Supabase Postgres + sync
action/             the FlagShift GitHub Action
```

`make venv db test fuzz matrix bench up seed` cover development; see `Makefile`.
