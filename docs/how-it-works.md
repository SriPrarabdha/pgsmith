# How it works

## The contract

For the same input, pgsmith returns what Flagsmith's reference engine returns from
`flag_engine.get_evaluation_result(context)`: the same enabled state, value, variant and reason for every flag, and
the same segments. The input format is the engine's `EvaluationContext`, the format of every case in Flagsmith's
[engine-test-data](https://github.com/Flagsmith/engine-test-data). One loader serves both the test suite and
production.

Matching the engine means matching Python, detail by detail. A few of the details:

- Trait strings that look like numbers are numbers (`"30"` compares as 30).
- Comparisons cast the condition value to the trait's type, with Python's `int()`, `float()` and `str()`.
- SemVer conditions use python-semver's precedence.
- `REGEX` is `re.match`, translated to Postgres's regex dialect.
- `MODULO` uses Python's float `%`.
- Splits use the engine's MD5 bucketing, including its rare re-hash.
- Flag dependencies (`$.flags.<name>.enabled`) are resolved lazily, with cycle detection.

## Snapshots

A load turns a context into an immutable **snapshot**: rows in `flagsmith.segment`, `rule`, `condition`,
`feature_context`, `variant` and `identity_override`, with every condition value parsed once in advance. A load is one
transaction that flips a single pointer, `environment.current_snapshot`, so a statement sees one configuration or the
other. An unchanged context is recognised by its hash and not loaded again.

## Two tiers

- **The interpreter** (PL/pgSQL) evaluates any snapshot, including flag dependencies. It is the correctness baseline.
- **The compiler** turns each snapshot into a SQL-standard function: segments are evaluated once per identity,
  conditions are ordered cheapest first, overrides are picked from constant arrays, split hashes are reduced in bigint
  arithmetic, and constant `IN` lists are hashed. The planner inlines the function into the calling query, prunes the
  features it does not need, and runs it in parallel.

Both tiers are tested against the corpus and against each other. `flagsmith.flags()` and the per-environment
functions point at the compiled function when there is one, and at the interpreter otherwise.

## Proof

| Oracle | Result |
|---|---|
| engine-test-data v3.13.2 (230 cases) | 230/230 on the interpreter; 211/230 compiled, and the other 19 (flag dependencies) run on the interpreter by design |
| The official Python engine, on random contexts (Hypothesis) | 5,000 contexts on the interpreter and 3,069 on the compiled tier, 0 differences |
| The official SDK's mapper, against the SQL mapper | 5,000 random and 5,000 damaged documents: identical output, and failures in the same places; plus engine-test-data's mapper case |
| A live self-hosted Flagsmith, through the official SDK | 10,000 identities × every flag × both tiers, 0 mismatches |

The random contexts mix nested ALL/ANY/NONE rules, every operator, big integers, Unicode, SemVer pre-releases,
numeric-looking strings and flag-dependency cycles. The building blocks are also fuzzed against Python itself
(`int()`, `float()`, `repr(float)`, `%`, `re.match`, python-semver, the hash).

This is strong evidence, not a formal proof.

## Known divergences

Where Python raises an exception, the SDK call fails. pgsmith instead evaluates the condition as false and records
an `error` warning in these cases:

- `MODULO` with a zero divisor;
- a `REGEX` pattern Python rejects;
- an `IN` value that is neither a string nor an array.

Also:

- `REGEX` patterns Postgres cannot express (atomic groups, possessive quantifiers, conditional groups, scoped
  case-insensitivity, repeat counts over 255, backreferences to repeated groups) are reported as `regex_unportable`.
  The environment's `regex_policy` decides what happens: `reject` (the default: keep serving the previous snapshot),
  `false`, or `approximate`.
- Non-singular JSONPath properties (`$.identity.traits.*`, filters, descendants) are evaluated as not set, with a
  warning: Python takes the first match in dict insertion order, which a `jsonb` trait map does not keep.
- Traits passed as `jsonb` lose the difference between `1e5` and `100000` (Python reads the first as a float).
- The Unicode tables (`\d`, `\w`, `int()` digits) are generated from Python 3.12 (Unicode 15.0).
- The SQL mapper accepts multivariate `mv_fs_value_uuid` values in the spellings Flagsmith writes. Python's
  `int(x, 16)` also takes whitespace, `+`, `_` and `0x`, which Flagsmith never writes.

## Source map

| File | |
|---|---|
| `extension/sql/00_schema.sql` | tables and types |
| `10_pycompat.sql` to `14_jsonpath.sql` | Python's `int()`, `float()`, `repr()` and `%`, the hash, SemVer, the regex translator, JSONPath |
| `20_loader.sql` | contexts into snapshots |
| `30_interp.sql` | the interpreter |
| `40_compile.sql` | the compiler |
| `50_api.sql`, `60_ops.sql` | the public API; publishing, pin, health, garbage collection |
| `70_flagshift.sql` | plans in SQL |
| `80_mapper.sql` to `83_access.sql` | the document mapper, in-database sync, the exposure queue, access for the tools |
| `90_grants.sql` | roles and privileges |
