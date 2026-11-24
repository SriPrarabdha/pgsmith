-- REGEX: the reference evaluates re.compile(value).match(str(trait)), Python `re`
-- syntax anchored at the start. This translates a Python pattern into a Postgres
-- ARE that matches exactly the same strings:
--   * anchored: ^(?: ... )
--   * '.' excludes '\n' unless DOTALL; '$' is "end, or before a final newline";
--     MULTILINE '^'/'$' work per line
--   * \d \s \w \b and their negations use Python's Unicode classes (generated
--     tables), not the database locale
--   * named groups and backreferences are renumbered (ARE does not capture
--     inside lookarounds)
--   * Python-only constructs (atomic groups, possessive quantifiers, conditional
--     groups, scoped case-insensitivity, repeat counts over 255) are reported as
--     'unsupported'; patterns Python itself rejects are reported as 'invalid'.

CREATE FUNCTION flagsmith._re_chr(cp int) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT CASE WHEN cp <= 65535 THEN '\u' || lpad(to_hex(cp), 4, '0')
              ELSE '\U' || lpad(to_hex(cp), 8, '0') END
$$;

-- bracket-expression body for a Python class shorthand
CREATE FUNCTION flagsmith._re_shorthand(c text, ascii_only boolean) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT CASE
    WHEN NOT ascii_only THEN flagsmith._re_class(c)
    WHEN c = 'd' THEN '0-9'
    WHEN c = 'w' THEN 'a-zA-Z0-9_'
    WHEN c = 's' THEN '\u0009-\u000d '
    WHEN c = 'D' THEN '\u0001-/:-\U0010ffff'
    WHEN c = 'W' THEN '\u0001-/:-@[-^`{-\U0010ffff'
    WHEN c = 'S' THEN '\u0001-\u0008\u000e-\u001f!-\U0010ffff'
  END
$$;

-- Parse one escape starting at chars[i] = '\'. Returns kind:
--   'char' (cp), 'class' (cls), 'anchor' (cls in A Z b B), 'backref' (cp = group),
--   'named_backref' never here, 'error', 'unsupported'.
CREATE FUNCTION flagsmith._re_escape(chars text[], i int, in_class boolean,
  OUT kind text, OUT cp int, OUT cls text, OUT next_i int, OUT err text)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  n int := cardinality(chars);
  c text;
  hex text;
  j int;
  digs text;
BEGIN
  next_i := i + 2;
  IF i + 1 > n THEN
    kind := 'error'; err := 'bad escape (end of pattern)'; RETURN;
  END IF;
  c := chars[i + 1];
  IF c IN ('d', 'D', 's', 'S', 'w', 'W') THEN
    kind := 'class'; cls := c; RETURN;
  END IF;
  IF c IN ('a', 'f', 'n', 'r', 't', 'v') THEN
    kind := 'char';
    cp := CASE c WHEN 'a' THEN 7 WHEN 'f' THEN 12 WHEN 'n' THEN 10 WHEN 'r' THEN 13 WHEN 't' THEN 9 ELSE 11 END;
    RETURN;
  END IF;
  IF c = 'b' THEN
    IF in_class THEN kind := 'char'; cp := 8; ELSE kind := 'anchor'; cls := 'b'; END IF;
    RETURN;
  END IF;
  IF c IN ('B', 'A', 'Z') THEN
    IF in_class THEN kind := 'error'; err := 'bad escape \' || c; ELSE kind := 'anchor'; cls := c; END IF;
    RETURN;
  END IF;
  IF c IN ('x', 'u', 'U') THEN
    j := CASE c WHEN 'x' THEN 2 WHEN 'u' THEN 4 ELSE 8 END;
    hex := array_to_string(chars[i + 2 : i + 1 + j], '');
    IF length(hex) <> j OR hex !~ '^[0-9a-fA-F]+$' THEN
      kind := 'error'; err := 'incomplete escape \' || c; RETURN;
    END IF;
    IF c = 'U' AND ('x' || hex)::bit(32)::bigint > 1114111 THEN
      kind := 'error'; err := 'bad escape \U'; RETURN;
    END IF;
    kind := 'char';
    cp := ('x' || lpad(hex, 8, '0'))::bit(32)::int;
    next_i := i + 2 + j;
    IF cp = 0 OR cp BETWEEN 55296 AND 57343 THEN
      kind := 'unsupported'; err := 'NUL or surrogate escape';
    END IF;
    RETURN;
  END IF;
  IF c = 'N' THEN
    kind := 'unsupported'; err := '\N{...} named characters'; RETURN;
  END IF;
  IF c ~ '^[0-9]$' THEN
    -- octal: \0, \0n, \0nn, or three octal digits; otherwise a group reference
    IF c = '0' THEN
      digs := '0';
      j := i + 2;
      WHILE j <= n AND length(digs) < 3 AND chars[j] ~ '^[0-7]$' LOOP
        digs := digs || chars[j]; j := j + 1;
      END LOOP;
      kind := 'char'; cp := flagsmith._re_octal(digs); next_i := j;
      IF cp = 0 THEN kind := 'unsupported'; err := 'NUL escape'; END IF;
      RETURN;
    END IF;
    IF in_class THEN
      IF c ~ '^[0-7]$' THEN
        digs := c; j := i + 2;
        WHILE j <= n AND length(digs) < 3 AND chars[j] ~ '^[0-7]$' LOOP
          digs := digs || chars[j]; j := j + 1;
        END LOOP;
        cp := flagsmith._re_octal(digs);
        IF cp > 255 THEN kind := 'error'; err := 'octal escape out of range'; RETURN; END IF;
        kind := 'char'; next_i := j; RETURN;
      END IF;
      kind := 'error'; err := 'bad escape \' || c; RETURN;
    END IF;
    IF i + 3 <= n AND c ~ '^[0-7]$' AND chars[i + 2] ~ '^[0-7]$' AND chars[i + 3] ~ '^[0-7]$' THEN
      cp := flagsmith._re_octal(c || chars[i + 2] || chars[i + 3]);
      IF cp > 255 THEN kind := 'error'; err := 'octal escape out of range'; RETURN; END IF;
      kind := 'char'; next_i := i + 4; RETURN;
    END IF;
    digs := c;
    IF i + 2 <= n AND chars[i + 2] ~ '^[0-9]$' THEN
      digs := digs || chars[i + 2]; next_i := i + 3;
    END IF;
    kind := 'backref'; cp := digs::int; RETURN;
  END IF;
  IF c ~ '^[A-Za-z]$' THEN
    kind := 'error'; err := 'bad escape \' || c; RETURN;
  END IF;
  kind := 'char'; cp := ascii(c);
END $$;

CREATE FUNCTION flagsmith._re_octal(d text) RETURNS int
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT sum((substr(d, k, 1)::int) * (8 ^ (length(d) - k))::int)::int
  FROM generate_series(1, length(d)) k
$$;

-- literal character outside a bracket expression
CREATE FUNCTION flagsmith._re_lit(cp int) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT CASE
    WHEN cp BETWEEN 48 AND 57 OR cp BETWEEN 65 AND 90 OR cp BETWEEN 97 AND 122 THEN chr(cp)
    ELSE flagsmith._re_chr(cp) END
$$;

CREATE FUNCTION flagsmith.py_regex_to_are(p text,
  OUT pattern text, OUT status text, OUT detail text)
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  chars text[] := CASE WHEN p = '' THEN '{}'::text[] ELSE regexp_split_to_array(p, '') END;
  n int := cardinality(chars);
  i int := 1;
  c text;
  out text := '';
  -- flags
  f_i boolean := false; f_m boolean := false; f_s boolean := false;
  f_x boolean := false; f_a boolean := false;
  fl text;
  -- groups: stacks
  g_kind text[] := '{}';       -- 'cap' | 'noncap' | 'look' | 'scoped'
  g_saved text[] := '{}';      -- saved m/s/x flags for scoped groups
  g_pynum int[] := '{}';
  g_outpos int[] := '{}';      -- length of `out` where each open group started
  g_first int[] := '{}';       -- first python group number opened inside each open group
  atom_g_first int;            -- python groups inside the last atom (when it is a group)
  atom_g_last int;
  quantified boolean[] := '{}';  -- python group sits under a quantifier: backreferences are unsupported
  atom_start int := 0;         -- length of `out` before the last atom
  atom_is_look boolean := false;
  qmin numeric;
  look_depth int := 0;
  py_groups int := 0;
  are_groups int := 0;
  cap_map int[] := '{}';       -- python group number -> ARE group number (NULL: not capturing in ARE)
  closed boolean[] := '{}';
  names text[] := '{}';
  name_num int[] := '{}';
  -- atoms
  can_repeat boolean := false;
  last_quant boolean := false;
  esc record;
  -- classes
  negate boolean;
  body text;
  start_i int;
  lo int; hi int;
  esc2 record;
  that text;
  -- quantifiers
  qlo text; qhi text; k int; nm text; gnum int;
  at_start boolean := true;
BEGIN
  status := 'ok';
  WHILE i <= n LOOP
    c := chars[i];

    -- verbose mode: whitespace and comments
    IF f_x AND c IN (' ', E'\t', E'\n', E'\r', E'\x0b', E'\x0c') THEN
      i := i + 1; CONTINUE;
    END IF;
    IF f_x AND c = '#' THEN
      WHILE i <= n AND chars[i] <> E'\n' LOOP i := i + 1; END LOOP;
      CONTINUE;
    END IF;

    -- quantifiers
    IF c IN ('*', '+', '?') OR (c = '{' AND flagsmith._re_is_bound(chars, i)) THEN
      IF NOT can_repeat THEN
        status := 'invalid';
        detail := CASE WHEN last_quant THEN 'multiple repeat' ELSE 'nothing to repeat' END;
        RETURN;
      END IF;
      IF atom_is_look THEN
        -- Python repeats an assertion; Postgres cannot. Zero repetitions allowed: it
        -- always passes, so drop it; otherwise one repetition is the same as the assertion.
        IF c = '{' THEN
          k := i + 1; qlo := '';
          WHILE chars[k] ~ '^[0-9]$' LOOP qlo := qlo || chars[k]; k := k + 1; END LOOP;
          WHILE chars[k] <> '}' LOOP k := k + 1; END LOOP;
          qmin := coalesce(nullif(qlo, '')::numeric, 0);
          i := k + 1;
        ELSE
          qmin := CASE WHEN c = '+' THEN 1 ELSE 0 END;
          i := i + 1;
        END IF;
        IF i <= n AND chars[i] = '?' THEN i := i + 1;
        ELSIF i <= n AND chars[i] = '+' THEN status := 'unsupported'; detail := 'possessive quantifier'; RETURN;
        END IF;
        IF qmin = 0 THEN out := left(out, atom_start); END IF;
        can_repeat := false; last_quant := true; atom_is_look := false; at_start := false;
        CONTINUE;
      END IF;
      IF atom_g_first IS NOT NULL AND atom_g_last >= atom_g_first THEN
        FOR k IN atom_g_first .. atom_g_last LOOP quantified[k] := true; END LOOP;
      END IF;
      IF c = '{' THEN
        k := i + 1; qlo := ''; qhi := NULL;
        WHILE chars[k] ~ '^[0-9]$' LOOP qlo := qlo || chars[k]; k := k + 1; END LOOP;
        IF chars[k] = ',' THEN
          k := k + 1; qhi := '';
          WHILE chars[k] ~ '^[0-9]$' LOOP qhi := qhi || chars[k]; k := k + 1; END LOOP;
        END IF;
        i := k + 1;   -- past '}'
        IF qhi IS NULL THEN
          IF qlo::numeric > 255 THEN status := 'unsupported'; detail := 'repeat count over 255'; RETURN; END IF;
          out := out || '{' || qlo::int || '}';
        ELSIF qlo = '' AND qhi = '' THEN
          out := out || '*';
        ELSE
          IF (qlo <> '' AND qlo::numeric > 255) OR (qhi <> '' AND qhi::numeric > 255) THEN
            status := 'unsupported'; detail := 'repeat count over 255'; RETURN;
          END IF;
          IF qlo <> '' AND qhi <> '' AND qhi::numeric < qlo::numeric THEN
            status := 'invalid'; detail := 'min repeat greater than max repeat'; RETURN;
          END IF;
          out := out || '{' || coalesce(nullif(qlo, ''), '0')::int || ','
                 || CASE WHEN qhi = '' THEN '' ELSE qhi::int::text END || '}';
        END IF;
      ELSE
        out := out || c;
        i := i + 1;
      END IF;
      IF i <= n AND chars[i] = '?' THEN
        out := out || '?'; i := i + 1;
      ELSIF i <= n AND chars[i] = '+' THEN
        status := 'unsupported'; detail := 'possessive quantifier'; RETURN;
      END IF;
      can_repeat := false; last_quant := true; at_start := false;
      CONTINUE;
    END IF;
    last_quant := false;
    atom_start := length(out);
    atom_is_look := false;
    atom_g_first := NULL; atom_g_last := NULL;

    IF c = '(' THEN
      IF i + 1 <= n AND chars[i + 1] = '?' THEN
        c := chars[i + 2];
        IF c = ':' THEN
          out := out || '(?:';
          g_kind := g_kind || 'noncap'::text; g_outpos := g_outpos || atom_start; g_first := g_first || (py_groups + 1); g_saved := g_saved || NULL::text; g_pynum := g_pynum || NULL::int;
          i := i + 3; can_repeat := false; at_start := false; CONTINUE;
        ELSIF c = 'P' AND chars[i + 3] = '<' THEN
          k := i + 4; nm := '';
          WHILE k <= n AND chars[k] <> '>' LOOP nm := nm || chars[k]; k := k + 1; END LOOP;
          IF k > n OR nm !~ '^[A-Za-z_\u00aa-\U0010ffff][A-Za-z0-9_\u00aa-\U0010ffff]*$' THEN
            status := 'invalid'; detail := 'bad group name'; RETURN;
          END IF;
          IF nm = ANY (names) THEN status := 'invalid'; detail := 'redefinition of group name'; RETURN; END IF;
          py_groups := py_groups + 1;
          names := names || nm; name_num := name_num || py_groups;
          IF look_depth > 0 THEN
            out := out || '(?:'; cap_map := cap_map || NULL::int;
          ELSE
            out := out || '('; are_groups := are_groups + 1; cap_map := cap_map || are_groups;
          END IF;
          closed := closed || false;
          g_kind := g_kind || 'cap'::text; g_outpos := g_outpos || atom_start; g_first := g_first || py_groups; g_saved := g_saved || NULL::text; g_pynum := g_pynum || py_groups;
          i := k + 1; can_repeat := false; at_start := false; CONTINUE;
        ELSIF c = 'P' AND chars[i + 3] = '=' THEN
          k := i + 4; nm := '';
          WHILE k <= n AND chars[k] <> ')' LOOP nm := nm || chars[k]; k := k + 1; END LOOP;
          gnum := name_num[array_position(names, nm)];
          IF k > n OR gnum IS NULL THEN status := 'invalid'; detail := 'unknown group name'; RETURN; END IF;
          IF NOT closed[gnum] THEN status := 'invalid'; detail := 'cannot refer to an open group'; RETURN; END IF;
          IF cap_map[gnum] IS NULL OR look_depth > 0 THEN
            status := 'unsupported'; detail := 'backreference into or inside a lookaround'; RETURN;
          END IF;
          IF coalesce(quantified[gnum], false) THEN
            status := 'unsupported'; detail := 'backreference to a repeated group'; RETURN;
          END IF;
          out := out || '(?:\' || cap_map[gnum] || ')';
          i := k + 1; can_repeat := true; at_start := false; CONTINUE;
        ELSIF c = '#' THEN
          k := i + 3;
          WHILE k <= n AND chars[k] <> ')' LOOP k := k + 1; END LOOP;
          IF k > n THEN status := 'invalid'; detail := 'missing ), unterminated comment'; RETURN; END IF;
          i := k + 1; CONTINUE;
        ELSIF c IN ('=', '!') OR (c = '<' AND chars[i + 3] IN ('=', '!')) THEN
          IF c = '<' THEN
            out := out || '(?<' || chars[i + 3]; i := i + 4;
          ELSE
            out := out || '(?' || c; i := i + 3;
          END IF;
          look_depth := look_depth + 1;
          g_kind := g_kind || 'look'::text; g_outpos := g_outpos || atom_start; g_first := g_first || (py_groups + 1); g_saved := g_saved || NULL::text; g_pynum := g_pynum || NULL::int;
          can_repeat := false; at_start := false; CONTINUE;
        ELSIF c = '(' THEN
          status := 'unsupported'; detail := 'conditional group'; RETURN;
        ELSIF c = '>' THEN
          status := 'unsupported'; detail := 'atomic group'; RETURN;
        ELSIF c ~ '^[aiLmsux-]$' THEN
          k := i + 2; fl := '';
          WHILE k <= n AND chars[k] ~ '^[aiLmsux-]$' LOOP fl := fl || chars[k]; k := k + 1; END LOOP;
          IF k > n THEN status := 'invalid'; detail := 'missing -, : or )'; RETURN; END IF;
          IF chars[k] = ')' THEN
            -- global flags: only at the start of the pattern
            IF NOT at_start OR strpos(fl, '-') > 0 THEN
              status := 'invalid'; detail := 'global flags not at the start of the expression'; RETURN;
            END IF;
            IF strpos(fl, 'L') > 0 THEN status := 'invalid'; detail := 'bad inline flags: cannot use ''L'' flag with a str pattern'; RETURN; END IF;
            IF strpos(fl, 'a') > 0 AND strpos(fl, 'u') > 0 THEN status := 'invalid'; detail := 'bad inline flags: flags ''a'' and ''u'' are incompatible'; RETURN; END IF;
            f_i := f_i OR strpos(fl, 'i') > 0; f_m := f_m OR strpos(fl, 'm') > 0;
            f_s := f_s OR strpos(fl, 's') > 0; f_x := f_x OR strpos(fl, 'x') > 0;
            f_a := f_a OR strpos(fl, 'a') > 0;
            i := k + 1; CONTINUE;
          ELSIF chars[k] = ':' THEN
            -- scoped flags: s, m and x are emulated; others are not expressible in ARE
            IF fl ~ '[aiLu]' THEN
              status := 'unsupported'; detail := 'scoped inline flags (?' || fl || ':...)'; RETURN;
            END IF;
            g_kind := g_kind || 'scoped'::text; g_outpos := g_outpos || atom_start; g_first := g_first || (py_groups + 1);
            g_saved := g_saved || (f_m::int::text || f_s::int::text || f_x::int::text);
            g_pynum := g_pynum || NULL::int;
            IF split_part(fl, '-', 1) ~ 'm' THEN f_m := true; END IF;
            IF split_part(fl, '-', 1) ~ 's' THEN f_s := true; END IF;
            IF split_part(fl, '-', 1) ~ 'x' THEN f_x := true; END IF;
            IF split_part(fl, '-', 2) ~ 'm' THEN f_m := false; END IF;
            IF split_part(fl, '-', 2) ~ 's' THEN f_s := false; END IF;
            IF split_part(fl, '-', 2) ~ 'x' THEN f_x := false; END IF;
            out := out || '(?:';
            i := k + 1; can_repeat := false; at_start := false; CONTINUE;
          ELSE
            status := 'invalid'; detail := 'unknown flag'; RETURN;
          END IF;
        ELSE
          status := 'invalid'; detail := 'unknown extension ?' || coalesce(c, ''); RETURN;
        END IF;
      END IF;
      -- plain capturing group
      py_groups := py_groups + 1;
      IF look_depth > 0 THEN
        out := out || '(?:'; cap_map := cap_map || NULL::int;
      ELSE
        out := out || '('; are_groups := are_groups + 1; cap_map := cap_map || are_groups;
      END IF;
      closed := closed || false;
      g_kind := g_kind || 'cap'::text; g_outpos := g_outpos || atom_start; g_first := g_first || py_groups; g_saved := g_saved || NULL::text; g_pynum := g_pynum || py_groups;
      i := i + 1; can_repeat := false; at_start := false; CONTINUE;
    END IF;

    at_start := false;

    IF c = ')' THEN
      IF cardinality(g_kind) = 0 THEN status := 'invalid'; detail := 'unbalanced parenthesis'; RETURN; END IF;
      k := cardinality(g_kind);
      IF g_kind[k] = 'look' THEN look_depth := look_depth - 1; END IF;
      IF g_kind[k] = 'cap' THEN closed[g_pynum[k]] := true; END IF;
      IF g_kind[k] = 'scoped' THEN
        f_m := substr(g_saved[k], 1, 1) = '1';
        f_s := substr(g_saved[k], 2, 1) = '1';
        f_x := substr(g_saved[k], 3, 1) = '1';
      END IF;
      can_repeat := true;
      atom_start := g_outpos[k];
      atom_is_look := g_kind[k] = 'look';
      atom_g_first := g_first[k]; atom_g_last := py_groups;
      g_kind := g_kind[1 : k - 1]; g_saved := g_saved[1 : k - 1]; g_pynum := g_pynum[1 : k - 1];
      g_outpos := g_outpos[1 : k - 1]; g_first := g_first[1 : k - 1];
      out := out || ')';
      i := i + 1; CONTINUE;
    END IF;

    IF c = '|' THEN
      out := out || '|'; i := i + 1; can_repeat := false; CONTINUE;
    END IF;

    IF c = '.' THEN
      out := out || CASE WHEN f_s THEN '[\u0001-\U0010ffff]' ELSE '[^\u000a]' END;
      i := i + 1; can_repeat := true; CONTINUE;
    END IF;
    IF c = '^' THEN
      out := out || CASE WHEN f_m THEN '(?:^|(?<=\u000a))' ELSE '^' END;
      i := i + 1; can_repeat := false; CONTINUE;
    END IF;
    IF c = '$' THEN
      out := out || CASE WHEN f_m THEN '(?=\u000a|$)' ELSE '(?=\u000a?$)' END;
      i := i + 1; can_repeat := false; CONTINUE;
    END IF;

    IF c = '[' THEN
      i := i + 1;
      negate := false;
      IF i <= n AND chars[i] = '^' THEN negate := true; i := i + 1; END IF;
      start_i := i;
      body := '';
      LOOP
        IF i > n THEN status := 'invalid'; detail := 'unterminated character set'; RETURN; END IF;
        c := chars[i];
        IF c = ']' AND i <> start_i THEN i := i + 1; EXIT; END IF;
        IF c = '\' THEN
          esc := flagsmith._re_escape(chars, i, true);
          IF esc.kind IN ('error', 'unsupported') THEN
            status := CASE esc.kind WHEN 'error' THEN 'invalid' ELSE 'unsupported' END;
            detail := esc.err; RETURN;
          END IF;
          i := esc.next_i;
        ELSE
          SELECT 'char'::text AS kind, ascii(c) AS cp, NULL::text AS cls, i + 1 AS next_i, NULL::text AS err INTO esc;
          i := i + 1;
        END IF;
        IF i <= n AND chars[i] = '-' THEN
          IF i + 1 > n THEN status := 'invalid'; detail := 'unterminated character set'; RETURN; END IF;
          that := chars[i + 1];
          IF that = ']' THEN
            body := body || CASE WHEN esc.kind = 'class' THEN flagsmith._re_shorthand(esc.cls, f_a)
                                 ELSE flagsmith._re_chr(esc.cp) END || flagsmith._re_chr(45);
            i := i + 2; EXIT;
          END IF;
          IF that = '\' THEN
            esc2 := flagsmith._re_escape(chars, i + 1, true);
            IF esc2.kind IN ('error', 'unsupported') THEN
              status := CASE esc2.kind WHEN 'error' THEN 'invalid' ELSE 'unsupported' END;
              detail := esc2.err; RETURN;
            END IF;
            i := esc2.next_i;
          ELSE
            SELECT 'char'::text AS kind, ascii(that) AS cp, NULL::text AS cls, i + 2 AS next_i, NULL::text AS err INTO esc2;
            i := i + 2;
          END IF;
          IF esc.kind <> 'char' OR esc2.kind <> 'char' THEN
            status := 'invalid'; detail := 'bad character range'; RETURN;
          END IF;
          lo := esc.cp; hi := esc2.cp;
          IF hi < lo THEN status := 'invalid'; detail := 'bad character range'; RETURN; END IF;
          IF lo = 0 THEN lo := 1; END IF;
          IF lo <= hi THEN
            body := body || flagsmith._re_chr(lo) || '-' || flagsmith._re_chr(hi);
          END IF;
        ELSE
          body := body || CASE WHEN esc.kind = 'class' THEN flagsmith._re_shorthand(esc.cls, f_a)
                               ELSE flagsmith._re_chr(esc.cp) END;
        END IF;
      END LOOP;
      IF body = '' THEN
        -- only NUL: never matches (or always, if negated)
        out := out || CASE WHEN negate THEN '[\u0001-\U0010ffff]' ELSE '(?!)' END;
      ELSE
        out := out || '[' || CASE WHEN negate THEN '^' ELSE '' END || body || ']';
      END IF;
      can_repeat := true;
      CONTINUE;
    END IF;

    IF c = '\' THEN
      esc := flagsmith._re_escape(chars, i, false);
      IF esc.kind IN ('error', 'unsupported') THEN
        status := CASE esc.kind WHEN 'error' THEN 'invalid' ELSE 'unsupported' END;
        detail := esc.err; RETURN;
      END IF;
      i := esc.next_i;
      CASE esc.kind
        WHEN 'char' THEN
          out := out || flagsmith._re_lit(esc.cp); can_repeat := true;
        WHEN 'class' THEN
          out := out || '[' || flagsmith._re_shorthand(esc.cls, f_a) || ']'; can_repeat := true;
        WHEN 'anchor' THEN
          can_repeat := false;
          IF esc.cls = 'A' THEN out := out || '\A';
          ELSIF esc.cls = 'Z' THEN out := out || '\Z';
          ELSE
            body := flagsmith._re_shorthand('w', f_a);
            out := out || CASE esc.cls
              WHEN 'b' THEN '(?:(?<=[' || body || '])(?![' || body || '])|(?<![' || body || '])(?=[' || body || ']))'
              -- \B: not a boundary, and (Python <= 3.13) never in an empty string
              ELSE '(?:(?=[\u0001-\U0010ffff])|(?<=[\u0001-\U0010ffff]))'
                   || '(?:(?<=[' || body || '])(?=[' || body || '])|(?<![' || body || '])(?![' || body || ']))' END;
          END IF;
        WHEN 'backref' THEN
          IF esc.cp > py_groups THEN status := 'invalid'; detail := 'invalid group reference ' || esc.cp; RETURN; END IF;
          IF NOT closed[esc.cp] THEN status := 'invalid'; detail := 'cannot refer to an open group'; RETURN; END IF;
          IF cap_map[esc.cp] IS NULL OR look_depth > 0 THEN
            status := 'unsupported'; detail := 'backreference into or inside a lookaround'; RETURN;
          END IF;
          IF coalesce(quantified[esc.cp], false) THEN
            status := 'unsupported'; detail := 'backreference to a repeated group'; RETURN;
          END IF;
          out := out || '(?:\' || cap_map[esc.cp] || ')';
          can_repeat := true;
      END CASE;
      CONTINUE;
    END IF;

    -- literal (a '{' that does not start a bound lands here too)
    out := out || flagsmith._re_lit(ascii(c));
    i := i + 1; can_repeat := true;
  END LOOP;

  IF cardinality(g_kind) > 0 THEN
    status := 'invalid'; detail := 'missing ), unterminated subpattern'; RETURN;
  END IF;
  pattern := CASE WHEN f_i THEN '(?i)' ELSE '' END || '^(?:' || out || ')';
END $$;

-- Is chars[i] = '{' the start of a valid Python repeat bound: {m}, {m,}, {,n}, {m,n}, {,}?
CREATE FUNCTION flagsmith._re_is_bound(chars text[], i int) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE k int := i + 1; n int := cardinality(chars);
BEGIN
  IF k <= n AND chars[k] = '}' THEN RETURN false; END IF;
  WHILE k <= n AND chars[k] ~ '^[0-9]$' LOOP k := k + 1; END LOOP;
  IF k <= n AND chars[k] = ',' THEN
    k := k + 1;
    WHILE k <= n AND chars[k] ~ '^[0-9]$' LOOP k := k + 1; END LOOP;
  END IF;
  RETURN k <= n AND chars[k] = '}';
END $$;

-- Does a translated pattern compile in Postgres?
CREATE FUNCTION flagsmith._re_compiles(are text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
BEGIN
  PERFORM '' ~ are;
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END $$;

-- Python re.match(p, s) is not None, for patterns that translate.
CREATE FUNCTION flagsmith.py_re_match(p text, s text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE t record;
BEGIN
  t := flagsmith.py_regex_to_are(p);
  IF t.status <> 'ok' THEN RETURN NULL; END IF;
  RETURN s ~ t.pattern;
END $$;
