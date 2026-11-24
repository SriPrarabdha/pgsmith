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
```

pg_flagsmith keeps a read-only replica of your Flagsmith environments in Postgres and evaluates flags there:
segments, every condition operator, percentage splits, multivariate variants, segment and identity overrides, and
flag dependencies. It is pure SQL and PL/pgSQL, so it installs as a **Trusted Language Extension** on **Supabase** and
**Amazon RDS/Aurora**, and as a plain extension on any **PostgreSQL 14–18**.

It ships with two tools built on it:

* **FlagShift**, a `terraform plan` for flag changes: shows, over your real users, who a proposed change (or a
  staging → production promotion) moves and why, as a CLI and a GitHub Action, then applies it and verifies it.
* **A/B testing a SQL ranking query**: Postgres picks each user's arm with the SDKs' exact bucketing and ranks with that
  arm's formula; Flagsmith Experimentation reads the exposures and conversions.

## How we know it is right

Parity means: for the same input, pg_flagsmith returns what `flag_engine.get_evaluation_result(context)` returns.
That is checked by three independent oracles. This is strong evidence, not a formal proof.

| Oracle | Result |
|---|---|
| Flagsmith's [engine-test-data](https://github.com/Flagsmith/engine-test-data) v3.13.2 (230 cases) | **230/230** on the interpreter; **211/230** compiled, the other 19 (flag dependencies) are served by the interpreter by design |
| The official Python engine (flagsmith-flag-engine 11.1.2) on random contexts (Hypothesis) | final run: **5,000** random contexts on the interpreter and **3,069** on the compiled tier (the other 1,931 had flag dependencies, which the interpreter serves), **0 differences**; contexts mix nested ALL/ANY/NONE rules, every operator, big ints, Unicode, SemVer pre-releases, numeric-looking strings and flag-dependency cycles |
| Your live Flagsmith, through the official Python SDK in local-evaluation mode | `pg-flagsmith parity`: 10,000 identities × every flag × both tiers, **0 mismatches** against a self-hosted Flagsmith 2.295.2 |

Plus differential fuzzing of the building blocks against Python itself (`int()`, `float()`, `repr(float)`, `%`,
`re.match`, python-semver, the hash), boundary tests (the 1-in-9,999 rehash, the exact 50.0 split boundary, floor modulo,
regex anchoring and newlines, SemVer precedence), and property tests (atomic reloads, idempotent loads, monotone splits,
prepared statements following reloads). CI runs the corpus on PostgreSQL 14, 15, 16, 17 and 18, on Supabase's image
through pg_tle, and in a non-C-locale database.

## Install

**Supabase, Amazon RDS / Aurora (pg_tle)**: run the generated installer in the SQL editor or psql:

```bash
python extension/build.py                       # writes extension/dist/
psql "$DATABASE_URL" -f extension/dist/pg_flagsmith--0.1.0.pgtle.sql
# or: pg-flagsmith install --tle --dsn "$DATABASE_URL"
```

On RDS, add `pg_tle` to `shared_preload_libraries` first and run as a member of `pgtle_admin`. Supabase preloads it.
The database must be UTF-8.

**Self-managed Postgres**: `make install` (PGXS), then `CREATE EXTENSION pg_flagsmith;`.

**database.dev**: `extension/dist/dbdev/` is a ready package (`dbdev publish` from that directory).

Grant evaluation to your application roles: `GRANT flagsmith_reader TO authenticated;` (Supabase) or to your app user.
Nothing in the `flagsmith` schemas is granted to `PUBLIC`.

## Keep it in sync

```bash
pip install ./                                  # the pg-flagsmith and flagshift commands
export PGFS_DSN=postgresql://...                # a role that can run flagsmith.load_context (flagsmith_loader)
export FLAGSMITH_API_URL=https://your-flagsmith/api/v1/
export FLAGSMITH_SERVER_KEYS=ser.xxxx,ser.yyyy  # server-side environment keys
pg-flagsmith sync --once                        # or --poll 30
pg-flagsmith serve --port 8080 --poll 30        # webhook receiver (POST /webhook, HMAC-checked) + polling backstop
```

The sync fetches each environment document and maps it with the **official SDK's own mapper**, so the mapping is
correct by construction. Each load is **one transaction**: a statement sees the whole old configuration or the whole new
one. Unchanged documents are deduplicated. If Flagsmith is unreachable, the last snapshot keeps serving ("fail static")
and `flagsmith.health()` reports its age. To have identity overrides mirrored, turn on *Environment Settings → SDK
Settings → Use identity overrides in local evaluation* in Flagsmith.

`infra/docker-compose.yml` runs the whole thing locally: self-hosted Flagsmith (with experimentation), a Supabase
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
| `flagsmith.evaluate_context(context json)` | the engine's whole result for an EvaluationContext, as JSON |
| `flagsmith.plan(env, candidate, population)` / `plan_diff` / `cohort_overlap` | FlagShift in SQL |
| `flagsmith.health()` | one row per environment: snapshot, age, warnings, compiled or not, last parity check, `status` |
| `flagsmith.pin(env, snapshot_id)` / `unpin(env)` | emergency brake: serve a previous configuration everywhere, now |

Traits are a JSON object of `name: value` (strings, numbers, booleans, null). The identity key used for splits and
variants is `<environment key>_<identifier>` as in the SDKs; pass `identity_key` to override it.

**Per-request queries**: evaluate the flag once, not once per row: put it in a `MATERIALIZED` CTE (see the ranking
example above). **Population scans**: `flagsmith.flags()` is parallel safe. Turn JIT off for sessions that evaluate
flags over many rows (`SET jit = off`, or `ALTER ROLE ... SET jit = off`): Postgres's default `jit_above_cost`
triggers on these scans, and compiling the generated expressions costs about two seconds per query while saving
nothing. FlagShift's functions set it themselves.

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
* `--format markdown` for pull requests; `action/action.yml` is a GitHub Action that posts the plan as a comment.
* `flagshift apply ...` writes the change through Flagsmith's Admin API, re-syncs, and verifies that the plan against the
  new live configuration is empty. `flagshift pin/unpin/history` manage snapshots.

Change Requests and Release Pipelines are Flagsmith Enterprise features; FlagShift gives open-source self-hosters a
review step.

## Performance

Measured on Flagsmith's Edge Proxy benchmark profile (50 features, 15 segments, 750 overrides, 15 conditions per
segment, 1M users), Postgres 17 in Docker on a Ryzen 9 9950X3D. Full table and script: [bench/RESULTS.md](bench/RESULTS.md).

| | |
|---|---|
| 1M users × 50 flags, 8 parallel workers | **5.9 s, ~8.5M flag evaluations/s** |
| 1M users × 50 flags, 4 parallel workers | 10.5 s, ~4.7M flag evaluations/s |
| per identity, all 50 flags, one core (compiled) | ~48 µs (the official Python engine: ~203 µs) |
| point lookup, prepared, localhost | one flag ~0.3 ms p50; all 50 flags ~0.5 ms p50 (mostly executor start-up for the inlined plan) |
| load + compile a snapshot | ~80 ms |

Two evaluation tiers share one contract: an **interpreter** (PL/pgSQL, any snapshot, flag dependencies, the
correctness baseline) and a **compiler** that turns each snapshot into a `LANGUAGE sql` function: every condition value
parsed at load, segments evaluated once per identity, overrides picked from constant arrays, cheapest conditions
first, split hashes reduced in bigint arithmetic, constant IN lists hashed. Both are checked against the corpus and
against each other.

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

## Repository

```
extension/sql/      the extension, in load order (schema, Python compatibility, hash, SemVer, regex, JSONPath,
                    loader, interpreter, compiler, API, operations, FlagShift, grants)
extension/build.py  builds dist/: the install script, the pg_tle installer, the database.dev package
tools/pgflagsmith/  pg-flagsmith (sync, serve, parity, install, health) and flagshift
tests/              conformance corpus, differential fuzzing, properties
bench/              benchmark profile, runner, RESULTS.md
demos/              Flagsmith seed, FlagShift and search A/B walkthroughs
infra/              docker compose: Flagsmith + Supabase Postgres + sync
action/             the FlagShift GitHub Action
```

`make venv db test fuzz matrix bench up seed` cover development; see `Makefile`.
