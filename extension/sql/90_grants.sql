-- Roles and privileges. Nothing in the flagsmith schemas is granted to PUBLIC.
--   flagsmith_reader: evaluate flags (grant it to your application roles)
--   flagsmith_loader: load configuration, pin/unpin, collect garbage
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_reader') THEN
    BEGIN
      CREATE ROLE flagsmith_reader NOLOGIN;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'pg_flagsmith: cannot create role flagsmith_reader; grant EXECUTE on flagsmith functions manually';
    END;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_loader') THEN
    BEGIN
      CREATE ROLE flagsmith_loader NOLOGIN;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'pg_flagsmith: cannot create role flagsmith_loader; grant EXECUTE on load_context manually';
    END;
  END IF;
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA flagsmith FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA flagsmith FROM PUBLIC;

DO $$
DECLARE f text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_reader') THEN
    GRANT USAGE ON SCHEMA flagsmith, flagsmith_c TO flagsmith_reader;
    -- everything except the functions that write
    FOR f IN
      SELECT p.oid::regprocedure::text FROM pg_proc p
      WHERE p.pronamespace = 'flagsmith'::regnamespace
        AND p.proname NOT IN ('load_context', 'evaluate_context', 'gc', 'drop_test_snapshots', 'pin', 'unpin',
                              'recompile', 'compile_snapshot', 'record_parity', '_publish', '_drop_compiled',
                              '_load_condition', '_load_rules', '_load_fc', '_warn', '_alias_for', '_grant_reader')
    LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO flagsmith_reader', f);
    END LOOP;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_loader') THEN
    GRANT USAGE ON SCHEMA flagsmith, flagsmith_c TO flagsmith_loader;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA flagsmith TO flagsmith_loader;
    GRANT SELECT ON flagsmith.warnings TO flagsmith_loader;
  END IF;
END $$;
