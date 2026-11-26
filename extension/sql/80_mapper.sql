-- The environment document -> EvaluationContext mapper, in SQL.
--
-- A port of the official Python SDK's mapper (flagsmith 6.7:
-- map_environment_document_to_context and
-- map_environment_document_to_identity_overrides_segments), so that the
-- database can sync itself (pg_net / http + pg_cron) and load exactly what the
-- pusher loads. Output is checked against the Python mapper by differential
-- tests and against the mapper test case of engine-test-data.
--
-- Where the Python mapper raises (a missing key, a value of the wrong type), the
-- port raises too: the load fails and the previous snapshot keeps serving.
-- Differences, all on documents Flagsmith never produces: a multivariate
-- mv_fs_value_uuid must be 32 hex digits once 'urn:', 'uuid:', braces and
-- hyphens are removed (Python's int(x, 16) also accepts whitespace, '+',
-- underscores and '0x').

-- Python truthiness of a JSON value; a missing value (SQL NULL) is falsy.
CREATE FUNCTION flagsmith._py_truthy(j json) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
  SELECT CASE json_typeof(j)
           WHEN 'boolean' THEN j::text = 'true'
           WHEN 'number' THEN j::text::numeric <> 0
           WHEN 'string' THEN (j #>> '{}') <> ''
           WHEN 'array' THEN json_array_length(j) > 0
           WHEN 'object' THEN j::text !~ '^\s*\{\s*\}\s*$'
           ELSE false END;
END;

-- The key json.dumps() writes for a dict key (str, int, float, bool or None).
CREATE FUNCTION flagsmith._py_json_key(j json) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
  SELECT CASE json_typeof(j)
           WHEN 'string' THEN j #>> '{}'
           WHEN 'number' THEN flagsmith.py_str_json(j)
           WHEN 'boolean' THEN j::text
           ELSE 'null' END;
END;

-- Which dict key a JSON value is in Python: equal keys are one key (True == 1 == 1.0;
-- "1" is another), so a dict built from them keeps the first key and the last value.
CREATE FUNCTION flagsmith._py_key_ident(j json) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
  SELECT CASE json_typeof(j)
           WHEN 'string' THEN 's' || (j #>> '{}')
           WHEN 'boolean' THEN CASE WHEN j::text = 'true' THEN 'n1' ELSE 'n0' END
           WHEN 'number' THEN 'n' || trim_scale(CASE WHEN j::text ~ '[.eE]'
                                                     THEN flagsmith._float8_exact(flagsmith._dec_to_float8(j::text))
                                                     ELSE j::text::numeric END)::text
           ELSE 'z' END;
END;

-- Elements of a JSON array with their position (nothing for anything else).
CREATE FUNCTION flagsmith._elems(j json) RETURNS TABLE (value json, ord bigint)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
  SELECT e.value, e.ord
  FROM json_array_elements(CASE WHEN json_typeof(j) = 'array' THEN j ELSE '[]'::json END) WITH ORDINALITY e(value, ord);
END;

-- NULL when `for x in j: x[...]` works in Python, else why not: an array of
-- objects iterates; an empty object or string iterates nothing; anything else
-- raises (iterating a non-empty dict or str yields strings, which cannot be
-- subscripted by key).
CREATE FUNCTION flagsmith._iter_err(j json, path text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
  SELECT CASE
    WHEN j IS NULL THEN path || ': missing'
    WHEN json_typeof(j) = 'array' THEN
      (SELECT path || '[' || (e.ord - 1) || ']: not an object'
       FROM json_array_elements(j) WITH ORDINALITY e(value, ord)
       WHERE json_typeof(e.value) <> 'object' ORDER BY e.ord LIMIT 1)
    WHEN json_typeof(j) IN ('object', 'string') AND NOT flagsmith._py_truthy(j) THEN NULL
    ELSE path || ': not a list of objects' END;
END;

-- NULL when the object j has every key in keys, else the first problem.
CREATE FUNCTION flagsmith._need(j json, keys text[], path text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
  SELECT CASE
    WHEN json_typeof(j) IS DISTINCT FROM 'object' THEN path || ': not an object'
    ELSE (SELECT path || '.' || k.k || ': missing'
          FROM unnest(keys) WITH ORDINALITY k(k, o) WHERE j -> k.k IS NULL ORDER BY k.o LIMIT 1) END;
END;

-- uuid.UUID(s).int for the canonical spellings (see the header), else NULL.
CREATE FUNCTION flagsmith._uuid_int(s text) RETURNS numeric
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
BEGIN ATOMIC
  SELECT CASE WHEN h ~ '^[0-9A-Fa-f]{32}$' THEN
           ('x' || substr(h, 1, 8))::bit(32)::bigint::numeric * 79228162514264337593543950336
         + ('x' || substr(h, 9, 8))::bit(32)::bigint::numeric * 18446744073709551616
         + ('x' || substr(h, 17, 8))::bit(32)::bigint::numeric * 4294967296
         + ('x' || substr(h, 25, 8))::bit(32)::bigint::numeric END
  FROM (SELECT replace(btrim(replace(replace(s, 'urn:', ''), 'uuid:', ''), '{}'), '-', '') AS h) x;
END;

-- Checks a list of feature states as _map_environment_document_feature_states_to_feature_contexts
-- reads them; raises like the Python mapper would.
CREATE FUNCTION flagsmith._check_feature_states(arr json, path text) RETURNS void
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE err text;
BEGIN
  err := flagsmith._iter_err(arr, path);
  IF err IS NULL THEN
    SELECT x.e INTO err FROM (
      SELECT f.ord, coalesce(
        flagsmith._need(f.value, ARRAY['feature'], p),
        flagsmith._need(f.value -> 'feature', ARRAY['id'], p || '.feature'),
        CASE WHEN flagsmith._py_truthy(f.value -> 'metadata') AND json_typeof(f.value -> 'metadata') <> 'object'
             THEN p || '.metadata: not an object' END,
        CASE WHEN NOT flagsmith._py_truthy(f.value -> 'django_id') THEN
             flagsmith._need(f.value, ARRAY['featurestate_uuid'], p) END,
        flagsmith._need(f.value -> 'feature', ARRAY['name'], p || '.feature'),
        flagsmith._need(f.value, ARRAY['enabled', 'feature_state_value'], p),
        CASE WHEN flagsmith._py_truthy(f.value -> 'multivariate_feature_state_values') THEN coalesce(
          flagsmith._iter_err(f.value -> 'multivariate_feature_state_values', p || '.multivariate_feature_state_values'),
          (SELECT y.msg FROM (
             SELECT m.ord, coalesce(
                      flagsmith._need(m.value, ARRAY['multivariate_feature_option'], mp),
                      flagsmith._need(m.value -> 'multivariate_feature_option', ARRAY['value'], mp || '.multivariate_feature_option'),
                      flagsmith._need(m.value, ARRAY['percentage_allocation'], mp),
                      CASE WHEN NOT flagsmith._py_truthy(m.value -> 'id') THEN coalesce(
                        flagsmith._need(m.value, ARRAY['mv_fs_value_uuid'], mp),
                        CASE WHEN json_typeof(m.value -> 'mv_fs_value_uuid') <> 'string'
                                  OR flagsmith._uuid_int(m.value ->> 'mv_fs_value_uuid') IS NULL
                             THEN mp || '.mv_fs_value_uuid: badly formed hexadecimal UUID string' END) END) AS msg
             FROM flagsmith._elems(f.value -> 'multivariate_feature_state_values') m,
                  LATERAL (SELECT p || '.multivariate_feature_state_values[' || (m.ord - 1) || ']' AS mp) q) y
           WHERE y.msg IS NOT NULL ORDER BY y.ord LIMIT 1)) END,
        CASE WHEN flagsmith._py_truthy(f.value -> 'feature_segment') THEN
             flagsmith._need(f.value -> 'feature_segment', ARRAY['priority'], p || '.feature_segment') END
      ) AS e
      FROM flagsmith._elems(arr) f, LATERAL (SELECT path || '[' || (f.ord - 1) || ']' AS p) pp
    ) x WHERE x.e IS NOT NULL ORDER BY x.ord LIMIT 1;
  END IF;
  IF err IS NOT NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: environment document: %', err USING ERRCODE = 'data_exception';
  END IF;
END $$;

-- Feature contexts of a list of feature states (checked first), in order.
CREATE FUNCTION flagsmith._map_feature_states(arr json, path text)
RETURNS TABLE (ord bigint, name json, fc json)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
BEGIN
  PERFORM flagsmith._check_feature_states(arr, path);
  RETURN QUERY
  SELECT f.ord, f.value -> 'feature' -> 'name',
         CASE WHEN b.vs IS NOT NULL AND b.pr IS NOT NULL THEN
                json_build_object('key', b.k, 'name', b.nm, 'enabled', b.en, 'value', b.v, 'metadata', b.md,
                                  'variants', b.vs, 'priority', b.pr)
              WHEN b.vs IS NOT NULL THEN
                json_build_object('key', b.k, 'name', b.nm, 'enabled', b.en, 'value', b.v, 'metadata', b.md,
                                  'variants', b.vs)
              WHEN b.pr IS NOT NULL THEN
                json_build_object('key', b.k, 'name', b.nm, 'enabled', b.en, 'value', b.v, 'metadata', b.md,
                                  'priority', b.pr)
              ELSE json_build_object('key', b.k, 'name', b.nm, 'enabled', b.en, 'value', b.v, 'metadata', b.md) END
  FROM flagsmith._elems(arr) f
  CROSS JOIN LATERAL (
    SELECT
      flagsmith.py_str_json(CASE WHEN flagsmith._py_truthy(f.value -> 'django_id') THEN f.value -> 'django_id'
                                 ELSE f.value -> 'featurestate_uuid' END) AS k,
      f.value -> 'feature' -> 'name' AS nm,
      f.value -> 'enabled' AS en,
      f.value -> 'feature_state_value' AS v,
      CASE WHEN flagsmith._py_truthy(f.value -> 'metadata' -> 'experiment')
           THEN json_build_object('id', f.value -> 'feature' -> 'id', 'experiment', f.value -> 'metadata' -> 'experiment')
           ELSE json_build_object('id', f.value -> 'feature' -> 'id') END AS md,
      CASE WHEN flagsmith._py_truthy(f.value -> 'multivariate_feature_state_values') THEN (
        SELECT json_agg(CASE WHEN m.value -> 'multivariate_feature_option' -> 'key' IS NOT NULL
                              AND json_typeof(m.value -> 'multivariate_feature_option' -> 'key') <> 'null'
                             THEN json_build_object('value', m.value -> 'multivariate_feature_option' -> 'value',
                                                    'weight', m.value -> 'percentage_allocation',
                                                    'priority', q.pri,
                                                    'key', m.value -> 'multivariate_feature_option' -> 'key')
                             ELSE json_build_object('value', m.value -> 'multivariate_feature_option' -> 'value',
                                                    'weight', m.value -> 'percentage_allocation',
                                                    'priority', q.pri) END
                        ORDER BY m.ord)
        FROM flagsmith._elems(f.value -> 'multivariate_feature_state_values') m
        CROSS JOIN LATERAL (
          SELECT CASE WHEN flagsmith._py_truthy(m.value -> 'id') THEN m.value -> 'id'
                      ELSE to_json(flagsmith._uuid_int(m.value ->> 'mv_fs_value_uuid')) END AS pri) q) END AS vs,
      CASE WHEN flagsmith._py_truthy(f.value -> 'feature_segment') THEN f.value -> 'feature_segment' -> 'priority' END AS pr
  ) b;
END $$;

-- Segment rules, recursively, as _map_environment_document_rules_to_context_rules.
CREATE FUNCTION flagsmith._map_rules(rules json, path text) RETURNS json
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE err text; out json;
BEGIN
  err := flagsmith._iter_err(rules, path);
  IF err IS NULL THEN
    SELECT x.e INTO err FROM (
      SELECT r.ord, coalesce(
        flagsmith._need(r.value, ARRAY['type'], p),
        CASE WHEN r.value -> 'conditions' IS NOT NULL THEN coalesce(
          flagsmith._iter_err(r.value -> 'conditions', p || '.conditions'),
          (SELECT y.msg FROM (
             SELECT c.ord, flagsmith._need(c.value, ARRAY['operator', 'value'], p || '.conditions[' || (c.ord - 1) || ']') AS msg
             FROM flagsmith._elems(r.value -> 'conditions') c) y
           WHERE y.msg IS NOT NULL ORDER BY y.ord LIMIT 1)) END
      ) AS e
      FROM flagsmith._elems(rules) r, LATERAL (SELECT path || '[' || (r.ord - 1) || ']' AS p) pp
    ) x WHERE x.e IS NOT NULL ORDER BY x.ord LIMIT 1;
  END IF;
  IF err IS NOT NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: environment document: %', err USING ERRCODE = 'data_exception';
  END IF;
  SELECT coalesce(json_agg(json_build_object(
           'type', r.value -> 'type',
           'conditions', (SELECT coalesce(json_agg(json_build_object(
                                   'property', CASE WHEN flagsmith._py_truthy(c.value -> 'property_')
                                                    THEN c.value -> 'property_' ELSE '""'::json END,
                                   'operator', c.value -> 'operator',
                                   'value', c.value -> 'value') ORDER BY c.ord), '[]'::json)
                          FROM flagsmith._elems(r.value -> 'conditions') c),
           'rules', flagsmith._map_rules(coalesce(r.value -> 'rules', '[]'::json), path || '[' || (r.ord - 1) || '].rules'))
         ORDER BY r.ord), '[]'::json)
  INTO out
  FROM flagsmith._elems(rules) r;
  RETURN out;
END $$;

-- The mapper. Returns the arguments of load_context(): the EvaluationContext,
-- the SDK's per-identity override segments ({} when there are none) and
-- source_rev (the document's updated_at).
CREATE FUNCTION flagsmith.map_environment_document(
  doc json,
  OUT context json,
  OUT identity_overrides json,
  OUT source_rev text)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  err text;
  features json;
  segments json;
  ios json;
BEGIN
  err := coalesce(flagsmith._need(doc, ARRAY['api_key', 'name', 'feature_states', 'project'], 'document'),
                  flagsmith._need(doc -> 'project', ARRAY['segments'], 'document.project'));
  IF err IS NOT NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: environment document: %', err USING ERRCODE = 'data_exception';
  END IF;

  -- features: {name: feature context}; a name must be hashable
  SELECT 'feature_states[' || (m.ord - 1) || '].feature.name: unhashable type'
  INTO err
  FROM flagsmith._elems(doc -> 'feature_states') m
  WHERE json_typeof(m.value -> 'feature' -> 'name') IN ('array', 'object')
  ORDER BY m.ord LIMIT 1;
  IF err IS NULL THEN
    -- {name: context}: a later feature state with an equal name replaces the value, not the key
    SELECT coalesce(json_object_agg(flagsmith._py_json_key(g.first_name), g.last_fc ORDER BY g.first_ord), '{}'::json)
    INTO features
    FROM (SELECT min(m.ord) AS first_ord,
                 (array_agg(m.name ORDER BY m.ord))[1] AS first_name,
                 (array_agg(m.fc ORDER BY m.ord DESC))[1] AS last_fc
          FROM flagsmith._map_feature_states(doc -> 'feature_states', 'feature_states') m
          GROUP BY flagsmith._py_key_ident(m.name)) g;
  ELSE
    -- the Python mapper checks every feature state before it builds the dict
    PERFORM flagsmith._check_feature_states(doc -> 'feature_states', 'feature_states');
    RAISE EXCEPTION 'pg_flagsmith: environment document: %', err USING ERRCODE = 'data_exception';
  END IF;

  -- segments: {str(id): segment context}
  err := flagsmith._iter_err(doc -> 'project' -> 'segments', 'project.segments');
  IF err IS NULL THEN
    SELECT y.msg INTO err FROM (
      SELECT s.ord, flagsmith._need(s.value, ARRAY['id', 'name', 'rules'], 'project.segments[' || (s.ord - 1) || ']') AS msg
      FROM flagsmith._elems(doc -> 'project' -> 'segments') s) y
    WHERE y.msg IS NOT NULL ORDER BY y.ord LIMIT 1;
  END IF;
  IF err IS NOT NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: environment document: %', err USING ERRCODE = 'data_exception';
  END IF;
  SELECT coalesce(json_object_agg(flagsmith.py_str_json(s.value -> 'id'), json_build_object(
           'key', flagsmith.py_str_json(s.value -> 'id'),
           'name', s.value -> 'name',
           'rules', flagsmith._map_rules(s.value -> 'rules', 'project.segments[' || (s.ord - 1) || '].rules'),
           'overrides', CASE WHEN flagsmith._py_truthy(s.value -> 'feature_states') THEN
                          (SELECT coalesce(json_agg(o.fc ORDER BY o.ord), '[]'::json)
                           FROM flagsmith._map_feature_states(s.value -> 'feature_states',
                                  'project.segments[' || (s.ord - 1) || '].feature_states') o)
                        ELSE '[]'::json END,
           'metadata', json_build_object('id', s.value -> 'id', 'source', 'api'))
         ORDER BY s.ord), '{}'::json)
  INTO segments
  FROM flagsmith._elems(doc -> 'project' -> 'segments') s;

  context := json_build_object('environment', json_build_object('key', doc -> 'api_key', 'name', doc -> 'name'),
                               'features', features,
                               'segments', segments);

  -- identity overrides: {identifier: per-identity segment}, for identities with overrides
  IF flagsmith._py_truthy(doc -> 'identity_overrides') THEN
    err := flagsmith._iter_err(doc -> 'identity_overrides', 'identity_overrides');
    IF err IS NULL THEN
      SELECT x.e INTO err FROM (
        SELECT i.ord, coalesce(
          flagsmith._need(i.value, ARRAY['identity_features'], p),
          CASE WHEN flagsmith._py_truthy(i.value -> 'identity_features') THEN coalesce(
            flagsmith._need(i.value, ARRAY['identifier'], p),
            CASE WHEN json_typeof(i.value -> 'identifier') IN ('array', 'object') THEN p || '.identifier: unhashable type' END,
            flagsmith._iter_err(i.value -> 'identity_features', p || '.identity_features'),
            (SELECT y.msg FROM (
               SELECT f.ord, coalesce(flagsmith._need(f.value, ARRAY['feature'], fp),
                                      flagsmith._need(f.value -> 'feature', ARRAY['name'], fp || '.feature'),
                                      flagsmith._need(f.value, ARRAY['enabled', 'feature_state_value'], fp),
                                      flagsmith._need(f.value -> 'feature', ARRAY['id'], fp || '.feature')) AS msg
               FROM flagsmith._elems(i.value -> 'identity_features') f,
                    LATERAL (SELECT p || '.identity_features[' || (f.ord - 1) || ']' AS fp) q) y
             WHERE y.msg IS NOT NULL ORDER BY y.ord LIMIT 1)) END
        ) AS e
        FROM flagsmith._elems(doc -> 'identity_overrides') i,
             LATERAL (SELECT 'identity_overrides[' || (i.ord - 1) || ']' AS p) pp
      ) x WHERE x.e IS NOT NULL ORDER BY x.ord LIMIT 1;
    END IF;
    IF err IS NOT NULL THEN
      RAISE EXCEPTION 'pg_flagsmith: environment document: %', err USING ERRCODE = 'data_exception';
    END IF;
    SELECT json_object_agg(flagsmith._py_json_key(g.first_id), g.last_seg ORDER BY g.first_ord)
    INTO ios
    FROM (SELECT min(x.ord) AS first_ord,
                 (array_agg(x.identifier ORDER BY x.ord))[1] AS first_id,
                 (array_agg(x.seg ORDER BY x.ord DESC))[1] AS last_seg
          FROM (
    SELECT i.ord, i.value -> 'identifier' AS identifier, json_build_object(
             'key', 'identity_overrides',
             'name', 'identity_overrides',
             'rules', json_build_array(json_build_object(
                        'type', 'ALL',
                        'conditions', json_build_array(json_build_object(
                          'property', '$.identity.identifier',
                          'operator', 'IN',
                          'value', json_build_array(i.value -> 'identifier'))))),
             'overrides', (SELECT json_agg(json_build_object(
                                    'key', '',
                                    'name', f.value -> 'feature' -> 'name',
                                    'enabled', f.value -> 'enabled',
                                    'value', f.value -> 'feature_state_value',
                                    'priority', '-Infinity',
                                    'metadata', json_build_object('id', f.value -> 'feature' -> 'id'))
                                  ORDER BY f.ord)
                           FROM flagsmith._elems(i.value -> 'identity_features') f),
             'metadata', json_build_object('source', 'identity_overrides')) AS seg
    FROM flagsmith._elems(doc -> 'identity_overrides') i
    WHERE flagsmith._py_truthy(i.value -> 'identity_features')
          ) x
          GROUP BY flagsmith._py_key_ident(x.identifier)) g;
  END IF;
  identity_overrides := coalesce(ios, '{}'::json);
  source_rev := CASE WHEN flagsmith._py_truthy(doc -> 'updated_at') THEN flagsmith.py_str_json(doc -> 'updated_at')
                     ELSE '' END;
END $$;

-- Map an environment document and load it (what the pusher does with the SDK's mapper).
CREATE FUNCTION flagsmith.load_document(doc json, source text DEFAULT 'manual')
RETURNS TABLE (snapshot_id bigint, outcome text)
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE m record;
BEGIN
  m := flagsmith.map_environment_document(doc);
  RETURN QUERY SELECT * FROM flagsmith.apply_context(m.context, m.identity_overrides, source, m.source_rev);
END $$;
