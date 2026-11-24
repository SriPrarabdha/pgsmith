-- Demo application schema: 100k users with the traits the demo segments use.
CREATE SCHEMA IF NOT EXISTS app;
DROP TABLE IF EXISTS app.users;
CREATE TABLE app.users AS
SELECT CASE g WHEN 1 THEN 'user42' WHEN 2 THEN 'vip-1' WHEN 3 THEN '007' WHEN 4 THEN '12345'
              ELSE 'user-' || g END AS identifier,
       jsonb_strip_nulls(jsonb_build_object(
         'plan', (ARRAY['free','free','pro','team','enterprise'])[1 + abs(hashint4(g)) % 5],
         'beta', CASE WHEN abs(hashint4(g + 1)) % 7 = 0 THEN true END,
         'country', (ARRAY['IN','US','GB','DE','BR','IN','JP'])[1 + abs(hashint4(g + 2)) % 7],
         'device', (ARRAY['ios','android','web'])[1 + abs(hashint4(g + 3)) % 3],
         'app_version', (1 + abs(hashint4(g + 4)) % 4) || '.' || (abs(hashint4(g + 5)) % 6) || '.' || (abs(hashint4(g + 6)) % 3)
                        || CASE WHEN abs(hashint4(g + 7)) % 10 = 0 THEN '-beta.' || (abs(hashint4(g + 8)) % 3) ELSE '' END,
         'email', 'u' || g || (ARRAY['@gmail.com','@corp.com','@acme.com','@mail.io'])[1 + abs(hashint4(g + 9)) % 4],
         'orders', abs(hashint4(g + 10)) % 40,
         'ltv', round((abs(hashint4(g + 11)) % 100000) / 100.0, 2)
       )) AS traits,
       now() - make_interval(days => abs(hashint4(g + 12)) % 900) AS created_at
FROM generate_series(1, 100000) g;
ALTER TABLE app.users ADD PRIMARY KEY (identifier);
ANALYZE app.users;
