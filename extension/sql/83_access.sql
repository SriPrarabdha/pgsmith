-- Narrow, privilege-checked access for the tools (FlagShift, parity, sync), so
-- that none of them needs privileges on pg_flagsmith's tables.

-- The live configuration of an environment (key, alias or name). It includes
-- identity-override identifiers: planner and loader only.
CREATE FUNCTION flagsmith.live_context(env text)
RETURNS TABLE (env_key text, name text, alias text, snapshot_id bigint, context json,
               identity_overrides json, source_rev text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT e.env_key, e.name, e.alias, s.snapshot_id, s.context, s.identity_overrides, s.source_rev
  FROM flagsmith.environment e JOIN flagsmith.snapshot s ON s.snapshot_id = e.current_snapshot
  WHERE e.env_key = env OR e.alias = env OR e.name = env
  ORDER BY (e.env_key = env) DESC, (e.alias = env) DESC
  LIMIT 1
$$;

-- The context of a live or candidate snapshot.
CREATE FUNCTION flagsmith.snapshot_context(snapshot_id bigint) RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT s.context FROM flagsmith.snapshot s
  WHERE s.snapshot_id = snapshot_context.snapshot_id AND s.kind IN ('live', 'candidate')
$$;

-- Load a FlagShift candidate: never served, compiled for fast plans, collected
-- after 7 days (at most 100 are kept per environment). The environment must
-- already be mirrored.
CREATE FUNCTION flagsmith.load_candidate(ctx json, env_key text, identity_overrides json DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE ek text;
BEGIN
  SELECT e.env_key INTO ek FROM flagsmith.environment e WHERE e.env_key = load_candidate.env_key;
  IF ek IS NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: environment % is not mirrored here', env_key;
  END IF;
  IF octet_length(ctx::text) > 67108864 THEN
    RAISE EXCEPTION 'pg_flagsmith: candidate context over 64 MB';
  END IF;
  RETURN flagsmith.load_context(ctx, env_key => ek, source => 'flagshift', kind => 'candidate',
                                identity_overrides => identity_overrides);
END $$;

-- Recent loads of an environment.
CREATE FUNCTION flagsmith.load_history(env text, n int DEFAULT 20)
RETURNS TABLE (at timestamptz, snapshot_id bigint, outcome text, source text, source_rev text, detail text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT l.at, l.snapshot_id, l.outcome, l.source, l.source_rev, l.detail
  FROM flagsmith.load_log l
  WHERE l.env_key = (SELECT e.env_key FROM flagsmith.environment e
                     WHERE e.env_key = env OR e.alias = env OR e.name = env
                     ORDER BY (e.env_key = env) DESC LIMIT 1)
  ORDER BY l.load_id DESC LIMIT least(greatest(n, 1), 1000)
$$;

-- Mirrored environments (no configuration content): for readers and tools.
CREATE FUNCTION flagsmith.environments()
RETURNS TABLE (env_key text, name text, alias text, is_default boolean, snapshot_id bigint, compiled boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT e.env_key, e.name, e.alias, e.is_default, e.current_snapshot, coalesce(s.compiled, false)
  FROM flagsmith.environment e LEFT JOIN flagsmith.snapshot s ON s.snapshot_id = e.current_snapshot
  WHERE e.env_key <> '__pg_flagsmith_test__'
  ORDER BY e.is_default DESC, e.env_key
$$;

-- A sync found the environment unchanged (HTTP 304): health() counts it as a check.
CREATE FUNCTION flagsmith.mark_checked(env_key text) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  UPDATE flagsmith.environment e SET last_checked_at = clock_timestamp()
  WHERE e.env_key = mark_checked.env_key
  RETURNING true
$$;
