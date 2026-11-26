-- The exposure queue: experiment exposures and custom events recorded in SQL,
-- delivered to Flagsmith's events API in batches.
--
--   SELECT flagsmith.track_exposure('search_ranking', 'user-42', 'boosted');
--   SELECT flagsmith.track_event('add_to_cart', 'user-42');
--   SELECT flagsmith.track_variant('search_ranking', 'user-42', traits);  -- evaluate + record
--
-- Evaluation stays read-only: nothing here runs inside flags(), variant() and
-- friends, which keep working on replicas. Recording is an explicit write.
--
-- Delivery matches the Python SDK's event processor: the same event JSON, POSTed
-- as {"events": [...]} to <events_url> with the server-side key; identical
-- exposures (feature, identifier, value) in one batch are sent once; 408, 429 and
-- 5xx are retried with backoff; 401/403 stops delivery for that environment
-- (batches are kept); other 4xx drop the batch (kept as 'rejected' for a week).
-- Senders: the database itself (events_tick(), over http or pg_net, for
-- environments with a remote source) or `pgsmith events` (events_claim()).
-- Both can run at once: claims use SKIP LOCKED.

CREATE TABLE flagsmith.settings (
  id                  boolean PRIMARY KEY DEFAULT true CHECK (id),
  events_max_queued   bigint NOT NULL DEFAULT 1000000 CHECK (events_max_queued >= 1000),
  events_batch_size   int NOT NULL DEFAULT 1000 CHECK (events_batch_size BETWEEN 1 AND 10000),
  events_max_batches  int NOT NULL DEFAULT 20 CHECK (events_max_batches >= 1),
  events_max_attempts int NOT NULL DEFAULT 5 CHECK (events_max_attempts >= 1)
);
ALTER TABLE flagsmith.settings ENABLE ROW LEVEL SECURITY;
-- Change with: INSERT INTO flagsmith.settings (events_max_queued) VALUES (5000000)
--              ON CONFLICT (id) DO UPDATE SET events_max_queued = excluded.events_max_queued;
SELECT pg_catalog.pg_extension_config_dump('flagsmith.settings', '');

-- The settings in force (the defaults until a row is written).
CREATE FUNCTION flagsmith._settings() RETURNS flagsmith.settings
LANGUAGE sql STABLE
BEGIN ATOMIC
  SELECT x.s FROM (SELECT s, 0 FROM flagsmith.settings s
                   UNION ALL SELECT ROW(true, 1000000, 1000, 20, 5)::flagsmith.settings, 1) x(s, o)
  ORDER BY x.o LIMIT 1;
END;

-- Append-only: a bigint identity, no secondary index, aggressive vacuum (rows
-- are deleted in id order as they are sent).
CREATE TABLE flagsmith.event_queue (
  event_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  env_key      text NOT NULL,
  event        text NOT NULL,
  feature_name text,
  identifier   text,
  value        text,
  traits       jsonb,
  metadata     jsonb,
  ts_ms        bigint NOT NULL
) WITH (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 10000,
        autovacuum_vacuum_insert_scale_factor = 0, autovacuum_vacuum_insert_threshold = 100000);
ALTER TABLE flagsmith.event_queue ENABLE ROW LEVEL SECURITY;

-- Batches sent over pg_net (in flight), waiting for a retry, or given up on.
CREATE TABLE flagsmith.event_batch (
  batch_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  env_key         text NOT NULL,
  source          text,
  n_events        int NOT NULL,
  payload         jsonb NOT NULL,
  state           text NOT NULL CHECK (state IN ('in_flight', 'retry', 'failed', 'rejected', 'refused')),
  request_id      bigint,
  attempts        int NOT NULL DEFAULT 0,
  next_attempt_at timestamptz,
  last_status     int,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX event_batch_state ON flagsmith.event_batch (state, next_attempt_at);
ALTER TABLE flagsmith.event_batch ENABLE ROW LEVEL SECURITY;

-- Counters, updated once per batch (never per event).
CREATE TABLE flagsmith.event_stats (
  env_key           text PRIMARY KEY,
  delivered         bigint NOT NULL DEFAULT 0,
  deduplicated      bigint NOT NULL DEFAULT 0,
  rejected          bigint NOT NULL DEFAULT 0,
  dropped_overflow  bigint NOT NULL DEFAULT 0,
  last_delivered_at timestamptz
);
ALTER TABLE flagsmith.event_stats ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION flagsmith._event_stat(ek text, delivered bigint, deduplicated bigint, rejected bigint, dropped bigint)
RETURNS void
LANGUAGE sql VOLATILE
BEGIN ATOMIC
  INSERT INTO flagsmith.event_stats AS s (env_key, delivered, deduplicated, rejected, dropped_overflow, last_delivered_at)
  VALUES (ek, delivered, deduplicated, rejected, dropped, CASE WHEN delivered > 0 THEN clock_timestamp() END)
  ON CONFLICT (env_key) DO UPDATE SET
    delivered = s.delivered + excluded.delivered,
    deduplicated = s.deduplicated + excluded.deduplicated,
    rejected = s.rejected + excluded.rejected,
    dropped_overflow = s.dropped_overflow + excluded.dropped_overflow,
    last_delivered_at = coalesce(excluded.last_delivered_at, s.last_delivered_at);
END;

-- The environment key events are recorded under: the default environment, or an
-- environment's key, alias or name.
CREATE FUNCTION flagsmith._event_env(env text) RETURNS text
LANGUAGE sql STABLE
BEGIN ATOMIC
  SELECT e.env_key FROM flagsmith.environment e
  WHERE CASE WHEN env IS NULL THEN e.is_default ELSE e.env_key = env OR e.alias = env OR e.name = env END
  ORDER BY (e.env_key = env) DESC NULLS LAST LIMIT 1;
END;

-- Enqueue one event; every 1024th id, enforce events_max_queued by dropping the
-- oldest events (the SDK drops the oldest when its buffer is full).
CREATE FUNCTION flagsmith._enqueue(event text, feature text, identifier text, value text,
                                   traits jsonb, metadata jsonb, env text)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE ek text; eid bigint; cap bigint; lo bigint; d record; n bigint := 0;
BEGIN
  ek := flagsmith._event_env(env);
  IF ek IS NULL THEN
    RAISE EXCEPTION 'pgsmith: unknown environment %', coalesce(env, '(no default environment)');
  END IF;
  IF event IS NULL OR length(event) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'pgsmith: event names are 1 to 200 characters';
  END IF;
  IF length(feature) > 2000 OR length(identifier) > 2000 OR length(value) > 10000 THEN
    RAISE EXCEPTION 'pgsmith: feature and identifier are at most 2000 characters, value 10000';
  END IF;
  IF (traits IS NOT NULL AND (jsonb_typeof(traits) <> 'object' OR octet_length(traits::text) > 65536))
     OR (metadata IS NOT NULL AND (jsonb_typeof(metadata) <> 'object' OR octet_length(metadata::text) > 65536)) THEN
    RAISE EXCEPTION 'pgsmith: traits and metadata are JSON objects of at most 64 kB';
  END IF;
  INSERT INTO flagsmith.event_queue (env_key, event, feature_name, identifier, value, traits, metadata, ts_ms)
  VALUES (ek, event, feature, identifier, value, traits, metadata,
          (extract(epoch FROM clock_timestamp()) * 1000)::bigint)
  RETURNING event_id INTO eid;
  IF eid % 1024 = 0 THEN
    cap := (flagsmith._settings()).events_max_queued;
    SELECT min(q.event_id) INTO lo FROM flagsmith.event_queue q;
    IF eid - lo > cap THEN
      -- MATERIALIZED: the pick runs once (an IN (... LIMIT ... SKIP LOCKED) subquery can
      -- be rescanned, and pick more rows than its LIMIT)
      FOR d IN
        WITH pick AS MATERIALIZED (
          SELECT q2.event_id FROM flagsmith.event_queue q2 WHERE q2.event_id <= eid - cap
          ORDER BY q2.event_id LIMIT 100000 FOR UPDATE SKIP LOCKED),
        gone AS (
          DELETE FROM flagsmith.event_queue q USING pick WHERE q.event_id = pick.event_id
          RETURNING q.env_key)
        SELECT g.env_key, count(*) AS cnt FROM gone g GROUP BY g.env_key
      LOOP
        PERFORM flagsmith._event_stat(d.env_key, 0, 0, 0, d.cnt);
        n := n + d.cnt;
      END LOOP;
      IF n > 0 THEN
        RAISE WARNING 'pgsmith: event queue over events_max_queued (%): dropped the % oldest events', cap, n;
      END IF;
    END IF;
  END IF;
END $$;

-- Record that identifier saw value (the variant) of feature: Flagsmith
-- Experimentation counts these. value is sent as text, as the SDK sends str(value).
CREATE FUNCTION flagsmith.track_exposure(feature text, identifier text, value text DEFAULT NULL,
                                         traits jsonb DEFAULT NULL, metadata jsonb DEFAULT NULL,
                                         env text DEFAULT NULL)
RETURNS void
LANGUAGE sql VOLATILE
BEGIN ATOMIC
  SELECT flagsmith._enqueue('$flag_exposure', feature, identifier, value, traits, metadata, env);
END;

-- A custom event (a conversion: 'add_to_cart', 'search_latency_ms' with a value, ...).
CREATE FUNCTION flagsmith.track_event(event text, identifier text DEFAULT NULL, value text DEFAULT NULL,
                                      traits jsonb DEFAULT NULL, metadata jsonb DEFAULT NULL,
                                      env text DEFAULT NULL)
RETURNS void
LANGUAGE sql VOLATILE
BEGIN ATOMIC
  SELECT flagsmith._enqueue(event, NULL, identifier, value, traits, metadata, env);
END;

-- Evaluate a feature's variant for an identity and record the exposure, in one
-- call: SELECT flagsmith.track_variant('search_ranking', $1, $2). A write: call it
-- on the primary (on a replica it raises instead of silently not recording).
CREATE FUNCTION flagsmith.track_variant(feature text, identifier text, traits jsonb DEFAULT NULL,
                                        env text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE v text;
BEGIN
  v := flagsmith.variant(feature, identifier, traits, env);
  PERFORM flagsmith._enqueue('$flag_exposure', feature, identifier, v, NULL, NULL, env);
  RETURN v;
END $$;

-- Claim up to max_events of an environment's oldest events, deleting them, and
-- return them as an events API payload. Exposures repeated within the batch are
-- sent once. Run it in a transaction and roll back if the payload is not delivered.
CREATE FUNCTION flagsmith.events_claim(env_key text, max_events int DEFAULT 1000,
                                       OUT n_claimed int, OUT n_events int, OUT payload text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
BEGIN
  -- MATERIALIZED: the pick runs exactly once (as a rescanned IN subquery, LIMIT with
  -- SKIP LOCKED could pick more rows than asked for)
  WITH pick AS MATERIALIZED (
    SELECT q2.event_id FROM flagsmith.event_queue q2 WHERE q2.env_key = events_claim.env_key
    ORDER BY q2.event_id LIMIT greatest(least(max_events, 10000), 1) FOR UPDATE SKIP LOCKED),
  claimed AS (
    DELETE FROM flagsmith.event_queue q USING pick WHERE q.event_id = pick.event_id
    RETURNING q.*),
  ranked AS (
    SELECT c.*, CASE WHEN c.event = '$flag_exposure'
                     THEN row_number() OVER (PARTITION BY c.event, c.feature_name, c.identifier, c.value
                                             ORDER BY c.event_id) ELSE 1 END AS rn
    FROM claimed c)
  SELECT count(*)::int,
         count(*) FILTER (WHERE r.rn = 1)::int,
         '{"events": ' || coalesce(jsonb_agg(jsonb_build_object(
             'event', r.event,
             'feature_name', r.feature_name,
             'identifier', r.identifier,
             'value', r.value,
             'traits', CASE WHEN r.traits IS NULL OR r.traits = '{}'::jsonb THEN NULL ELSE r.traits END,
             'metadata', coalesce(r.metadata, '{}'::jsonb) || jsonb_build_object('sdk_version', 'pgsmith/@@VERSION@@'),
             'timestamp', r.ts_ms) ORDER BY r.event_id) FILTER (WHERE r.rn = 1), '[]'::jsonb)::text || '}'
  INTO n_claimed, n_events, payload
  FROM ranked r;
  IF n_claimed = 0 THEN payload := NULL; END IF;
END $$;

-- Count a batch's outcome (the CLI sender calls this before it commits a claim).
--   outcome: 'delivered' or 'rejected'
CREATE FUNCTION flagsmith.events_record(env_key text, outcome text, n_claimed int, n_events int)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
BEGIN
  IF outcome = 'delivered' THEN
    PERFORM flagsmith._event_stat(env_key, n_events, n_claimed - n_events, 0, 0);
  ELSIF outcome = 'rejected' THEN
    PERFORM flagsmith._event_stat(env_key, 0, n_claimed - n_events, n_events, 0);
  ELSE
    RAISE EXCEPTION 'pgsmith: outcome must be delivered or rejected';
  END IF;
END $$;

-- The environments with queued events, oldest first.
CREATE FUNCTION flagsmith.events_pending()
RETURNS TABLE (env_key text, queued bigint, oldest timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT q.env_key, count(*), to_timestamp(min(q.ts_ms) / 1000.0)
  FROM flagsmith.event_queue q GROUP BY q.env_key ORDER BY min(q.event_id)
$$;

-- What an HTTP status means for a batch (the SDK's rules).
CREATE FUNCTION flagsmith._event_outcome(status int) RETURNS text
LANGUAGE sql IMMUTABLE
BEGIN ATOMIC
  SELECT CASE WHEN status IS NULL THEN 'retry'
              WHEN status < 400 THEN 'delivered'
              WHEN status IN (401, 403) THEN 'refused'
              WHEN status IN (408, 429, 500, 502, 503, 504) THEN 'retry'
              ELSE 'rejected' END;
END;

-- Settle a batch with a known status: delete it when delivered, else retry or keep.
CREATE FUNCTION flagsmith._event_settle(b flagsmith.event_batch, status int, err text) RETURNS text
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE o text := flagsmith._event_outcome(status); maxa int;
BEGIN
  maxa := (flagsmith._settings()).events_max_attempts;
  IF o = 'delivered' THEN
    DELETE FROM flagsmith.event_batch x WHERE x.batch_id = b.batch_id;
    PERFORM flagsmith._event_stat(b.env_key, b.n_events, 0, 0, 0);
  ELSIF o = 'refused' THEN
    UPDATE flagsmith.event_batch x SET state = 'refused', request_id = NULL, last_status = status, last_error = err
    WHERE x.batch_id = b.batch_id;
    UPDATE flagsmith.remote_source r SET events_refused = true WHERE r.name = b.source;
  ELSIF o = 'rejected' THEN
    UPDATE flagsmith.event_batch x SET state = 'rejected', request_id = NULL, last_status = status, last_error = err
    WHERE x.batch_id = b.batch_id;
    PERFORM flagsmith._event_stat(b.env_key, 0, 0, b.n_events, 0);
  ELSIF b.attempts >= maxa THEN
    UPDATE flagsmith.event_batch x SET state = 'failed', request_id = NULL, last_status = status, last_error = err
    WHERE x.batch_id = b.batch_id;
  ELSE
    -- full jitter backoff: up to 2^attempts seconds, at most 5 minutes
    UPDATE flagsmith.event_batch x SET state = 'retry', request_id = NULL, last_status = status, last_error = err,
      next_attempt_at = clock_timestamp() + make_interval(secs => random() * least(power(2, b.attempts), 300))
    WHERE x.batch_id = b.batch_id;
  END IF;
  RETURN o;
END $$;

-- Send a batch over the source's transport. http settles at once; pg_net leaves it in flight.
CREATE FUNCTION flagsmith._event_send(b flagsmith.event_batch) RETURNS text
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE src flagsmith.remote_source; hdr jsonb; resp record; rid bigint;
BEGIN
  SELECT * INTO src FROM flagsmith.remote_source r WHERE r.name = b.source;
  hdr := jsonb_build_object('X-Environment-Key', flagsmith._remote_key(src.secret_name),
                            'Flagsmith-SDK-User-Agent', 'pgsmith/@@VERSION@@');
  UPDATE flagsmith.event_batch x SET attempts = x.attempts + 1 WHERE x.batch_id = b.batch_id;
  b.attempts := b.attempts + 1;
  IF src.transport = 'http' THEN
    BEGIN
      resp := flagsmith._http_call('POST', src.events_url, hdr, b.payload::text, least(src.timeout_ms, 10000));
    EXCEPTION WHEN OTHERS THEN
      RETURN flagsmith._event_settle(b, NULL, SQLERRM);
    END;
    RETURN flagsmith._event_settle(b, resp.status, CASE WHEN resp.status >= 400 THEN left(resp.content, 500) END);
  END IF;
  EXECUTE 'SELECT net.http_post($1, $2, ''{}''::jsonb, $3, $4)' INTO rid
    USING src.events_url, b.payload, hdr || '{"Content-Type": "application/json"}'::jsonb, least(src.timeout_ms, 10000);
  UPDATE flagsmith.event_batch x SET state = 'in_flight', request_id = rid WHERE x.batch_id = b.batch_id;
  RETURN 'in_flight';
END $$;

-- One delivery pass for environments with a remote source: settle pg_net batches
-- whose responses arrived, resend due retries, then send new batches.
CREATE FUNCTION flagsmith.events_tick()
RETURNS TABLE (env_key text, batches int, events int, outcome text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  b flagsmith.event_batch;
  src flagsmith.remote_source;
  st int; emsg text; tout boolean; got boolean;
  cl record;
  o text;
  k int;
  cfg flagsmith.settings;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('flagsmith:events_tick', 0)) THEN
    RETURN;
  END IF;
  cfg := flagsmith._settings();
  -- 1. pg_net responses
  FOR b IN SELECT * FROM flagsmith.event_batch x WHERE x.state = 'in_flight' ORDER BY x.batch_id FOR UPDATE SKIP LOCKED LOOP
    got := NULL;
    EXECUTE 'SELECT true, status_code, timed_out, error_msg FROM net._http_response WHERE id = $1'
      INTO got, st, tout, emsg USING b.request_id;
    IF got THEN
      EXECUTE 'DELETE FROM net._http_response WHERE id = $1' USING b.request_id;
      o := flagsmith._event_settle(b, CASE WHEN tout OR emsg IS NOT NULL THEN NULL ELSE st END,
                                   CASE WHEN tout THEN 'timed out' ELSE emsg END);
      env_key := b.env_key; batches := 1; events := b.n_events; outcome := o; RETURN NEXT;
    ELSIF b.created_at < clock_timestamp() - interval '10 minutes' THEN
      o := flagsmith._event_settle(b, NULL, 'no response from the pg_net worker');
    END IF;
  END LOOP;
  -- 2. due retries
  FOR b IN SELECT * FROM flagsmith.event_batch x WHERE x.state = 'retry' AND x.next_attempt_at <= clock_timestamp()
           ORDER BY x.batch_id FOR UPDATE SKIP LOCKED LOOP
    o := flagsmith._event_send(b);
    env_key := b.env_key; batches := 1; events := b.n_events; outcome := 'retried: ' || o; RETURN NEXT;
  END LOOP;
  -- 3. new batches, for environments a remote source can deliver to
  FOR src IN SELECT DISTINCT ON (r.env_key) r.* FROM flagsmith.remote_source r
             WHERE r.enabled AND r.env_key IS NOT NULL AND NOT r.events_refused AND r.events_url IS NOT NULL
             ORDER BY r.env_key, r.name LOOP
    k := 0;
    WHILE k < cfg.events_max_batches LOOP
      cl := flagsmith.events_claim(src.env_key, cfg.events_batch_size);
      EXIT WHEN cl.n_claimed = 0;
      IF cl.n_claimed > cl.n_events THEN
        PERFORM flagsmith._event_stat(src.env_key, 0, cl.n_claimed - cl.n_events, 0, 0);
      END IF;
      INSERT INTO flagsmith.event_batch (env_key, source, n_events, payload, state)
      VALUES (src.env_key, src.name, cl.n_events, cl.payload::jsonb, 'in_flight')
      RETURNING * INTO b;
      o := flagsmith._event_send(b);
      env_key := src.env_key; batches := 1; events := cl.n_events; outcome := o; RETURN NEXT;
      k := k + 1;
      EXIT WHEN o IN ('refused', 'retry');   -- the endpoint is struggling: stop for now
    END LOOP;
  END LOOP;
END $$;

-- Schedule event delivery with pg_cron (as the calling role).
CREATE FUNCTION flagsmith.schedule_events(every interval DEFAULT '10 seconds') RETURNS bigint
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE secs int := extract(epoch FROM every)::int; sched text; jid bigint;
BEGIN
  IF flagsmith._ext_schema('pg_cron') IS NULL THEN
    RAISE EXCEPTION 'pgsmith: schedule_events needs pg_cron' USING HINT = 'CREATE EXTENSION pg_cron;';
  END IF;
  sched := CASE WHEN secs BETWEEN 1 AND 59 THEN secs || ' seconds'
                WHEN secs >= 60 AND secs % 60 = 0 AND secs / 60 <= 59 THEN format('*/%s * * * *', secs / 60) END;
  IF sched IS NULL THEN
    RAISE EXCEPTION 'pgsmith: every must be 1-59 seconds or 1-59 whole minutes, not %', every;
  END IF;
  EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO jid
    USING 'pgsmith_events', sched, 'SELECT count(*) FROM flagsmith.events_tick()';
  RETURN jid;
END $$;

CREATE FUNCTION flagsmith.unschedule_events() RETURNS boolean
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE ok boolean;
BEGIN
  IF flagsmith._ext_schema('pg_cron') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = $1' INTO ok USING 'pgsmith_events';
  RETURN coalesce(ok, false);
END $$;

-- Per environment: queue depth, age, batches and counters.
CREATE FUNCTION flagsmith.event_status()
RETURNS TABLE (env_key text, queued bigint, oldest_age interval, in_flight int, retrying int,
               failed int, rejected_batches int, refused int, delivered bigint, deduplicated bigint,
               rejected bigint, dropped_overflow bigint, last_delivered_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  WITH envs AS (SELECT q.env_key FROM flagsmith.event_queue q
                UNION SELECT b.env_key FROM flagsmith.event_batch b
                UNION SELECT s.env_key FROM flagsmith.event_stats s)
  SELECT e.env_key,
         (SELECT count(*) FROM flagsmith.event_queue q WHERE q.env_key = e.env_key),
         clock_timestamp() - (SELECT to_timestamp(min(q.ts_ms) / 1000.0) FROM flagsmith.event_queue q WHERE q.env_key = e.env_key),
         (SELECT count(*)::int FROM flagsmith.event_batch b WHERE b.env_key = e.env_key AND b.state = 'in_flight'),
         (SELECT count(*)::int FROM flagsmith.event_batch b WHERE b.env_key = e.env_key AND b.state = 'retry'),
         (SELECT count(*)::int FROM flagsmith.event_batch b WHERE b.env_key = e.env_key AND b.state = 'failed'),
         (SELECT count(*)::int FROM flagsmith.event_batch b WHERE b.env_key = e.env_key AND b.state = 'rejected'),
         (SELECT count(*)::int FROM flagsmith.event_batch b WHERE b.env_key = e.env_key AND b.state = 'refused'),
         coalesce(s.delivered, 0), coalesce(s.deduplicated, 0), coalesce(s.rejected, 0),
         coalesce(s.dropped_overflow, 0), s.last_delivered_at
  FROM envs e LEFT JOIN flagsmith.event_stats s ON s.env_key = e.env_key
  ORDER BY e.env_key
$$;

-- Requeue failed/refused batches after fixing the cause (a key, an outage).
CREATE FUNCTION flagsmith.events_retry_failed(env text DEFAULT NULL) RETURNS int
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE n int;
BEGIN
  UPDATE flagsmith.remote_source r SET events_refused = false
  WHERE env IS NULL OR r.env_key = env OR r.name = env;
  UPDATE flagsmith.event_batch b SET state = 'retry', attempts = 0, next_attempt_at = clock_timestamp()
  WHERE b.state IN ('failed', 'refused') AND (env IS NULL OR b.env_key = env);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
