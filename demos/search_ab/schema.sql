-- Demo 2: A/B testing a SQL ranking query.
-- The ranking formula is the experiment. Postgres picks each user's arm with the
-- same bucketing as the Flagsmith SDKs (pgsmith) and ranks with that arm's
-- formula in the same query; Flagsmith Experimentation decides which ranking wins.

CREATE SCHEMA IF NOT EXISTS shop;

-- 200k synthetic products (deterministic): titles from a small vocabulary,
-- heavy-tailed 30-day sales.
DROP TABLE IF EXISTS shop.products CASCADE;
CREATE TABLE shop.products AS
WITH words AS (
  SELECT ARRAY['wireless','organic','vintage','compact','premium','smart','classic','ultra','eco','portable',
               'leather','bamboo','steel','cotton','ceramic','solar','mini','pro','retro','silk'] AS adj,
         ARRAY['headphones','backpack','lamp','kettle','sneakers','watch','speaker','mug','jacket','charger',
               'keyboard','blender','tent','camera','bottle','notebook','sofa','helmet','drone','guitar'] AS noun,
         ARRAY['audio','travel','home','kitchen','sports','fashion','office','outdoor','tech','music'] AS cat
)
SELECT g AS id,
       initcap(adj[1 + abs(hashint4(g)) % 20] || ' '
               || adj[1 + (abs(hashint4(g)) % 20 + 1 + abs(hashint4(g + 7)) % 19) % 20] || ' '
               || noun[1 + abs(hashint4(g + 13)) % 20]) AS title,
       cat[1 + abs(hashint4(g + 21)) % 10] AS category,
       round((5 + abs(hashint4(g + 3)) % 49500 / 100.0)::numeric, 2) AS price,
       -- heavy tail: most products sell little, a few sell a lot
       floor(exp((abs(hashint4(g + 5)) % 1000) / 1000.0 * 7.5))::int - 1 AS sales_30d
FROM generate_series(1, 200000) g, words;
ALTER TABLE shop.products ADD PRIMARY KEY (id);
ALTER TABLE shop.products ADD COLUMN search_vec tsvector
  GENERATED ALWAYS AS (to_tsvector('english', title || ' ' || category)) STORED;
CREATE INDEX products_search ON shop.products USING gin (search_vec);
ANALYZE shop.products;

-- The two arms. control: text relevance only; boosted: relevance blended with 30-day sales.
CREATE OR REPLACE FUNCTION shop.rank(q text, arm text, n int DEFAULT 20)
RETURNS TABLE (product_id int, title text, score real)
LANGUAGE sql STABLE AS $$
  SELECT p.id, p.title,
         (CASE arm WHEN 'boosted' THEN ts_rank(p.search_vec, query) * (1 + ln(1 + p.sales_30d))
                   ELSE ts_rank(p.search_vec, query) END)::real AS score
  FROM shop.products p, websearch_to_tsquery('english', q) query
  WHERE p.search_vec @@ query
  ORDER BY 3 DESC, p.id
  LIMIT n
$$;

-- The production query (PLAN.md): the arm is evaluated once per request, not
-- once per candidate row, and drives the ORDER BY of the same statement.
CREATE OR REPLACE FUNCTION shop.search(user_id text, user_traits jsonb, q text, n int DEFAULT 20)
RETURNS TABLE (product_id int, title text, arm text)
LANGUAGE sql STABLE AS $$
  WITH v AS MATERIALIZED (                -- evaluated once per request, not once per product row
    SELECT coalesce(flagsmith.variant('search_ranking', user_id, user_traits), 'control') AS arm
  )
  SELECT p.id, p.title, v.arm
  FROM shop.products p, v, websearch_to_tsquery('english', q) query
  WHERE p.search_vec @@ query
  ORDER BY CASE v.arm
             WHEN 'boosted' THEN ts_rank(p.search_vec, query) * (1 + ln(1 + p.sales_30d))
             ELSE ts_rank(p.search_vec, query)
           END DESC, p.id
  LIMIT n
$$;

-- Events recorded by the demo application (also sent to Flagsmith with the SDK).
CREATE TABLE IF NOT EXISTS shop.events (
  at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  identifier text NOT NULL,
  event      text NOT NULL,             -- '$flag_exposure', search_result_clicked, add_to_cart, search_latency_ms
  arm        text,
  value      numeric,
  query      text
);
CREATE INDEX IF NOT EXISTS events_event ON shop.events (event, identifier);

-- Pre-launch check: replay logged searches through both arms and measure how much
-- the top ten differ. If they barely differ, the experiment cannot detect anything.
CREATE OR REPLACE FUNCTION shop.overlap_at_10(queries text[])
RETURNS TABLE (queries_replayed int, mean_overlap_at_10 numeric, identical_top10 int)
LANGUAGE sql STABLE AS $$
  WITH r AS (
    SELECT q,
           ARRAY(SELECT product_id FROM shop.rank(q, 'control', 10)) AS top_control,
           ARRAY(SELECT product_id FROM shop.rank(q, 'boosted', 10)) AS top_boosted
    FROM unnest(queries) q
  )
  SELECT count(*)::int,
         round(avg(cardinality(ARRAY(SELECT unnest(top_control) INTERSECT SELECT unnest(top_boosted))) / 10.0), 3),
         count(*) FILTER (WHERE top_control = top_boosted)::int
  FROM r WHERE cardinality(top_control) > 0
$$;

-- erf for the normal CDF (Abramowitz-Stegun 7.1.26, |error| < 1.5e-7)
CREATE OR REPLACE FUNCTION erf(x numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT sign(x) * (1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592)
                         * t * exp(-(x * x)))
  FROM (SELECT 1 / (1 + 0.3275911 * abs(x)) AS t) s
$$;

-- Bayesian read-out computed in Postgres (a cross-check of Flagsmith's results):
-- per arm, Beta(1 + converters, 1 + non-converters) on users who converted at least
-- once; win probability and a 95% interval for the lift by normal approximation.
CREATE OR REPLACE VIEW shop.experiment_results AS
WITH exposed AS (
  SELECT DISTINCT ON (identifier) identifier, arm FROM shop.events
  WHERE event = '$flag_exposure' ORDER BY identifier, at
),
per_user AS (
  SELECT e.identifier, e.arm,
         bool_or(v.event = 'search_result_clicked') AS clicked,
         bool_or(v.event = 'add_to_cart') AS carted,
         avg(v.value) FILTER (WHERE v.event = 'search_latency_ms') AS latency
  FROM exposed e LEFT JOIN shop.events v ON v.identifier = e.identifier AND v.event <> '$flag_exposure'
  GROUP BY 1, 2
),
arms AS (
  SELECT arm, metric, count(*) AS n, count(*) FILTER (WHERE hit) AS k, avg(lat) AS mean_latency
  FROM per_user,
       LATERAL (VALUES ('search_result_clicked', clicked, latency), ('add_to_cart', carted, latency)) m(metric, hit, lat)
  GROUP BY 1, 2
),
post AS (
  SELECT arm, metric, n, k, (1.0 + k) / (2.0 + n) AS mean,
         ((1.0 + k) * (1.0 + n - k)) / ((2.0 + n) ^ 2 * (3.0 + n)) AS var, mean_latency
  FROM arms
)
SELECT b.metric,
       c.n AS control_users, round(c.k / c.n::numeric, 4) AS control_rate,
       b.n AS boosted_users, round(b.k / b.n::numeric, 4) AS boosted_rate,
       round((b.mean - c.mean) / c.mean * 100, 2) AS lift_pct,
       round(100 * 0.5 * (1 + erf((b.mean - c.mean) / sqrt(2 * (b.var + c.var)))), 1) AS p_boosted_better_pct,
       round(((b.mean - c.mean) - 1.96 * sqrt(b.var + c.var)) / c.mean * 100, 2) AS lift_ci_low_pct,
       round(((b.mean - c.mean) + 1.96 * sqrt(b.var + c.var)) / c.mean * 100, 2) AS lift_ci_high_pct,
       round(c.mean_latency, 2) AS control_latency_ms, round(b.mean_latency, 2) AS boosted_latency_ms
FROM post b JOIN post c ON c.metric = b.metric AND c.arm = 'control'
WHERE b.arm = 'boosted';

