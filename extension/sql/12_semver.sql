-- SemVer 2.0, with python-semver 3's parser (Version.parse) and ordering
-- (Version.compare, which ignores build metadata).

CREATE FUNCTION flagsmith.semver_parse(s text) RETURNS flagsmith.semver
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE m text[];
BEGIN
  m := regexp_match(s,
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    '(?:-((?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?'
    '(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$');
  IF m IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN ROW(m[1]::numeric, m[2]::numeric, m[3]::numeric, m[4], m[5])::flagsmith.semver;
END $$;

-- -1, 0 or 1. Build metadata does not take part.
CREATE FUNCTION flagsmith.semver_cmp(a flagsmith.semver, b flagsmith.semver) RETURNS int
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE pa text[]; pb text[]; x text; y text; i int; xn boolean; yn boolean; xs text; ys text;
BEGIN
  IF a.major <> b.major THEN RETURN sign(a.major - b.major); END IF;
  IF a.minor <> b.minor THEN RETURN sign(a.minor - b.minor); END IF;
  IF a.patch <> b.patch THEN RETURN sign(a.patch - b.patch); END IF;
  IF a.pre IS NOT DISTINCT FROM b.pre THEN RETURN 0; END IF;
  IF a.pre IS NULL THEN RETURN 1; END IF;      -- a release outranks its pre-releases
  IF b.pre IS NULL THEN RETURN -1; END IF;
  pa := string_to_array(a.pre, '.');
  pb := string_to_array(b.pre, '.');
  FOR i IN 1..least(cardinality(pa), cardinality(pb)) LOOP
    x := pa[i]; y := pb[i];
    xn := x ~ '^[0-9]+$'; yn := y ~ '^[0-9]+$';
    IF xn AND yn THEN
      xs := coalesce(nullif(ltrim(x, '0'), ''), '0');
      ys := coalesce(nullif(ltrim(y, '0'), ''), '0');
      IF length(xs) <> length(ys) THEN RETURN sign(length(xs) - length(ys)); END IF;
      IF xs <> ys THEN RETURN CASE WHEN xs COLLATE "C" < ys COLLATE "C" THEN -1 ELSE 1 END; END IF;
    ELSIF xn THEN
      RETURN -1;                                 -- numeric identifiers rank below text
    ELSIF yn THEN
      RETURN 1;
    ELSIF x <> y THEN
      RETURN CASE WHEN x COLLATE "C" < y COLLATE "C" THEN -1 ELSE 1 END;
    END IF;
  END LOOP;
  RETURN sign(cardinality(pa) - cardinality(pb));
END $$;
