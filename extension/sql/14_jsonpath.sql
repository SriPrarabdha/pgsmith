-- JSONPath condition properties. The reference compiles any property starting
-- with "$." as an RFC 9535 query (python-jsonpath-rfc9535); if that fails to
-- parse, the property is a trait name. Singular queries (names and indexes only)
-- are resolved at load time; other valid queries are reported as unsupported.
--
-- Returns ok = false on a syntax error. Path elements are '.name' or '#index'.

CREATE FUNCTION flagsmith.jsonpath_parse(q text,
  OUT ok boolean, OUT singular boolean, OUT segs text[])
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  chars text[] := regexp_split_to_array(q, '');
  n int := cardinality(chars);
  i int := 2;
  c text;
  name text;
  quote text;
  sel_count int;
  sel text;
  depth int;
  hex text;
  cp int;
  cp2 int;
  m text;
BEGIN
  ok := false; singular := true; segs := '{}';
  IF n = 0 OR chars[1] <> '$' THEN RETURN; END IF;
  LOOP
    -- whitespace between segments (not trailing)
    IF i <= n AND chars[i] IN (' ', E'\n', E'\r', E'\t') THEN
      WHILE i <= n AND chars[i] IN (' ', E'\n', E'\r', E'\t') LOOP i := i + 1; END LOOP;
      IF i > n THEN RETURN; END IF;   -- unexpected trailing whitespace
    END IF;
    IF i > n THEN EXIT; END IF;
    c := chars[i];
    IF c = '.' THEN
      IF i + 1 <= n AND chars[i + 1] = '.' THEN
        -- descendant segment: valid, never singular
        singular := false;
        i := i + 2;
        IF i > n THEN RETURN; END IF;
        IF chars[i] = '*' THEN i := i + 1; CONTINUE; END IF;
        IF chars[i] = '[' THEN
          -- fall through to bracket parsing below
          NULL;
        ELSE
          m := substring(array_to_string(chars[i:n], '') from '^[\u0080-\uffffa-zA-Z_][\u0080-\uffffa-zA-Z0-9_-]*');
          IF m IS NULL THEN RETURN; END IF;
          i := i + length(m);
          CONTINUE;
        END IF;
      ELSE
        i := i + 1;
        IF i > n THEN RETURN; END IF;
        IF chars[i] IN (' ', E'\n', E'\r', E'\t') THEN RETURN; END IF;
        IF chars[i] = '*' THEN singular := false; i := i + 1; CONTINUE; END IF;
        m := substring(array_to_string(chars[i:n], '') from '^[\u0080-\uffffa-zA-Z_][\u0080-\uffffa-zA-Z0-9_-]*');
        IF m IS NULL THEN RETURN; END IF;
        segs := segs || ('.' || m);
        i := i + length(m);
        CONTINUE;
      END IF;
    END IF;
    IF chars[i] <> '[' THEN RETURN; END IF;
    -- bracketed selection
    i := i + 1;
    sel_count := 0;
    sel := NULL;
    LOOP
      WHILE i <= n AND chars[i] IN (' ', E'\n', E'\r', E'\t') LOOP i := i + 1; END LOOP;
      IF i > n THEN RETURN; END IF;
      c := chars[i];
      IF c = ']' THEN
        IF sel_count = 0 THEN RETURN; END IF;
        i := i + 1; EXIT;
      ELSIF c = ',' THEN
        i := i + 1; CONTINUE;
      ELSIF c = '*' OR c = ':' THEN
        singular := false; sel_count := sel_count + 1; i := i + 1;
        -- slice bounds may follow
        WHILE i <= n AND chars[i] ~ '^[-0-9: \n\r\t]$' LOOP i := i + 1; END LOOP;
        CONTINUE;
      ELSIF c = '?' THEN
        -- filter selector: skip to the matching ']' (strings and nesting respected)
        singular := false; sel_count := sel_count + 1;
        depth := 0; i := i + 1;
        IF i > n THEN RETURN; END IF;
        WHILE i <= n LOOP
          c := chars[i];
          IF c IN ('''', '"') THEN
            quote := c; i := i + 1;
            WHILE i <= n AND chars[i] <> quote LOOP
              IF chars[i] = '\' THEN i := i + 1; END IF;
              i := i + 1;
            END LOOP;
          ELSIF c IN ('[', '(') THEN depth := depth + 1;
          ELSIF c IN (']', ')') THEN
            EXIT WHEN depth = 0 AND c = ']';
            depth := depth - 1;
          END IF;
          i := i + 1;
        END LOOP;
        IF i > n THEN RETURN; END IF;
        CONTINUE;
      ELSIF c IN ('''', '"') THEN
        quote := c; i := i + 1; name := '';
        LOOP
          IF i > n THEN RETURN; END IF;
          c := chars[i];
          IF c = quote THEN i := i + 1; EXIT; END IF;
          IF c = '\' THEN
            IF i + 1 > n THEN RETURN; END IF;
            c := chars[i + 1];
            IF c = quote THEN name := name || quote; i := i + 2;
            ELSIF c = '\' THEN name := name || '\'; i := i + 2;
            ELSIF c = '/' THEN name := name || '/'; i := i + 2;
            ELSIF c = 'b' THEN name := name || E'\b'; i := i + 2;
            ELSIF c = 'f' THEN name := name || E'\f'; i := i + 2;
            ELSIF c = 'n' THEN name := name || E'\n'; i := i + 2;
            ELSIF c = 'r' THEN name := name || E'\r'; i := i + 2;
            ELSIF c = 't' THEN name := name || E'\t'; i := i + 2;
            ELSIF c = 'u' THEN
              hex := array_to_string(chars[i + 2 : i + 5], '');
              IF length(hex) <> 4 OR hex !~ '^[0-9a-fA-F]{4}$' THEN RETURN; END IF;
              cp := ('x' || lpad(hex, 8, '0'))::bit(32)::int;
              i := i + 6;
              IF cp BETWEEN 56320 AND 57343 THEN RETURN; END IF;       -- lone low surrogate
              IF cp BETWEEN 55296 AND 56319 THEN
                IF i + 5 > n OR chars[i] <> '\' OR chars[i + 1] <> 'u' THEN RETURN; END IF;
                hex := array_to_string(chars[i + 2 : i + 5], '');
                IF hex !~ '^[0-9a-fA-F]{4}$' THEN RETURN; END IF;
                cp2 := ('x' || lpad(hex, 8, '0'))::bit(32)::int;
                IF cp2 NOT BETWEEN 56320 AND 57343 THEN RETURN; END IF;
                cp := 65536 + (((cp & 1023) << 10) | (cp2 & 1023));
                i := i + 6;
              END IF;
              IF cp < 32 THEN RETURN; END IF;
              name := name || chr(cp);
            ELSE
              RETURN;   -- invalid escape (including the other quote)
            END IF;
          ELSE
            IF ascii(c) < 32 THEN RETURN; END IF;
            name := name || c; i := i + 1;
          END IF;
        END LOOP;
        sel_count := sel_count + 1; sel := '.' || name;
        CONTINUE;
      ELSE
        m := substring(array_to_string(chars[i:least(n, i + 40)], '') from '^-?[0-9]+');
        IF m IS NULL THEN RETURN; END IF;
        IF m ~ '^-?0[0-9]' OR m = '-0' THEN RETURN; END IF;           -- leading zeros, negative zero
        IF abs(m::numeric) > 9007199254740991 THEN RETURN; END IF;    -- outside the I-JSON range
        i := i + length(m);
        -- a slice?
        WHILE i <= n AND chars[i] IN (' ', E'\n', E'\r', E'\t') LOOP i := i + 1; END LOOP;
        IF i <= n AND chars[i] = ':' THEN
          singular := false; sel_count := sel_count + 1;
          WHILE i <= n AND chars[i] ~ '^[-0-9: \n\r\t]$' LOOP i := i + 1; END LOOP;
          CONTINUE;
        END IF;
        sel_count := sel_count + 1; sel := '#' || m;
        CONTINUE;
      END IF;
    END LOOP;
    IF sel_count = 1 AND sel IS NOT NULL THEN
      segs := segs || sel;
    ELSE
      singular := false;
    END IF;
  END LOOP;
  ok := true;
END $$;

-- Walk a parsed path ('.name' / '#index' elements) through a json value, the way
-- an RFC 9535 singular query selects one node. NULL when nothing is selected.
CREATE FUNCTION flagsmith.json_walk(j json, segs text[]) RETURNS json
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE s text; idx bigint; len int;
BEGIN
  IF segs IS NULL THEN RETURN j; END IF;
  FOREACH s IN ARRAY segs LOOP
    IF j IS NULL THEN RETURN NULL; END IF;
    IF left(s, 1) = '.' THEN
      IF json_typeof(j) <> 'object' THEN RETURN NULL; END IF;
      j := j -> substr(s, 2);            -- json keeps the last duplicate key, like json.loads
    ELSE
      IF json_typeof(j) <> 'array' THEN RETURN NULL; END IF;
      idx := substr(s, 2)::bigint;
      len := json_array_length(j);
      IF idx < 0 THEN idx := idx + len; END IF;
      IF idx < 0 OR idx >= len THEN RETURN NULL; END IF;
      j := j -> idx::int;
    END IF;
  END LOOP;
  RETURN j;
END $$;

CREATE FUNCTION flagsmith.jsonb_walk(j jsonb, segs text[]) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE s text; idx bigint; len int;
BEGIN
  IF segs IS NULL THEN RETURN j; END IF;
  FOREACH s IN ARRAY segs LOOP
    IF j IS NULL THEN RETURN NULL; END IF;
    IF left(s, 1) = '.' THEN
      IF jsonb_typeof(j) <> 'object' THEN RETURN NULL; END IF;
      j := j -> substr(s, 2);
    ELSE
      IF jsonb_typeof(j) <> 'array' THEN RETURN NULL; END IF;
      idx := substr(s, 2)::bigint;
      len := jsonb_array_length(j);
      IF idx < 0 THEN idx := idx + len; END IF;
      IF idx < 0 OR idx >= len THEN RETURN NULL; END IF;
      j := j -> idx::int;
    END IF;
  END LOOP;
  RETURN j;
END $$;
