-- Interpreter: evaluates any snapshot (live, candidate, test, old) by walking its
-- tables. It follows flag_engine.get_evaluation_result step by step, including
-- the evaluation order that flag dependencies make observable (short-circuiting
-- within a rule, memoised segment matches, cycle detection), using an explicit
-- stack instead of recursion.

-- Comparison operators, by the context value's type (Python's casting rules).
CREATE FUNCTION flagsmith._cmp_eval(op text, v flagsmith.ctxval, c flagsmith.condition) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE cmp int; tv flagsmith.semver;
BEGIN
  CASE v.k
    WHEN 's' THEN
      IF NOT c.v_is_str THEN
        -- outside the schema: a number or bool value raises TypeError in the reference
        IF json_typeof(c.value_raw) IN ('number', 'boolean') THEN RETURN false; END IF;
      ELSIF c.v_is_semver THEN
        tv := flagsmith.semver_parse(v.s);
        IF tv IS NULL THEN RETURN false; END IF;
        IF op = 'CONTAINS' THEN
          -- `x in Version` iterates (major, minor, patch, prerelease, build)
          RETURN coalesce(c.v_semver_txt = tv.pre OR c.v_semver_txt = tv.build, false);
        END IF;
        IF c.v_semver IS NULL THEN RETURN false; END IF;
        cmp := flagsmith.semver_cmp(tv, c.v_semver);
      END IF;
      IF cmp IS NULL THEN
        IF op = 'CONTAINS' THEN RETURN strpos(v.s, c.v_text) > 0; END IF;
        cmp := CASE WHEN v.s = c.v_text THEN 0
                    WHEN v.s COLLATE "C" < c.v_text COLLATE "C" THEN -1 ELSE 1 END;
      END IF;
    WHEN 'i' THEN
      IF op = 'CONTAINS' OR c.v_int IS NULL THEN RETURN false; END IF;
      cmp := sign(v.n - c.v_int)::int;
    WHEN 'f' THEN
      IF op = 'CONTAINS' OR c.v_float IS NULL THEN RETURN false; END IF;
      IF v.f = 'NaN'::float8 OR c.v_float = 'NaN'::float8 THEN
        RETURN op = 'NOT_EQUAL';           -- NaN compares unequal to everything
      END IF;
      cmp := CASE WHEN v.f < c.v_float THEN -1 WHEN v.f > c.v_float THEN 1 ELSE 0 END;
    WHEN 'b' THEN
      IF op = 'CONTAINS' THEN RETURN false; END IF;
      cmp := CASE WHEN v.b = c.v_bool THEN 0 WHEN v.b THEN 1 ELSE -1 END;
    ELSE
      RETURN false;
  END CASE;
  RETURN CASE op
    WHEN 'EQUAL' THEN cmp = 0
    WHEN 'NOT_EQUAL' THEN cmp <> 0
    WHEN 'GREATER_THAN' THEN cmp > 0
    WHEN 'GREATER_THAN_INCLUSIVE' THEN cmp >= 0
    WHEN 'LESS_THAN' THEN cmp < 0
    WHEN 'LESS_THAN_INCLUSIVE' THEN cmp <= 0
    ELSE false END;
END $$;

-- One condition against an already resolved context value.
CREATE FUNCTION flagsmith._cond_eval(c flagsmith.condition, v flagsmith.ctxval, segment_key text)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE op text := c.operator; x float8; m float8;
BEGIN
  IF c.status <> 'ok' THEN RETURN false; END IF;
  IF op = 'IN' THEN
    RETURN CASE v.k WHEN 's' THEN coalesce(v.s = ANY (c.in_set), false)
                    WHEN 'i' THEN coalesce(v.n::text = ANY (c.in_set), false)
                    ELSE false END;
  END IF;
  IF op = 'PERCENTAGE_SPLIT' THEN
    IF v.k = 'n' OR c.v_threshold IS NULL OR c.v_threshold = 'NaN'::float8 THEN RETURN false; END IF;
    RETURN flagsmith.hash_pct(segment_key, flagsmith.py_str(v)) <= c.v_threshold;
  END IF;
  IF op = 'IS_NOT_SET' THEN RETURN v.k = 'n'; END IF;
  IF op = 'IS_SET' THEN RETURN v.k <> 'n'; END IF;
  IF v.k = 'n' THEN RETURN false; END IF;
  CASE op
    WHEN 'NOT_CONTAINS' THEN
      RETURN v.k = 's' AND strpos(v.s, c.v_text) = 0;
    WHEN 'REGEX' THEN
      RETURN flagsmith.py_str(v) ~ c.v_regex;
    WHEN 'MODULO' THEN
      IF v.k NOT IN ('i', 'f', 'b') OR c.v_mod_div IS NULL OR c.v_mod_rem IS NULL THEN RETURN false; END IF;
      IF v.k = 'i' AND abs(v.n) >= 1e308 THEN RETURN false; END IF;   -- OverflowError in Python
      x := CASE v.k WHEN 'i' THEN v.n::float8 WHEN 'f' THEN v.f ELSE v.b::int::float8 END;
      m := flagsmith.py_fmod(x, c.v_mod_div);
      RETURN m IS NOT NULL AND m <> 'NaN'::float8 AND c.v_mod_rem <> 'NaN'::float8 AND m = c.v_mod_rem;
    WHEN 'EQUAL', 'NOT_EQUAL', 'GREATER_THAN', 'GREATER_THAN_INCLUSIVE', 'LESS_THAN',
         'LESS_THAN_INCLUSIVE', 'CONTAINS' THEN
      RETURN flagsmith._cmp_eval(op, v, c);
    ELSE
      RETURN false;
  END CASE;
END $$;

-- The context value a (non flag-dependent) condition reads.
CREATE FUNCTION flagsmith._ctx_value(c flagsmith.condition, has_identity boolean, identifier text,
                                     ikey text, traits jsonb)
RETURNS flagsmith.ctxval
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE tv jsonb;
BEGIN
  IF c.prop_kind = 'split_ik' THEN
    RETURN CASE WHEN ikey IS NULL THEN ROW('n', NULL, NULL, NULL, NULL)::flagsmith.ctxval
                ELSE ROW('s', ikey, NULL, NULL, NULL)::flagsmith.ctxval END;
  END IF;
  IF NOT has_identity THEN
    IF c.prop_kind = 'jp_const' THEN RETURN c.const_val; END IF;
    RETURN ROW('n', NULL, NULL, NULL, NULL)::flagsmith.ctxval;
  END IF;
  IF c.prop_kind = 'trait' THEN
    RETURN flagsmith.ctxval(traits -> c.prop_name);
  END IF;
  -- a JSONPath property: a trait literally named like the query wins
  tv := traits -> c.property;
  IF tv IS NOT NULL AND jsonb_typeof(tv) <> 'null' THEN
    RETURN flagsmith.ctxval(tv);
  END IF;
  RETURN CASE c.prop_kind
    WHEN 'jp_identifier' THEN flagsmith.ctxval_str(identifier)
    WHEN 'jp_identity_key' THEN flagsmith.ctxval_str(ikey)
    WHEN 'jp_trait' THEN flagsmith.ctxval_jp(traits -> c.prop_name)
    WHEN 'jp_trait_path' THEN flagsmith.ctxval_jp(flagsmith.jsonb_walk(traits -> c.prop_name, c.prop_path))
    WHEN 'jp_const' THEN c.const_val
    ELSE ROW('n', NULL, NULL, NULL, NULL)::flagsmith.ctxval
  END;
END $$;

-- A flag result from a feature context: variant selection, value, reason.
CREATE FUNCTION flagsmith._flag_result(sid bigint, fcid int, name text, enabled boolean, val jsonb,
  fkey text, nvar int, meta jsonb, reason text, ikey text)
RETURNS flagsmith.flag_result
LANGUAGE plpgsql STABLE PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE p float8; vr record;
BEGIN
  IF ikey IS NOT NULL AND nvar > 0 THEN
    p := flagsmith.hash_pct(fkey, ikey);
    SELECT v.value, v.variant_key, v.weight_txt INTO vr
    FROM flagsmith.variant v
    WHERE v.snapshot_id = sid AND v.fc_id = fcid AND v.lo <= p AND p < v.hi
    ORDER BY v.ord LIMIT 1;
    IF FOUND THEN
      RETURN ROW(name, enabled, vr.value, vr.variant_key, 'SPLIT; weight=' || vr.weight_txt, meta)::flagsmith.flag_result;
    END IF;
    RETURN ROW(name, enabled, val, 'control', reason, meta)::flagsmith.flag_result;
  END IF;
  RETURN ROW(name, enabled, val, NULL, reason, meta)::flagsmith.flag_result;
END $$;

CREATE FUNCTION flagsmith._interp(
  sid bigint,
  has_identity boolean,
  identifier text,
  identity_key text,
  traits jsonb,
  env_mode boolean DEFAULT false,
  OUT flags flagsmith.flag_result[],
  OUT segments flagsmith.segment_result[])
LANGUAGE plpgsql STABLE PARALLEL SAFE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  sn flagsmith.snapshot;
  ikey text;
  -- program: segments by position
  nseg int;
  sg_key text[]; sg_name text[]; sg_meta jsonb[]; sg_rule int[]; sg_io boolean[];
  sg_ovf int[]; sg_ovn int[]; sg_ord int[]; sg_src text[];
  -- rules by rule_id, conditions by cond_id
  r_type text[]; r_c1 int[]; r_cn int[]; r_child int[]; r_next int[];
  conds flagsmith.condition[];
  -- feature contexts by position (defaults 1..nfeat)
  nfeat int; nfc int;
  fc_name text[]; fc_en boolean[]; fc_val jsonb[]; fc_key text[]; fc_prio numeric[];
  fc_meta jsonb[]; fc_nvar int[]; fc_real int[]; fc_fb text[]; fc_seg int[]; fc_segpos int[];
  fnames text[];
  -- identity overrides
  io_v flagsmith.ctxval; io_key text; io_matched int[] := '{}'; io_seg int; io_ovf int; io_ovn int;
  -- machine
  st_t int[] := '{}'; st_a int[] := '{}'; st_b int[] := '{}'; st_c int[] := '{}';
  st_d int[] := '{}'; st_e int[] := '{}';
  sp int := 0;
  ret boolean;
  rid int; cid int; rt text; res boolean; fin boolean; mr boolean;
  -- flag dependency state (Python: _LazyFlags and _DependencyResolver)
  used boolean := false; cycle_hits int := 0; resolving int[] := '{}';
  cyclic boolean[] := '{}'; res_done boolean[] := '{}'; res_fc int[] := '{}'; res_reason text[] := '{}';
  seg_memo int[] := '{}';
  -- main pass
  ov_fc int[] := '{}';
  main_hits int;
  p int; i int; j int; f int; s int;
  cnd flagsmith.condition;
  v flagsmith.ctxval;
  fr flagsmith.flag_result;
  tv jsonb;
  fj jsonb;
BEGIN
  SELECT * INTO sn FROM flagsmith.snapshot x WHERE x.snapshot_id = sid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pgsmith: snapshot % does not exist', sid;
  END IF;
  IF has_identity THEN
    ikey := coalesce(nullif(identity_key, ''), sn.ctx_env_key || '_' || coalesce(identifier, 'None'));
    IF sn.n_identity_overrides > 0 THEN
      SELECT g.seg_ord, g.ov_first, g.ov_count INTO io_seg, io_ovf, io_ovn FROM flagsmith.segment g
      WHERE g.snapshot_id = sid AND g.source = 'identity_override' AND g.io_identifier = identifier;
    END IF;
  END IF;

  -- load the program
  SELECT array_agg(g.segment_key ORDER BY g.seg_ord), array_agg(g.name ORDER BY g.seg_ord),
         array_agg(g.metadata ORDER BY g.seg_ord), array_agg(g.first_rule ORDER BY g.seg_ord),
         array_agg(g.io_indexed ORDER BY g.seg_ord), array_agg(g.ov_first ORDER BY g.seg_ord),
         array_agg(g.ov_count ORDER BY g.seg_ord), array_agg(g.seg_ord ORDER BY g.seg_ord),
         array_agg(g.source ORDER BY g.seg_ord)
  INTO sg_key, sg_name, sg_meta, sg_rule, sg_io, sg_ovf, sg_ovn, sg_ord, sg_src
  FROM (SELECT * FROM flagsmith.segment g1
        WHERE g1.snapshot_id = sid AND g1.seg_ord BETWEEN 1 AND sn.n_ctx_segments
        UNION ALL
        -- the identity's own override segment (an index probe, however many there are)
        SELECT * FROM flagsmith.segment g2
        WHERE g2.snapshot_id = sid AND g2.seg_ord = io_seg) g
  WHERE NOT env_mode OR g.identity_free;
  nseg := coalesce(cardinality(sg_key), 0);

  SELECT array_agg(ru.rule_type ORDER BY ru.rule_id), array_agg(ru.first_cond ORDER BY ru.rule_id),
         array_agg(ru.n_cond ORDER BY ru.rule_id), array_agg(ru.first_child ORDER BY ru.rule_id),
         array_agg(ru.next_sibling ORDER BY ru.rule_id)
  INTO r_type, r_c1, r_cn, r_child, r_next
  FROM flagsmith.rule ru WHERE ru.snapshot_id = sid AND ru.rule_id <= sn.n_ctx_rules;
  SELECT array_agg(c ORDER BY c.cond_id) INTO conds
  FROM flagsmith.condition c WHERE c.snapshot_id = sid AND c.cond_id <= sn.n_ctx_conds;

  SELECT array_agg(x.feature_name ORDER BY x.fc_id), array_agg(x.enabled ORDER BY x.fc_id),
         array_agg(x.value ORDER BY x.fc_id), array_agg(x.feature_key ORDER BY x.fc_id),
         array_agg(x.priority ORDER BY x.fc_id), array_agg(x.metadata ORDER BY x.fc_id),
         array_agg(x.n_variants ORDER BY x.fc_id), array_agg(x.fc_id ORDER BY x.fc_id),
         array_agg(x.fallback_reason ORDER BY x.fc_id), array_agg(x.seg_ord ORDER BY x.fc_id)
  INTO fc_name, fc_en, fc_val, fc_key, fc_prio, fc_meta, fc_nvar, fc_real, fc_fb, fc_seg
  FROM (SELECT * FROM flagsmith.feature_context x1
        WHERE x1.snapshot_id = sid AND x1.fc_id BETWEEN 1 AND sn.n_ctx_fcs
        UNION ALL
        SELECT * FROM flagsmith.feature_context x2
        WHERE x2.snapshot_id = sid AND x2.fc_id BETWEEN io_ovf AND io_ovf + io_ovn - 1) x;
  nfc := coalesce(cardinality(fc_name), 0);
  nfeat := sn.n_features;
  fnames := coalesce(fc_name[1:nfeat], '{}');

  -- positions: the per-identity segment's overrides follow the context's feature contexts
  fc_segpos := array_fill(NULL::int, ARRAY[greatest(nfc, 1)]);
  FOR p IN 1..nseg LOOP
    IF sg_src[p] = 'identity_override' THEN
      sg_ovf[p] := sn.n_ctx_fcs + 1;
    END IF;
    IF sg_ovn[p] > 0 THEN
      FOR j IN sg_ovf[p] .. sg_ovf[p] + sg_ovn[p] - 1 LOOP
        fc_segpos[j] := p;
      END LOOP;
    END IF;
  END LOOP;

  -- fallback reasons: DEFAULT when a segment in the evaluated context overrides the feature
  IF env_mode THEN
    FOR f IN 1..nfeat LOOP fc_fb[f] := 'STATIC'; END LOOP;
    FOR j IN nfeat + 1 .. nfc LOOP
      IF fc_segpos[j] IS NOT NULL THEN
        f := array_position(fnames, fc_name[j]);
        IF f IS NOT NULL THEN fc_fb[f] := 'DEFAULT'; END IF;
      END IF;
    END LOOP;
  ELSIF io_seg IS NOT NULL THEN
    FOR j IN sn.n_ctx_fcs + 1 .. nfc LOOP
      f := array_position(fnames, fc_name[j]);
      IF f IS NOT NULL THEN fc_fb[f] := 'DEFAULT'; END IF;
    END LOOP;
  END IF;

  -- identity overrides: one index probe for every IN-identifier segment
  IF has_identity AND sn.n_io_indexed > 0 THEN
    tv := traits -> '$.identity.identifier';
    IF tv IS NOT NULL AND jsonb_typeof(tv) <> 'null' THEN
      io_v := flagsmith.ctxval(tv);
    ELSE
      io_v := flagsmith.ctxval_str(identifier);
    END IF;
    io_key := CASE io_v.k WHEN 's' THEN io_v.s WHEN 'i' THEN io_v.n::text END;
    IF io_key IS NOT NULL THEN
      io_matched := ARRAY(SELECT o.seg_ord FROM flagsmith.identity_override o
                          WHERE o.snapshot_id = sid AND o.in_key = io_key);
    END IF;
  END IF;

  -- main pass over segments, in context order
  FOR p IN 1..nseg LOOP
    main_hits := cycle_hits;

    -- run the machine on is_context_in_segment(p)
    sp := 1; st_t[1] := 1; st_a[1] := p; st_b[1] := 0; st_c[1] := 0; st_d[1] := 0; st_e[1] := 0;
    LOOP
      EXIT WHEN sp = 0;
      IF st_t[sp] = 1 THEN
        -- ---- is_context_in_segment: every top-level rule must match ----
        s := st_a[sp];
        IF st_b[sp] = 0 THEN
          IF sg_io[s] THEN
            ret := sg_ord[s] = ANY (io_matched); sp := sp - 1; CONTINUE;
          END IF;
          IF sg_rule[s] IS NULL THEN
            ret := false; sp := sp - 1; CONTINUE;
          END IF;
          st_b[sp] := 1; st_c[sp] := sg_rule[s];
          sp := sp + 1; st_t[sp] := 2; st_a[sp] := sg_rule[s]; st_b[sp] := 0; st_c[sp] := 0; st_d[sp] := 0; st_e[sp] := s;
          CONTINUE;
        END IF;
        IF NOT ret THEN sp := sp - 1; CONTINUE; END IF;
        j := r_next[st_c[sp]];
        IF j IS NULL THEN ret := true; sp := sp - 1; CONTINUE; END IF;
        st_c[sp] := j;
        sp := sp + 1; st_t[sp] := 2; st_a[sp] := j; st_b[sp] := 0; st_c[sp] := 0; st_d[sp] := 0; st_e[sp] := s;
        CONTINUE;

      ELSIF st_t[sp] = 2 THEN
        -- ---- context_matches_rule: conditions, then sub-rules, by the rule type ----
        rid := st_a[sp];
        rt := r_type[rid];
        IF st_b[sp] = 0 THEN
          IF r_cn[rid] > 0 THEN
            st_b[sp] := 1; st_c[sp] := r_c1[rid];
          ELSE
            st_d[sp] := 1;               -- no conditions: that check passes
            st_b[sp] := 3;
          END IF;
        END IF;

        IF st_b[sp] IN (1, 2) THEN
          fin := false;
          LOOP
            cid := st_c[sp];
            IF cid > r_c1[rid] + r_cn[rid] - 1 THEN
              st_d[sp] := CASE WHEN rt = 'ANY' THEN 0 ELSE 1 END;    -- exhausted
              fin := true; EXIT;
            END IF;
            cnd := conds[cid];
            IF cnd.prop_kind = 'jp_flag' THEN
              tv := CASE WHEN has_identity THEN traits -> cnd.property END;
              IF tv IS NOT NULL AND jsonb_typeof(tv) <> 'null' THEN
                v := flagsmith.ctxval(tv);
              ELSE
                f := array_position(fnames, cnd.prop_name);
                IF f IS NOT NULL AND coalesce(res_done[f], false) THEN
                  v := NULL;     -- resolved below
                ELSIF f IS NULL THEN
                  used := true;  -- __missing__: the feature is absent, nothing resolves
                  v := ROW('n', NULL, NULL, NULL, NULL)::flagsmith.ctxval;
                ELSIF st_b[sp] = 2 THEN
                  v := ROW('n', NULL, NULL, NULL, NULL)::flagsmith.ctxval;  -- resolution left it unresolved
                ELSE
                  used := true;
                  st_b[sp] := 2;
                  sp := sp + 1; st_t[sp] := 3; st_a[sp] := f; st_b[sp] := 0; st_c[sp] := 0; st_d[sp] := 0; st_e[sp] := 0;
                  EXIT;
                END IF;
                IF v IS NULL THEN
                  fr := flagsmith._flag_result(sid, fc_real[res_fc[f]], fc_name[res_fc[f]], fc_en[res_fc[f]],
                          fc_val[res_fc[f]], fc_key[res_fc[f]], fc_nvar[res_fc[f]], fc_meta[res_fc[f]],
                          res_reason[f], ikey);
                  fj := jsonb_build_object('enabled', fr.enabled, 'name', fr.feature, 'reason', fr.reason,
                                           'value', fr.value, 'variant', fr.variant);
                  IF fr.metadata IS NOT NULL THEN fj := fj || jsonb_build_object('metadata', fr.metadata); END IF;
                  v := flagsmith.ctxval_jp(flagsmith.jsonb_walk(fj, cnd.prop_path));
                END IF;
              END IF;
            ELSE
              v := flagsmith._ctx_value(cnd, has_identity, identifier, ikey, traits);
            END IF;
            st_b[sp] := 1;
            res := flagsmith._cond_eval(cnd, v, sg_key[st_e[sp]]);
            IF rt = 'ALL' AND NOT res THEN st_d[sp] := 0; fin := true; EXIT; END IF;
            IF rt = 'ANY' AND res THEN st_d[sp] := 1; fin := true; EXIT; END IF;
            IF rt = 'NONE' AND res THEN st_d[sp] := 0; fin := true; EXIT; END IF;
            st_c[sp] := cid + 1;
          END LOOP;
          IF NOT fin THEN CONTINUE; END IF;     -- a resolve frame was pushed
          st_b[sp] := 3;
        END IF;

        IF st_b[sp] = 3 THEN
          -- sub-rules are evaluated whatever the conditions gave
          IF r_child[rid] IS NULL THEN
            ret := st_d[sp] = 1; sp := sp - 1; CONTINUE;
          END IF;
          st_b[sp] := 4; st_c[sp] := r_child[rid];
          i := st_e[sp];
          sp := sp + 1; st_t[sp] := 2; st_a[sp] := st_c[sp - 1]; st_b[sp] := 0; st_c[sp] := 0; st_d[sp] := 0; st_e[sp] := i;
          CONTINUE;
        END IF;

        IF st_b[sp] = 4 THEN
          -- a sub-rule returned `ret`
          mr := NULL;
          IF rt = 'ALL' AND NOT ret THEN mr := false;
          ELSIF rt = 'ANY' AND ret THEN mr := true;
          ELSIF rt = 'NONE' AND ret THEN mr := false;
          END IF;
          IF mr IS NULL THEN
            j := r_next[st_c[sp]];
            IF j IS NOT NULL THEN
              st_c[sp] := j;
              i := st_e[sp];
              sp := sp + 1; st_t[sp] := 2; st_a[sp] := j; st_b[sp] := 0; st_c[sp] := 0; st_d[sp] := 0; st_e[sp] := i;
              CONTINUE;
            END IF;
            mr := rt <> 'ANY';
          END IF;
          ret := st_d[sp] = 1 AND mr; sp := sp - 1; CONTINUE;
        END IF;

      ELSE
        -- ---- _DependencyResolver.resolve_feature(fnames[f]) ----
        f := st_a[sp];
        IF st_b[sp] = 0 THEN
          i := array_position(resolving, f);
          IF i IS NOT NULL THEN
            FOR j IN i .. cardinality(resolving) LOOP cyclic[resolving[j]] := true; END LOOP;
            cycle_hits := cycle_hits + 1;
            sp := sp - 1; CONTINUE;
          END IF;
          resolving := resolving || f;
          st_b[sp] := 1; st_c[sp] := nfeat; st_d[sp] := 0;
        ELSIF st_b[sp] = 2 THEN
          -- matches_segment returned `ret` for the segment of override st_c
          s := fc_segpos[st_c[sp]];
          IF cycle_hits <> st_e[sp] THEN
            res := false;                       -- reached by cutting a cycle: no match, no memo
          ELSE
            seg_memo[s] := ret::int; res := ret;
          END IF;
          IF res AND (st_d[sp] = 0 OR fc_prio[st_c[sp]] < fc_prio[st_d[sp]]) THEN st_d[sp] := st_c[sp]; END IF;
          st_b[sp] := 1;
        END IF;
        -- walk the overrides of this feature, in context order
        fin := true;
        LOOP
          j := st_c[sp] + 1;
          WHILE j <= nfc AND NOT (fc_segpos[j] IS NOT NULL AND fc_name[j] = fnames[f]) LOOP j := j + 1; END LOOP;
          EXIT WHEN j > nfc;
          st_c[sp] := j;
          s := fc_segpos[j];
          IF seg_memo[s] IS NOT NULL THEN
            IF seg_memo[s] = 1 AND (st_d[sp] = 0 OR fc_prio[j] < fc_prio[st_d[sp]]) THEN st_d[sp] := j; END IF;
            CONTINUE;
          END IF;
          st_e[sp] := cycle_hits; st_b[sp] := 2;
          sp := sp + 1; st_t[sp] := 1; st_a[sp] := s; st_b[sp] := 0; st_c[sp] := 0; st_d[sp] := 0; st_e[sp] := 0;
          fin := false;
          EXIT;
        END LOOP;
        IF NOT fin THEN CONTINUE; END IF;
        resolving := resolving[1 : cardinality(resolving) - 1];
        IF NOT coalesce(cyclic[f], false) THEN
          res_done[f] := true;
          IF st_d[sp] = 0 THEN
            res_fc[f] := f; res_reason[f] := fc_fb[f];
          ELSE
            res_fc[f] := st_d[sp];
            res_reason[f] := 'TARGETING_MATCH; segment=' || sg_name[fc_segpos[st_d[sp]]];
          END IF;
        END IF;
        sp := sp - 1; CONTINUE;
      END IF;
    END LOOP;

    IF cycle_hits <> main_hits THEN CONTINUE; END IF;   -- evaluating it cut a cycle: unsound
    IF NOT ret THEN CONTINUE; END IF;
    segments := segments || ROW(sg_name[p], sg_meta[p])::flagsmith.segment_result;
    IF sg_ovn[p] > 0 THEN
      FOR j IN sg_ovf[p] .. sg_ovf[p] + sg_ovn[p] - 1 LOOP
        f := array_position(fnames, fc_name[j]);
        IF f IS NOT NULL AND (ov_fc[f] IS NULL OR fc_prio[j] < fc_prio[ov_fc[f]]) THEN
          ov_fc[f] := j;
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  -- flags, in feature order
  FOR f IN 1..nfeat LOOP
    IF used AND coalesce(res_done[f], false) THEN
      j := res_fc[f];
      fr := flagsmith._flag_result(sid, fc_real[j], fc_name[j], fc_en[j], fc_val[j], fc_key[j], fc_nvar[j],
                                   fc_meta[j], res_reason[f], ikey);
    ELSIF ov_fc[f] IS NOT NULL THEN
      j := ov_fc[f];
      fr := flagsmith._flag_result(sid, fc_real[j], fc_name[j], fc_en[j], fc_val[j], fc_key[j], fc_nvar[j],
                                   fc_meta[j], 'TARGETING_MATCH; segment=' || sg_name[fc_segpos[j]], ikey);
    ELSE
      fr := flagsmith._flag_result(sid, fc_real[f], fc_name[f], fc_en[f], fc_val[f], fc_key[f], fc_nvar[f],
                                   fc_meta[f], fc_fb[f], ikey);
    END IF;
    IF used AND coalesce(cyclic[f], false) THEN
      fr.reason := 'ERROR; code=CIRCULAR_DEPENDENCY';
    END IF;
    IF env_mode AND fr.metadata ? 'experiment' THEN
      fr.metadata := nullif(fr.metadata - 'experiment', '{}'::jsonb);
    END IF;
    flags := flags || fr;
  END LOOP;
  flags := coalesce(flags, '{}');
  segments := coalesce(segments, '{}');
END $$;
