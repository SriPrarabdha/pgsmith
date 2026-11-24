-- Compiler: turns a snapshot into one LANGUAGE sql function the planner can
-- inline into the calling query.
--
--   flagsmith_c.flags_s<id>(identifier, traits jsonb, identity_key, engine_mode)
--   flagsmith_c.flag_s<id>(feature, identifier, traits jsonb, identity_key, engine_mode)
--
-- Shape: fences compute each context value once (typed with Python's rules),
-- then each segment's membership once, then each feature's winning override,
-- read from constant arrays. flags_s<id> fences with LATERAL ROWS FROM (parallel
-- safe, one VALUES row per feature); flag_s<id> fences with OFFSET 0 and has one
-- UNION ALL arm per feature, so a constant feature filter prunes it to one arm.
-- Every condition value is already parsed: the generated code only classifies
-- the trait side. All constants go through format('%L'). Identity-override
-- identifiers stay out of the generated code (they are read through
-- SECURITY DEFINER lookups), because function bodies are visible to every role.
--
-- Snapshots whose segments read other flags ($.flags...) are not compiled: the
-- reference resolves those lazily with cycle detection, which the interpreter
-- reproduces exactly.

-- identity-override lookups (the only table reads of compiled code)
CREATE FUNCTION flagsmith._io_matched(sid bigint, in_key text) RETURNS int[]
LANGUAGE sql STABLE PARALLEL SAFE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT coalesce(array_agg(o.seg_ord), '{}') FROM flagsmith.identity_override o
  WHERE o.snapshot_id = sid AND o.in_key = _io_matched.in_key
$$;

CREATE FUNCTION flagsmith._io_segment(sid bigint, identifier text) RETURNS jsonb
LANGUAGE sql STABLE PARALLEL SAFE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT jsonb_build_object('seg_ord', g.seg_ord, 'name', g.name, 'ov', coalesce(g.io_overrides, '{}'::jsonb))
  FROM flagsmith.segment g
  WHERE g.snapshot_id = sid AND g.source = 'identity_override' AND g.io_identifier = identifier
$$;

-- first variant whose [lo, hi) contains p, among positions off+1 .. off+cnt; 0 for none
CREATE FUNCTION flagsmith._vpick(p float8, lo float8[], hi float8[], off int, cnt int) RETURNS int
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
BEGIN
  FOR i IN off + 1 .. off + cnt LOOP
    IF lo[i] <= p AND p < hi[i] THEN RETURN i; END IF;
  END LOOP;
  RETURN 0;
END $$;

CREATE FUNCTION flagsmith._mod_eval(v flagsmith.ctxval, d float8, r float8) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE x float8; m float8;
BEGIN
  IF v.k NOT IN ('i', 'f', 'b') OR d IS NULL OR r IS NULL THEN RETURN false; END IF;
  IF v.k = 'i' AND abs(v.n) >= 1e308 THEN RETURN false; END IF;
  x := CASE v.k WHEN 'i' THEN v.n::float8 WHEN 'f' THEN v.f ELSE v.b::int::float8 END;
  m := flagsmith.py_fmod(x, d);
  RETURN m IS NOT NULL AND m <> 'NaN'::float8 AND r <> 'NaN'::float8 AND m = r;
END $$;

CREATE FUNCTION flagsmith._semver_cond(s text, op text, cv flagsmith.semver, ctxt text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE tv flagsmith.semver; cmp int;
BEGIN
  tv := flagsmith.semver_parse(s);
  IF tv IS NULL THEN RETURN false; END IF;
  IF op = 'CONTAINS' THEN RETURN coalesce(ctxt = tv.pre OR ctxt = tv.build, false); END IF;
  IF cv IS NULL THEN RETURN false; END IF;
  cmp := flagsmith.semver_cmp(tv, cv);
  RETURN CASE op WHEN 'EQUAL' THEN cmp = 0 WHEN 'NOT_EQUAL' THEN cmp <> 0 WHEN 'GREATER_THAN' THEN cmp > 0
                 WHEN 'GREATER_THAN_INCLUSIVE' THEN cmp >= 0 WHEN 'LESS_THAN' THEN cmp < 0
                 WHEN 'LESS_THAN_INCLUSIVE' THEN cmp <= 0 ELSE false END;
END $$;

-- The largest r in 0..9997 with r / 9998 * 100 <= thr in float8 (the reference's
-- operation order), so a split compares the integer digest residue directly.
CREATE FUNCTION flagsmith._split_rmax(thr float8) RETURNS int
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE r int;
BEGIN
  r := least(9997, greatest(-1, floor(thr * 9998 / 100)::int + 2));
  WHILE r >= 0 AND NOT (r::float8 / 9998 * 100 <= thr) LOOP r := r - 1; END LOOP;
  RETURN r;
END $$;

-- digest residue r of an md5 hex column, inline (no function call)
CREATE FUNCTION flagsmith._r_expr(h text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT format('((((''x'' || substr(%1$s, 1, 8))::bit(32)::bigint %% 9999) * 7291 + ((''x'' || substr(%1$s, 9, 8))::bit(32)::bigint %% 9999) * 1897 + ((''x'' || substr(%1$s, 17, 8))::bit(32)::bigint %% 9999) * 6835 + (''x'' || substr(%1$s, 25, 8))::bit(32)::bigint) %% 9999)', h)
$$;

-- Relative cost of a compiled condition: cheap ones are tested first (evaluation
-- order is unobservable without flag dependencies, which are never compiled).
CREATE FUNCTION flagsmith._cond_cost(c flagsmith.condition) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN c.status <> 'ok' THEN 0
    WHEN c.operator IN ('IS_SET', 'IS_NOT_SET') THEN 1
    WHEN c.operator = 'PERCENTAGE_SPLIT' THEN 6
    WHEN c.operator = 'REGEX' THEN 4
    WHEN c.operator = 'MODULO' THEN 3
    WHEN c.v_is_semver THEN 5
    ELSE 2 END
$$;

-- SQL for one condition. v: the ctxval expression it reads; ikx: the identity
-- key; hx: its digest column (PERCENTAGE_SPLIT); svx: the parsed SemVer column.
CREATE FUNCTION flagsmith._compile_cond(c flagsmith.condition, v text, segkey text, ikx text,
                                         hx text DEFAULT NULL, svx text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET extra_float_digits = 1 AS $$
DECLARE op text := c.operator; sym text; sb text; ib text; fb text; bb text; keyx text; rmax int; r text;
  dint numeric; mx text;
BEGIN
  IF c.status <> 'ok' THEN RETURN 'false'; END IF;
  CASE op
    WHEN 'IN' THEN
      RETURN format('(CASE (%1$s).k WHEN ''s'' THEN (%1$s).s = ANY (%2$L::text[]) '
                    'WHEN ''i'' THEN (%1$s).n::text = ANY (%2$L::text[]) ELSE false END)', v, c.in_set);
    WHEN 'PERCENTAGE_SPLIT' THEN
      IF c.v_threshold IS NULL OR c.v_threshold = 'NaN'::float8 OR c.v_threshold < 0 THEN RETURN 'false'; END IF;
      keyx := CASE WHEN c.prop_kind = 'split_ik' THEN ikx
                   ELSE format('CASE WHEN (%1$s).k <> ''n'' THEN flagsmith.py_str(%1$s) END', v) END;
      IF c.v_threshold >= 100 THEN RETURN format('((%s) IS NOT NULL)', keyx); END IF;
      rmax := flagsmith._split_rmax(c.v_threshold);
      r := flagsmith._r_expr(hx);
      RETURN format('(CASE WHEN %1$s IS NULL THEN false WHEN %2$s = 9998 THEN flagsmith.hash_pct(ARRAY[%3$L, %4$s]) <= %5$L::float8 '
                    'ELSE %2$s <= %6$s END)', hx, r, segkey, keyx, c.v_threshold, rmax);
    WHEN 'IS_SET' THEN RETURN format('((%s).k <> ''n'')', v);
    WHEN 'IS_NOT_SET' THEN RETURN format('((%s).k = ''n'')', v);
    WHEN 'NOT_CONTAINS' THEN RETURN format('((%1$s).k = ''s'' AND strpos((%1$s).s, %2$L) = 0)', v, c.v_text);
    WHEN 'REGEX' THEN RETURN format('((%1$s).k <> ''n'' AND flagsmith.py_str(%1$s) ~ %2$L)', v, c.v_regex);
    WHEN 'MODULO' THEN
      IF c.v_mod_div IS NULL OR c.v_mod_rem IS NULL THEN RETURN 'false'; END IF;
      IF c.v_mod_div = trunc(c.v_mod_div) AND c.v_mod_div <> 0 AND abs(c.v_mod_div) < 9.0e15 THEN
        -- integer trait, integral divisor: exact integer arithmetic, Python's sign rule
        dint := c.v_mod_div::numeric;
        mx := format('mod((%s).n, %s::numeric)', v, dint);
        RETURN format('(CASE (%1$s).k WHEN ''i'' THEN CASE WHEN abs((%1$s).n) < 9007199254740992 '
                      'THEN (CASE WHEN %2$s <> 0 AND (%2$s < 0) <> (%3$s::numeric < 0) THEN %2$s + %3$s::numeric ELSE %2$s END)::float8 = %4$L::float8 '
                      'ELSE flagsmith._mod_eval(%1$s, %5$L::float8, %4$L::float8) END '
                      'WHEN ''f'' THEN flagsmith._mod_eval(%1$s, %5$L::float8, %4$L::float8) '
                      'WHEN ''b'' THEN flagsmith._mod_eval(%1$s, %5$L::float8, %4$L::float8) ELSE false END)',
                      v, mx, dint, c.v_mod_rem, c.v_mod_div);
      END IF;
      RETURN format('flagsmith._mod_eval(%s, %L::float8, %L::float8)', v, c.v_mod_div, c.v_mod_rem);
    WHEN 'EQUAL', 'NOT_EQUAL', 'GREATER_THAN', 'GREATER_THAN_INCLUSIVE', 'LESS_THAN', 'LESS_THAN_INCLUSIVE', 'CONTAINS' THEN
      sym := CASE op WHEN 'EQUAL' THEN '=' WHEN 'NOT_EQUAL' THEN '<>' WHEN 'GREATER_THAN' THEN '>'
                     WHEN 'GREATER_THAN_INCLUSIVE' THEN '>=' WHEN 'LESS_THAN' THEN '<' WHEN 'LESS_THAN_INCLUSIVE' THEN '<='
                     ELSE NULL END;
      -- str trait
      IF NOT c.v_is_str AND json_typeof(c.value_raw) IN ('number', 'boolean') THEN
        sb := 'false';
      ELSIF c.v_is_str AND c.v_is_semver THEN
        IF svx IS NULL THEN
          sb := format('flagsmith._semver_cond((%s).s, %L, %L::flagsmith.semver, %L)', v, op, c.v_semver, c.v_semver_txt);
        ELSIF op = 'CONTAINS' THEN
          sb := format('coalesce(%1$L = (%2$s).pre OR %1$L = (%2$s).build, false)', c.v_semver_txt, svx);
        ELSIF c.v_semver IS NULL THEN
          sb := 'false';
        ELSIF (c.v_semver).pre IS NULL THEN
          sb := format('(CASE WHEN %1$s IS NULL THEN false WHEN (%1$s).pre IS NULL '
                       'THEN ROW((%1$s).major, (%1$s).minor, (%1$s).patch) %2$s ROW(%3$s::numeric, %4$s::numeric, %5$s::numeric) '
                       'ELSE flagsmith.semver_cmp(%1$s, %6$L::flagsmith.semver) %2$s 0 END)',
                       svx, sym, (c.v_semver).major, (c.v_semver).minor, (c.v_semver).patch, c.v_semver);
        ELSE
          sb := format('(CASE WHEN %1$s IS NULL THEN false ELSE flagsmith.semver_cmp(%1$s, %2$L::flagsmith.semver) %3$s 0 END)',
                       svx, c.v_semver, sym);
        END IF;
      ELSIF op = 'CONTAINS' THEN
        sb := format('(strpos((%s).s, %L) > 0)', v, c.v_text);
      ELSE
        sb := format('((%s).s COLLATE "C" %s %L COLLATE "C")', v, sym, c.v_text);
      END IF;
      -- int trait
      ib := CASE WHEN op = 'CONTAINS' OR c.v_int IS NULL THEN 'false'
                 ELSE format('((%s).n %s %s::numeric)', v, sym, c.v_int) END;
      -- float trait (NaN is unequal to everything)
      IF op = 'CONTAINS' OR c.v_float IS NULL THEN
        fb := 'false';
      ELSIF c.v_float = 'NaN'::float8 THEN
        fb := (op = 'NOT_EQUAL')::text;
      ELSE
        fb := format('(CASE WHEN (%1$s).f = ''NaN''::float8 THEN %2$s ELSE (%1$s).f %3$s %4$L::float8 END)',
                     v, (op = 'NOT_EQUAL')::text, sym, c.v_float);
      END IF;
      -- bool trait (Python orders False < True)
      bb := CASE WHEN op = 'CONTAINS' THEN 'false' ELSE format('((%s).b %s %s)', v, sym, c.v_bool::text) END;
      RETURN format('(CASE (%s).k WHEN ''s'' THEN %s WHEN ''i'' THEN %s WHEN ''f'' THEN %s WHEN ''b'' THEN %s ELSE false END)',
                    v, sb, ib, fb, bb);
    ELSE
      RETURN 'false';
  END CASE;
END $$;

-- SQL for a context value read by a (non flag-dependent) condition.
CREATE FUNCTION flagsmith._compile_value(c flagsmith.condition) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE none text := 'ROW(''n'', NULL, NULL, NULL, NULL)::flagsmith.ctxval'; route text; constx text;
BEGIN
  constx := CASE WHEN c.const_val IS NULL THEN none ELSE format('%L::flagsmith.ctxval', c.const_val) END;
  IF c.prop_kind = 'trait' THEN
    RETURN format('CASE WHEN identifier IS NULL THEN %s ELSE flagsmith.ctxval(traits -> %L) END', none, c.prop_name);
  END IF;
  route := CASE c.prop_kind
    WHEN 'jp_identifier' THEN 'flagsmith.ctxval_str(identifier)'
    WHEN 'jp_identity_key' THEN format('flagsmith.ctxval_str(coalesce(nullif(identity_key, %L), %L || identifier))', '', '@@ENVKEY@@')
    WHEN 'jp_trait' THEN format('flagsmith.ctxval_jp(traits -> %L)', c.prop_name)
    WHEN 'jp_trait_path' THEN format('flagsmith.ctxval_jp(flagsmith.jsonb_walk(traits -> %L, %L::text[]))', c.prop_name, c.prop_path)
    WHEN 'jp_const' THEN constx
    ELSE none END;
  -- a trait literally named like the query wins
  RETURN format('CASE WHEN identifier IS NULL THEN %s WHEN jsonb_typeof(traits -> %L) <> ''null'' '
                'THEN flagsmith.ctxval(traits -> %L) ELSE %s END',
                CASE WHEN c.prop_kind = 'jp_const' THEN constx ELSE none END, c.property, c.property, route);
END $$;

-- Column references in generated code. Two shapes are generated per snapshot:
--   'offset': nested subqueries fenced with OFFSET 0 (cheapest per call, never
--             parallel: Postgres keeps correlated subqueries out of workers)
--   'rows':   LATERAL ROWS FROM (flagsmith._fx(...)) function scans, which compute
--             each column once per row and are parallel safe; composite columns
--             arrive split into fields and are rebuilt with ROW(...), which the
--             planner folds back into plain column references.
CREATE FUNCTION flagsmith._ref_val(mode text, vname text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN mode = 'offset' THEN 'u.' || vname
              ELSE format('ROW(t.%1$s_k, t.%1$s_s, t.%1$s_n, t.%1$s_f, t.%1$s_b)::flagsmith.ctxval', vname) END
$$;

CREATE FUNCTION flagsmith._ref_sv(mode text, vname text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN mode = 'offset' THEN 'u.sv' || substr(vname, 2)
              ELSE format('ROW(u.sv%1$s_major, u.sv%1$s_minor, u.sv%1$s_patch, u.sv%1$s_pre, u.sv%1$s_build)::flagsmith.semver',
                          substr(vname, 2)) END
$$;

-- identity function used to place expressions in ROWS FROM (inlined by the planner)
CREATE FUNCTION flagsmith._fx(anyelement) RETURNS anyelement
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT $1';

-- SQL for a rule (and its sub-rules): conditions then sub-rules, by rule type.
-- Operands are ordered cheapest first; cost is the most expensive operand.
CREATE FUNCTION flagsmith._compile_rule(sid bigint, rid int, vcols jsonb, segkey text, mode text,
                                         OUT expr text, OUT cost int)
LANGUAGE plpgsql STABLE AS $$
DECLARE r flagsmith.rule; parts text[] := '{}'; pcost int[] := '{}'; subs text[] := '{}'; scost int[] := '{}';
  c flagsmith.condition; ch int; cp text; sp text; sub record; vname text; ikx text; hp text;
BEGIN
  ikx := CASE WHEN mode = 'offset' THEN 'u.ik' ELSE 't.ik' END;
  hp := 'u.h';
  SELECT * INTO r FROM flagsmith.rule x WHERE x.snapshot_id = sid AND x.rule_id = rid;
  FOR c IN SELECT * FROM flagsmith.condition x WHERE x.snapshot_id = sid AND x.rule_id = rid ORDER BY x.cond_id LOOP
    vname := vcols ->> flagsmith._value_key(c);
    parts := parts || flagsmith._compile_cond(c,
      CASE WHEN vname IS NULL THEN ikx ELSE flagsmith._ref_val(mode, vname) END,
      segkey, ikx, hp || c.cond_id,
      CASE WHEN c.v_is_semver AND vname IS NOT NULL THEN flagsmith._ref_sv(mode, vname) END);
    pcost := pcost || flagsmith._cond_cost(c);
  END LOOP;
  ch := r.first_child;
  WHILE ch IS NOT NULL LOOP
    sub := flagsmith._compile_rule(sid, ch, vcols, segkey, mode);
    subs := subs || sub.expr; scost := scost || sub.cost;
    SELECT x.next_sibling INTO ch FROM flagsmith.rule x WHERE x.snapshot_id = sid AND x.rule_id = ch;
  END LOOP;
  SELECT array_agg(q.p ORDER BY q.kc, q.ni) INTO parts FROM unnest(parts, pcost) WITH ORDINALITY q(p, kc, ni);
  SELECT array_agg(q.p ORDER BY q.kc, q.ni) INTO subs FROM unnest(subs, scost) WITH ORDINALITY q(p, kc, ni);
  parts := coalesce(parts, '{}'); subs := coalesce(subs, '{}');
  cp := CASE WHEN cardinality(parts) = 0 THEN 'true'
             WHEN r.rule_type = 'ALL' THEN '(' || array_to_string(parts, ' AND ') || ')'
             WHEN r.rule_type = 'ANY' THEN '(' || array_to_string(parts, ' OR ') || ')'
             ELSE '(NOT (' || array_to_string(parts, ' OR ') || '))' END;
  sp := CASE WHEN cardinality(subs) = 0 THEN 'true'
             WHEN r.rule_type = 'ALL' THEN '(' || array_to_string(subs, ' AND ') || ')'
             WHEN r.rule_type = 'ANY' THEN '(' || array_to_string(subs, ' OR ') || ')'
             ELSE '(NOT (' || array_to_string(subs, ' OR ') || '))' END;
  expr := CASE WHEN sp = 'true' THEN cp WHEN cp = 'true' THEN sp
               WHEN coalesce((SELECT max(x) FROM unnest(pcost) x), 0) <= coalesce((SELECT max(x) FROM unnest(scost) x), 0)
               THEN '(' || cp || ' AND ' || sp || ')' ELSE '(' || sp || ' AND ' || cp || ')' END;
  cost := greatest(coalesce((SELECT max(x) FROM unnest(pcost) x), 0), coalesce((SELECT max(x) FROM unnest(scost) x), 0));
END $$;

-- identity of a context value source, to share one fenced column between conditions
CREATE FUNCTION flagsmith._value_key(c flagsmith.condition) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT md5(concat_ws(E'\x1f', c.prop_kind, c.property, c.prop_name, c.prop_path::text, c.const_val::text))
$$;

-- The six output expressions of one feature, given where its winner index (wref),
-- variant index (viref), identity-override document (ioref) and environment-flags
-- mode (envmref) live.
CREATE FUNCTION flagsmith._arm(fname text, en boolean[], vval jsonb[], vals jsonb[], vkey text[], vw text[],
  rsn text[], metas jsonb[], fb_default text, env_fb text, has_io boolean, any_exp boolean,
  wref text, viref text, ioref text, envmref text) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE fbx text; metax text; enx text; valx text; rsnx text;
BEGIN
  fbx := format('%L', fb_default);
  IF has_io THEN
    fbx := format('CASE WHEN (%s -> ''ov'') ? %L THEN ''DEFAULT'' ELSE %s END', ioref, fname, fbx);
  END IF;
  IF env_fb <> fb_default THEN
    fbx := format('CASE WHEN %s THEN %L ELSE %s END', envmref, env_fb, fbx);
  END IF;
  metax := format('(%L::jsonb[])[%s]', metas, wref);
  enx := format('(%L::boolean[])[%s]', en, wref);
  valx := format('(%L::jsonb[])[%s]', vals, wref);
  rsnx := format('CASE WHEN %s = 1 THEN %s ELSE (%L::text[])[%s] END', wref, fbx, rsn, wref);
  IF has_io THEN
    metax := format('CASE WHEN %1$s = 0 THEN %2$s -> ''ov'' -> %3$L -> ''metadata'' ELSE %4$s END', wref, ioref, fname, metax);
    enx := format('CASE WHEN %1$s = 0 THEN (%2$s -> ''ov'' -> %3$L ->> ''enabled'')::boolean ELSE %4$s END', wref, ioref, fname, enx);
    valx := format('CASE WHEN %1$s = 0 THEN %2$s -> ''ov'' -> %3$L -> ''value'' ELSE %4$s END', wref, ioref, fname, valx);
    rsnx := format('CASE WHEN %1$s = 0 THEN ''TARGETING_MATCH; segment='' || (%2$s ->> ''name'') ELSE %3$s END', wref, ioref, rsnx);
  END IF;
  IF any_exp THEN
    metax := format('CASE WHEN %1$s THEN nullif((%2$s) - ''experiment'', ''{}''::jsonb) ELSE %2$s END', envmref, metax);
  END IF;
  IF cardinality(vval) = 0 THEN
    RETURN ARRAY[format('%L::text', fname), enx, valx, 'NULL::text', rsnx, metax];
  END IF;
  RETURN ARRAY[
    format('%L::text', fname),
    enx,
    format('CASE WHEN %1$s > 0 THEN (%2$L::jsonb[])[%1$s] ELSE %3$s END', viref, vval, valx),
    format('CASE WHEN %1$s > 0 THEN (%2$L::text[])[%1$s] WHEN %1$s = 0 THEN ''control'' END', viref, vkey),
    format('CASE WHEN %1$s > 0 THEN ''SPLIT; weight='' || (%2$L::text[])[%1$s] ELSE %3$s END', viref, vw, rsnx),
    metax];
END $$;

-- The variant index expression of one feature (NULL: no variant selection).
CREATE FUNCTION flagsmith._arm_vi(vcnt int[], salts text[], vlo float8[], vhi float8[], voff int[],
                                  wref text, ikref text) RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET extra_float_digits = 1 AS $$
BEGIN
  IF cardinality(vlo) = 0 THEN RETURN 'NULL::int'; END IF;
  RETURN format('CASE WHEN %1$s IS NOT NULL AND %2$s > 0 AND (%3$L::int[])[%2$s] > 0 '
                'THEN flagsmith._vpick(flagsmith.hash_pct((%4$L::text[])[%2$s], %1$s), %5$L::float8[], %6$L::float8[], '
                '(%7$L::int[])[%2$s], (%3$L::int[])[%2$s]) END',
                ikref, wref, vcnt, salts, vlo, vhi, voff);
END $$;

-- a ROWS FROM fence over (expression, column names) pairs
CREATE FUNCTION flagsmith._rows_from(exprs text[], names text[], alias text, is_lateral boolean) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN is_lateral THEN E'\nCROSS JOIN LATERAL ROWS FROM (' ELSE E'\nFROM ROWS FROM (' END
         || (SELECT string_agg('flagsmith._fx(' || e || ')', E',\n    ') FROM unnest(exprs) e)
         || ') ' || alias || '(' || array_to_string(names, ', ') || ')'
$$;

CREATE FUNCTION flagsmith.compile_snapshot(sid bigint) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp
SET extra_float_digits = 1 AS $$
DECLARE
  t0 timestamptz := clock_timestamp();
  sn flagsmith.snapshot;
  env flagsmith.environment;
  note text;
  vcols jsonb := '{}';
  c flagsmith.condition;
  k text;
  n int := 0;
  g record;
  o record;
  vr record;
  rr record;
  has_io boolean;
  has_io_idx boolean;
  m text;
  -- per level: expressions and column names, for both shapes
  t_off text := ''; t_x text[] := '{}'; t_n text[] := '{}';
  u_off text := ''; u_x text[] := '{}'; u_n text[] := '{}';
  s_off text := ''; s_x text[] := '{}'; s_n text[] := '{}';
  z_x text[] := '{}'; z_n text[] := '{}';
  y_x text[] := '{}'; y_n text[] := '{}';
  svdone jsonb := '{}';
  segparts text[]; segcosts int[];
  w text; w_off text; w_rows text; widx int;
  vexpr text; segkey text; keyx text;
  arms text[] := '{}'; vrows text[] := '{}';
  en boolean[]; vals jsonb[]; rsn text[]; metas jsonb[]; salts text[]; voff int[]; vcnt int[];
  vlo float8[]; vhi float8[]; vval jsonb[]; vkey text[]; vw text[];
  nv int; fi int := 0; outs text[]; env_fb text; any_exp boolean;
  f record;
  iom_off text; iom_rows text; io_x text;
  head text; body text; flag_body text;
BEGIN
  SELECT * INTO sn FROM flagsmith.snapshot x WHERE x.snapshot_id = sid;
  SELECT * INTO env FROM flagsmith.environment e WHERE e.env_key = sn.env_key;
  PERFORM flagsmith._drop_compiled(sid);

  IF sn.has_flag_deps THEN
    note := 'segments read other flags ($.flags...): evaluated by the interpreter';
  ELSIF EXISTS (SELECT 1 FROM flagsmith.feature_context x JOIN flagsmith.segment gs USING (snapshot_id, seg_ord)
                WHERE x.snapshot_id = sid AND gs.source = 'identity_override' AND x.n_variants > 0) THEN
    note := 'identity overrides with variants: evaluated by the interpreter';
  ELSIF EXISTS (SELECT 1 FROM flagsmith.feature_context x WHERE x.snapshot_id = sid AND x.seg_ord <= sn.n_ctx_segments
                AND x.priority = '-Infinity'::numeric) AND sn.n_identity_overrides > 0 THEN
    note := 'segment overrides at priority -Infinity alongside identity overrides: evaluated by the interpreter';
  END IF;
  IF note IS NOT NULL THEN
    UPDATE flagsmith.snapshot x SET compiled = false, compile_note = note WHERE x.snapshot_id = sid;
    RETURN false;
  END IF;
  has_io := sn.n_identity_overrides > 0;
  has_io_idx := sn.n_io_indexed > 0;

  -- level t: identity basics and one typed context value per distinct source
  t_off := format(E'(identifier IS NULL AND NOT coalesce(engine_mode, false)) AS envm,\n'
                  || E'      CASE WHEN identifier IS NOT NULL THEN coalesce(nullif(identity_key, ''''), %1$L || identifier) END AS ik,\n'
                  || E'      CASE WHEN identifier IS NULL THEN NULL WHEN jsonb_typeof(traits -> ''$.identity.identifier'') <> ''null'' '
                  || 'THEN flagsmith.ctxval(traits -> ''$.identity.identifier'') ELSE flagsmith.ctxval_str(identifier) END AS vio',
                  sn.ctx_env_key || '_');
  t_x := ARRAY[
    '(identifier IS NULL AND NOT coalesce(engine_mode, false))',
    format('CASE WHEN identifier IS NOT NULL THEN coalesce(nullif(identity_key, ''''), %L || identifier) END', sn.ctx_env_key || '_'),
    'CASE WHEN identifier IS NULL THEN NULL::flagsmith.ctxval WHEN jsonb_typeof(traits -> ''$.identity.identifier'') <> ''null'' '
      || 'THEN flagsmith.ctxval(traits -> ''$.identity.identifier'') ELSE flagsmith.ctxval_str(identifier) END'];
  t_n := ARRAY['envm', 'ik', 'vio_k', 'vio_s', 'vio_n', 'vio_f', 'vio_b'];
  FOR c IN SELECT x.* FROM flagsmith.condition x JOIN flagsmith.rule r USING (snapshot_id, rule_id)
           WHERE x.snapshot_id = sid AND r.seg_ord <= sn.n_ctx_segments AND x.prop_kind <> 'split_ik'
           ORDER BY x.cond_id LOOP
    k := flagsmith._value_key(c);
    IF NOT vcols ? k THEN
      n := n + 1;
      vcols := vcols || jsonb_build_object(k, 'v' || n);
      vexpr := replace(flagsmith._compile_value(c), '''@@ENVKEY@@''', quote_literal(sn.ctx_env_key || '_'));
      t_off := t_off || format(E',\n      %s AS v%s', vexpr, n);
      t_x := t_x || vexpr;
      t_n := t_n || ARRAY['v' || n || '_k', 'v' || n || '_s', 'v' || n || '_n', 'v' || n || '_f', 'v' || n || '_b'];
    END IF;
  END LOOP;

  -- level u: identity-override lookups, split digests, parsed SemVer traits
  iom_off := CASE WHEN has_io_idx OR has_io
                  THEN format('CASE WHEN t.vio IS NULL THEN ''{}''::int[] ELSE flagsmith._io_matched(%s, CASE (t.vio).k WHEN ''s'' THEN (t.vio).s WHEN ''i'' THEN (t.vio).n::text END) END', sid)
                  ELSE '''{}''::int[]' END;
  iom_rows := CASE WHEN has_io_idx OR has_io
                   THEN format('CASE WHEN t.vio_k IS NULL THEN ''{}''::int[] ELSE flagsmith._io_matched(%s, CASE t.vio_k WHEN ''s'' THEN t.vio_s WHEN ''i'' THEN t.vio_n::text END) END', sid)
                   ELSE '''{}''::int[]' END;
  io_x := CASE WHEN has_io THEN format('CASE WHEN identifier IS NOT NULL THEN flagsmith._io_segment(%s, identifier) END', sid)
               ELSE 'NULL::jsonb' END;
  u_off := format(E'%s AS iom,\n      %s AS io', iom_off, io_x);
  u_x := ARRAY[iom_rows, io_x];
  u_n := ARRAY['iom', 'io'];
  FOR c IN SELECT x.* FROM flagsmith.condition x JOIN flagsmith.rule r USING (snapshot_id, rule_id)
           WHERE x.snapshot_id = sid AND r.seg_ord <= sn.n_ctx_segments AND x.status = 'ok'
             AND (x.operator = 'PERCENTAGE_SPLIT' OR x.v_is_semver)
           ORDER BY x.cond_id LOOP
    m := vcols ->> flagsmith._value_key(c);
    IF c.operator = 'PERCENTAGE_SPLIT' THEN
      SELECT g2.segment_key INTO segkey FROM flagsmith.rule r2 JOIN flagsmith.segment g2 USING (snapshot_id, seg_ord)
      WHERE r2.snapshot_id = sid AND r2.rule_id = c.rule_id;
      keyx := CASE WHEN c.prop_kind = 'split_ik' THEN 't.ik'
                   ELSE format('CASE WHEN (t.%1$s).k <> ''n'' THEN flagsmith.py_str(t.%1$s) END', m) END;
      u_off := u_off || format(E',\n      md5(convert_to(%L || '','' || %s, ''UTF8'')) AS h%s', segkey, keyx, c.cond_id);
      keyx := CASE WHEN c.prop_kind = 'split_ik' THEN 't.ik'
                   ELSE format('CASE WHEN t.%1$s_k <> ''n'' THEN flagsmith.py_str(%2$s) END', m, flagsmith._ref_val('rows', m)) END;
      u_x := u_x || format('md5(convert_to(%L || '','' || %s, ''UTF8''))', segkey, keyx);
      u_n := u_n || ('h' || c.cond_id);
    ELSIF m IS NOT NULL AND NOT svdone ? m THEN
      svdone := svdone || jsonb_build_object(m, true);
      u_off := u_off || format(E',\n      CASE WHEN (t.%1$s).k = ''s'' THEN flagsmith.semver_parse((t.%1$s).s) END AS sv%2$s', m, substr(m, 2));
      u_x := u_x || format('CASE WHEN t.%1$s_k = ''s'' THEN flagsmith.semver_parse(t.%1$s_s) ELSE NULL::flagsmith.semver END', m);
      u_n := u_n || ARRAY['sv' || substr(m, 2) || '_major', 'sv' || substr(m, 2) || '_minor', 'sv' || substr(m, 2) || '_patch',
                          'sv' || substr(m, 2) || '_pre', 'sv' || substr(m, 2) || '_build'];
    END IF;
  END LOOP;

  -- level s: segment membership (segments with overrides only)
  FOR g IN SELECT * FROM flagsmith.segment x WHERE x.snapshot_id = sid AND x.seg_ord <= sn.n_ctx_segments
           AND x.ov_count > 0 ORDER BY x.seg_ord LOOP
    FOREACH m IN ARRAY ARRAY['offset', 'rows'] LOOP
      IF g.io_indexed THEN
        w := format('(%s = ANY (u.iom))', g.seg_ord);
      ELSIF g.first_rule IS NULL THEN
        w := 'false';
      ELSE
        segparts := '{}'; segcosts := '{}';
        FOR o IN SELECT x.rule_id FROM flagsmith.rule x WHERE x.snapshot_id = sid AND x.seg_ord = g.seg_ord
                 AND x.parent_id IS NULL ORDER BY x.ord LOOP
          rr := flagsmith._compile_rule(sid, o.rule_id, vcols, g.segment_key, m);
          segparts := segparts || rr.expr; segcosts := segcosts || rr.cost;
        END LOOP;
        SELECT string_agg(q.p, ' AND ' ORDER BY q.kc, q.ni) INTO w FROM unnest(segparts, segcosts) WITH ORDINALITY q(p, kc, ni);
      END IF;
      IF NOT g.identity_free THEN
        w := format('(NOT %s.envm AND %s)', CASE WHEN m = 'offset' THEN 'u' ELSE 't' END, w);
      END IF;
      IF m = 'offset' THEN
        s_off := s_off || format(E',\n      %s AS s%s', w, g.seg_ord);
      ELSE
        s_x := s_x || w; s_n := s_n || ('s' || g.seg_ord);
      END IF;
    END LOOP;
  END LOOP;
  IF has_io THEN
    s_off := s_off || E',\n      coalesce((u.io ->> ''seg_ord'')::int = ANY (u.iom), false) AS iomatch';
    s_x := s_x || 'coalesce((u.io ->> ''seg_ord'')::int = ANY (u.iom), false)'::text; s_n := s_n || 'iomatch'::text;
  END IF;

  -- features: winner index (1 = default, 2.. = overrides by precedence, 0 = identity override)
  FOR f IN SELECT * FROM flagsmith.feature_context x WHERE x.snapshot_id = sid AND x.seg_ord IS NULL ORDER BY x.fc_id LOOP
    fi := fi + 1;
    en := ARRAY[f.enabled]; vals := ARRAY[f.value]; rsn := ARRAY[NULL::text]; metas := ARRAY[f.metadata];
    salts := ARRAY[f.feature_key]; voff := ARRAY[0]; vcnt := ARRAY[f.n_variants];
    vlo := '{}'; vhi := '{}'; vval := '{}'; vkey := '{}'; vw := '{}';
    nv := 0;
    FOR vr IN SELECT * FROM flagsmith.variant x WHERE x.snapshot_id = sid AND x.fc_id = f.fc_id ORDER BY x.ord LOOP
      vlo := vlo || vr.lo; vhi := vhi || vr.hi; vval := vval || vr.value; vkey := vkey || vr.variant_key; vw := vw || vr.weight_txt;
      nv := nv + 1;
    END LOOP;
    w_off := 'CASE'; w_rows := 'CASE';
    IF has_io THEN
      w_off := w_off || format(' WHEN s.iomatch AND (s.io -> ''ov'') ? %L THEN 0', f.feature_name);
      w_rows := w_rows || format(' WHEN s.iomatch AND (u.io -> ''ov'') ? %L THEN 0', f.feature_name);
    END IF;
    widx := 1;
    any_exp := coalesce(f.metadata ? 'experiment', false);
    FOR o IN SELECT x.*, gs.name AS seg_name FROM flagsmith.feature_context x
             JOIN flagsmith.segment gs USING (snapshot_id, seg_ord)
             WHERE x.snapshot_id = sid AND x.feature_name = f.feature_name AND x.seg_ord <= sn.n_ctx_segments
             ORDER BY x.win_rank LOOP
      widx := widx + 1;
      w_off := w_off || format(' WHEN s.s%s THEN %s', o.seg_ord, widx);
      w_rows := w_rows || format(' WHEN s.s%s THEN %s', o.seg_ord, widx);
      en := en || o.enabled; vals := vals || o.value; rsn := rsn || ('TARGETING_MATCH; segment=' || o.seg_name);
      metas := metas || o.metadata; salts := salts || o.feature_key; voff := voff || nv; vcnt := vcnt || o.n_variants;
      any_exp := any_exp OR coalesce(o.metadata ? 'experiment', false);
      FOR vr IN SELECT * FROM flagsmith.variant x WHERE x.snapshot_id = sid AND x.fc_id = o.fc_id ORDER BY x.ord LOOP
        vlo := vlo || vr.lo; vhi := vhi || vr.hi; vval := vval || vr.value; vkey := vkey || vr.variant_key; vw := vw || vr.weight_txt;
        nv := nv + 1;
      END LOOP;
    END LOOP;
    w_off := CASE WHEN w_off = 'CASE' THEN '1' ELSE w_off || ' ELSE 1 END' END;
    w_rows := CASE WHEN w_rows = 'CASE' THEN '1' ELSE w_rows || ' ELSE 1 END' END;
    SELECT CASE WHEN EXISTS (SELECT 1 FROM flagsmith.feature_context x JOIN flagsmith.segment gs USING (snapshot_id, seg_ord)
                             WHERE x.snapshot_id = sid AND x.feature_name = f.feature_name AND gs.identity_free)
                THEN 'DEFAULT' ELSE 'STATIC' END INTO env_fb;

    -- shape 'offset': a UNION ALL arm per feature with its own fence
    outs := flagsmith._arm(f.feature_name, en, vval, vals, vkey, vw, rsn, metas, f.fallback_reason, env_fb,
                           has_io, any_exp, 'x.w', 'x.vi', 's.io', 's.envm');
    arms := arms || format(E'\n    SELECT %s AS feature, %s AS enabled, %s AS value, %s AS variant, %s AS reason, %s AS metadata'
                           || E'\n    FROM (SELECT y.w, %s AS vi FROM (SELECT %s AS w) y OFFSET 0) x',
                           outs[1], outs[2], outs[3], outs[4], outs[5], outs[6],
                           flagsmith._arm_vi(vcnt, salts, vlo, vhi, voff, 'y.w', 's.ik'), w_off);
    -- shape 'rows': winners and variant picks as fenced columns, then one VALUES list
    z_x := z_x || w_rows; z_n := z_n || ('w' || fi);
    IF nv > 0 THEN
      y_x := y_x || flagsmith._arm_vi(vcnt, salts, vlo, vhi, voff, 'z.w' || fi, 't.ik'); y_n := y_n || ('vi' || fi);
    END IF;
    outs := flagsmith._arm(f.feature_name, en, vval, vals, vkey, vw, rsn, metas, f.fallback_reason, env_fb,
                           has_io, any_exp, 'z.w' || fi, CASE WHEN nv > 0 THEN 'y.vi' || fi ELSE 'NULL::int' END,
                           'u.io', 't.envm');
    vrows := vrows || format('(%s, %s, %s, %s, %s, %s)', outs[1], outs[2], outs[3], outs[4], outs[5], outs[6]);
  END LOOP;

  IF cardinality(arms) = 0 THEN
    body := 'SELECT NULL::text AS feature, NULL::boolean AS enabled, NULL::jsonb AS value, NULL::text AS variant, '
            || 'NULL::text AS reason, NULL::jsonb AS metadata WHERE false';
    flag_body := body;
  ELSE
    -- all flags: parallel-safe ROWS FROM fences
    body := E'\nSELECT a.feature, a.enabled, a.value, a.variant, a.reason, a.metadata'
            || flagsmith._rows_from(t_x, t_n, 't', false)
            || flagsmith._rows_from(u_x, u_n, 'u', true)
            || CASE WHEN cardinality(s_x) > 0 THEN flagsmith._rows_from(s_x, s_n, 's', true) ELSE '' END
            || flagsmith._rows_from(z_x, z_n, 'z', true)
            || CASE WHEN cardinality(y_x) > 0 THEN flagsmith._rows_from(y_x, y_n, 'y', true) ELSE '' END
            || E'\nCROSS JOIN LATERAL (VALUES\n    ' || array_to_string(vrows, E',\n    ')
            || E'\n) a(feature, enabled, value, variant, reason, metadata)\n';
    -- one flag: OFFSET 0 fences, one arm per feature, pruned by a constant feature filter
    head := format(E'\n  SELECT u.*%s\n  FROM (\n    SELECT t.*,\n      %s\n    FROM (\n      SELECT %s\n      OFFSET 0) t\n    OFFSET 0) u\n  OFFSET 0',
                   s_off, u_off, t_off);
    flag_body := format(E'\nSELECT a.feature, a.enabled, a.value, a.variant, a.reason, a.metadata\nFROM (%s) s\n'
                        || E'CROSS JOIN LATERAL (%s\n) a\nWHERE a.feature = flag_s%s.feature\n',
                        head, array_to_string(arms, E'\n    UNION ALL'), sid);
  END IF;

  IF length(body) + length(flag_body) > env.max_compiled_bytes THEN
    UPDATE flagsmith.snapshot x SET compiled = false,
      compile_note = format('generated code is %s bytes, over max_compiled_bytes (%s): evaluated by the interpreter',
                            length(body) + length(flag_body), env.max_compiled_bytes)
    WHERE x.snapshot_id = sid;
    RETURN false;
  END IF;

  EXECUTE format($f$CREATE FUNCTION flagsmith_c.flags_s%s(identifier text, traits jsonb DEFAULT '{}',
      identity_key text DEFAULT NULL, engine_mode boolean DEFAULT false)
    RETURNS SETOF flagsmith.flag_result LANGUAGE sql STABLE PARALLEL SAFE AS %L$f$, sid, body);
  EXECUTE format($f$CREATE FUNCTION flagsmith_c.flag_s%s(feature text, identifier text, traits jsonb DEFAULT '{}',
      identity_key text DEFAULT NULL, engine_mode boolean DEFAULT false)
    RETURNS SETOF flagsmith.flag_result LANGUAGE sql STABLE PARALLEL SAFE AS %L$f$, sid, flag_body);
  EXECUTE format('REVOKE ALL ON FUNCTION flagsmith_c.flags_s%s(text, jsonb, text, boolean) FROM PUBLIC', sid);
  EXECUTE format('REVOKE ALL ON FUNCTION flagsmith_c.flag_s%s(text, text, jsonb, text, boolean) FROM PUBLIC', sid);
  PERFORM flagsmith._grant_reader(format('FUNCTION flagsmith_c.flags_s%s(text, jsonb, text, boolean)', sid));
  PERFORM flagsmith._grant_reader(format('FUNCTION flagsmith_c.flag_s%s(text, text, jsonb, text, boolean)', sid));

  UPDATE flagsmith.snapshot x SET compiled = true, compile_note = NULL, compile_bytes = length(body) + length(flag_body),
    compile_ms = round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 2)
  WHERE x.snapshot_id = sid;
  RETURN true;
END $$;
