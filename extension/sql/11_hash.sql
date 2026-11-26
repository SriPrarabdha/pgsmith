-- The hash behind every percentage split and multivariate allocation:
--   p = (int(md5(",".join(ids)), 16) % 9999) / 9998 * 100
-- and, when p is exactly 100, the same with the id list repeated (a,b,a,b).
--
-- The 128-bit digest is reduced mod 9999 without numeric or C: split it into
-- four 32-bit words w1..w4, then r = (w1*2^96 + w2*2^64 + w3*2^32 + w4) mod 9999,
-- with the powers of two precomputed mod 9999. Every term fits in bigint.

-- r = md5 digest (hex) mod 9999
CREATE FUNCTION flagsmith.md5_mod9999(h text) RETURNS int
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE BEGIN ATOMIC
  SELECT (((('x' || substr(h, 1, 8))::bit(32)::bigint % 9999) * 7291
         + (('x' || substr(h, 9, 8))::bit(32)::bigint % 9999) * 1897
         + (('x' || substr(h, 17, 8))::bit(32)::bigint % 9999) * 6835
         +  ('x' || substr(h, 25, 8))::bit(32)::bigint) % 9999)::int
;
END;

-- The engine's hashed percentage for an id list, rehash included.
CREATE FUNCTION flagsmith.hash_pct(ids text[]) RETURNS float8
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  rep text[] := ids;
  r   int;
BEGIN
  LOOP
    r := flagsmith.md5_mod9999(md5(convert_to(array_to_string(rep, ','), 'UTF8')));
    EXIT WHEN r <> 9998;          -- 9998 / 9998 * 100 = 100: hash again
    rep := rep || ids;            -- Python repeats the list: a,b,a,b
  END LOOP;
  RETURN r::float8 / 9998 * 100;  -- same operation order as the reference
END $$;

-- Two-id fast path (every split and variant hashes exactly two ids).
CREATE FUNCTION flagsmith.hash_pct(a text, b text) RETURNS float8
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  h text := md5(convert_to(a || ',' || b, 'UTF8'));
  r int;
BEGIN
  r := (((('x' || substr(h, 1, 8))::bit(32)::bigint % 9999) * 7291
       + (('x' || substr(h, 9, 8))::bit(32)::bigint % 9999) * 1897
       + (('x' || substr(h, 17, 8))::bit(32)::bigint % 9999) * 6835
       +  ('x' || substr(h, 25, 8))::bit(32)::bigint) % 9999)::int;
  IF r <> 9998 THEN
    RETURN r::float8 / 9998 * 100;
  END IF;
  RETURN flagsmith.hash_pct(ARRAY[a, b]);
END $$;
