# Tests

## invariants.sql

Smoke test for the DB-enforced invariants in SPEC.md §2 and the lifecycle
machinery. Wraps everything in a transaction and rolls back, so it is safe to
run repeatedly against a local stack.

```bash
supabase start
docker exec -i supabase_db_turnout psql -U postgres -d postgres -q \
  < supabase/tests/invariants.sql
```

Thirteen checks, all of which must print PASS. Every negative case catches one
specific SQLSTATE, so an unexpected error fails rather than passing quietly.

This is a smoke test, not the pgTAP suite SPEC.md §10 calls for — that one has
to enumerate every legal transition and a sample of illegal ones. This covers
one path through each invariant.

## rls.sql

Tests I4 by impersonation: each block runs as `authenticated` or `anon` with a
JWT claim set, because the table owner bypasses RLS and a superuser session
would pass every check while the policies did nothing.

```bash
docker exec -i supabase_db_turnout psql -U postgres -d postgres -q \
  < supabase/tests/rls.sql
```

Twenty checks across three roles. Note that some assertions expect a permission
error rather than an empty result — grants and RLS are separate gates, and being
unreachable is the stronger outcome.
