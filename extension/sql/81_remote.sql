-- In-database sync (Supabase): Postgres fetches its own environment documents.
--
--   SELECT vault.create_secret('ser.xxxx', 'flagsmith_production');      -- the server-side key
--   SELECT flagsmith.add_remote_source('production',
--            'https://flagsmith.example.com/api/v1/', 'flagsmith_production');
--   SELECT flagsmith.schedule_sync();                                    -- pg_cron, every 30 s
--
-- Each run fetches the document (http extension, or pg_net), maps it with
-- map_environment_document() and loads it in one transaction. An unchanged body is
-- recognised by its SHA-256 before it is parsed. No conditional GETs: Flagsmith
-- (2.295) caches Last-Modified per worker, so If-Modified-Since can be answered 304
-- for seconds after a change.
--
-- Security:
--   * The server-side key is read from Supabase Vault when a request is made;
--     it is never stored in a pg_flagsmith table.
--   * Only the owner of the extension can add or change a source: a source
--     decides where a key is sent. flagsmith_loader can only run syncs.
--   * Plain http:// URLs are refused unless allow_insecure_http is set (local stacks).
--   * Transport 'http' (the pgsql-http extension) keeps the key and the document
--     in memory. Transport 'pg_net' queues the request, key included, in
--     net.http_request_queue and receives the document in net._http_response,
--     tables Supabase grants to anon and authenticated; pg_flagsmith deletes its
--     response as soon as it reads it, and sync_status() reports roles that can
--     read or write those tables. Prefer 'http' where it is installed (the default).

CREATE TABLE flagsmith.remote_source (
  name               text PRIMARY KEY CHECK (name ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$'),
  api_url            text NOT NULL,                  -- ends in '/', e.g. https://host/api/v1/
  secret_name        text NOT NULL,                  -- Vault secret holding the server-side key
  transport          text NOT NULL CHECK (transport IN ('http', 'pg_net')),
  enabled            boolean NOT NULL DEFAULT true,
  timeout_ms         int NOT NULL DEFAULT 10000 CHECK (timeout_ms BETWEEN 100 AND 120000),
  max_document_bytes bigint NOT NULL DEFAULT 67108864 CHECK (max_document_bytes > 0),
  events_url         text,                           -- the events endpoint (exposure queue)
  env_key            text,                           -- learned from the first document
  -- state
  request_id         bigint,                         -- pg_net: request in flight
  requested_at       timestamptz,
  body_sha256        bytea,
  last_attempt_at    timestamptz,
  last_success_at    timestamptz,
  last_status        int,
  last_outcome       text,
  last_error         text,
  consecutive_failures int NOT NULL DEFAULT 0,
  last_snapshot      bigint,
  events_refused     boolean NOT NULL DEFAULT false, -- the events API refused the key (401/403)
  created_at         timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE flagsmith.remote_source ENABLE ROW LEVEL SECURITY;
-- configuration, not derived data: pg_dump keeps it (the secrets stay in Vault)
SELECT pg_catalog.pg_extension_config_dump('flagsmith.remote_source', '');

-- The schema of an installed extension, or NULL.
CREATE FUNCTION flagsmith._ext_schema(ext text) RETURNS text
LANGUAGE sql STABLE
BEGIN ATOMIC
  SELECT n.nspname::text FROM pg_extension x JOIN pg_namespace n ON n.oid = x.extnamespace WHERE x.extname = ext;
END;

-- Validate a URL for a source: http(s), a host, no credentials, no query or fragment.
CREATE FUNCTION flagsmith._check_url(url text, what text, allow_insecure_http boolean) RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
BEGIN
  IF url IS NULL OR url !~ '^https?://[A-Za-z0-9._~%!$&''()*+,;=:\[\]-]+(/[A-Za-z0-9._~%!$&''()*+,;=:@/-]*)?$'
     OR split_part(split_part(url, '://', 2), '/', 1) ~ '@' THEN
    RAISE EXCEPTION 'pg_flagsmith: % must be an http(s) URL without credentials, query or fragment: %', what, url;
  END IF;
  IF url ~ '^http://' AND NOT allow_insecure_http THEN
    RAISE EXCEPTION 'pg_flagsmith: % uses plain http, which would send the server-side key unencrypted', what
      USING HINT = 'Use https, or pass allow_insecure_http => true for a local stack.';
  END IF;
  RETURN url;
END $$;

-- Configure (or reconfigure) a source. Owner only: not granted to any role.
CREATE FUNCTION flagsmith.add_remote_source(
  name text,
  api_url text,
  secret_name text,
  transport text DEFAULT NULL,
  events_url text DEFAULT NULL,
  timeout_ms int DEFAULT 10000,
  allow_insecure_http boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  url text := api_url;
  ev text;
  tr text := transport;
  found_secret boolean;
BEGIN
  IF url !~ '/$' THEN url := url || '/'; END IF;
  PERFORM flagsmith._check_url(url, 'api_url', allow_insecure_http);
  ev := coalesce(events_url,
                 CASE WHEN split_part(split_part(url, '://', 2), '/', 1) IN ('edge.api.flagsmith.com', 'api.flagsmith.com')
                      THEN 'https://events.api.flagsmith.com/v1/events'
                      ELSE url || 'events' END);
  PERFORM flagsmith._check_url(ev, 'events_url', allow_insecure_http);
  IF tr IS NULL THEN
    tr := CASE WHEN flagsmith._ext_schema('http') IS NOT NULL THEN 'http'
               WHEN flagsmith._ext_schema('pg_net') IS NOT NULL THEN 'pg_net' END;
    IF tr = 'pg_net' THEN
      RAISE NOTICE 'pg_flagsmith: using pg_net; the http extension keeps the key out of shared tables (CREATE EXTENSION http)';
    END IF;
  END IF;
  IF tr IS NULL OR (tr = 'http' AND flagsmith._ext_schema('http') IS NULL)
     OR (tr = 'pg_net' AND flagsmith._ext_schema('pg_net') IS NULL) THEN
    RAISE EXCEPTION 'pg_flagsmith: in-database sync needs the http or pg_net extension'
      USING HINT = 'CREATE EXTENSION http WITH SCHEMA extensions;  (or pg_net)';
  END IF;
  IF to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: in-database sync reads the server-side key from Supabase Vault, which is not installed';
  END IF;
  EXECUTE 'SELECT EXISTS (SELECT 1 FROM vault.secrets WHERE name = $1)' INTO found_secret USING secret_name;
  IF NOT found_secret THEN
    RAISE EXCEPTION 'pg_flagsmith: no Vault secret named %', secret_name
      USING HINT = 'SELECT vault.create_secret(''ser.your-server-side-key'', ''' || secret_name || ''');';
  END IF;
  INSERT INTO flagsmith.remote_source AS r (name, api_url, secret_name, transport, events_url, timeout_ms)
  VALUES (add_remote_source.name, url, add_remote_source.secret_name, tr, ev, add_remote_source.timeout_ms)
  ON CONFLICT ON CONSTRAINT remote_source_pkey DO UPDATE SET
    api_url = excluded.api_url, secret_name = excluded.secret_name, transport = excluded.transport,
    events_url = excluded.events_url, timeout_ms = excluded.timeout_ms, enabled = true,
    -- a different server or key may serve a different environment: start over
    env_key = CASE WHEN r.api_url = excluded.api_url AND r.secret_name = excluded.secret_name THEN r.env_key END,
    body_sha256 = NULL, events_refused = false;
END $$;

CREATE FUNCTION flagsmith.remove_remote_source(name text) RETURNS boolean
LANGUAGE sql VOLATILE
BEGIN ATOMIC
  WITH d AS (DELETE FROM flagsmith.remote_source r WHERE r.name = remove_remote_source.name RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM d);
END;

-- The server-side key of a source, from Vault.
CREATE FUNCTION flagsmith._remote_key(secret text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE k text;
BEGIN
  EXECUTE 'SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = $1' INTO k USING secret;
  IF k IS NULL OR k = '' THEN
    RAISE EXCEPTION 'pg_flagsmith: Vault secret % is missing or empty', secret;
  END IF;
  RETURN k;
END $$;

-- A header of a response (names are case-insensitive).
CREATE FUNCTION flagsmith._header(headers jsonb, name text) RETURNS text
LANGUAGE sql IMMUTABLE
BEGIN ATOMIC
  SELECT h.value FROM jsonb_each_text(headers) h WHERE lower(h.key) = lower(name) LIMIT 1;
END;

-- One HTTP request through the http extension: (status, headers, body), or an error.
CREATE FUNCTION flagsmith._http_call(method text, url text, headers jsonb, body text, timeout_ms int,
                                     OUT status int, OUT resp_headers jsonb, OUT content text)
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE sch text := flagsmith._ext_schema('http');
BEGIN
  IF sch IS NULL THEN RAISE EXCEPTION 'pg_flagsmith: the http extension is not installed'; END IF;
  EXECUTE format('SELECT %I.http_set_curlopt(''CURLOPT_TIMEOUT_MS'', $1)', sch) USING timeout_ms::text;
  BEGIN
    EXECUTE format($q$
      SELECT (r).status,
             (SELECT jsonb_object_agg(h.field, h.value) FROM unnest((r).headers) h),
             (r).content
      FROM (SELECT %1$I.http(ROW($1, $2,
              ARRAY(SELECT ROW(e.key, e.value)::%1$I.http_header FROM jsonb_each_text($3) e),
              CASE WHEN $4 IS NOT NULL THEN 'application/json' END, $4)::%1$I.http_request) AS r) x$q$, sch)
      INTO status, resp_headers, content USING method, url, headers, body;
    EXECUTE format('SELECT %I.http_reset_curlopt()', sch);
  EXCEPTION WHEN OTHERS THEN
    EXECUTE format('SELECT %I.http_reset_curlopt()', sch);
    RAISE;
  END;
END $$;

-- What a source sends with a document request.
CREATE FUNCTION flagsmith._remote_headers(src flagsmith.remote_source) RETURNS jsonb
LANGUAGE sql STABLE
BEGIN ATOMIC
  SELECT jsonb_build_object('X-Environment-Key', flagsmith._remote_key(src.secret_name),
                            'Accept', 'application/json',
                            'User-Agent', 'pg_flagsmith/@@VERSION@@');
END;

-- Record a failed attempt.
CREATE FUNCTION flagsmith._remote_fail(src_name text, status int, err text) RETURNS text
LANGUAGE sql VOLATILE
BEGIN ATOMIC
  UPDATE flagsmith.remote_source r SET
    last_status = status, last_outcome = 'error', last_error = left(err, 1000),
    consecutive_failures = r.consecutive_failures + 1, request_id = NULL, requested_at = NULL
  WHERE r.name = src_name
  RETURNING 'error';
END;

-- Turn a response into a load. Runs in the caller's subtransaction: any error
-- rolls back a partial load, and the caller records it.
CREATE FUNCTION flagsmith._remote_ingest(src_name text, status int, headers jsonb, body text, err text,
                                         OUT outcome text, OUT snapshot_id bigint, OUT detail text)
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  src flagsmith.remote_source;
  sha bytea;
  doc json;
  r record;
BEGIN
  SELECT * INTO src FROM flagsmith.remote_source x WHERE x.name = src_name;
  IF err IS NOT NULL OR status IS NULL THEN
    RAISE EXCEPTION 'request failed: %', coalesce(err, 'no response');
  END IF;
  IF status = 304 THEN
    outcome := 'not_modified';
  ELSIF status = 200 THEN
    IF octet_length(body) > src.max_document_bytes THEN
      RAISE EXCEPTION 'document is % bytes, over max_document_bytes (%)', octet_length(body), src.max_document_bytes;
    END IF;
    sha := sha256(convert_to(body, 'UTF8'));
    IF sha = src.body_sha256 THEN
      outcome := 'unchanged';
    ELSE
      doc := body::json;
      IF src.env_key IS NOT NULL AND (doc ->> 'api_key') IS DISTINCT FROM src.env_key THEN
        RAISE EXCEPTION 'the document is for environment %, but source % serves %', doc ->> 'api_key', src_name, src.env_key
          USING HINT = 'Re-add the source if its key now belongs to another environment.';
      END IF;
      SELECT * INTO r FROM flagsmith.load_document(doc, 'in_db:' || src.transport);
      outcome := r.outcome;
      snapshot_id := r.snapshot_id;
      src.env_key := doc ->> 'api_key';
    END IF;
  ELSE
    RAISE EXCEPTION 'HTTP %: %', status,
      CASE WHEN status IN (401, 403) THEN 'Flagsmith refused the server-side key'
           ELSE left(coalesce(body, ''), 200) END;
  END IF;
  IF outcome IN ('not_modified', 'unchanged') AND src.env_key IS NOT NULL THEN
    UPDATE flagsmith.environment e SET last_checked_at = clock_timestamp() WHERE e.env_key = src.env_key;
  END IF;
  UPDATE flagsmith.remote_source x SET
    env_key = coalesce(src.env_key, x.env_key),
    body_sha256 = CASE WHEN status = 200 THEN sha ELSE x.body_sha256 END,
    last_snapshot = coalesce(_remote_ingest.snapshot_id, x.last_snapshot),
    last_status = status, last_outcome = outcome, last_error = NULL, consecutive_failures = 0,
    last_success_at = clock_timestamp(), request_id = NULL, requested_at = NULL
  WHERE x.name = src_name;
  detail := CASE WHEN outcome IN ('loaded', 'reused', 'pinned') THEN 'snapshot ' || snapshot_id END;
END $$;

-- Collect pg_net responses that have arrived. Returns how many requests are still pending.
CREATE FUNCTION flagsmith._sync_collect(OUT pending int, OUT results jsonb)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  src flagsmith.remote_source;
  st int; hd jsonb; body text; timed_out boolean; emsg text; got boolean;
  res record;
BEGIN
  pending := 0;
  results := '[]'::jsonb;
  FOR src IN SELECT * FROM flagsmith.remote_source r WHERE r.request_id IS NOT NULL ORDER BY r.name FOR UPDATE SKIP LOCKED LOOP
    EXECUTE 'SELECT true, status_code, headers, content, timed_out, error_msg FROM net._http_response WHERE id = $1'
      INTO got, st, hd, body, timed_out, emsg USING src.request_id;
    IF got IS NULL THEN
      IF src.requested_at < clock_timestamp() - make_interval(secs => src.timeout_ms / 1000.0 + 60) THEN
        PERFORM flagsmith._remote_fail(src.name, NULL, 'no response from the pg_net worker (is it running?)');
        results := results || jsonb_build_object('source', src.name, 'outcome', 'error', 'detail', 'no response');
      ELSE
        pending := pending + 1;
      END IF;
      CONTINUE;
    END IF;
    -- the document (and its environment's identity overrides) leaves the shared table now
    EXECUTE 'DELETE FROM net._http_response WHERE id = $1' USING src.request_id;
    BEGIN
      res := flagsmith._remote_ingest(src.name, st, hd, body,
                                      CASE WHEN timed_out THEN 'timed out' ELSE emsg END);
      results := results || jsonb_build_object('source', src.name, 'outcome', res.outcome,
                                               'snapshot_id', res.snapshot_id, 'detail', res.detail);
    EXCEPTION WHEN OTHERS THEN
      PERFORM flagsmith._remote_fail(src.name, st, SQLERRM);
      results := results || jsonb_build_object('source', src.name, 'outcome', 'error', 'detail', SQLERRM);
    END;
  END LOOP;
END $$;

-- One sync pass: collect pg_net responses, then fetch every enabled source
-- (synchronously over http; pg_net requests are sent when this transaction
-- commits and collected by the next pass, or by sync_run()).
CREATE FUNCTION flagsmith.sync_tick()
RETURNS TABLE (source text, outcome text, snapshot_id bigint, detail text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  src flagsmith.remote_source;
  c record;
  resp record;
  res record;
  rid bigint;
  j jsonb;
BEGIN
  -- one pass at a time (overlapping cron runs simply skip)
  IF NOT pg_try_advisory_xact_lock(hashtextextended('flagsmith:sync_tick', 0)) THEN
    RETURN;
  END IF;
  c := flagsmith._sync_collect();
  FOR j IN SELECT * FROM jsonb_array_elements(c.results) LOOP
    source := j ->> 'source'; outcome := j ->> 'outcome';
    snapshot_id := (j ->> 'snapshot_id')::bigint; detail := j ->> 'detail';
    RETURN NEXT;
  END LOOP;
  FOR src IN SELECT * FROM flagsmith.remote_source r WHERE r.enabled AND r.request_id IS NULL
             ORDER BY r.name FOR UPDATE SKIP LOCKED LOOP
    source := src.name; snapshot_id := NULL; detail := NULL;
    UPDATE flagsmith.remote_source r SET last_attempt_at = clock_timestamp() WHERE r.name = src.name;
    BEGIN
      IF src.transport = 'http' THEN
        resp := flagsmith._http_call('GET', src.api_url || 'environment-document/', flagsmith._remote_headers(src),
                                     NULL, src.timeout_ms);
        res := flagsmith._remote_ingest(src.name, resp.status, resp.resp_headers, resp.content, NULL);
        outcome := res.outcome; snapshot_id := res.snapshot_id; detail := res.detail;
      ELSE
        EXECUTE 'SELECT net.http_get($1, ''{}''::jsonb, $2, $3)' INTO rid
          USING src.api_url || 'environment-document/', flagsmith._remote_headers(src), src.timeout_ms;
        UPDATE flagsmith.remote_source r SET request_id = rid, requested_at = clock_timestamp() WHERE r.name = src.name;
        outcome := 'requested'; detail := 'pg_net request ' || rid;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      PERFORM flagsmith._remote_fail(src.name, NULL, SQLERRM);
      outcome := 'error'; detail := SQLERRM;
    END;
    RETURN NEXT;
  END LOOP;
END $$;

-- Wait for the pg_net requests of this pass and load what arrives.
CREATE FUNCTION flagsmith._sync_await()
RETURNS TABLE (source text, outcome text, snapshot_id bigint, detail text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  deadline timestamptz := clock_timestamp()
    + make_interval(secs => coalesce((SELECT max(r.timeout_ms) FROM flagsmith.remote_source r
                                      WHERE r.request_id IS NOT NULL), 0) / 1000.0 + 5);
  c record;
  j jsonb;
BEGIN
  -- the requests were committed just before: have the pg_net worker send them now
  -- rather than at its next poll (net.wake() exists in pg_net 0.13 and later)
  IF to_regprocedure('net.wake()') IS NOT NULL
     AND EXISTS (SELECT 1 FROM flagsmith.remote_source r WHERE r.request_id IS NOT NULL) THEN
    EXECUTE 'SELECT net.wake()';
  END IF;
  LOOP
    c := flagsmith._sync_collect();
    FOR j IN SELECT * FROM jsonb_array_elements(c.results) LOOP
      source := j ->> 'source'; outcome := j ->> 'outcome';
      snapshot_id := (j ->> 'snapshot_id')::bigint; detail := j ->> 'detail';
      RETURN NEXT;
    END LOOP;
    EXIT WHEN c.pending = 0 OR clock_timestamp() > deadline;
    PERFORM pg_sleep(0.02);
  END LOOP;
END $$;

-- The cron entry point: a pass, then (pg_net) commit so the requests go out and
-- wait for their responses, so a change is loaded in the same run.
-- A procedure that commits cannot carry SET or SECURITY DEFINER; its body only
-- calls schema-qualified pg_flagsmith functions, so search_path cannot redirect it.
CREATE PROCEDURE flagsmith.sync_run()
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM flagsmith.sync_tick();
  COMMIT;
  PERFORM flagsmith._sync_await();
END $$;

-- Schedule syncing with pg_cron (as the calling role). Intervals under a minute
-- use pg_cron's seconds syntax.
CREATE FUNCTION flagsmith.schedule_sync(every interval DEFAULT '30 seconds') RETURNS bigint
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE secs int := extract(epoch FROM every)::int; sched text; jid bigint;
BEGIN
  IF flagsmith._ext_schema('pg_cron') IS NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: schedule_sync needs pg_cron' USING HINT = 'CREATE EXTENSION pg_cron;';
  END IF;
  sched := CASE WHEN secs BETWEEN 1 AND 59 THEN secs || ' seconds'
                WHEN secs >= 60 AND secs % 60 = 0 AND secs / 60 <= 59 THEN format('*/%s * * * *', secs / 60)
           END;
  IF sched IS NULL THEN
    RAISE EXCEPTION 'pg_flagsmith: every must be 1-59 seconds or 1-59 whole minutes, not %', every;
  END IF;
  EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO jid
    USING 'pg_flagsmith_sync', sched, 'CALL flagsmith.sync_run()';
  RETURN jid;
END $$;

CREATE FUNCTION flagsmith.unschedule_sync() RETURNS boolean
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE ok boolean;
BEGIN
  IF flagsmith._ext_schema('pg_cron') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = $1' INTO ok USING 'pg_flagsmith_sync';
  RETURN coalesce(ok, false);
END $$;

-- Roles other than superusers and the owner that can read or write pg_net's tables.
CREATE FUNCTION flagsmith._pg_net_exposure() RETURNS text[]
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE r text[];
BEGIN
  IF to_regclass('net._http_response') IS NULL THEN RETURN NULL; END IF;
  SELECT array_agg(DISTINCT x.rolname ORDER BY x.rolname) INTO r
  FROM (SELECT a.rolname FROM pg_roles a
        CROSS JOIN unnest(ARRAY['net._http_response', 'net.http_request_queue']) t
        WHERE NOT a.rolsuper AND a.rolname NOT LIKE 'pg\_%' AND a.oid <> (SELECT c.relowner FROM pg_class c WHERE c.oid = t::regclass)
          AND a.rolname <> current_user
          AND (has_table_privilege(a.oid, t::regclass, 'SELECT') OR has_table_privilege(a.oid, t::regclass, 'UPDATE'))) x;
  RETURN r;
END $$;

-- One row per source: what it does and how it is doing.
CREATE FUNCTION flagsmith.sync_status()
RETURNS TABLE (name text, env_key text, transport text, enabled boolean, api_url text,
               last_success_at timestamptz, last_outcome text, last_status int, last_error text,
               consecutive_failures int, last_snapshot bigint, in_flight boolean, security_note text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
  SELECT r.name, r.env_key, r.transport, r.enabled, r.api_url,
         r.last_success_at, r.last_outcome, r.last_status, r.last_error,
         r.consecutive_failures, r.last_snapshot, r.request_id IS NOT NULL,
         CASE WHEN r.transport = 'pg_net' AND cardinality(flagsmith._pg_net_exposure()) > 0
              THEN 'roles ' || array_to_string(flagsmith._pg_net_exposure(), ', ')
                   || ' can read pg_net''s request queue (it holds the server-side key while a request is queued)'
                   || ' and its responses; use transport ''http'', or revoke their access to schema net'
              WHEN r.api_url ~ '^http://' THEN 'plain http: the server-side key travels unencrypted' END
  FROM flagsmith.remote_source r
  ORDER BY r.name
$$;
