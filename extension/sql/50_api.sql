-- Public evaluation API.

-- The snapshot an evaluation reads: an explicit snapshot_id, else the current
-- snapshot of `env` (environment key, alias or name; default environment when NULL).
CREATE FUNCTION flagsmith._snapshot_for(env text, snapshot_id bigint) RETURNS bigint
LANGUAGE plpgsql STABLE PARALLEL SAFE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE sid bigint;
BEGIN
  IF snapshot_id IS NOT NULL THEN
    RETURN snapshot_id;
  END IF;
  IF env IS NULL THEN
    SELECT e.current_snapshot INTO sid FROM flagsmith.environment e WHERE e.is_default;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'pg_flagsmith: no default environment; load one with flagsmith.load_context()';
    END IF;
  ELSE
    SELECT e.current_snapshot INTO sid FROM flagsmith.environment e
    WHERE e.env_key = env OR e.alias = env OR e.name = env
    ORDER BY (e.env_key = env) DESC, (e.alias = env) DESC LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'pg_flagsmith: unknown environment %', env;
    END IF;
  END IF;
  IF sid IS NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: environment % has no live snapshot yet', coalesce(env, '(default)');
  END IF;
  RETURN sid;
END $$;

-- All flags for an identity (or, with identifier NULL, the environment flags the
-- SDKs return from get_environment_flags()). Interpreted; works on any snapshot.
CREATE FUNCTION flagsmith.get_flags(
  identifier text DEFAULT NULL,
  traits jsonb DEFAULT NULL,
  env text DEFAULT NULL,
  snapshot_id bigint DEFAULT NULL,
  identity_key text DEFAULT NULL)
RETURNS SETOF flagsmith.flag_result
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT * FROM unnest((flagsmith._interp(flagsmith._snapshot_for(env, snapshot_id),
                                          identifier IS NOT NULL, identifier, identity_key,
                                          coalesce(traits, '{}'::jsonb), identifier IS NULL)).flags)
$$;

-- The segments an identity belongs to.
CREATE FUNCTION flagsmith.get_segments(
  identifier text,
  traits jsonb DEFAULT NULL,
  env text DEFAULT NULL,
  snapshot_id bigint DEFAULT NULL,
  identity_key text DEFAULT NULL)
RETURNS SETOF flagsmith.segment_result
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT * FROM unnest((flagsmith._interp(flagsmith._snapshot_for(env, snapshot_id),
                                          true, identifier, identity_key,
                                          coalesce(traits, '{}'::jsonb), false)).segments)
$$;

-- Engine-compatible evaluation of a whole EvaluationContext: returns what
-- flag_engine.get_evaluation_result(context) returns, as JSON. The context is
-- loaded as a 'test' snapshot (deduplicated by content).
CREATE FUNCTION flagsmith.evaluate_context(ctx json, compiled boolean DEFAULT false) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  sid bigint;
  ident json := ctx -> 'identity';
  has_identity boolean;
  r record;
  fl flagsmith.flag_result[];
  sg flagsmith.segment_result[];
  sql text;
BEGIN
  -- the identity is an input of the evaluation, not part of the configuration
  sid := flagsmith.load_context(
    (SELECT json_object_agg(e.key, e.value ORDER BY e.pos) FROM flagsmith._json_entries(ctx) e
     WHERE e.key NOT IN ('identity', 'flags')),
    env_key => '__pg_flagsmith_test__', source => 'test', kind => 'test', compile => compiled);
  has_identity := json_typeof(ident) = 'object' AND ident::text <> '{}' AND ident::jsonb <> '{}'::jsonb;
  IF compiled THEN
    IF NOT (SELECT s.compiled FROM flagsmith.snapshot s WHERE s.snapshot_id = sid) THEN
      RAISE EXCEPTION 'pg_flagsmith: snapshot % has no compiled code (%)', sid,
        (SELECT s.compile_note FROM flagsmith.snapshot s WHERE s.snapshot_id = sid);
    END IF;
    sql := format('SELECT array_agg(f) FROM flagsmith_c.flags_s%s($1, $2, $3, $4) f', sid);
    EXECUTE sql INTO fl
      USING CASE WHEN has_identity THEN ident ->> 'identifier' END,
            CASE WHEN has_identity THEN coalesce((ident -> 'traits')::jsonb, '{}'::jsonb) END,
            CASE WHEN has_identity THEN ident ->> 'key' END,
            true;
    sg := (flagsmith._interp(sid, has_identity, ident ->> 'identifier', ident ->> 'key',
                             coalesce((ident -> 'traits')::jsonb, '{}'::jsonb), false)).segments;
  ELSE
    SELECT i.flags, i.segments INTO fl, sg
    FROM flagsmith._interp(sid, has_identity,
                           CASE WHEN has_identity THEN ident ->> 'identifier' END,
                           CASE WHEN has_identity THEN ident ->> 'key' END,
                           CASE WHEN has_identity THEN coalesce((ident -> 'traits')::jsonb, '{}'::jsonb)
                                ELSE '{}'::jsonb END,
                           false) i;
  END IF;
  RETURN json_build_object(
    'flags', coalesce((SELECT json_object_agg(f.feature,
                         (CASE WHEN f.metadata IS NULL THEN '{}'::jsonb
                               ELSE jsonb_build_object('metadata', f.metadata) END)
                         || jsonb_build_object('enabled', f.enabled, 'name', f.feature, 'reason', f.reason,
                                               'value', f.value, 'variant', f.variant)
                         ORDER BY f.n)
                       FROM unnest(fl) WITH ORDINALITY f(feature, enabled, value, variant, reason, metadata, n)), '{}'::json),
    'segments', coalesce((SELECT json_agg(jsonb_build_object('name', s.name)
                                          || CASE WHEN s.metadata IS NULL THEN '{}'::jsonb
                                                  ELSE jsonb_build_object('metadata', s.metadata) END
                          ORDER BY s.n)
                         FROM unnest(sg) WITH ORDINALITY s(name, metadata, n)), '[]'::json));
END $$;

-- Single-flag helpers. With env NULL they use the default environment's
-- published (compiled when possible) function flagsmith.flag().
CREATE FUNCTION flagsmith.get_flag(
  feature text,
  identifier text DEFAULT NULL,
  traits jsonb DEFAULT NULL,
  env text DEFAULT NULL,
  snapshot_id bigint DEFAULT NULL,
  identity_key text DEFAULT NULL)
RETURNS flagsmith.flag_result
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT f FROM flagsmith.get_flags(identifier, traits, env, snapshot_id, identity_key) f
  WHERE f.feature = get_flag.feature
$$;

CREATE FUNCTION flagsmith.is_enabled(feature text, identifier text DEFAULT NULL, traits jsonb DEFAULT NULL,
                                     env text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE r boolean;
BEGIN
  IF env IS NULL AND identifier IS NOT NULL THEN
    SELECT f.enabled INTO r FROM flagsmith.flag(feature, identifier, coalesce(traits, '{}'::jsonb)) f;
  ELSE
    SELECT f.enabled INTO r FROM flagsmith.get_flags(identifier, traits, env) f WHERE f.feature = is_enabled.feature;
  END IF;
  RETURN r;
END $$;

CREATE FUNCTION flagsmith.value(feature text, identifier text DEFAULT NULL, traits jsonb DEFAULT NULL,
                                env text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE r jsonb;
BEGIN
  IF env IS NULL AND identifier IS NOT NULL THEN
    SELECT f.value INTO r FROM flagsmith.flag(feature, identifier, coalesce(traits, '{}'::jsonb)) f;
  ELSE
    SELECT f.value INTO r FROM flagsmith.get_flags(identifier, traits, env) f WHERE f.feature = value.feature;
  END IF;
  RETURN r;
END $$;

-- The multivariate variant key ('control' when no option is hit, NULL for a
-- feature without variants).
CREATE FUNCTION flagsmith.variant(feature text, identifier text, traits jsonb DEFAULT NULL,
                                  env text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE r text;
BEGIN
  IF env IS NULL THEN
    SELECT f.variant INTO r FROM flagsmith.flag(feature, identifier, coalesce(traits, '{}'::jsonb)) f;
  ELSE
    SELECT f.variant INTO r FROM flagsmith.get_flags(identifier, traits, env) f WHERE f.feature = variant.feature;
  END IF;
  RETURN r;
END $$;

-- Published entry points for the default environment. Every live load replaces
-- them in the same transaction: compiled code the planner can inline when the
-- snapshot compiles, otherwise these interpreter wrappers.
CREATE FUNCTION flagsmith.flags(identifier text, traits jsonb DEFAULT '{}', identity_key text DEFAULT NULL)
RETURNS SETOF flagsmith.flag_result
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT * FROM flagsmith.get_flags(identifier, traits, NULL, NULL, identity_key)
$$;

CREATE FUNCTION flagsmith.flag(feature text, identifier text, traits jsonb DEFAULT '{}', identity_key text DEFAULT NULL)
RETURNS SETOF flagsmith.flag_result
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT * FROM flagsmith.get_flags(identifier, traits, NULL, NULL, identity_key) f WHERE f.feature = flag.feature
$$;
