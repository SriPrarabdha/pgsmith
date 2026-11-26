# SQL reference

All functions live in the `flagsmith` schema. Traits are a JSON object of `name: value` (strings, numbers, booleans,
null). Splits and variants hash the identity key `<environment key>_<identifier>`, as the SDKs do; pass
`identity_key` to override it.

## Evaluate

| Function | Returns |
|---|---|
| `flagsmith.flags(identifier, traits jsonb, identity_key)` | every flag of the default environment, as rows of `(feature, enabled, value jsonb, variant, reason, metadata)`; compiled, inlined by the planner, parallel safe |
| `flagsmith.flag(feature, identifier, traits, identity_key)` | one flag; the planner prunes every other feature |
| `flagsmith.is_enabled(feature, identifier, traits, env)` | `boolean` |
| `flagsmith.value(feature, identifier, traits, env)` | `jsonb` |
| `flagsmith.variant(feature, identifier, traits, env)` | the multivariate arm (`text`) |
| `flagsmith.get_flags(identifier, traits, env, snapshot_id, identity_key)` | any environment or snapshot, through the interpreter; `identifier => NULL` gives the SDKs' environment flags |
| `flagsmith.get_segments(identifier, traits, env, snapshot_id, identity_key)` | the segments an identity is in |
| `flagsmith_c.flags_<alias>(...)`, `flagsmith_c.flag_<alias>(...)` | the compiled functions of every mirrored environment (the alias comes from its name, e.g. `flags_production`) |
| `flagsmith.evaluate_context(context json, compiled boolean)` | the engine's whole result for an `EvaluationContext`, as JSON |

`reason` is the engine's: `DEFAULT`, `STATIC`, `TARGETING_MATCH; segment=<name>`, `SPLIT; weight=<w>`.

## Record (experiments)

| Function | |
|---|---|
| `flagsmith.track_exposure(feature, identifier, value, traits, metadata, env)` | record that `identifier` saw `value` of `feature` |
| `flagsmith.track_event(event, identifier, value, traits, metadata, env)` | a conversion or a measurement |
| `flagsmith.track_variant(feature, identifier, traits, env)` | evaluate, record the exposure, return the arm |
| `flagsmith.event_status()` | queued, delivered, deduplicated, rejected per environment |

See [Experiments](experiments.md).

## Plan (FlagShift)

| Function | |
|---|---|
| `flagsmith.plan(env, candidate_snapshot, population regclass)` | one row per feature: users changing, turned on/off, value and variant moves |
| `flagsmith.plan_diff(env, candidate_snapshot, population, live_snapshot)` | every transition with its user count and sample identities |
| `flagsmith.cohort_overlap(snapshot_a, snapshot_b, population, only_feature)` | how many identities targeted in one snapshot are targeted the same way in another |
| `flagsmith.load_candidate(context, env_key, identity_overrides)` | load a proposed configuration that is never served |

The population is any table or view with `identifier text` and `traits jsonb` columns. See [FlagShift](flagshift.md).

## Operate

| Function | |
|---|---|
| `flagsmith.health(stale_after)` | one row per environment: snapshot, age, warnings, compiled or not, last parity check, `status` |
| `flagsmith.environments()` | mirrored environments and their aliases |
| `flagsmith.pin(env, snapshot_id)` / `unpin(env)` | serve a previous configuration everywhere, now, until unpinned |
| `flagsmith.load_history(env, n)` | recent loads |
| `flagsmith.sync_status()`, `sync_tick()`, `schedule_sync()` | in-database sync ([Sync](sync.md)) |
| `flagsmith.recompile(env)`, `gc(env)`, `remove_environment(env)` | maintenance ([Operations](operations.md)) |

## Query patterns

**One request, one evaluation.** In a per-request query, evaluate a flag once, not once per row: put it in a
`MATERIALIZED` CTE. Otherwise the planner may inline it into the scan.

```sql
WITH v AS MATERIALIZED (SELECT flagsmith.variant('search_ranking', $1, $2) AS arm)
SELECT p.id, p.title FROM products p, v
WHERE p.search @@ plainto_tsquery($3)
ORDER BY CASE v.arm WHEN 'boosted' THEN p.rank * (1 + ln(1 + p.sales)) ELSE p.rank END DESC
LIMIT 20;
```

**Whole tables.** `flagsmith.flags()` is parallel safe: `SELECT ... FROM users u, LATERAL flagsmith.flags(u.id::text,
u.traits) f` uses parallel workers. Turn JIT off for sessions that do this (`SET jit = off`, or
`ALTER ROLE reporting SET jit = off`). Postgres's default `jit_above_cost` triggers on these scans, and compiling the
generated expressions costs about two seconds per query while saving nothing.

**Pinned evaluation.** A statement always sees one configuration. For a longer job that must not see a reload
midway, pass the snapshot: `flagsmith.get_flags(id, traits, snapshot_id => 42)`.

## Roles

| Role | For | Can |
|---|---|---|
| `flagsmith_reader` | application roles | evaluate flags |
| `flagsmith_tracker` | application roles (on the primary) | record exposures and events |
| `flagsmith_planner` | FlagShift in CI | reader, plus read the live configuration and load candidates that are never served |
| `flagsmith_loader` | the sync service, operators | planner and tracker, plus load and serve configuration, pin, run syncs, deliver events |
| owner | the extension's owner | everything, including adding in-database sync sources |

Nothing is granted to `PUBLIC`, and no role can read pgsmith's tables directly: each reaches them only through the
functions granted to it.

## Supabase: flags for the signed-in user

Do not grant `flagsmith_reader` to `anon` or `authenticated`: readers can evaluate any identifier with any traits, and
row-level security policies run as the querying role. Expose a wrapper bound to the caller instead:

```sql
create function public.my_flags() returns setof flagsmith.flag_result
language sql stable security definer set search_path = '' as $$
  select * from flagsmith.flags((select auth.uid())::text,
                                coalesce((select p.traits from public.profiles p where p.id = (select auth.uid())), '{}'))
$$;
revoke all on function public.my_flags() from public, anon;
grant execute on function public.my_flags() to authenticated;

-- and for policies:
create function public.flag_on(feature text) returns boolean
language sql stable security definer set search_path = '' as $$
  select flagsmith.is_enabled(feature, (select auth.uid())::text)
$$;
create policy beta_reports on public.reports for select to authenticated
  using (not beta or public.flag_on('beta_reports'));
```
