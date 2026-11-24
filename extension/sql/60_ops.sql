-- Operations: publishing, garbage collection, the emergency pin, health.

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
  all_body text;
  one_body text;
  targets text[];
  t text;
BEGIN
  SELECT * INTO env FROM flagsmith.environment e WHERE e.env_key = ek;
  IF env.current_snapshot IS NULL THEN RETURN; END IF;
  SELECT * INTO snap FROM flagsmith.snapshot s WHERE s.snapshot_id = env.current_snapshot;
  IF snap.compiled THEN
    all_body := format('SELECT * FROM flagsmith_c.flags_s%s(identifier, traits, identity_key, false)', snap.snapshot_id);
    one_body := format('SELECT * FROM flagsmith_c.flag_s%s(feature, identifier, traits, identity_key, false)', snap.snapshot_id);
  ELSE
    all_body := format('SELECT * FROM flagsmith.get_flags(identifier, traits, %L, NULL, identity_key)', ek);
    one_body := format('SELECT * FROM flagsmith.get_flags(identifier, traits, %L, NULL, identity_key) f WHERE f.feature = feature', ek);
  END IF;
  targets := ARRAY[format('flagsmith_c.%I', 'flags_' || env.alias)];
  IF env.is_default THEN targets := targets || 'flagsmith.flags'::text; END IF;
  FOREACH t IN ARRAY targets LOOP
    EXECUTE format($f$CREATE OR REPLACE FUNCTION %s(identifier text, traits jsonb DEFAULT '{}', identity_key text DEFAULT NULL)
      RETURNS SETOF flagsmith.flag_result LANGUAGE sql STABLE PARALLEL SAFE AS %L$f$, t, all_body);
    EXECUTE format('REVOKE ALL ON FUNCTION %s(text, jsonb, text) FROM PUBLIC', t);
    PERFORM flagsmith._grant_reader(format('FUNCTION %s(text, jsonb, text)', t));
  END LOOP;
  targets := ARRAY[format('flagsmith_c.%I', 'flag_' || env.alias)];
  IF env.is_default THEN targets := targets || 'flagsmith.flag'::text; END IF;
  FOREACH t IN ARRAY targets LOOP
    EXECUTE format($f$CREATE OR REPLACE FUNCTION %s(feature text, identifier text, traits jsonb DEFAULT '{}', identity_key text DEFAULT NULL)
      RETURNS SETOF flagsmith.flag_result LANGUAGE sql STABLE PARALLEL SAFE AS %L$f$, t,
      replace(one_body, 'f.feature = feature', 'f.feature = ' || regexp_replace(t, '^.*\.', '') || '.feature'));
    EXECUTE format('REVOKE ALL ON FUNCTION %s(text, text, jsonb, text) FROM PUBLIC', t);
    PERFORM flagsmith._grant_reader(format('FUNCTION %s(text, text, jsonb, text)', t));
  END LOOP;
END $$;

CREATE FUNCTION flagsmith._grant_reader(obj text) RETURNS void
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_reader') THEN
    EXECUTE format('GRANT EXECUTE ON %s TO flagsmith_reader', obj);
  END IF;
END $$;

CREATE FUNCTION flagsmith._drop_compiled(sid bigint) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
BEGIN
  IF to_regprocedure(format('flagsmith_c.flags_s%s(text, jsonb, text, boolean)', sid)) IS NOT NULL THEN
    EXECUTE format('DROP FUNCTION flagsmith_c.flags_s%s(text, jsonb, text, boolean)', sid);
  END IF;
  IF to_regprocedure(format('flagsmith_c.flag_s%s(text, text, jsonb, text, boolean)', sid)) IS NOT NULL THEN
    EXECUTE format('DROP FUNCTION flagsmith_c.flag_s%s(text, text, jsonb, text, boolean)', sid);
  END IF;
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
        OR (s.kind = 'candidate' AND s.loaded_at < clock_timestamp() - interval '7 days')
        OR (s.kind = 'test' AND s.loaded_at < clock_timestamp() - interval '1 hour')
      )
  LOOP
    PERFORM flagsmith._drop_compiled(r.snapshot_id);
    DELETE FROM flagsmith.snapshot s WHERE s.snapshot_id = r.snapshot_id;
    n := n + 1;
  END LOOP;
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
         l.at, clock_timestamp() - coalesce(l.at, s.loaded_at), e.pinned,
         coalesce(s.compiled, false), CASE WHEN NOT coalesce(s.compiled, false) THEN s.compile_note END,
         coalesce(w.errors, 0), coalesce(w.warnings, 0), p.started_at, p.mismatches,
         CASE
           WHEN s.snapshot_id IS NULL THEN 'no_snapshot'
           WHEN e.pinned THEN 'pinned'
           WHEN coalesce(w.errors, 0) > 0 THEN 'error'
           WHEN p.mismatches > 0 THEN 'parity_mismatch'
           WHEN clock_timestamp() - coalesce(l.at, s.loaded_at) > stale_after THEN 'stale'
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
