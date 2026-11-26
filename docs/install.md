# Install

pgsmith is pure SQL and PL/pgSQL: no compiled code, so it installs wherever you can run SQL. The database must use
UTF-8 (Flagsmith hashes UTF-8 bytes), and PostgreSQL must be 14 or later.

Build the installers first (Python 3.10+, no dependencies):

```bash
python3 extension/build.py        # writes extension/dist/
```

## Supabase, Amazon RDS / Aurora (pg_tle)

Run the generated installer in the SQL editor or with psql:

```bash
psql "$DATABASE_URL" -f extension/dist/pgsmith--0.1.0.pgtle.sql
# or, with the Python tools installed:
pgsmith install --tle --dsn "$DATABASE_URL"
```

Supabase preloads pg_tle. On RDS and Aurora, add `pg_tle` to `shared_preload_libraries` in the parameter group, and
run the installer as a member of `pgtle_admin`.

## database.dev

`extension/dist/dbdev/` is a ready package (control file, script and README) that passes dbdev's checks. Publish it
from that directory with the [dbdev CLI](https://database.dev/docs/publish-extension):

```bash
cd extension/dist/dbdev && dbdev publish
```

Users then install it as with any dbdev package:

```sql
select dbdev.install('<handle>@pgsmith');
create extension "<handle>@pgsmith";
```

## Any PostgreSQL 14–18

With `pg_config` on your `PATH`:

```bash
make install                      # PGXS: copies pgsmith.control and the SQL script
psql -c 'CREATE EXTENSION pgsmith'
```

## Roles

Installing creates four roles (when the installing role may create roles): `flagsmith_reader`, `flagsmith_tracker`,
`flagsmith_planner` and `flagsmith_loader`. Grant them to your own roles:

```sql
GRANT flagsmith_reader, flagsmith_tracker TO app_user;     -- evaluate flags, record events
GRANT flagsmith_loader TO sync_user;                       -- the sync service
GRANT flagsmith_planner TO ci_user;                        -- FlagShift in CI
```

See [SQL reference: roles](sql-reference.md#roles).

## Uninstall

```sql
DROP EXTENSION pgsmith;           -- generated functions belong to the extension: no CASCADE needed
```

On pg_tle, also run `SELECT pgtle.uninstall_extension('pgsmith');` to remove the stored installer.
