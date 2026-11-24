-- FlagShift: `terraform plan` for flag changes. Evaluates the live and a
-- candidate snapshot over a population of identities in one statement and
-- reports who changes and why. Uses each snapshot's compiled function when it
-- has one (parallel safe), the interpreter otherwise.
--
-- population: a table or view with columns identifier (text) and traits (jsonb).
-- These functions are SECURITY INVOKER: they read the population as the caller.

-- SQL that evaluates every flag of a snapshot for p.identifier / p.traits.
CREATE FUNCTION flagsmith._eval_sql(sid bigint) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT CASE WHEN s.compiled
              THEN format('flagsmith_c.flags_s%s(p.identifier, p.traits)', sid)
              ELSE format('flagsmith.get_flags(p.identifier, p.traits, snapshot_id => %s)', sid) END
  FROM flagsmith.snapshot s WHERE s.snapshot_id = sid
  UNION ALL
  SELECT NULL WHERE NOT EXISTS (SELECT 1 FROM flagsmith.snapshot s WHERE s.snapshot_id = sid)
  LIMIT 1
$$;

-- Every (feature, before, after) transition with its user count. `changed` is
-- false for identities whose flag stays the same.
CREATE FUNCTION flagsmith.plan_diff(env text, candidate bigint, population regclass, live bigint DEFAULT NULL)
RETURNS TABLE (
  feature text, changed boolean,
  from_enabled boolean, to_enabled boolean, from_value jsonb, to_value jsonb,
  from_variant text, to_variant text, from_reason text, to_reason text,
  users bigint, sample_identities text[])
LANGUAGE plpgsql STABLE
-- every row is expensive: let the planner use workers even for modest populations
SET parallel_setup_cost = 10
SET parallel_tuple_cost = 0.01
SET min_parallel_table_scan_size = '64kB'
-- JIT compiling the generated expression trees costs ~seconds per query and saves nothing
SET jit = off AS $$
DECLARE l bigint := coalesce(live, flagsmith._snapshot_for(env, NULL));
BEGIN
  IF flagsmith._eval_sql(candidate) IS NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: candidate snapshot % does not exist', candidate;
  END IF;
  RETURN QUERY EXECUTE format($q$
    SELECT coalesce(l.feature, c.feature),
           (l.enabled, l.value, l.variant) IS DISTINCT FROM (c.enabled, c.value, c.variant),
           l.enabled, c.enabled, l.value, c.value, l.variant, c.variant, l.reason, c.reason,
           count(*),
           ARRAY[min(coalesce(l.identifier, c.identifier)), max(coalesce(l.identifier, c.identifier))]
    FROM (SELECT p.identifier, f.* FROM (SELECT identifier::text, coalesce(traits::jsonb, '{}'::jsonb) AS traits FROM %1$s) p
          CROSS JOIN LATERAL %2$s f) l
    FULL JOIN (SELECT p.identifier, f.* FROM (SELECT identifier::text, coalesce(traits::jsonb, '{}'::jsonb) AS traits FROM %1$s) p
          CROSS JOIN LATERAL %3$s f) c
      ON l.identifier = c.identifier AND l.feature = c.feature
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
    ORDER BY 1, 2 DESC, 11 DESC$q$,
    population, flagsmith._eval_sql(l), flagsmith._eval_sql(candidate));
END $$;

-- One line per feature: how many identities change, and how.
CREATE FUNCTION flagsmith.plan(env text, candidate bigint, population regclass, live bigint DEFAULT NULL)
RETURNS TABLE (
  feature text, users bigint, users_changed bigint, turned_on bigint, turned_off bigint,
  value_changes bigint, variant_moves bigint, sample_identities text[])
LANGUAGE sql STABLE AS $$
  WITH d AS MATERIALIZED (SELECT * FROM flagsmith.plan_diff(env, candidate, population, live))
  SELECT d.feature, sum(d.users)::bigint,
         coalesce(sum(d.users) FILTER (WHERE d.changed), 0)::bigint,
         coalesce(sum(d.users) FILTER (WHERE NOT coalesce(d.from_enabled, false) AND d.to_enabled), 0)::bigint,
         coalesce(sum(d.users) FILTER (WHERE d.from_enabled AND NOT coalesce(d.to_enabled, false)), 0)::bigint,
         coalesce(sum(d.users) FILTER (WHERE d.from_value IS DISTINCT FROM d.to_value), 0)::bigint,
         coalesce(sum(d.users) FILTER (WHERE d.from_variant IS DISTINCT FROM d.to_variant), 0)::bigint,
         (SELECT (array_agg(DISTINCT x ORDER BY x))[1:5]
          FROM d d2, unnest(d2.sample_identities) x WHERE d2.feature = d.feature AND d2.changed)
  FROM d
  GROUP BY d.feature
  ORDER BY 3 DESC, 1
$$;

-- Cohort overlap of a feature between two snapshots (e.g. staging and
-- production): of the identities served `value`/variant in A, how many get the
-- same in B. Splits hash environment-specific keys, so "25% in staging" and
-- "25% in production" select different people.
CREATE FUNCTION flagsmith.cohort_overlap(snapshot_a bigint, snapshot_b bigint, population regclass,
                                         only_feature text DEFAULT NULL)
RETURNS TABLE (feature text, in_a bigint, in_b bigint, in_both bigint, overlap_pct numeric)
LANGUAGE plpgsql STABLE
SET parallel_setup_cost = 10
SET parallel_tuple_cost = 0.01
SET min_parallel_table_scan_size = '64kB'
-- JIT compiling the generated expression trees costs ~seconds per query and saves nothing
SET jit = off AS $$
BEGIN
  -- one pass over the population for every feature (or just only_feature); an identity
  -- is "targeted" when a segment, split or identity override serves it the flag enabled
  RETURN QUERY EXECUTE format($q$
    SELECT a.feature,
           count(*) FILTER (WHERE a.enabled AND a.reason NOT IN ('DEFAULT', 'STATIC')),
           count(*) FILTER (WHERE b.enabled AND b.reason NOT IN ('DEFAULT', 'STATIC')),
           count(*) FILTER (WHERE a.enabled AND b.enabled AND a.reason NOT IN ('DEFAULT', 'STATIC')
                            AND b.reason NOT IN ('DEFAULT', 'STATIC') AND a.variant IS NOT DISTINCT FROM b.variant),
           round(100.0 * count(*) FILTER (WHERE a.enabled AND b.enabled AND a.reason NOT IN ('DEFAULT', 'STATIC')
                                          AND b.reason NOT IN ('DEFAULT', 'STATIC') AND a.variant IS NOT DISTINCT FROM b.variant)
                 / nullif(count(*) FILTER (WHERE a.enabled AND a.reason NOT IN ('DEFAULT', 'STATIC')), 0), 1)
    FROM (SELECT p.identifier, f.* FROM (SELECT identifier::text, coalesce(traits::jsonb, '{}'::jsonb) AS traits FROM %1$s) p
          CROSS JOIN LATERAL %2$s f WHERE %4$L::text IS NULL OR f.feature = %4$L) a
    JOIN (SELECT p.identifier, f.* FROM (SELECT identifier::text, coalesce(traits::jsonb, '{}'::jsonb) AS traits FROM %1$s) p
          CROSS JOIN LATERAL %3$s f WHERE %4$L::text IS NULL OR f.feature = %4$L) b
      ON a.identifier = b.identifier AND a.feature = b.feature
    GROUP BY a.feature
    ORDER BY a.feature$q$,
    population, flagsmith._eval_sql(snapshot_a), flagsmith._eval_sql(snapshot_b), only_feature);
END $$;
