-- Operations: publishing, garbage collection, the emergency pin, health.

-- The extension's own name ('pg_flagsmith', or '<handle>@pg_flagsmith' from database.dev).
CREATE FUNCTION flagsmith._ext_name() RETURNS text
LANGUAGE sql STABLE
BEGIN ATOMIC
  SELECT e.extname::text FROM pg_extension e JOIN pg_depend d
    ON d.refclassid = 'pg_extension'::regclass AND d.refobjid = e.oid AND d.deptype = 'e'
  WHERE d.classid = 'pg_namespace'::regclass AND d.objid = 'flagsmith'::regnamespace;
END;

-- Generated functions belong to the extension: DROP EXTENSION removes them,
-- pg_dump leaves them out (they are rebuilt from the configuration), and
-- linters that skip extension objects skip them.
CREATE FUNCTION flagsmith._adopt(fn regprocedure) RETURNS void
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE ext text := flagsmith._ext_name();
BEGIN
  IF ext IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
                                     AND d.objid = fn AND d.deptype = 'e') THEN
    EXECUTE format('ALTER EXTENSION %I ADD FUNCTION %s', ext, fn);
  END IF;
END $$;

CREATE FUNCTION flagsmith._drop_generated(fn regprocedure) RETURNS void
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE ext text := flagsmith._ext_name();
BEGIN
  IF ext IS NOT NULL AND EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
                                 AND d.objid = fn AND d.deptype = 'e') THEN
    EXECUTE format('ALTER EXTENSION %I DROP FUNCTION %s', ext, fn);
  END IF;
  EXECUTE format('DROP FUNCTION %s', fn);
END $$;

-- (Re)create an environment's published entry points for its current snapshot:
--   flagsmith_c.flags_<alias>(identifier, traits, identity_key)
--   flagsmith_c.flag_<alias>(feature, identifier, traits, identity_key)
-- and, for the default environment, flagsmith.flags(...) / flagsmith.flag(...).
CREATE FUNCTION flagsmith._publish(ek text) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  env flagsmith.environment;
  snap flagsmith.snapshot;
  t text;
  fname text;
BEGIN
  SELECT * INTO env FROM flagsmith.environment e WHERE e.env_key = ek;
  IF env.current_snapshot IS NULL THEN RETURN; END IF;
  SELECT * INTO snap FROM flagsmith.snapshot s WHERE s.snapshot_id = env.current_snapshot;
  -- Bodies are SQL-standard (BEGIN ATOMIC): names are resolved here, under this
  -- function's search_path, not under the caller's; the planner still inlines them.
  FOREACH t IN ARRAY CASE WHEN env.is_default THEN ARRAY[format('flagsmith_c.%I', 'flags_' || env.alias), 'flagsmith.flags']
                          ELSE ARRAY[format('flagsmith_c.%I', 'flags_' || env.alias)] END LOOP
    EXECUTE format($f$CREATE OR REPLACE FUNCTION %s(identifier text, traits jsonb DEFAULT '{}', identity_key text DEFAULT NULL)
      RETURNS SETOF flagsmith.flag_result LANGUAGE sql STABLE PARALLEL SAFE
      BEGIN ATOMIC %s; END$f$, t,
      CASE WHEN snap.compiled
           THEN format('SELECT * FROM flagsmith_c.flags_s%s(identifier, traits, identity_key, false)', snap.snapshot_id)
           ELSE format('SELECT * FROM flagsmith.get_flags(identifier, traits, %L, NULL, identity_key)', ek) END);
    EXECUTE format('REVOKE ALL ON FUNCTION %s(text, jsonb, text) FROM PUBLIC', t);
    PERFORM flagsmith._grant_reader(format('FUNCTION %s(text, jsonb, text)', t));
    PERFORM flagsmith._adopt(format('%s(text, jsonb, text)', t)::regprocedure);
  END LOOP;
  FOREACH t IN ARRAY CASE WHEN env.is_default THEN ARRAY[format('flagsmith_c.%I', 'flag_' || env.alias), 'flagsmith.flag']
                          ELSE ARRAY[format('flagsmith_c.%I', 'flag_' || env.alias)] END LOOP
    -- the feature parameter, qualified by the function's own name
    fname := CASE WHEN t = 'flagsmith.flag' THEN 'flag' ELSE 'flag_' || env.alias END;
    EXECUTE format($f$CREATE OR REPLACE FUNCTION %s(feature text, identifier text, traits jsonb DEFAULT '{}', identity_key text DEFAULT NULL)
      RETURNS SETOF flagsmith.flag_result LANGUAGE sql STABLE PARALLEL SAFE
      BEGIN ATOMIC %s; END$f$, t,
      CASE WHEN snap.compiled
           THEN format('SELECT * FROM flagsmith_c.flag_s%s(%I.feature, identifier, traits, identity_key, false)',
                       snap.snapshot_id, fname)
           ELSE format('SELECT * FROM flagsmith.get_flags(identifier, traits, %L, NULL, identity_key) f WHERE f.feature = %I.feature',
                       ek, fname) END);
    EXECUTE format('REVOKE ALL ON FUNCTION %s(text, text, jsonb, text) FROM PUBLIC', t);
    PERFORM flagsmith._grant_reader(format('FUNCTION %s(text, text, jsonb, text)', t));
    PERFORM flagsmith._adopt(format('%s(text, text, jsonb, text)', t)::regprocedure);
  END LOOP;
END $$;

CREATE FUNCTION flagsmith._grant_reader(obj text) RETURNS void
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_reader') THEN
    EXECUTE format('GRANT EXECUTE ON %s TO flagsmith_reader', obj);
  END IF;
END $$;

CREATE FUNCTION flagsmith._drop_compiled(sid bigint) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE fn regprocedure;
BEGIN
  fn := to_regprocedure(format('flagsmith_c.flags_s%s(text, jsonb, text, boolean)', sid));
  IF fn IS NOT NULL THEN PERFORM flagsmith._drop_generated(fn); END IF;
  fn := to_regprocedure(format('flagsmith_c.flag_s%s(text, text, jsonb, text, boolean)', sid));
  IF fn IS NOT NULL THEN PERFORM flagsmith._drop_generated(fn); END IF;
END $$;

-- Delete old snapshots: live ones beyond keep_snapshots whose successor has
-- served for longer than the grace period (so a long query still reading one
-- is not pulled from under it), stale candidates, and test snapshots.
CREATE FUNCTION flagsmith.gc(env text DEFAULT NULL) RETURNS int
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT s.snapshot_id
    FROM flagsmith.snapshot s
    JOIN flagsmith.environment e USING (env_key)
    WHERE (env IS NULL OR e.env_key = env OR e.alias = env)
      AND s.snapshot_id IS DISTINCT FROM e.current_snapshot
      AND (
        (s.kind = 'live'
         AND s.snapshot_id NOT IN (SELECT s2.snapshot_id FROM flagsmith.snapshot s2
                                   WHERE s2.env_key = e.env_key AND s2.kind = 'live'
                                   ORDER BY s2.snapshot_id DESC LIMIT e.keep_snapshots)
         AND EXISTS (SELECT 1 FROM flagsmith.snapshot s3
                     WHERE s3.env_key = e.env_key AND s3.kind = 'live' AND s3.snapshot_id > s.snapshot_id
                       AND s3.loaded_at < clock_timestamp() - e.gc_grace))
        OR (s.kind = 'candidate' AND (s.loaded_at < clock_timestamp() - interval '7 days'
                                      OR s.snapshot_id NOT IN (SELECT s4.snapshot_id FROM flagsmith.snapshot s4
                                                               WHERE s4.env_key = e.env_key AND s4.kind = 'candidate'
                                                               ORDER BY s4.snapshot_id DESC LIMIT 100)))
        OR (s.kind = 'test' AND s.loaded_at < clock_timestamp() - interval '1 hour')
      )
  LOOP
    BEGIN
      PERFORM flagsmith._drop_compiled(r.snapshot_id);
      DELETE FROM flagsmith.snapshot s WHERE s.snapshot_id = r.snapshot_id;
      n := n + 1;
    EXCEPTION WHEN dependent_objects_still_exist THEN
      -- a user view or function calls this snapshot's compiled function: keep it
      RAISE WARNING 'pg_flagsmith: snapshot % is still referenced (%); not collected', r.snapshot_id, SQLERRM;
    END;
  END LOOP;
  -- the load log keeps 30 days, and at least the last 100 entries per environment
  DELETE FROM flagsmith.load_log l
  WHERE l.at < clock_timestamp() - interval '30 days'
    AND (env IS NULL OR l.env_key IN (SELECT e.env_key FROM flagsmith.environment e WHERE e.env_key = env OR e.alias = env))
    AND l.load_id < (SELECT min(x.load_id) FROM (SELECT l2.load_id FROM flagsmith.load_log l2
                                                 WHERE l2.env_key = l.env_key ORDER BY l2.load_id DESC LIMIT 100) x);
  RETURN n;
END $$;

-- Remove every test snapshot now (conformance runs).
CREATE FUNCTION flagsmith.drop_test_snapshots() RETURNS int
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT s.snapshot_id FROM flagsmith.snapshot s WHERE s.kind = 'test' LOOP
    PERFORM flagsmith._drop_compiled(r.snapshot_id);
    DELETE FROM flagsmith.snapshot s WHERE s.snapshot_id = r.snapshot_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- Emergency brake: serve a previous snapshot and stop sync loads from flipping
-- the pointer until unpin(). Works while Flagsmith is unreachable.
CREATE FUNCTION flagsmith.pin(env text, snapshot_id bigint) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE ek text;
BEGIN
  SELECT e.env_key INTO ek FROM flagsmith.environment e WHERE e.env_key = env OR e.alias = env OR e.name = env
  ORDER BY (e.env_key = env) DESC LIMIT 1;
  IF ek IS NULL THEN RAISE EXCEPTION 'pg_flagsmith: unknown environment %', env; END IF;
  IF NOT EXISTS (SELECT 1 FROM flagsmith.snapshot s WHERE s.snapshot_id = pin.snapshot_id
                 AND s.env_key = ek AND s.kind IN ('live', 'candidate')) THEN
    RAISE EXCEPTION 'pg_flagsmith: snapshot % is not a live or candidate snapshot of %', snapshot_id, ek;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('flagsmith:' || ek, 0));
  IF NOT (SELECT s.compiled FROM flagsmith.snapshot s WHERE s.snapshot_id = pin.snapshot_id)
     AND (SELECT e.compile FROM flagsmith.environment e WHERE e.env_key = ek) THEN
    PERFORM flagsmith.compile_snapshot(snapshot_id);
  END IF;
  UPDATE flagsmith.environment e SET current_snapshot = snapshot_id, pinned = true WHERE e.env_key = ek;
  PERFORM flagsmith._publish(ek);
  INSERT INTO flagsmith.load_log (env_key, snapshot_id, source, outcome, detail)
  VALUES (ek, snapshot_id, 'pin', 'pinned', 'pinned by ' || session_user);
END $$;

CREATE FUNCTION flagsmith.unpin(env text) RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE ek text; latest bigint;
BEGIN
  SELECT e.env_key INTO ek FROM flagsmith.environment e WHERE e.env_key = env OR e.alias = env OR e.name = env
  ORDER BY (e.env_key = env) DESC LIMIT 1;
  IF ek IS NULL THEN RAISE EXCEPTION 'pg_flagsmith: unknown environment %', env; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('flagsmith:' || ek, 0));
  SELECT max(s.snapshot_id) INTO latest FROM flagsmith.snapshot s WHERE s.env_key = ek AND s.kind = 'live';
  UPDATE flagsmith.environment e SET pinned = false, current_snapshot = coalesce(latest, e.current_snapshot)
  WHERE e.env_key = ek;
  PERFORM flagsmith._publish(ek);
  INSERT INTO flagsmith.load_log (env_key, snapshot_id, source, outcome, detail)
  VALUES (ek, latest, 'unpin', 'loaded', 'unpinned by ' || session_user);
  RETURN latest;
END $$;

-- Recompile and republish current snapshots (after a restore, or an upgrade).
CREATE FUNCTION flagsmith.recompile(env text DEFAULT NULL) RETURNS int
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT e.env_key, e.current_snapshot, e.compile FROM flagsmith.environment e
           WHERE e.current_snapshot IS NOT NULL AND (env IS NULL OR e.env_key = env OR e.alias = env) LOOP
    IF r.compile THEN PERFORM flagsmith.compile_snapshot(r.current_snapshot); END IF;
    PERFORM flagsmith._publish(r.env_key);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- One row per mirrored environment. Alert on status <> 'ok'.
CREATE FUNCTION flagsmith.health(stale_after interval DEFAULT '5 minutes')
RETURNS TABLE (
  env_key text, name text, alias text, is_default boolean,
  snapshot_id bigint, source text, source_rev text, loaded_at timestamptz,
  last_sync_at timestamptz, age interval, pinned boolean, compiled boolean, interpreted_reason text,
  errors int, warnings int, parity_checked_at timestamptz, parity_mismatches int,
  status text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT e.env_key, e.name, e.alias, e.is_default,
         s.snapshot_id, s.source, s.source_rev, s.loaded_at,
         greatest(l.at, e.last_checked_at), clock_timestamp() - coalesce(greatest(l.at, e.last_checked_at), s.loaded_at), e.pinned,
         coalesce(s.compiled, false), CASE WHEN NOT coalesce(s.compiled, false) THEN s.compile_note END,
         coalesce(w.errors, 0), coalesce(w.warnings, 0), p.started_at, p.mismatches,
         CASE
           WHEN s.snapshot_id IS NULL THEN 'no_snapshot'
           WHEN e.pinned THEN 'pinned'
           WHEN coalesce(w.errors, 0) > 0 THEN 'error'
           WHEN p.mismatches > 0 THEN 'parity_mismatch'
           WHEN clock_timestamp() - coalesce(greatest(l.at, e.last_checked_at), s.loaded_at) > stale_after THEN 'stale'
           ELSE 'ok'
         END
  FROM flagsmith.environment e
  LEFT JOIN flagsmith.snapshot s ON s.snapshot_id = e.current_snapshot
  LEFT JOIN LATERAL (SELECT max(ll.at) AS at FROM flagsmith.load_log ll
                     WHERE ll.env_key = e.env_key AND ll.outcome IN ('loaded', 'unchanged', 'reused', 'pinned')) l ON true
  LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE sw.severity = 'error')::int AS errors,
                            count(*) FILTER (WHERE sw.severity = 'warning')::int AS warnings
                     FROM flagsmith.snapshot_warning sw WHERE sw.snapshot_id = e.current_snapshot) w ON true
  LEFT JOIN LATERAL (SELECT pr.started_at, pr.mismatches FROM flagsmith.parity_run pr
                     WHERE pr.env_key = e.env_key ORDER BY pr.run_id DESC LIMIT 1) p ON true
  WHERE e.env_key <> '__pg_flagsmith_test__'
  ORDER BY e.is_default DESC, e.env_key
$$;

-- Record a live parity check result (used by `pg-flagsmith parity`).
CREATE FUNCTION flagsmith.record_parity(env text, snapshot_id bigint, oracle text, identities int,
                                        flags_compared bigint, mismatches int, details jsonb)
RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  INSERT INTO flagsmith.parity_run (env_key, snapshot_id, oracle, identities, flags_compared, mismatches, details)
  VALUES ((SELECT e.env_key FROM flagsmith.environment e WHERE e.env_key = env OR e.alias = env LIMIT 1),
          snapshot_id, oracle, identities, flags_compared, mismatches, details)
  RETURNING run_id
$$;

-- Read-only views for operators (owner and loader).
CREATE VIEW flagsmith.warnings AS
  SELECT s.env_key, w.snapshot_id, w.severity, w.code, w.path, w.detail
  FROM flagsmith.snapshot_warning w JOIN flagsmith.snapshot s USING (snapshot_id)
  WHERE s.kind <> 'test';

-- Stop mirroring an environment: its entry points, compiled code and snapshots go.
-- (If it was the default, flagsmith.flags()/flag() fall back to the interpreter
-- until another environment is loaded.)
CREATE FUNCTION flagsmith.remove_environment(env text) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE e flagsmith.environment; fn regprocedure; r record;
BEGIN
  SELECT * INTO e FROM flagsmith.environment x WHERE x.env_key = env OR x.alias = env
  ORDER BY (x.env_key = env) DESC LIMIT 1;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('flagsmith:' || e.env_key, 0));
  IF e.is_default THEN
    EXECUTE $q$CREATE OR REPLACE FUNCTION flagsmith.flags(identifier text, traits jsonb DEFAULT '{}', identity_key text DEFAULT NULL)
      RETURNS SETOF flagsmith.flag_result LANGUAGE sql STABLE PARALLEL SAFE
      BEGIN ATOMIC SELECT * FROM flagsmith.get_flags(identifier, traits, NULL, NULL, identity_key); END$q$;
    EXECUTE $q$CREATE OR REPLACE FUNCTION flagsmith.flag(feature text, identifier text, traits jsonb DEFAULT '{}', identity_key text DEFAULT NULL)
      RETURNS SETOF flagsmith.flag_result LANGUAGE sql STABLE PARALLEL SAFE
      BEGIN ATOMIC SELECT * FROM flagsmith.get_flags(identifier, traits, NULL, NULL, identity_key) f WHERE f.feature = flag.feature; END$q$;
  END IF;
  FOR fn IN SELECT p.oid::regprocedure FROM pg_proc p
            WHERE p.pronamespace = 'flagsmith_c'::regnamespace AND p.proname IN ('flags_' || e.alias, 'flag_' || e.alias) LOOP
    PERFORM flagsmith._drop_generated(fn);
  END LOOP;
  UPDATE flagsmith.environment x SET current_snapshot = NULL WHERE x.env_key = e.env_key;
  FOR r IN SELECT s.snapshot_id FROM flagsmith.snapshot s WHERE s.env_key = e.env_key LOOP
    PERFORM flagsmith._drop_compiled(r.snapshot_id);
  END LOOP;
  UPDATE flagsmith.remote_source rs SET enabled = false WHERE rs.env_key = e.env_key;
  DELETE FROM flagsmith.event_queue q WHERE q.env_key = e.env_key;
  DELETE FROM flagsmith.event_batch b WHERE b.env_key = e.env_key;
  DELETE FROM flagsmith.event_stats st WHERE st.env_key = e.env_key;
  DELETE FROM flagsmith.environment x WHERE x.env_key = e.env_key;
  INSERT INTO flagsmith.load_log (env_key, source, outcome, detail)
  VALUES (e.env_key, 'remove', 'removed', 'removed by ' || session_user);
  RETURN true;
END $$;
