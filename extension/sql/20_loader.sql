-- Loader: an EvaluationContext (the engine's input format, also the format of
-- engine-test-data) becomes an immutable, numbered snapshot in one transaction.

-- Python json.loads semantics for an object: the last value of a duplicate key
-- wins, at the position of the key's first occurrence.
CREATE FUNCTION flagsmith._json_entries(j json)
RETURNS TABLE (key text, value json, pos int)
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT e.key, (array_agg(e.value ORDER BY e.n DESC))[1], (row_number() OVER (ORDER BY min(e.n)))::int
  FROM json_each(CASE WHEN json_typeof(j) = 'object' THEN j ELSE '{}'::json END)
       WITH ORDINALITY AS e(key, value, n)
  GROUP BY e.key
  ORDER BY min(e.n)
$$;

-- A JSON value reached by a JSONPath query, as a context value (non-scalars are None).
CREATE FUNCTION flagsmith.ctxval_json(j json) RETURNS flagsmith.ctxval
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE json_typeof(j)
    WHEN 'string' THEN flagsmith.ctxval_str(j #>> '{}')
    WHEN 'number' THEN
      CASE WHEN j::text ~ '[.eE]'
           THEN ROW('f', NULL, NULL, flagsmith._dec_to_float8(j::text), NULL)::flagsmith.ctxval
           ELSE ROW('i', NULL, j::text::numeric, NULL, NULL)::flagsmith.ctxval END
    WHEN 'boolean' THEN ROW('b', NULL, NULL, NULL, j::text = 'true')::flagsmith.ctxval
    ELSE ROW('n', NULL, NULL, NULL, NULL)::flagsmith.ctxval
  END
$$;

-- A JSON number as numeric, exactly as Python sees it: ints exact, floats as the
-- exact value of the double they parse to.
CREATE FUNCTION flagsmith._json_num_exact(j json) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE f float8;
BEGIN
  -- JSON cannot carry infinities; the SDK's identity overrides use priority -inf,
  -- which pg-flagsmith sync sends as the string "-Infinity"
  IF json_typeof(j) = 'string' AND lower(j #>> '{}') IN ('-infinity', '-inf') THEN RETURN '-Infinity'::numeric; END IF;
  IF json_typeof(j) = 'string' AND lower(j #>> '{}') IN ('infinity', 'inf', '+infinity', '+inf') THEN RETURN 'Infinity'::numeric; END IF;
  IF j IS NULL OR json_typeof(j) <> 'number' THEN RETURN NULL; END IF;
  IF j::text !~ '[.eE]' THEN RETURN j::text::numeric; END IF;
  f := flagsmith._dec_to_float8(j::text);
  IF f IN ('Infinity'::float8, '-Infinity'::float8) THEN RETURN f::numeric; END IF;
  RETURN flagsmith._float8_exact(f);
END $$;

CREATE FUNCTION flagsmith._warn(sid bigint, sev text, code text, path text, detail text) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO flagsmith.snapshot_warning (snapshot_id, severity, code, path, detail)
  VALUES (sid, sev, code, path, detail)
$$;

-- IN values: a JSON array, or a string (JSON array when it starts with '[' and
-- parses, otherwise split on commas, untrimmed). Non-strings become Python str().
CREATE FUNCTION flagsmith._in_values(v json) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE s text; parsed json;
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  IF json_typeof(v) = 'array' THEN
    RETURN ARRAY(SELECT flagsmith.py_str_json(e) FROM json_array_elements(v) e);
  END IF;
  IF json_typeof(v) <> 'string' THEN RETURN NULL; END IF;
  s := v #>> '{}';
  IF left(s, 1) = '[' THEN
    BEGIN
      parsed := s::json;
      IF json_typeof(parsed) = 'array' THEN
        RETURN ARRAY(SELECT flagsmith.py_str_json(e) FROM json_array_elements(parsed) e);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;  -- fall back to CSV, as the reference does on a JSON error
    END;
  END IF;
  RETURN string_to_array(s, ',');
END $$;

CREATE FUNCTION flagsmith._load_condition(
  sid bigint, cid int, rid int, cnd json, ctx json, policy text, path text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  prop text := coalesce(cnd ->> 'property', '');
  op text := coalesce(cnd ->> 'operator', '');
  v json := cnd -> 'value';
  vs text;
  is_str boolean := json_typeof(v) = 'string';
  kind text;
  pname text;
  ppath text[];
  cval flagsmith.ctxval;
  jp record;
  st text := 'ok';
  v_int numeric; v_float float8; v_bool boolean; v_sem flagsmith.semver; is_sem boolean := false;
  sem_txt text; in_set text[]; v_re text; m_div float8; m_rem float8; thr float8; parts text[];
  tr record;
BEGIN
  IF v IS NULL THEN v := 'null'::json; is_str := false; END IF;
  vs := flagsmith.py_str_json(v);

  -- where the context value comes from
  IF op = 'PERCENTAGE_SPLIT' AND prop = '' THEN
    kind := 'split_ik';
  ELSIF left(prop, 2) = '$.' THEN
    jp := flagsmith.jsonpath_parse(prop);
    IF NOT jp.ok THEN
      kind := 'trait'; pname := prop;      -- not a valid query: a trait named like one
    ELSIF NOT jp.singular THEN
      kind := 'jp_none';
      PERFORM flagsmith._warn(sid, 'warning', 'jsonpath_unsupported', path,
        format('non-singular JSONPath %s is evaluated as not set', prop));
    ELSE
      kind := 'jp_none';
      IF jp.segs[1] = '.identity' THEN
        IF cardinality(jp.segs) = 2 AND jp.segs[2] = '.identifier' THEN kind := 'jp_identifier';
        ELSIF cardinality(jp.segs) = 2 AND jp.segs[2] = '.key' THEN kind := 'jp_identity_key';
        ELSIF cardinality(jp.segs) >= 3 AND jp.segs[2] = '.traits' AND left(jp.segs[3], 1) = '.' THEN
          pname := substr(jp.segs[3], 2);
          IF cardinality(jp.segs) = 3 THEN kind := 'jp_trait';
          ELSE kind := 'jp_trait_path'; ppath := jp.segs[4:];
          END IF;
        END IF;
      ELSIF jp.segs[1] = '.flags' THEN
        IF cardinality(jp.segs) >= 2 AND left(jp.segs[2], 1) = '.' THEN
          kind := 'jp_flag'; pname := substr(jp.segs[2], 2); ppath := coalesce(jp.segs[3:], '{}');
        END IF;
      ELSE
        kind := 'jp_const';
        cval := flagsmith.ctxval_json(flagsmith.json_walk(ctx, jp.segs));
      END IF;
    END IF;
  ELSE
    kind := 'trait'; pname := prop;
  END IF;

  -- parse the condition value once, with Python's rules
  IF is_str THEN
    v_int := flagsmith.py_int(vs);
    v_float := flagsmith.py_float(vs);
    v_bool := vs NOT IN ('False', 'false');
    IF right(vs, 7) = ':semver' THEN
      is_sem := true;
      sem_txt := left(vs, -7);
      v_sem := flagsmith.semver_parse(sem_txt);
    END IF;
  ELSIF json_typeof(v) IN ('number', 'boolean') THEN
    -- outside the schema: Python's int()/float() of a number or bool
    v_float := CASE json_typeof(v) WHEN 'boolean' THEN (v::text = 'true')::int::float8
                    ELSE flagsmith._dec_to_float8(v::text) END;
    v_int := CASE json_typeof(v) WHEN 'boolean' THEN (v::text = 'true')::int
                  WHEN 'number' THEN trunc(flagsmith._json_num_exact(v)) END;
    v_bool := true;
    PERFORM flagsmith._warn(sid, 'warning', 'non_string_value', path, 'condition value is not a string');
  ELSE
    v_bool := true;
  END IF;

  CASE op
    WHEN 'IN' THEN
      in_set := flagsmith._in_values(v);
      IF in_set IS NULL THEN
        st := 'invalid';
        PERFORM flagsmith._warn(sid, 'error', 'invalid_value', path, 'IN value must be a string or an array');
      END IF;
    WHEN 'REGEX' THEN
      tr := flagsmith.py_regex_to_are(vs);
      IF tr.status = 'unsupported' AND policy = 'approximate' THEN
        tr := flagsmith.py_regex_to_are(
          regexp_replace(regexp_replace(vs, '\(\?>', '(?:', 'g'), '([*+?}])\+', '\1', 'g'));
        IF tr.status = 'ok' THEN
          PERFORM flagsmith._warn(sid, 'warning', 'regex_approximate', path,
            format('pattern %s evaluated approximately', vs));
        END IF;
      END IF;
      IF tr.status = 'ok' AND NOT flagsmith._re_compiles(tr.pattern) THEN
        tr.status := 'unsupported'; tr.detail := 'translation does not compile in Postgres';
      END IF;
      IF tr.status = 'ok' THEN
        v_re := tr.pattern;
      ELSIF tr.status = 'invalid' THEN
        st := 'invalid';
        PERFORM flagsmith._warn(sid, 'error', 'regex_invalid', path,
          format('Python rejects pattern %s (%s); the reference engine raises, pg_flagsmith evaluates false', vs, tr.detail));
      ELSE
        st := 'unsupported';
        PERFORM flagsmith._warn(sid, CASE WHEN policy = 'reject' THEN 'error' ELSE 'warning' END,
          'regex_unportable', path, format('pattern %s: %s', vs, tr.detail));
      END IF;
    WHEN 'MODULO' THEN
      IF is_str AND vs <> '' THEN
        parts := string_to_array(vs, '|');
        IF cardinality(parts) = 2 THEN
          m_div := flagsmith.py_float(parts[1]);
          m_rem := flagsmith.py_float(parts[2]);
        END IF;
      END IF;
      IF m_div = 0 THEN
        PERFORM flagsmith._warn(sid, 'error', 'modulo_zero', path,
          'zero divisor: the reference engine raises ZeroDivisionError, pg_flagsmith evaluates false');
      END IF;
    WHEN 'PERCENTAGE_SPLIT' THEN
      thr := CASE WHEN is_str THEN flagsmith.py_float(vs)
                  WHEN json_typeof(v) = 'number' THEN flagsmith._dec_to_float8(v::text) END;
    WHEN 'EQUAL', 'NOT_EQUAL', 'GREATER_THAN', 'GREATER_THAN_INCLUSIVE', 'LESS_THAN',
         'LESS_THAN_INCLUSIVE', 'CONTAINS', 'NOT_CONTAINS', 'IS_SET', 'IS_NOT_SET' THEN
      NULL;
    ELSE
      st := 'unknown_operator';
      PERFORM flagsmith._warn(sid, 'warning', 'unknown_operator', path,
        format('operator %s is not supported by the reference engine and evaluates false', op));
  END CASE;

  INSERT INTO flagsmith.condition (snapshot_id, cond_id, rule_id, property, operator, value_raw,
    prop_kind, prop_name, prop_path, const_val, v_text, v_is_str, v_int, v_float, v_bool,
    v_semver, v_is_semver, v_semver_txt, in_set, v_regex, v_mod_div, v_mod_rem, v_threshold, status)
  VALUES (sid, cid, rid, prop, op, v, kind, pname, ppath, cval, vs, is_str, v_int, v_float, v_bool,
    v_sem, is_sem, sem_txt, in_set, v_re, m_div, m_rem, thr, st);
END $$;

-- Rules in preorder: a rule, its conditions, then its sub-rules.
CREATE FUNCTION flagsmith._load_rules(
  sid bigint, seg int, rules json, parent int, path text, ctx json, policy text,
  INOUT next_rule int, INOUT next_cond int)
LANGUAGE plpgsql AS $$
DECLARE r json; k int := 0; rid int; c json; ck int; t text;
BEGIN
  IF rules IS NULL OR json_typeof(rules) <> 'array' THEN RETURN; END IF;
  FOR r IN SELECT value FROM json_array_elements(rules) LOOP
    rid := next_rule; next_rule := next_rule + 1;
    t := coalesce(r ->> 'type', '');
    IF t NOT IN ('ALL', 'ANY', 'NONE') THEN
      RAISE EXCEPTION 'pg_flagsmith: %.rules.% has rule type %, expected ALL, ANY or NONE', path, k, t;
    END IF;
    INSERT INTO flagsmith.rule (snapshot_id, rule_id, seg_ord, parent_id, ord, rule_type)
    VALUES (sid, rid, seg, parent, k, t);
    ck := 0;
    IF json_typeof(r -> 'conditions') = 'array' THEN
      FOR c IN SELECT value FROM json_array_elements(r -> 'conditions') LOOP
        PERFORM flagsmith._load_condition(sid, next_cond, rid, c, ctx, policy,
          format('%s.rules.%s.conditions.%s', path, k, ck));
        next_cond := next_cond + 1; ck := ck + 1;
      END LOOP;
    END IF;
    SELECT l.next_rule, l.next_cond INTO next_rule, next_cond
    FROM flagsmith._load_rules(sid, seg, r -> 'rules', rid, format('%s.rules.%s', path, k), ctx, policy,
                               next_rule, next_cond) l;
    k := k + 1;
  END LOOP;
END $$;

-- One feature context (an environment default or a segment override) and its variants.
CREATE FUNCTION flagsmith._load_fc(sid bigint, fcid int, fc json, seg int, ordn int, path text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  vars json := fc -> 'variants';
  nv int := 0;
  start float8 := 0.0;
  lim float8;
  r record;
  w float8;
BEGIN
  IF fc ->> 'name' IS NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: %: feature context without a name', path;
  END IF;
  INSERT INTO flagsmith.feature_context (snapshot_id, fc_id, feature_name, seg_ord, ord, feature_key,
    enabled, value, value_json, priority, metadata)
  VALUES (sid, fcid, fc ->> 'name', seg, ordn, coalesce(fc ->> 'key', ''),
    coalesce((fc ->> 'enabled')::boolean, false),
    coalesce((fc -> 'value')::jsonb, 'null'::jsonb), coalesce(fc -> 'value', 'null'::json),
    coalesce(flagsmith._json_num_exact(fc -> 'priority'), 'Infinity'::numeric),
    CASE WHEN json_typeof(fc -> 'metadata') = 'object' AND (fc -> 'metadata')::text <> '{}'
              AND (fc -> 'metadata')::jsonb <> '{}'::jsonb
         THEN (fc -> 'metadata')::jsonb END);

  IF json_typeof(vars) = 'array' AND json_array_length(vars) > 0 THEN
    -- stable sort by priority; cumulative float sums in that order, like the reference
    FOR r IN
      SELECT e.value AS v, e.n,
             coalesce(flagsmith._json_num_exact(e.value -> 'priority'), 'Infinity'::numeric) AS prio
      FROM json_array_elements(vars) WITH ORDINALITY e(value, n)
      ORDER BY 3, e.n
    LOOP
      w := CASE WHEN json_typeof(r.v -> 'weight') = 'number'
                THEN flagsmith._dec_to_float8((r.v -> 'weight')::text) ELSE 0 END;
      lim := w + start;
      nv := nv + 1;
      INSERT INTO flagsmith.variant (snapshot_id, fc_id, ord, value, variant_key, weight_txt, lo, hi)
      VALUES (sid, fcid, nv, coalesce((r.v -> 'value')::jsonb, 'null'::jsonb), r.v ->> 'key',
              flagsmith.py_str_json(coalesce(r.v -> 'weight', 'null'::json)), start, lim);
      start := lim;
    END LOOP;
    UPDATE flagsmith.feature_context SET n_variants = nv WHERE snapshot_id = sid AND fc_id = fcid;
  END IF;
END $$;

CREATE FUNCTION flagsmith._alias_for(name text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE base text; a text; k int := 1;
BEGIN
  base := left(trim(both '_' from regexp_replace(lower(coalesce(name, 'env')), '[^a-z0-9]+', '_', 'g')), 30);
  IF base = '' OR base ~ '^[0-9]' THEN base := 'env_' || base; END IF;
  a := base;
  WHILE EXISTS (SELECT 1 FROM flagsmith.environment e WHERE e.alias = a) LOOP
    k := k + 1; a := base || '_' || k;
  END LOOP;
  RETURN a;
END $$;

-- Load a context. Returns the snapshot id (an existing one when the content is unchanged).
--   ctx                 the EvaluationContext (json keeps segment order, which decides tie-breaks)
--   env_key             defaults to ctx.environment.key
--   kind                'live' (served), 'candidate' (FlagShift plans) or 'test'
--   identity_overrides  the SDK's per-identity override segments: {identifier: segment context}
--   compile             default: the environment's setting for live/candidate, false for test
CREATE FUNCTION flagsmith.load_context(
  ctx json,
  env_key text DEFAULT NULL,
  source text DEFAULT 'manual',
  source_rev text DEFAULT NULL,
  kind text DEFAULT 'live',
  identity_overrides json DEFAULT NULL,
  compile boolean DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  t0 timestamptz := clock_timestamp();
  ek text := coalesce(env_key, ctx -> 'environment' ->> 'key');
  en text := coalesce(ctx -> 'environment' ->> 'name', ek);
  env flagsmith.environment;
  sha bytea;
  sid bigint;
  existing bigint;
  seg record;
  nseg int := 0;
  next_rule int := 1;
  next_cond int := 1;
  fcid int := 0;
  nfeat int;
  nctxfc int;
  r record;
  o json;
  k int;
  rej text;
  do_compile boolean;
  n_io int := 0;
  v_ctx_rules int;
  v_ctx_conds int;
BEGIN
  IF kind NOT IN ('live', 'candidate', 'test') THEN
    RAISE EXCEPTION 'pg_flagsmith: kind must be live, candidate or test, not %', kind;
  END IF;
  IF ek IS NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: no environment key (pass env_key or set context.environment.key)';
  END IF;
  IF json_typeof(ctx) <> 'object' THEN
    RAISE EXCEPTION 'pg_flagsmith: the context must be a JSON object';
  END IF;

  -- 1. one loader per environment
  PERFORM pg_advisory_xact_lock(hashtextextended('flagsmith:' || ek, 0));

  INSERT INTO flagsmith.environment (env_key, name) VALUES (ek, en) ON CONFLICT DO NOTHING;
  SELECT * INTO env FROM flagsmith.environment e WHERE e.env_key = ek;

  -- 2. deduplicate
  sha := sha256(convert_to(ctx::text || E'\n' || coalesce(identity_overrides::text, ''), 'UTF8'));
  SELECT s.snapshot_id INTO existing FROM flagsmith.snapshot s
  WHERE s.env_key = ek AND s.kind = load_context.kind AND s.content_sha256 = sha;
  IF existing IS NOT NULL THEN
    IF coalesce(compile, false) AND NOT (SELECT s.compiled FROM flagsmith.snapshot s WHERE s.snapshot_id = existing) THEN
      PERFORM flagsmith.compile_snapshot(existing);
    END IF;
    IF kind = 'live' THEN
      IF env.current_snapshot IS DISTINCT FROM existing AND NOT env.pinned THEN
        UPDATE flagsmith.environment e SET current_snapshot = existing WHERE e.env_key = ek;
        PERFORM flagsmith._publish(ek);
        INSERT INTO flagsmith.load_log (env_key, snapshot_id, source, source_rev, outcome)
        VALUES (ek, existing, source, source_rev, 'reused');
      ELSE
        INSERT INTO flagsmith.load_log (env_key, snapshot_id, source, source_rev, outcome)
        VALUES (ek, existing, source, source_rev, CASE WHEN env.pinned THEN 'pinned' ELSE 'unchanged' END);
      END IF;
    END IF;
    RETURN existing;
  END IF;

  -- 3. normalise
  INSERT INTO flagsmith.snapshot (env_key, kind, content_sha256, context, env_name, ctx_env_key, source,
                                  source_rev, identity_overrides)
  VALUES (ek, kind, sha, ctx, en, coalesce(ctx -> 'environment' ->> 'key', ek), source, source_rev,
          identity_overrides)
  RETURNING snapshot_id INTO sid;

  -- segments (context order), then the SDK's per-identity override segments
  FOR seg IN SELECT * FROM flagsmith._json_entries(ctx -> 'segments') LOOP
    nseg := nseg + 1;
    INSERT INTO flagsmith.segment (snapshot_id, seg_ord, segment_key, name, metadata, identity_free, reads_flags)
    VALUES (sid, nseg, coalesce(seg.value ->> 'key', seg.key), coalesce(seg.value ->> 'name', ''),
            CASE WHEN json_typeof(seg.value -> 'metadata') = 'object'
                      AND (seg.value -> 'metadata')::jsonb <> '{}'::jsonb
                 THEN (seg.value -> 'metadata')::jsonb END,
            true, false);
    SELECT l.next_rule, l.next_cond INTO next_rule, next_cond
    FROM flagsmith._load_rules(sid, nseg, seg.value -> 'rules', NULL, format('segments.%s', seg.key),
                               ctx, env.regex_policy, next_rule, next_cond) l;
  END LOOP;
  v_ctx_rules := next_rule - 1;
  v_ctx_conds := next_cond - 1;
  FOR seg IN SELECT * FROM flagsmith._json_entries(identity_overrides) LOOP
    nseg := nseg + 1;
    n_io := n_io + 1;
    INSERT INTO flagsmith.segment (snapshot_id, seg_ord, segment_key, name, metadata, source,
                                   io_identifier, identity_free, reads_flags)
    VALUES (sid, nseg, coalesce(seg.value ->> 'key', 'identity_overrides'),
            coalesce(seg.value ->> 'name', 'identity_overrides'),
            CASE WHEN json_typeof(seg.value -> 'metadata') = 'object'
                      AND (seg.value -> 'metadata')::jsonb <> '{}'::jsonb
                 THEN (seg.value -> 'metadata')::jsonb END,
            'identity_override', seg.key, false, false);
    SELECT l.next_rule, l.next_cond INTO next_rule, next_cond
    FROM flagsmith._load_rules(sid, nseg, seg.value -> 'rules', NULL,
                               format('identity_overrides.%s', seg.key),
                               ctx, env.regex_policy, next_rule, next_cond) l;
  END LOOP;

  -- feature defaults: fc_id 1..n_features, in context order
  FOR r IN SELECT * FROM flagsmith._json_entries(ctx -> 'features') LOOP
    fcid := fcid + 1;
    PERFORM flagsmith._load_fc(sid, fcid, r.value, NULL, r.pos, format('features.%s', r.key));
  END LOOP;
  nfeat := fcid;
  -- overrides, segment by segment
  FOR seg IN SELECT s.seg_ord, s.source, s.io_identifier, e.key, e.value
             FROM flagsmith.segment s
             LEFT JOIN flagsmith._json_entries(ctx -> 'segments') e
               ON s.source = 'api' AND e.pos = s.seg_ord
             WHERE s.snapshot_id = sid ORDER BY s.seg_ord LOOP
    IF seg.source = 'identity_override' THEN
      o := identity_overrides -> seg.io_identifier;
    ELSE
      o := seg.value;
    END IF;
    IF seg.source = 'identity_override' AND nctxfc IS NULL THEN
      nctxfc := fcid;
    END IF;
    k := 0;
    IF json_typeof(o -> 'overrides') = 'array' THEN
      UPDATE flagsmith.segment s SET ov_first = fcid + 1
      WHERE s.snapshot_id = sid AND s.seg_ord = seg.seg_ord;
      FOR r IN SELECT value FROM json_array_elements(o -> 'overrides') LOOP
        fcid := fcid + 1;
        PERFORM flagsmith._load_fc(sid, fcid, r.value, seg.seg_ord, k,
                                   format('segments.%s.overrides.%s', coalesce(seg.key, seg.io_identifier), k));
        k := k + 1;
      END LOOP;
      UPDATE flagsmith.segment s SET ov_count = k WHERE s.snapshot_id = sid AND s.seg_ord = seg.seg_ord;
    END IF;
  END LOOP;
  nctxfc := coalesce(nctxfc, fcid);

  -- rule navigation: conditions are contiguous per rule; rules form sibling lists
  UPDATE flagsmith.rule ru SET first_cond = c.first, n_cond = c.cnt
  FROM (SELECT rule_id, min(cond_id) AS first, count(*)::int AS cnt
        FROM flagsmith.condition WHERE snapshot_id = sid GROUP BY rule_id) c
  WHERE ru.snapshot_id = sid AND ru.rule_id = c.rule_id;
  UPDATE flagsmith.rule ru SET next_sibling = x.nxt
  FROM (SELECT rule_id, lead(rule_id) OVER (PARTITION BY seg_ord, parent_id ORDER BY ord) AS nxt
        FROM flagsmith.rule WHERE snapshot_id = sid) x
  WHERE ru.snapshot_id = sid AND ru.rule_id = x.rule_id AND x.nxt IS NOT NULL;
  UPDATE flagsmith.rule ru SET first_child = x.child
  FROM (SELECT parent_id, min(rule_id) AS child FROM flagsmith.rule
        WHERE snapshot_id = sid AND parent_id IS NOT NULL GROUP BY parent_id) x
  WHERE ru.snapshot_id = sid AND ru.rule_id = x.parent_id;
  UPDATE flagsmith.segment s SET first_rule = x.first
  FROM (SELECT seg_ord, min(rule_id) AS first FROM flagsmith.rule
        WHERE snapshot_id = sid AND parent_id IS NULL GROUP BY seg_ord) x
  WHERE s.snapshot_id = sid AND s.seg_ord = x.seg_ord;

  -- SDK environment-flags filter, and flag dependencies
  UPDATE flagsmith.segment s SET
    identity_free = s.source = 'api' AND NOT EXISTS (
      SELECT 1 FROM flagsmith.rule ru JOIN flagsmith.condition c
        ON c.snapshot_id = ru.snapshot_id AND c.rule_id = ru.rule_id
      WHERE ru.snapshot_id = sid AND ru.seg_ord = s.seg_ord
        AND NOT (left(c.property, 14) IN ('$.environment.', '$.environment[')
                 OR left(c.property, 8) IN ('$.flags.', '$.flags['))),
    reads_flags = EXISTS (
      SELECT 1 FROM flagsmith.rule ru JOIN flagsmith.condition c
        ON c.snapshot_id = ru.snapshot_id AND c.rule_id = ru.rule_id
      WHERE ru.snapshot_id = sid AND ru.seg_ord = s.seg_ord AND left(c.property, 7) = '$.flags')
  WHERE s.snapshot_id = sid;

  -- identity overrides: a segment whose only rule is ALL/ANY [$.identity.identifier IN [...]]
  -- is answered by an index probe instead of a list scan
  UPDATE flagsmith.segment s SET io_indexed = true
  FROM flagsmith.rule ru JOIN flagsmith.condition c
    ON c.snapshot_id = ru.snapshot_id AND c.rule_id = ru.rule_id
  WHERE s.snapshot_id = sid AND ru.snapshot_id = sid AND ru.seg_ord = s.seg_ord
    AND ru.parent_id IS NULL AND ru.next_sibling IS NULL AND ru.first_child IS NULL
    AND ru.rule_type IN ('ALL', 'ANY') AND ru.n_cond = 1
    AND c.operator = 'IN' AND c.property = '$.identity.identifier' AND c.status = 'ok'
    AND s.first_rule = ru.rule_id;
  INSERT INTO flagsmith.identity_override (snapshot_id, in_key, seg_ord)
  SELECT DISTINCT sid, m, s.seg_ord
  FROM flagsmith.segment s
  JOIN flagsmith.rule ru ON ru.snapshot_id = sid AND ru.rule_id = s.first_rule
  JOIN flagsmith.condition c ON c.snapshot_id = sid AND c.cond_id = ru.first_cond
  CROSS JOIN LATERAL unnest(c.in_set) m
  WHERE s.snapshot_id = sid AND s.io_indexed;
  IF EXISTS (SELECT 1 FROM flagsmith.segment s WHERE s.snapshot_id = sid
             AND s.source = 'identity_override' AND NOT s.io_indexed) THEN
    RAISE EXCEPTION 'pg_flagsmith: identity_overrides segments must have the SDK shape: '
      'one ALL rule with one condition $.identity.identifier IN [...]';
  END IF;

  -- per-identity override segments, as one jsonb per identity (compiled tier lookup)
  UPDATE flagsmith.segment s SET io_overrides = x.ov
  FROM (SELECT f.seg_ord,
               jsonb_object_agg(f.feature_name, jsonb_build_object('enabled', f.enabled, 'value', f.value)
                                || CASE WHEN f.metadata IS NULL THEN '{}'::jsonb
                                        ELSE jsonb_build_object('metadata', f.metadata) END) AS ov
        FROM (SELECT DISTINCT ON (fc.seg_ord, fc.feature_name) fc.*
              FROM flagsmith.feature_context fc
              JOIN flagsmith.segment g ON g.snapshot_id = fc.snapshot_id AND g.seg_ord = fc.seg_ord
              WHERE fc.snapshot_id = sid AND g.source = 'identity_override'
              ORDER BY fc.seg_ord, fc.feature_name, fc.priority, fc.ord) f
        GROUP BY f.seg_ord) x
  WHERE s.snapshot_id = sid AND s.seg_ord = x.seg_ord;

  -- override precedence: lower priority wins, then context order
  UPDATE flagsmith.feature_context f SET win_rank = x.rnk
  FROM (SELECT fc_id, row_number() OVER (PARTITION BY feature_name ORDER BY priority, seg_ord, ord)::int AS rnk
        FROM flagsmith.feature_context WHERE snapshot_id = sid AND seg_ord IS NOT NULL) x
  WHERE f.snapshot_id = sid AND f.fc_id = x.fc_id;
  -- DEFAULT when a segment of the context overrides the feature, STATIC otherwise
  UPDATE flagsmith.feature_context f SET fallback_reason =
    CASE WHEN EXISTS (SELECT 1 FROM flagsmith.feature_context o
                      WHERE o.snapshot_id = sid AND o.seg_ord IS NOT NULL AND o.seg_ord <= nseg - n_io
                        AND o.feature_name = f.feature_name)
         THEN 'DEFAULT' ELSE 'STATIC' END
  WHERE f.snapshot_id = sid AND f.seg_ord IS NULL;

  UPDATE flagsmith.snapshot s SET
    n_ctx_segments = nseg - n_io, n_ctx_fcs = nctxfc, n_features = nfeat, n_identity_overrides = n_io,
    n_ctx_rules = v_ctx_rules, n_ctx_conds = v_ctx_conds,
    n_io_indexed = (SELECT count(*) FROM flagsmith.segment g WHERE g.snapshot_id = sid AND g.io_indexed),
    has_flag_deps = EXISTS (SELECT 1 FROM flagsmith.condition c WHERE c.snapshot_id = sid AND c.prop_kind = 'jp_flag')
  WHERE s.snapshot_id = sid;

  IF EXISTS (SELECT 1 FROM flagsmith.snapshot s WHERE s.snapshot_id = sid AND s.has_flag_deps) THEN
    PERFORM flagsmith._warn(sid, 'warning', 'flag_dependency', 'segments',
      'segments read other flags ($.flags...): this snapshot is evaluated by the interpreter');
  END IF;

  -- 4. validate: a rejected snapshot rolls back and the previous one keeps serving
  IF env.regex_policy = 'reject' AND kind <> 'test' THEN
    SELECT string_agg(w.path || ': ' || w.detail, '; ') INTO rej
    FROM flagsmith.snapshot_warning w
    WHERE w.snapshot_id = sid AND w.code = 'regex_unportable';
    IF rej IS NOT NULL THEN
      RAISE EXCEPTION 'pg_flagsmith: snapshot rejected by regex_policy = reject: %', rej
        USING HINT = 'Set flagsmith.environment.regex_policy to ''false'' or ''approximate'' to load it anyway.';
    END IF;
  END IF;

  UPDATE flagsmith.snapshot s SET load_ms = round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 2)
  WHERE s.snapshot_id = sid;

  -- 5. compile
  do_compile := coalesce(compile, CASE WHEN kind = 'test' THEN false ELSE env.compile END);
  IF do_compile THEN
    PERFORM flagsmith.compile_snapshot(sid);
  END IF;

  -- 6. flip
  IF kind = 'live' THEN
    IF NOT EXISTS (SELECT 1 FROM flagsmith.environment e WHERE e.is_default) THEN
      UPDATE flagsmith.environment e SET is_default = true WHERE e.env_key = ek;
    END IF;
    IF env.alias IS NULL THEN
      UPDATE flagsmith.environment e SET alias = flagsmith._alias_for(en) WHERE e.env_key = ek;
    END IF;
    IF env.pinned THEN
      INSERT INTO flagsmith.load_log (env_key, snapshot_id, source, source_rev, outcome, detail)
      VALUES (ek, sid, source, source_rev, 'pinned', 'environment is pinned; snapshot loaded but not served');
    ELSE
      UPDATE flagsmith.environment e SET current_snapshot = sid, name = en WHERE e.env_key = ek;
      PERFORM flagsmith._publish(ek);
      INSERT INTO flagsmith.load_log (env_key, snapshot_id, source, source_rev, outcome)
      VALUES (ek, sid, source, source_rev, 'loaded');
    END IF;
    -- 7. collect garbage
    PERFORM flagsmith.gc(ek);
  END IF;

  RAISE LOG 'pg_flagsmith load env=% snapshot=% kind=% segments=% features=% conditions=% overrides=% identity_overrides=% ms=%',
    ek, sid, kind, nseg - n_io, nfeat, next_cond - 1, fcid - nfeat, n_io,
    round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
  RETURN sid;
END $$;
