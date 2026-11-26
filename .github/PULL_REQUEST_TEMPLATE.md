## What and why

<!-- What does this change, and why? Link the issue if there is one. -->

## Checklist

- [ ] `make test` passes (engine corpus on both tiers, properties, security)
- [ ] Behaviour that changes evaluation is covered by a test (a corpus-style case or a fuzz property)
- [ ] New SQL functions resolve no names through the caller's `search_path` (`BEGIN ATOMIC`, or `SET search_path`)
- [ ] A new SECURITY DEFINER function is granted by name in `90_grants.sql` and listed in `test_security.py`
- [ ] Docs updated (`docs/`, `README.md`, `CHANGELOG.md`)
