-- Roles and privileges. Nothing in the pgsmith schemas is granted to PUBLIC.
--
--   flagsmith_reader   evaluate flags                                   application roles
--   flagsmith_tracker  record exposures and events (writes: primary)    application roles
--   flagsmith_planner  reader + read live configuration, load           FlagShift in CI
--                      FlagShift candidates (never served)
--   flagsmith_loader   planner + tracker + load and serve configuration, sync jobs, operators
--                      pin/unpin, run syncs, deliver events
--   owner only         add_remote_source / remove_remote_source (a source decides
--                      where a server-side key is sent), the settings and every table
--
-- How grants are decided: SECURITY INVOKER routines run with the caller's own
-- privileges, and no role has privileges on pgsmith's tables, so readers get
-- every invoker routine except the administrative ones listed below. SECURITY
-- DEFINER routines act with the owner's privileges, so each is granted by name;
-- internal ones (_publish, _remote_key, ...) are granted to no one.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['flagsmith_reader', 'flagsmith_tracker', 'flagsmith_planner', 'flagsmith_loader'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      BEGIN
        EXECUTE format('CREATE ROLE %I NOLOGIN', r);
      EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'pgsmith: cannot create role %; grant EXECUTE on pgsmith functions manually', r;
      END;
    END IF;
  END LOOP;
END $$;

REVOKE ALL ON ALL ROUTINES IN SCHEMA flagsmith FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA flagsmith FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA flagsmith FROM PUBLIC;
-- generated functions: revoked explicitly when created, and by default
ALTER DEFAULT PRIVILEGES IN SCHEMA flagsmith_c REVOKE EXECUTE ON ROUTINES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA flagsmith REVOKE EXECUTE ON ROUTINES FROM PUBLIC;

DO $$
DECLARE
  f record;
  -- invoker routines that are not for readers
  admin_invoker text[] := ARRAY['add_remote_source', 'remove_remote_source',
                                'schedule_sync', 'unschedule_sync', 'schedule_events', 'unschedule_events',
                                'sync_run', 'load_document', 'track_exposure', 'track_event', 'track_variant',
                                '_adopt', '_drop_generated', '_grant_reader', '_settings',
                                -- internals of in-database sync and delivery
                                '_http_call', '_remote_headers', '_remote_fail', '_remote_ingest',
                                '_event_send', '_event_settle', '_event_stat', '_ext_name'];
  reader_definer  text[] := ARRAY['_interp', '_snapshot_for', '_io_matched', '_io_segment', 'health', 'environments'];
  tracker_names   text[] := ARRAY['_enqueue', 'track_exposure', 'track_event', 'track_variant'];
  planner_names   text[] := ARRAY['live_context', 'snapshot_context', 'load_candidate', '_eval_sql'];
  loader_names    text[] := ARRAY['load_context', 'apply_context', 'load_document', 'evaluate_context', 'mark_checked',
                                  'pin', 'unpin', 'gc', 'recompile', 'drop_test_snapshots', 'record_parity', 'remove_environment',
                                  'load_history', 'sync_tick', '_sync_await', 'sync_run', 'sync_status',
                                  'schedule_sync', 'unschedule_sync', 'schedule_events', 'unschedule_events',
                                  'events_claim', 'events_record', 'events_pending', 'events_tick',
                                  'event_status', 'events_retry_failed'];
  grantee text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure::text AS sig, p.proname::text AS name, p.prosecdef, p.prokind
    FROM pg_proc p WHERE p.pronamespace = 'flagsmith'::regnamespace
  LOOP
    FOREACH grantee IN ARRAY ARRAY['flagsmith_reader', 'flagsmith_tracker', 'flagsmith_planner', 'flagsmith_loader'] LOOP
      CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = grantee);
      IF (grantee = 'flagsmith_reader'
            AND ((NOT f.prosecdef AND f.name <> ALL (admin_invoker)) OR f.name = ANY (reader_definer)))
         OR (grantee = 'flagsmith_tracker' AND f.name = ANY (tracker_names))
         OR (grantee = 'flagsmith_planner' AND f.name = ANY (planner_names))
         OR (grantee = 'flagsmith_loader' AND f.name = ANY (loader_names)) THEN
        EXECUTE format('GRANT EXECUTE ON %s %s TO %I',
                       CASE WHEN f.prokind = 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, f.sig, grantee);
      END IF;
    END LOOP;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_reader') THEN
    GRANT USAGE ON SCHEMA flagsmith, flagsmith_c TO flagsmith_reader;
  END IF;
  FOREACH grantee IN ARRAY ARRAY['flagsmith_tracker', 'flagsmith_planner', 'flagsmith_loader'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = grantee) THEN
      EXECUTE format('GRANT USAGE ON SCHEMA flagsmith, flagsmith_c TO %I', grantee);
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_loader') THEN
    GRANT SELECT ON flagsmith.warnings TO flagsmith_loader;
  END IF;

  -- planner includes reader; loader includes planner and tracker
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_planner')
       AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_reader') THEN
      GRANT flagsmith_reader TO flagsmith_planner;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_loader') THEN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_planner') THEN
        GRANT flagsmith_planner TO flagsmith_loader;
      END IF;
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flagsmith_tracker') THEN
        GRANT flagsmith_tracker TO flagsmith_loader;
      END IF;
    END IF;
  EXCEPTION WHEN insufficient_privilege OR invalid_grant_operation THEN
    RAISE NOTICE 'pgsmith: could not set up role membership (planner > reader, loader > planner, tracker): %', SQLERRM;
  END;
END $$;
