# Security

pgsmith keeps a read-only replica of Flagsmith configuration inside your database and evaluates it there. This
page describes what it trusts, what it defends against, how each defence is tested, and what remains your call.

## Trust model

| Party | Trusted with |
|---|---|
| Flagsmith (your instance) | The configuration. Its documents are treated as **data**: names and values from it never become SQL code. |
| Owner of the extension (the role that ran `CREATE EXTENSION`) | Everything, including where in-database sync sends server-side keys. |
| `flagsmith_loader` | Loading and serving configuration, pin/unpin, running syncs, delivering events. Cannot read or redirect server-side keys. |
| `flagsmith_planner` | FlagShift in CI: read live configuration, load candidates that are never served, run plans. |
| `flagsmith_tracker` | Recording exposures and events. |
| `flagsmith_reader` | Evaluating flags. |
| Everyone else (`PUBLIC`) | Nothing. |

No role is granted any privilege on pgsmith's tables (they also have row-level security enabled with no policies);
each role reaches them only through the SECURITY DEFINER functions granted to it.

## Defences, and the tests that prove them

**1. A caller's `search_path` can never redirect pgsmith's code.** Every SQL function is SQL-standard
(`BEGIN ATOMIC`), so its names are resolved once, when it is created; every other routine pins
`search_path = pg_catalog, flagsmith, pg_temp`. That includes the functions generated for each configuration
snapshot, which stay inlinable (the planner still sees through them). The install script resolves its own names in
`pg_catalog` (`SET LOCAL`, so the installing session keeps its `search_path`).
*Tests:* `tests/sql/test_security.py` checks every routine in the catalog, then plants **727 trojans** (lookalikes of
every built-in function and operator the extension uses, which raise if called) in a schema placed before `pg_catalog`
in `search_path`, and runs loading, compiling, evaluation, FlagShift plans, the mapper and the event queue, as the
owner, a reader and a planner. None fires. A control query in the same session shows the trojans do capture ordinary SQL.

**2. Least privilege, enforced.** SECURITY DEFINER routines are granted by name, per role; internal ones (`_publish`,
`compile_snapshot`, `_remote_key`, ...) to no role. *Tests:* the exact grant matrix is asserted, and 35 allowed and
denied actions are exercised as each role (`test_each_role_can_do_its_job_and_nothing_more`).

**3. Configuration is data, not code.** Every value from a document enters generated SQL through `quote_literal`
(`%L`) or as a number; identifiers through `%I` or a validated alias (`^[a-z_][a-z0-9_]{0,39}$`). *Tests:* a context
with hostile strings in every position (`'; DROP TABLE ...`, `$$`, `$f$`, backslashes with quotes, `*/`, newlines,
`%s %L %I`, an environment key that `quote_literal` renders as `E'...'`) is compiled and evaluated on both tiers and
must match the reference engine exactly, with a canary table intact. (This found and removed a text-substitution step
in the compiler that a crafted FlagShift patch could have abused.)

**4. In-database sync keeps keys safe.**
* Server-side keys live in Supabase Vault and are read only when a request is made; no pgsmith table holds them.
* Only the owner can add or change a source (a source decides where a key is sent), so `flagsmith_loader` cannot
  exfiltrate a key by pointing a source at another URL.
* URLs must be `https` (plain `http` needs `allow_insecure_http`, for local stacks), with no credentials, query,
  fragment or whitespace.
* Documents are size-capped (`max_document_bytes`, 64 MB) and must keep the environment key the source first served.
  Any failure rolls back and the last snapshot keeps serving.
* Transport `http` (the default where the extension is installed) keeps the key and the document in memory. With
  `pg_net`, the key sits in `net.http_request_queue` until the worker sends it, and the document lands in
  `net._http_response`; Supabase grants both tables to `anon` and `authenticated`. pgsmith deletes its responses
  as soon as it reads them, and `flagsmith.sync_status()` names the roles that can read those tables.
*Tests:* `tests/remote/test_in_db_sync.py` (validation, failures keep serving, key header, no leftover responses).

**5. The exposure queue cannot be used to exhaust the database.** Input sizes are capped, the backlog is bounded
(`events_max_queued`, oldest dropped and counted, as the SDK does), and only `flagsmith_tracker` can write to it.

**6. The sync service.**
* Webhooks must carry a valid `X-Flagsmith-Signature` (HMAC-SHA256, constant-time compare) unless
  `--allow-unsigned-webhooks` is passed. Even then a webhook only triggers a fetch; its body is never used.
* Bodies are capped at 1 MB and sockets time out after 10 s.
* The service listens on 127.0.0.1 unless told otherwise. `/healthz` reveals no error details. Logs show key
  fingerprints, never keys. Documents are size-capped.
* The container runs as an unprivileged user.

*Tests:* `tests/tools/test_sync_service.py`.

**7. FlagShift in CI.**
* The GitHub Action passes every input to the shell through environment variables, so there is no `${{ }}` script
  injection.
* Actions are pinned to commit SHAs, and the workflow token is read-only by default.
* PR comments escape configuration text (no table breaks, HTML or @-mentions) and never include user identifiers.
* The CI database role needs only `flagsmith_planner`, which cannot serve anything.

**8. Dependencies.** `pip-audit`: no known vulnerabilities. `requests>=2.32.4`. The engine test corpus and the mapper
test case are pinned by commit and checksum. `bandit` reports nothing in the shipped tools beyond false positives:
`random` used for backoff jitter, and empty default secrets.

## What remains your decision

* **Compiled code is visible to every role that can connect.** PostgreSQL shows function bodies in `pg_proc` to all
  roles. Compiled snapshots contain segment rule values (never identity-override identifiers, which are looked up from
  a protected table). If untrusted roles can run SQL in this database and your segment rules hold confidential values,
  set `compile = false` for that environment: the interpreter keeps everything in protected tables.
* **End users.** Do not grant `flagsmith_reader` to Supabase's `anon` or `authenticated`. Readers can evaluate any
  identifier with any traits (as Flagsmith's client-side API allows), and trackers can record exposures for anyone.
  Expose a wrapper bound to the caller instead (see [docs/sql-reference.md](docs/sql-reference.md#supabase-flags-for-the-signed-in-user)).
* **Readers can evaluate any snapshot by id**, including FlagShift candidates (evaluation results only, never the
  configuration itself).
* **Trait values are yours.** REGEX conditions run against trait strings; cap trait sizes in your application and set
  `statement_timeout` for request paths.
* **Plain `http`** between Postgres and Flagsmith exposes the server-side key on the network; use it only on a
  private network (`allow_insecure_http`).
* **`pgsmith parity --population`** runs the SQL you give it (read-only) with your credentials.
* **The local stack** (`infra/docker-compose.yml`, `demos/`) uses development passwords and a demo admin account,
  bound to 127.0.0.1. Do not expose it.

## Reporting a vulnerability

Please report it privately (a GitHub security advisory on the repository) rather than in a public issue.
