-- Python compatibility: the reference engine is Python, so parity needs Python's
-- parsing and formatting rules for numbers and its str() of values.

-- A decimal literal (digits, optional fraction and exponent, no underscores) to
-- float8 the way Python's float() does it: correctly rounded, overflow to
-- +-inf, underflow to +-0.0 (Postgres raises on both).
CREATE FUNCTION flagsmith._dec_to_float8(s text) RETURNS float8
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  m text; e numeric; mant numeric; neg boolean; mag numeric; n numeric;
BEGIN
  IF length(s) < 300 AND strpos(lower(s), 'e') = 0 THEN
    RETURN s::float8;
  END IF;
  m := lower(btrim(s));
  neg := left(m, 1) = '-';
  e := coalesce(nullif(split_part(m, 'e', 2), '')::numeric, 0);
  m := split_part(m, 'e', 1);
  mant := m::numeric;
  IF mant = 0 THEN
    RETURN CASE WHEN neg THEN '-0'::float8 ELSE 0::float8 END;
  END IF;
  mag := floor(log(abs(mant))) + e;     -- decimal exponent of the leading digit
  IF mag > 400 THEN
    RETURN CASE WHEN neg THEN '-Infinity'::float8 ELSE 'Infinity'::float8 END;
  ELSIF mag < -400 THEN
    RETURN CASE WHEN neg THEN '-0'::float8 ELSE 0::float8 END;
  END IF;
  n := abs((m || 'e' || e::text)::numeric);
  -- >= DBL_MAX + half an ulp rounds to infinity
  IF n >= 179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792 THEN
    RETURN CASE WHEN neg THEN '-Infinity'::float8 ELSE 'Infinity'::float8 END;
  END IF;
  -- <= half the smallest subnormal rounds to zero (ties to even)
  IF n <= 0.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024703282292062327208828439643411068618252990130716238221279284125033775363510437593264991818081799618989828234772285886546332835517796989819938739800539093906315035659515570226392290858392449105184435931802849936536152500319370457678249219365623669863658480757001585769269903706311928279558551332927834338409351978015531246597263579574622766465272827220056374006485499977096599470454020828166226237857393450736339007967761930577506740176324673600968951340535537458516661134223766678604162159680461914467291840300530057530849048765391711386591646239524912623653881879636239373280423891018672348497668235089863388587925628302755995657524455507255189313690836254779186948667994968324049705821028513185451396213837722826145437693412532098591327667236328125 THEN
    RETURN CASE WHEN neg THEN '-0'::float8 ELSE 0::float8 END;
  END IF;
  RETURN (m || 'e' || e::text)::float8;
END $$;

-- Python int(x) for a str x: NULL where Python raises ValueError.
CREATE FUNCTION flagsmith.py_int(t text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE s text := t;
BEGIN
  IF octet_length(s) <> length(s) THEN
    s := translate(s, flagsmith._py_num_tr_from(), flagsmith._py_num_tr_to());
  END IF;
  IF s !~ '^[ \t\n\r\f\v]*[-+]?[0-9](_?[0-9])*[ \t\n\r\f\v]*$' THEN
    RETURN NULL;
  END IF;
  RETURN replace(btrim(s, E' \t\n\r\f\v'), '_', '')::numeric;
END $$;

-- Python float(x) for a str x: NULL where Python raises ValueError.
CREATE FUNCTION flagsmith.py_float(t text) RETURNS float8
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE s text := t; l text;
BEGIN
  IF octet_length(s) <> length(s) THEN
    s := translate(s, flagsmith._py_num_tr_from(), flagsmith._py_num_tr_to());
  END IF;
  s := btrim(s, E' \t\n\r\f\v');
  l := lower(s);
  IF l IN ('inf', '+inf', 'infinity', '+infinity') THEN RETURN 'Infinity'::float8; END IF;
  IF l IN ('-inf', '-infinity') THEN RETURN '-Infinity'::float8; END IF;
  IF l IN ('nan', '+nan', '-nan') THEN RETURN 'NaN'::float8; END IF;
  IF s !~ '^[-+]?(([0-9](_?[0-9])*)?\.[0-9](_?[0-9])*|[0-9](_?[0-9])*\.?)([eE][-+]?[0-9](_?[0-9])*)?$' THEN
    RETURN NULL;
  END IF;
  s := replace(s, '_', '');
  IF left(s, 1) = '+' THEN s := substr(s, 2); END IF;
  -- '5.' and '.5' are fine for Postgres; normalise a bare trailing dot anyway
  s := regexp_replace(s, '\.([eE]|$)', '.0\1');
  IF left(s, 1) = '.' THEN s := '0' || s; END IF;
  s := regexp_replace(s, '^-\.', '-0.');
  RETURN flagsmith._dec_to_float8(s);
END $$;

-- Python repr(float) / str(float): the shortest decimal string that reads back
-- as the same double (nearest one when several have that length), laid out the
-- way Python does. Postgres' own shortest output (Ryu) disagrees with Python's
-- dtoa on rounding-interval boundaries, so the digits are recomputed exactly.
CREATE FUNCTION flagsmith.py_float_repr(f float8) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET extra_float_digits = 1
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE
  t text; neg boolean; x float8; ex numeric; et text; decpt int; p int; sc int;
  lo numeric; hi numeric; ok_lo boolean; ok_hi boolean; ch numeric; digits text; r text; start_p int;
BEGIN
  IF f = 'NaN'::float8 THEN RETURN 'nan'; END IF;
  IF f = 'Infinity'::float8 THEN RETURN 'inf'; END IF;
  IF f = '-Infinity'::float8 THEN RETURN '-inf'; END IF;
  IF f = 0 THEN
    RETURN CASE WHEN float8send(f) = '\x8000000000000000'::bytea THEN '-0.0' ELSE '0.0' END;
  END IF;
  neg := f < 0;
  x := abs(f);
  -- Postgres' shortest digits: Python's are never more than one digit shorter
  t := x::text;
  start_p := length(rtrim(ltrim(replace(split_part(t, 'e', 1), '.', ''), '0'), '0'));
  ex := flagsmith._float8_exact(x);
  et := ex::text;
  IF ex >= 1 THEN
    decpt := length(split_part(et, '.', 1));
  ELSE
    decpt := -(length(split_part(et, '.', 2)) - length(ltrim(split_part(et, '.', 2), '0')));
  END IF;
  FOR p IN greatest(1, start_p - 1) .. 17 LOOP
    sc := p - decpt;
    lo := trunc(ex, sc);
    hi := lo + power(10::numeric, -sc);
    ok_lo := lo > 0 AND flagsmith._dec_to_float8(lo::text) = x;
    ok_hi := flagsmith._dec_to_float8(hi::text) = x;
    IF ok_lo OR ok_hi THEN
      IF ok_lo AND ok_hi THEN
        ch := CASE WHEN ex - lo < hi - ex THEN lo WHEN hi - ex < ex - lo THEN hi
                   WHEN right(rtrim(replace(lo::text, '.', ''), '0'), 1) IN ('0','2','4','6','8') THEN lo ELSE hi END;
      ELSE
        ch := CASE WHEN ok_lo THEN lo ELSE hi END;
      END IF;
      EXIT;
    END IF;
  END LOOP;
  -- digits and decimal point position of the chosen value
  et := ch::text;
  IF ch >= 1 THEN
    decpt := length(split_part(et, '.', 1));
  ELSE
    decpt := -(length(split_part(et, '.', 2)) - length(ltrim(split_part(et, '.', 2), '0')));
  END IF;
  digits := rtrim(ltrim(replace(et, '.', ''), '0'), '0');
  IF decpt <= -4 OR decpt > 16 THEN
    r := left(digits, 1)
         || CASE WHEN length(digits) > 1 THEN '.' || substr(digits, 2) ELSE '' END
         || 'e' || CASE WHEN decpt - 1 < 0 THEN '-' ELSE '+' END
         || CASE WHEN abs(decpt - 1) < 10 THEN '0' ELSE '' END || abs(decpt - 1)::text;
  ELSIF decpt <= 0 THEN
    r := '0.' || repeat('0', -decpt) || digits;
  ELSIF decpt >= length(digits) THEN
    r := digits || repeat('0', decpt - length(digits)) || '.0';
  ELSE
    r := left(digits, decpt) || '.' || substr(digits, decpt + 1);
  END IF;
  RETURN CASE WHEN neg THEN '-' || r ELSE r END;
END $$;

-- Python repr(str) (best effort: used only for non-scalar values, which the
-- Flagsmith schema does not allow in traits).
CREATE FUNCTION flagsmith._py_str_repr(s text) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE q text; r text := ''; c text; cp int;
BEGIN
  q := CASE WHEN strpos(s, '''') > 0 AND strpos(s, '"') = 0 THEN '"' ELSE '''' END;
  FOREACH c IN ARRAY CASE WHEN s = '' THEN '{}'::text[] ELSE regexp_split_to_array(s, '') END LOOP
    cp := ascii(c);
    r := r || CASE
      WHEN c = '\' THEN '\\'
      WHEN c = q THEN '\' || q
      WHEN cp = 10 THEN '\n' WHEN cp = 13 THEN '\r' WHEN cp = 9 THEN '\t'
      WHEN cp < 32 OR cp BETWEEN 127 AND 160 OR cp = 173 THEN '\x' || lpad(to_hex(cp), 2, '0')
      ELSE c END;
  END LOOP;
  RETURN q || r || q;
END $$;

-- Python str()/repr() of a JSON value parsed by json.loads.
--   repr = false: str() (top level); repr = true: repr() (inside containers)
CREATE FUNCTION flagsmith.py_str_json(j json, as_repr boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE t text; r text; k text; v json; first boolean := true;
BEGIN
  IF j IS NULL THEN RETURN 'None'; END IF;
  CASE json_typeof(j)
    WHEN 'null' THEN RETURN 'None';
    WHEN 'boolean' THEN RETURN CASE WHEN j::text = 'true' THEN 'True' ELSE 'False' END;
    WHEN 'string' THEN
      RETURN CASE WHEN as_repr THEN flagsmith._py_str_repr(j #>> '{}') ELSE j #>> '{}' END;
    WHEN 'number' THEN
      t := j::text;
      IF t ~ '[.eE]' THEN RETURN flagsmith.py_float_repr(flagsmith._dec_to_float8(t)); END IF;
      RETURN t::numeric::text;
    WHEN 'array' THEN
      r := '[';
      FOR v IN SELECT value FROM json_array_elements(j) LOOP
        IF NOT first THEN r := r || ', '; END IF;
        r := r || flagsmith.py_str_json(v, true);
        first := false;
      END LOOP;
      RETURN r || ']';
    ELSE
      r := '{';
      -- json.loads keeps the last value of a duplicate key, at its first position
      FOR k, v IN
        SELECT e.key, (array_agg(e.value ORDER BY e.n DESC))[1]
        FROM json_each(j) WITH ORDINALITY e(key, value, n)
        GROUP BY e.key ORDER BY min(e.n)
      LOOP
        IF NOT first THEN r := r || ', '; END IF;
        r := r || flagsmith._py_str_repr(k) || ': ' || flagsmith.py_str_json(v, true);
        first := false;
      END LOOP;
      RETURN r || '}';
  END CASE;
END $$;

CREATE FUNCTION flagsmith.ctxval_str(s text) RETURNS flagsmith.ctxval
LANGUAGE sql IMMUTABLE PARALLEL SAFE BEGIN ATOMIC
  SELECT CASE
    WHEN s IS NULL THEN ROW('n', NULL, NULL, NULL, NULL)::flagsmith.ctxval
    WHEN s ~ '^-?[0-9]+$' THEN ROW('i', NULL, s::numeric, NULL, NULL)::flagsmith.ctxval
    WHEN s ~ '^-?[0-9]+\.[0-9]+$' THEN ROW('f', NULL, NULL, flagsmith._dec_to_float8(s), NULL)::flagsmith.ctxval
    ELSE ROW('s', s, NULL, NULL, NULL)::flagsmith.ctxval
  END
;
END;

-- A JSON value mapped to a context value, as map_any_value_to_context_value() does
-- for values read by trait name: numeric-looking strings become int/float,
-- containers become their Python str().
CREATE FUNCTION flagsmith.ctxval(v jsonb) RETURNS flagsmith.ctxval
LANGUAGE sql IMMUTABLE PARALLEL SAFE BEGIN ATOMIC
  SELECT CASE jsonb_typeof(v)
    WHEN 'string' THEN flagsmith.ctxval_str(v #>> '{}')
    WHEN 'number' THEN
      CASE WHEN strpos(v::text, '.') > 0
           THEN ROW('f', NULL, NULL, flagsmith._dec_to_float8(v::text), NULL)::flagsmith.ctxval
           ELSE ROW('i', NULL, v::text::numeric, NULL, NULL)::flagsmith.ctxval END
    WHEN 'boolean' THEN ROW('b', NULL, NULL, NULL, v::text = 'true')::flagsmith.ctxval
    WHEN 'object' THEN ROW('s', flagsmith.py_str_json(v::json), NULL, NULL, NULL)::flagsmith.ctxval
    WHEN 'array'  THEN ROW('s', flagsmith.py_str_json(v::json), NULL, NULL, NULL)::flagsmith.ctxval
    ELSE ROW('n', NULL, NULL, NULL, NULL)::flagsmith.ctxval
  END
;
END;

-- Same, for a value reached through a JSONPath query: non-scalars are None.
CREATE FUNCTION flagsmith.ctxval_jp(v jsonb) RETURNS flagsmith.ctxval
LANGUAGE sql IMMUTABLE PARALLEL SAFE BEGIN ATOMIC
  SELECT CASE WHEN jsonb_typeof(v) IN ('object', 'array')
              THEN ROW('n', NULL, NULL, NULL, NULL)::flagsmith.ctxval
              ELSE flagsmith.ctxval(v) END
;
END;

-- Python str() of a context value.
CREATE FUNCTION flagsmith.py_str(c flagsmith.ctxval) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE BEGIN ATOMIC
  SELECT CASE c.k
    WHEN 's' THEN c.s
    WHEN 'i' THEN c.n::text
    WHEN 'f' THEN flagsmith.py_float_repr(c.f)
    WHEN 'b' THEN CASE WHEN c.b THEN 'True' ELSE 'False' END
    ELSE 'None'
  END
;
END;

-- The exact value of a finite float8 as numeric (float8::numeric rounds to 15 digits).
CREATE FUNCTION flagsmith._float8_exact(f float8) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE b bytea := float8send(f); hi bigint; lo bigint; e int; m numeric; neg boolean; r numeric; t text;
BEGIN
  hi := (get_byte(b,0)::bigint << 24) | (get_byte(b,1) << 16) | (get_byte(b,2) << 8) | get_byte(b,3);
  lo := (get_byte(b,4)::bigint << 24) | (get_byte(b,5) << 16) | (get_byte(b,6) << 8) | get_byte(b,7);
  neg := (hi >> 31) = 1;
  e := ((hi >> 20) & 2047)::int;
  m := ((hi & 1048575)::numeric * 4294967296) + lo;
  IF e = 0 THEN
    e := 1;            -- subnormal
  ELSE
    m := m + 4503599627370496;   -- implicit leading 1 (2^52)
  END IF;
  e := e - 1075;
  IF e >= 0 THEN
    r := m * (2::numeric ^ e);
  ELSE
    -- m / 2^k = m * 5^k / 10^k: an integer, then the decimal point k places left
    t := (m * (5::numeric ^ (-e)))::text;
    t := split_part(t, '.', 1);
    IF length(t) < -e + 1 THEN t := lpad(t, -e + 1, '0'); END IF;   -- lpad truncates longer input
    r := (left(t, length(t) + e) || '.' || right(t, -e))::numeric;
  END IF;
  RETURN CASE WHEN neg THEN -r ELSE r END;
END $$;

-- Python's float modulo x % d (fmod, then the sign of the divisor). NULL where
-- Python raises (zero divisor).
CREATE FUNCTION flagsmith.py_fmod(x float8, d float8) RETURNS float8
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, flagsmith, pg_temp AS $$
DECLARE r float8; xn numeric; dn numeric;
BEGIN
  IF d = 0 THEN RETURN NULL; END IF;
  IF x = 'NaN'::float8 OR d = 'NaN'::float8 OR x IN ('Infinity'::float8, '-Infinity'::float8) THEN
    RETURN 'NaN'::float8;
  END IF;
  IF d IN ('Infinity'::float8, '-Infinity'::float8) THEN
    r := x;                                   -- fmod(x, +-inf) = x
  ELSIF x = trunc(x) AND d = trunc(d) AND abs(x) < 9.0e15 AND abs(d) < 9.0e15 THEN
    r := (x::bigint % d::bigint)::float8;     -- exact, truncated toward zero like fmod
  ELSE
    xn := flagsmith._float8_exact(x);
    dn := flagsmith._float8_exact(d);
    r := mod(xn, dn)::float8;                 -- exact truncated remainder, representable
  END IF;
  IF r <> 0 THEN
    IF (d < 0) <> (r < 0) THEN r := r + d; END IF;
  ELSE
    r := CASE WHEN d < 0 THEN '-0'::float8 ELSE 0::float8 END;
  END IF;
  -- fmod keeps the sign of x for a zero result; Python then copies the divisor's sign
  RETURN r;
END $$;
