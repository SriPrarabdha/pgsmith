# Demos

Both demos run against the local stack: self-hosted Flagsmith 2.295.2 with experimentation enabled, and a Supabase
Postgres with pg_flagsmith installed through pg_tle.

```bash
make venv
docker compose -f infra/docker-compose.yml up -d flagsmith appdb
python extension/build.py
export PGFS_DSN=postgresql://postgres:pgfs@127.0.0.1:55433/postgres
.venv/bin/pg-flagsmith install --tle                         # pg_flagsmith via pg_tle, as on Supabase
.venv/bin/python demos/seed_flagsmith.py                     # project "Shop": Staging + Production -> demos/.env
set -a; . demos/.env; set +a
psql "$PGFS_DSN" -f demos/sql/app_users.sql                  # 100k synthetic users with traits
.venv/bin/pg-flagsmith sync --api $FLAGSMITH_API_URL --server-key $PROD_SERVER_KEY --server-key $STAGING_SERVER_KEY
.venv/bin/pg-flagsmith parity --api $FLAGSMITH_API_URL --server-key $PROD_SERVER_KEY \
    --population "SELECT identifier, traits FROM app.users" --sample 10000
```

## Demo 1: FlagShift, `terraform plan` for flag changes

1. **Two environments that look alike.** Staging and Production share segments; Staging puts `quarter_rollout`
   ahead of `enterprise` for `new_checkout`, adds a Diwali banner for `india_mobile`, and raises the upload limit
   for `app_v3`.
2. **Plan the promotion over real users:**
   `flagshift plan --env production --promote-from staging --population app.users`
   shows 12,922 users changing on `new_checkout`, including **4,426 enterprise accounts that would lose
   `v2-enterprise`** because of the priority order, plus the banner and upload-limit moves.
3. **The re-keying reveal.** `dark_mode` has the *same* 25% rule in both environments, yet only **25.0%** of Staging's
   cohort is in Production's: splits hash environment-specific keys, so "25% in staging" and "25% in production" are
   different people. FlagShift re-keys the candidate into Production's keys so the plan is exact.
4. **A pull request.** `demos/flagshift/github/flagshift.yml` + `action/action.yml` post
   `flagshift plan --format markdown` as a PR comment.
5. **Apply, sync, re-plan.**
   `flagshift apply --env production --patch demos/flagshift/enterprise_checkout.json --population app.users --server-key $PROD_SERVER_KEY`
   writes the change through the Admin API, re-syncs, and prints
   `Verified: live snapshot N now matches the plan (re-plan shows no changes).`
6. **A bad change, then the brake.** `flagshift pin production <previous snapshot>` serves the previous configuration
   to every query at once (even with Flagsmith down); `flagsmith.health()` shows `pinned`; `flagshift unpin production`.

## Demo 2: A/B testing a SQL ranking query

The ranking formula is the experiment: `control` ranks by text relevance, `boosted` blends in 30-day sales.

```bash
psql "$PGFS_DSN" -f demos/search_ab/schema.sql                      # 200k products, shop.search(), shop.rank()
psql "$PGFS_DSN" -c "SELECT * FROM shop.overlap_at_10(ARRAY['wireless headphones','smart watch','camera'])"
.venv/bin/python demos/search_ab/simulate.py --users 3000          # SIMULATED traffic
psql "$PGFS_DSN" -c "SELECT * FROM shop.experiment_results"
```

1. **One search, two users, two rankings, same SQL.** `shop.search(user, traits, 'wireless headphones')` evaluates
   `flagsmith.variant('search_ranking', ...)` once per request (a `MATERIALIZED` CTE) and orders by that arm's formula.
2. **Parity on screen.** `pg-flagsmith parity` compares the SDK and Postgres for 10,000 identities: 0 mismatches. This
   is what makes the experiment valid: an exposure attributed to the wrong arm would turn the result into noise.
3. **Check before launching.** `shop.overlap_at_10` replays searches through both arms; a mean top-10 overlap of
   ~0.4 means the arms differ enough to be measured.
4. **Traffic.** The simulator records `$flag_exposure` with `track_exposure_event` (value = the arm Postgres chose)
   and `search_result_clicked`, `add_to_cart`, `search_latency_ms` with `track_event`, to Flagsmith's experimentation
   (Flagsmith-database warehouse) and to `shop.events`.
5. **The read-out.** Flagsmith's experiment results (and `shop.experiment_results`, computed in Postgres as a cross-check)
   report lift, a 95% interval and the chance to win per metric; the latency guardrail's interval crosses zero, and
   the report says so. The traffic is simulated, and the read-out says that too.
6. **Roll out the winner by changing the flag** (e.g. 100% `boosted`). The SQL never changes.

**Exposures recorded in SQL.** `simulate.py --via-queue` records the same exposures and events with
`flagsmith.track_exposure` / `flagsmith.track_event` instead of the SDK. The database delivers them to Flagsmith in
batches: run `SELECT * FROM flagsmith.events_tick()`, or schedule it with `SELECT flagsmith.schedule_events()`, once the
in-database sync below is set up. You can also run `pg-flagsmith events --once` outside the database.
`SELECT * FROM flagsmith.event_status()` shows queued, delivered and deduplicated counts.

## Demo 3: Postgres syncs itself (Supabase)

No sync service: the database fetches the environment document, maps it with the SQL port of the SDK's mapper and
loads it, on a pg_cron schedule.

```sql
create extension if not exists http with schema extensions;
create extension if not exists pg_cron;
select vault.create_secret('<PROD_SERVER_KEY>', 'flagsmith_production');
select flagsmith.add_remote_source('production', 'http://flagsmith:8000/api/v1/', 'flagsmith_production',
                                   allow_insecure_http => true);   -- local stack only; use https in production
select * from flagsmith.sync_tick();                  -- loaded (snapshot N)
select * from flagsmith.sync_tick();                  -- unchanged (same document: not even parsed)
select flagsmith.schedule_sync('10 seconds');          -- pg_cron: CALL flagsmith.sync_run()
```

1. Change a flag in the Flagsmith UI; within one schedule interval, `flagsmith.flags()` serves it
   (`select * from flagsmith.sync_status()` shows the load).
2. Stop Flagsmith (`docker compose stop flagsmith`): `sync_status()` reports the error, `health()` goes `stale` after
   five minutes, and every query keeps using the last configuration.
3. `select flagsmith.unschedule_sync();` when done.
