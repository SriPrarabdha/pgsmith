-- pg_flagsmith: Flagsmith feature flag evaluation inside Postgres.
--
-- Parity contract: for the same EvaluationContext, every evaluation function
-- returns what flagsmith-flag-engine (Python, the reference implementation)
-- returns from get_evaluation_result(context).
--
-- This file is pure SQL and PL/pgSQL so that it installs as a Trusted Language
-- Extension (pg_tle) on Supabase and Amazon RDS, and as a plain extension on any
-- other PostgreSQL >= 14.

DO $$
BEGIN
  IF current_setting('server_version_num')::int < 140000 THEN
    RAISE EXCEPTION 'pg_flagsmith requires PostgreSQL 14 or later';
  END IF;
  IF getdatabaseencoding() <> 'UTF8' THEN
    RAISE EXCEPTION 'pg_flagsmith requires a UTF8 database (Flagsmith hashes UTF-8 bytes)';
  END IF;
END $$;

CREATE SCHEMA flagsmith;
COMMENT ON SCHEMA flagsmith IS 'pg_flagsmith: Flagsmith flag evaluation (read-only replica of Flagsmith configuration)';
CREATE SCHEMA flagsmith_c;
COMMENT ON SCHEMA flagsmith_c IS 'pg_flagsmith: generated per-snapshot evaluation functions (compiled tier)';

REVOKE ALL ON SCHEMA flagsmith FROM PUBLIC;
REVOKE ALL ON SCHEMA flagsmith_c FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- One evaluated flag. value is the flag value as JSON (string, number, bool or null).
CREATE TYPE flagsmith.flag_result AS (
  feature  text,
  enabled  boolean,
  value    jsonb,
  variant  text,
  reason   text,
  metadata jsonb
);

CREATE TYPE flagsmith.segment_result AS (
  name     text,
  metadata jsonb
);

-- A context value after Python's map_any_value_to_context_value():
--   k = 'n' None, 'b' bool, 'i' int, 'f' float, 's' str
CREATE TYPE flagsmith.ctxval AS (
  k "char",
  s text,
  n numeric,
  f float8,
  b boolean
);

-- A parsed SemVer 2.0 version (python-semver 3 semantics).
CREATE TYPE flagsmith.semver AS (
  major numeric,
  minor numeric,
  patch numeric,
  pre   text,     -- NULL when absent
  build text      -- NULL when absent
);

-- ---------------------------------------------------------------------------
-- Configuration replica
-- ---------------------------------------------------------------------------

-- One row per Flagsmith environment mirrored into this database.
CREATE TABLE flagsmith.environment (
  env_key            text PRIMARY KEY,               -- the client-side environment key
  name               text NOT NULL,
  alias              text UNIQUE
                     CHECK (alias ~ '^[a-z_][a-z0-9_]{0,39}$'),
  is_default         boolean NOT NULL DEFAULT false,
  current_snapshot   bigint,                        -- the single pointer a load flips
  pinned             boolean NOT NULL DEFAULT false, -- emergency brake: sync loads do not flip
  regex_policy       text NOT NULL DEFAULT 'reject'
                     CHECK (regex_policy IN ('reject', 'false', 'approximate')),
  compile            boolean NOT NULL DEFAULT true,
  keep_snapshots     int NOT NULL DEFAULT 50 CHECK (keep_snapshots >= 2),
  gc_grace           interval NOT NULL DEFAULT '10 minutes',
  max_compiled_bytes int NOT NULL DEFAULT 4000000,
  created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX environment_one_default ON flagsmith.environment ((true)) WHERE is_default;

-- Immutable configuration versions. Only 'live' snapshots are ever pointed to.
CREATE TABLE flagsmith.snapshot (
  snapshot_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  env_key         text NOT NULL REFERENCES flagsmith.environment ON DELETE CASCADE,
  kind            text NOT NULL DEFAULT 'live' CHECK (kind IN ('live', 'candidate', 'test')),
  content_sha256  bytea NOT NULL,
  context         json NOT NULL,      -- json, not jsonb: segment order decides tie-breaks
  env_name        text NOT NULL,
  ctx_env_key     text NOT NULL,      -- context.environment.key: the identity key prefix
  source          text NOT NULL,      -- 'pusher' | 'pg_net' | 'manual' | 'flagshift' | 'test'
  source_rev      text,               -- Flagsmith ETag or updated_at, for idempotent loads
  loaded_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
  load_ms         numeric,
  identity_overrides json,           -- SDK shape: {identifier: segment context}, or NULL
  has_flag_deps   boolean NOT NULL DEFAULT false,
  n_ctx_segments  int NOT NULL DEFAULT 0, -- segments of the context itself (seg_ord 1..n)
  n_ctx_fcs       int NOT NULL DEFAULT 0, -- feature contexts of the context itself (fc_id 1..n)
  n_features      int NOT NULL DEFAULT 0, -- defaults are fc_id 1..n_features
  n_ctx_rules     int NOT NULL DEFAULT 0, -- rules of the context's segments are rule_id 1..n
  n_ctx_conds     int NOT NULL DEFAULT 0,
  n_io_indexed    int NOT NULL DEFAULT 0,
  n_identity_overrides int NOT NULL DEFAULT 0,
  compiled        boolean NOT NULL DEFAULT false, -- flagsmith_c.flags_s<id> is real compiled code
  compile_ms      numeric,
  compile_bytes   int,
  compile_note    text,
  UNIQUE (env_key, kind, content_sha256)
);
ALTER TABLE flagsmith.environment ADD CONSTRAINT environment_current_snapshot_fkey
  FOREIGN KEY (current_snapshot) REFERENCES flagsmith.snapshot DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX snapshot_env_kind ON flagsmith.snapshot (env_key, kind, snapshot_id);

CREATE TABLE flagsmith.segment (
  snapshot_id   bigint NOT NULL REFERENCES flagsmith.snapshot ON DELETE CASCADE,
  seg_ord       int,                 -- 1-based position in the context's segments object
  segment_key   text NOT NULL,       -- hashed by PERCENTAGE_SPLIT
  name          text NOT NULL,
  metadata      jsonb,
  source        text NOT NULL DEFAULT 'api' CHECK (source IN ('api', 'identity_override')),
                                     -- identity_override: an SDK per-identity segment, present in the
                                     -- context only for the identity it belongs to
  io_indexed    boolean NOT NULL DEFAULT false, -- membership answered by identity_override
  io_identifier text,                -- identity_override segments: the identity they belong to
  io_overrides  jsonb,               -- identity_override segments: {feature: {enabled, value, metadata}}
  first_rule    int,                 -- first top-level rule (rules form sibling lists)
  ov_first      int,                 -- this segment's overrides are fc_id ov_first .. + ov_count - 1
  ov_count      int NOT NULL DEFAULT 0,
  identity_free boolean NOT NULL,    -- SDK environment-flags filter
  reads_flags   boolean NOT NULL,
  PRIMARY KEY (snapshot_id, seg_ord)
);

CREATE INDEX segment_io_identifier ON flagsmith.segment (snapshot_id, io_identifier)
  WHERE source = 'identity_override';

CREATE TABLE flagsmith.rule (
  snapshot_id  bigint NOT NULL REFERENCES flagsmith.snapshot ON DELETE CASCADE,
  rule_id      int,                  -- preorder id within the snapshot, 1-based
  seg_ord      int NOT NULL,
  parent_id    int,                  -- NULL = a top-level rule of the segment
  ord          int NOT NULL,         -- position among siblings
  rule_type    text NOT NULL,        -- ALL | ANY | NONE
  first_cond   int,                  -- conditions are numbered contiguously per rule
  n_cond       int NOT NULL DEFAULT 0,
  first_child  int,
  next_sibling int,
  PRIMARY KEY (snapshot_id, rule_id)
);

-- Condition values are parsed once, at load, with Python's parsing rules.
CREATE TABLE flagsmith.condition (
  snapshot_id  bigint NOT NULL REFERENCES flagsmith.snapshot ON DELETE CASCADE,
  cond_id      int,                  -- 1-based, contiguous within each rule
  rule_id      int NOT NULL,
  property     text NOT NULL,
  operator     text NOT NULL,        -- text, not an enum: unknown operators load and evaluate false
  value_raw    json,                 -- exactly as given
  prop_kind    text NOT NULL,        -- split_ik | trait | jp_identifier | jp_identity_key | jp_trait
                                     -- | jp_trait_path | jp_flag | jp_const | jp_none
  prop_name    text,                 -- trait name, or flag name for jp_flag
  prop_path    text[],               -- remaining path for jp_trait_path / jp_flag
  const_val    flagsmith.ctxval,     -- jp_const: folded at load
  v_text       text,                 -- the value as Python str
  v_is_str     boolean NOT NULL DEFAULT true,
  v_int        numeric,              -- Python int(value) or NULL
  v_float      float8,               -- Python float(value) or NULL
  v_bool       boolean,              -- value not in ('False', 'false')
  v_semver     flagsmith.semver,     -- value ends in ':semver' and the rest parses
  v_is_semver  boolean NOT NULL DEFAULT false,
  v_semver_txt text,                 -- value without ':semver'
  in_set       text[],               -- IN
  v_regex      text,                 -- REGEX rewritten for Postgres, anchored at the start
  v_mod_div    float8,
  v_mod_rem    float8,
  v_threshold  float8,               -- PERCENTAGE_SPLIT
  status       text NOT NULL DEFAULT 'ok'
               CHECK (status IN ('ok', 'unsupported', 'unknown_operator', 'invalid')),
  PRIMARY KEY (snapshot_id, cond_id)
);

-- Environment defaults (seg_ord NULL) and segment overrides share one shape.
CREATE TABLE flagsmith.feature_context (
  snapshot_id   bigint NOT NULL REFERENCES flagsmith.snapshot ON DELETE CASCADE,
  fc_id         int NOT NULL,        -- 1-based within the snapshot
  feature_name  text NOT NULL,
  seg_ord       int,                 -- NULL = environment default
  ord           int NOT NULL,        -- position (features object, or segment's overrides list)
  feature_key   text NOT NULL,       -- multivariate hashing salt
  enabled       boolean NOT NULL,
  value         jsonb,
  value_json    json,
  priority      numeric NOT NULL DEFAULT 'Infinity',
  win_rank      int,                 -- overrides: precedence among this feature's overrides
  fallback_reason text,              -- defaults: DEFAULT when any segment overrides it, else STATIC
  metadata      jsonb,
  n_variants    int NOT NULL DEFAULT 0,
  PRIMARY KEY (snapshot_id, fc_id)
);
CREATE UNIQUE INDEX feature_context_default ON flagsmith.feature_context (snapshot_id, feature_name)
  WHERE seg_ord IS NULL;
CREATE INDEX feature_context_override ON flagsmith.feature_context (snapshot_id, feature_name, win_rank)
  WHERE seg_ord IS NOT NULL;

CREATE TABLE flagsmith.variant (
  snapshot_id  bigint NOT NULL REFERENCES flagsmith.snapshot ON DELETE CASCADE,
  fc_id        int,
  ord          int,                  -- after a stable sort by priority
  value        jsonb,
  variant_key  text,                 -- NULL when the option has no key
  weight_txt   text NOT NULL,        -- Python str(weight), for the reason
  lo           float8 NOT NULL,      -- selected when lo <= p < hi
  hi           float8 NOT NULL,
  PRIMARY KEY (snapshot_id, fc_id, ord)
);

-- Identity overrides: any segment whose only rule is `$.identity.identifier IN [...]`
-- is answered by this index instead of scanning its IN list.
CREATE TABLE flagsmith.identity_override (
  snapshot_id bigint NOT NULL REFERENCES flagsmith.snapshot ON DELETE CASCADE,
  in_key      text,                  -- an IN list member
  seg_ord     int,
  PRIMARY KEY (snapshot_id, in_key, seg_ord)
);

CREATE TABLE flagsmith.snapshot_warning (
  snapshot_id bigint REFERENCES flagsmith.snapshot ON DELETE CASCADE,
  severity    text NOT NULL CHECK (severity IN ('error', 'warning')),
  code        text NOT NULL,
  path        text NOT NULL,         -- e.g. segments.12.rules.0.conditions.3
  detail      text
);
CREATE INDEX snapshot_warning_snapshot ON flagsmith.snapshot_warning (snapshot_id);

-- Results of live parity checks (pg-flagsmith parity), read by health().
CREATE TABLE flagsmith.parity_run (
  run_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  env_key      text NOT NULL,
  snapshot_id  bigint,
  started_at   timestamptz NOT NULL DEFAULT now(),
  oracle       text NOT NULL,        -- 'sdk' | 'engine'
  identities   int NOT NULL,
  flags_compared bigint NOT NULL,
  mismatches   int NOT NULL,
  details      jsonb                 -- up to 100 sample mismatches
);

-- Load history (also for loads deduplicated to an existing snapshot).
CREATE TABLE flagsmith.load_log (
  load_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  env_key     text NOT NULL,
  snapshot_id bigint,
  at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  source      text,
  source_rev  text,
  outcome     text NOT NULL,          -- 'loaded' | 'unchanged' | 'reused' | 'pinned'
  detail      text
);

-- Deny by default: row level security on, no policies for application roles.
ALTER TABLE flagsmith.environment      ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.snapshot         ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.segment          ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.rule             ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.condition        ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.feature_context  ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.variant          ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.identity_override ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.snapshot_warning ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.parity_run       ENABLE ROW LEVEL SECURITY;
ALTER TABLE flagsmith.load_log         ENABLE ROW LEVEL SECURITY;
