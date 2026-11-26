<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img alt="pgsmith" src="assets/logo-light.svg" width="380">
  </picture>
</p>

<h3 align="center">Flagsmith feature flags, evaluated inside Postgres.</h3>

<p align="center">
  The same answers as Flagsmith's own engine · compiled to SQL the planner inlines · keeps itself in sync
</p>

<p align="center">
  <img alt="Flagsmith engine tests: 230/230" src="https://img.shields.io/badge/Flagsmith%20engine%20tests-230%2F230-8B5CF6">
  <img alt="Live parity: 0 mismatches" src="https://img.shields.io/badge/live%20parity-0%20mismatches-2ea44f">
  <img alt="PostgreSQL 14 to 18" src="https://img.shields.io/badge/PostgreSQL-14%E2%80%9318-336791?logo=postgresql&logoColor=white">
  <img alt="Supabase via pg_tle" src="https://img.shields.io/badge/Supabase-pg__tle-3FCF8E?logo=supabase&logoColor=white">
  <img alt="Licence: BSD-3-Clause" src="https://img.shields.io/badge/licence-BSD--3--Clause-blue">
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="docs/README.md">Docs</a> ·
  <a href="docs/flagshift.md">FlagShift</a> ·
  <a href="docs/how-it-works.md">How it works</a> ·
  <a href="bench/RESULTS.md">Benchmarks</a> ·
  <a href="SECURITY.md">Security</a>
</p>

---

```sql
-- every flag for one user, from any query, view, policy or job
SELECT * FROM flagsmith.flags('user-42', '{"plan": "pro", "country": "IN"}');

-- who in my user table gets the new checkout, and why
SELECT f.reason, count(*)
FROM app.users u, LATERAL flagsmith.flags(u.id::text, u.traits) f
WHERE f.feature = 'new_checkout' AND f.enabled
GROUP BY 1;

-- rank search results by the experiment arm this user is in, in the same query
WITH v AS MATERIALIZED (SELECT flagsmith.variant('search_ranking', $1, $2) AS arm)
SELECT p.* FROM products p, v
ORDER BY CASE v.arm WHEN 'boosted' THEN p.relevance * p.popularity ELSE p.relevance END DESC;
```

pgsmith keeps a read-only replica of your [Flagsmith](https://github.com/Flagsmith/flagsmith) environments in Postgres and
evaluates flags there: segments, every operator, percentage splits, multivariate variants, segment and identity
overrides, and flag dependencies. It is pure SQL, so it installs on **Supabase** and **Amazon RDS** as a Trusted
Language Extension and on any **PostgreSQL 14–18** as a plain extension.

## Why

- **Flags where your data is.** Use flags in policies, reports, batch jobs and ranking queries, with no SDK and no
  network call. A whole user table is evaluated in one parallel query: 1M users × 50 flags in 6 seconds.
- **See who a change moves before you ship it.** [FlagShift](docs/flagshift.md) is a `terraform plan` for flags. It
  evaluates the live and the proposed configuration over your real users, in a CLI or as a pull-request comment.
  Change Requests are a paid Flagsmith feature (Scale-Up and Enterprise); FlagShift gives open-source self-hosters a
  review step.
- **Postgres that keeps itself in sync.** A small service follows Flagsmith's webhooks, or on Supabase the database
  fetches its own configuration with pg_cron. Every change is one transaction, and if Flagsmith is down the last
  configuration keeps serving.
- **Experiments from SQL.** Record exposures and conversions in SQL; pgsmith delivers them to Flagsmith
  Experimentation in the SDK's format.
- **Provably the same answers.** It passes Flagsmith's own engine test suite, and it agrees with the official engine
  on thousands of random configurations and with your live Flagsmith on your real users.

## Quickstart

In a clone of this repository, with Docker:

```bash
make quickstart
```

This starts self-hosted Flagsmith and a Supabase Postgres, seeds a demo project (two environments, segments, identity
overrides), installs pgsmith the way Supabase would (pg_tle), loads 100,000 demo users and syncs. It takes about a
minute once the images are downloaded. Then:

```bash
psql postgresql://postgres:pgfs@127.0.0.1:55433/postgres \
  -c "SELECT feature, enabled, value, reason FROM flagsmith.flags('user42', '{\"plan\": \"pro\"}')"

PGSMITH_DSN=postgresql://postgres:pgfs@127.0.0.1:55433/postgres \
  .venv/bin/flagshift plan --env production --promote-from staging --population app.users
```

<p align="center">
  <img alt="flagshift plan output: who a staging to production promotion moves, and why" src="assets/flagshift-plan.svg" width="900">
</p>

Your numbers will differ: splits hash each environment's own key, which is the point of the `dark_mode` warning.

## Use it on your database

| Where | Install |
|---|---|
| **Supabase**, **Amazon RDS / Aurora** | `psql "$DATABASE_URL" -f extension/dist/pgsmith--0.1.0.pgtle.sql` (pg_tle) |
| **database.dev** | `dbdev publish` from `extension/dist/dbdev/`, then `select dbdev.install('<handle>@pgsmith')` |
| **Any PostgreSQL 14–18** | `make install`, then `CREATE EXTENSION pgsmith;` |

Then keep it in sync, with the service or from inside the database:

```bash
export PGSMITH_DSN=postgresql://...  FLAGSMITH_WEBHOOK_SECRET=...        # a flagsmith_loader role; the webhook secret
pgsmith serve --api https://flagsmith.example.com/api/v1/ --server-key ser.xxx   # signed webhooks + polling
```

```sql
select vault.create_secret('ser.xxx', 'flagsmith_production');           -- Supabase: no service at all
select flagsmith.add_remote_source('production', 'https://flagsmith.example.com/api/v1/', 'flagsmith_production');
select flagsmith.schedule_sync('30 seconds');
```

Step by step: [install](docs/install.md) · [sync](docs/sync.md) · [SQL reference and roles](docs/sql-reference.md) ·
[experiments](docs/experiments.md) · [operations](docs/operations.md).

## How it works

```mermaid
flowchart LR
  FS["Flagsmith<br/>(self-hosted or cloud)"] -->|environment document| SYNC["pgsmith serve<br/>or pg_cron in Postgres"]
  SYNC -->|one transaction| SNAP[("immutable<br/>snapshots")]
  SNAP --> COMP["compiler:<br/>SQL functions the planner inlines"]
  SNAP --> INT["interpreter"]
  COMP --> APP["flagsmith.flags() in your queries,<br/>policies, views and jobs"]
  INT --> APP
  APP -->|track_exposure, track_event| Q[("event queue")]
  Q -->|batches| FS
  SNAP --> SHIFT["FlagShift:<br/>plan, apply, pin"]
  SHIFT -->|Admin API| FS
```

Each configuration is normalised into immutable snapshot tables and compiled into a SQL function. Condition values
are parsed at load, segments are evaluated once per identity, and constant `IN` lists are hashed; the planner inlines
the function into your query and runs it in parallel. A PL/pgSQL interpreter serves any snapshot and is the
correctness baseline. Details: [how it works](docs/how-it-works.md).

## Proof

| Checked against | Result |
|---|---|
| Flagsmith's [engine-test-data](https://github.com/Flagsmith/engine-test-data) v3.13.2 | **230/230** cases |
| The official engine (flagsmith-flag-engine 11.1.2) on random configurations | **5,000** configurations, both tiers, **0** differences |
| The official SDK's mapper, for in-database sync | **10,000** documents (half deliberately broken), **0** differences |
| A live self-hosted Flagsmith 2.295.2, through the official SDK | **10,000** identities × every flag, **0** mismatches |

CI runs the suite on PostgreSQL 14, 15, 16, 17 and 18, on Supabase's image through pg_tle, and in a non-C-locale
database. Run your own live check with `pgsmith parity`.

## Performance

| Flagsmith's Edge Proxy benchmark profile (50 features, 15 segments, 750 overrides) | |
|---|---|
| 1M users × 50 flags, 8 parallel workers | **5.95 s** (8.4M flag evaluations/s) |
| One identity, all 50 flags, one core | **47 µs** (official Python engine: 204 µs) |
| Point lookup, one flag / all flags | 0.28 ms / 0.47 ms |
| In-database sync pass on Supabase, unchanged / changed | 22 ms / 39 ms |
| Record an exposure (32 clients) | 30,000/s; 113,000/s with `synchronous_commit = off` |

Full tables and scripts: [bench/RESULTS.md](bench/RESULTS.md), [bench/STRETCH.md](bench/STRETCH.md).

## Security

- No pgsmith routine resolves names through the caller's `search_path`. A test plants 727 lookalike built-in
  functions and operators ahead of `pg_catalog`, and none is ever called.
- Least-privilege roles (`flagsmith_reader`, `flagsmith_tracker`, `flagsmith_planner`, `flagsmith_loader`), tested
  action by action. Nothing is granted to `PUBLIC`.
- Configuration values never become code, and server-side keys stay in Vault.

[SECURITY.md](SECURITY.md) has the threat model, the test behind each claim, and the decisions left to you.

## Related projects

| | Evaluates in | Full flags (values, variants, overrides) | Checked against engine-test-data |
|---|---|---|---|
| **pgsmith** | Postgres (SQL) | yes | yes, 230/230 |
| Flagsmith SDKs, local evaluation | your application | yes | yes |
| [Flagsmith Edge Proxy](https://github.com/Flagsmith/edge-proxy) | a proxy service | yes | yes |
| [flagsmith-sql-flag-engine](https://github.com/Flagsmith/flagsmith-sql-flag-engine) | ClickHouse (SQL) | segment membership only | yes |
| [KirioXX/pg_flagsmith](https://github.com/KirioXX/pg_flagsmith) | Postgres, wrapping the Flagsmith Rust client | enabled state only | not stated |

## Repository

```
extension/sql/   the extension, in load order         tools/pgsmith/   pgsmith and flagshift (Python)
extension/       build.py: plain, pg_tle, database.dev tests/           conformance, fuzzing, security, Supabase
docs/            guides and reference                  bench/           benchmark profile, runners, results
demos/           FlagShift and search A/B walkthroughs infra/           Flagsmith + Supabase Postgres (compose)
action/          the FlagShift GitHub Action           scripts/         quickstart, reinstall, test matrix
```

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains the development setup and the
conformance rules every change keeps. Please report vulnerabilities privately (see [SECURITY.md](SECURITY.md)).

## Licence

[BSD-3-Clause](LICENSE), the same licence as Flagsmith.

Built for [Toggle Wars](https://www.wemakedevs.org/hackathons/flagsmith), the Flagsmith Experimentation Hackathon
(Track 3: Build on Open Source Flagsmith). Flagsmith is a trademark of its owners; pgsmith is an independent
community project.
