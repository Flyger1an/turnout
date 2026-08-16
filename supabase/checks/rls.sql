-- ============================================================================
-- Turnout — RLS test (SPEC.md §2, I4)
-- ============================================================================
-- The other invariants fail loudly. This one fails silently, by returning a row
-- it should not have, so it is tested by impersonation rather than inspection.
--
-- Runs each block as the `authenticated` (or `anon`) role with a JWT claim set,
-- because the table owner bypasses RLS entirely — a superuser session would
-- pass every check here while the policies did nothing.
--
--   docker exec -i supabase_db_turnout psql -U postgres -d postgres \
--     < supabase/tests/rls.sql
--
-- Ends with a rollback.
-- ============================================================================

begin;

\set ON_ERROR_STOP on

\set coord    '''11111111-1111-1111-1111-111111111111'''
\set volA     '''22222222-2222-2222-2222-222222222222'''
\set volB     '''33333333-3333-3333-3333-333333333333'''

-- ---------------------------------------------------------------------------
-- Fixtures, built as owner (RLS bypassed here on purpose)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  (:coord, 'coordinator@test.local'),
  (:volA,  'vol-a@test.local'),
  (:volB,  'vol-b@test.local');

insert into orgs (id, slug, name, created_by) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'eastside', 'Eastside Food Bank', :coord),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'parks',    'Parks Alliance',     :coord);

-- The coordinator runs Eastside only. Parks is the org they must not see into.
insert into org_members (org_id, user_id, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', :coord, 'owner');

insert into opportunities (id, org_id, kind, status, title, capacity, is_remote, created_by) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
   'event', 'published', 'Published pantry shift', 5, true, :coord),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001',
   'event', 'draft',     'Unannounced gala',       5, true, :coord),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000002',
   'event', 'draft',     'Parks internal plan',    5, true, :coord);

insert into shifts (id, opportunity_id, starts_at, ends_at) values
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001',
   now() + interval '2 days', now() + interval '2 days 2 hours'),
  ('cccccccc-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002',
   now() + interval '5 days', now() + interval '5 days 2 hours'),
  ('cccccccc-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000003',
   now() + interval '6 days', now() + interval '6 days 2 hours');

insert into signups (id, shift_id, user_id, status) values
  ('dddddddd-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', :volA, 'accepted'),
  ('dddddddd-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000001', :volB, 'accepted');

insert into hour_entries (user_id, org_id, minutes, source) values
  (:volA, 'aaaaaaaa-0000-0000-0000-000000000001', 120, 'qr'),
  (:volB, 'aaaaaaaa-0000-0000-0000-000000000001',  90, 'qr');

insert into scheduled_reminders (signup_id, user_id, org_id, kind, send_at) values
  ('dddddddd-0000-0000-0000-000000000002', :volB,
   'aaaaaaaa-0000-0000-0000-000000000001', 'confirm_48h', now());

-- ===========================================================================
-- Volunteer A
-- ===========================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

do $$
declare n integer;
begin
  -- Grants exist and published listings are readable.
  select count(*) into n from opportunities where status = 'published' and org_id in ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002');
  if n <> 1 then raise exception 'FAIL: volunteer sees % published opportunities, want 1', n; end if;
  raise notice 'PASS  volunteer reads published opportunities';

  select count(*) into n from opportunities where status = 'draft' and org_id in ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002');
  if n <> 0 then raise exception 'FAIL: volunteer sees % drafts, want 0', n; end if;
  raise notice 'PASS  volunteer cannot read drafts';

  select count(*) into n from signups;
  if n <> 1 then raise exception 'FAIL: volunteer sees % signups, want only their own', n; end if;
  raise notice 'PASS  volunteer sees only their own signup';

  select count(*) into n from users;
  if n <> 1 then raise exception 'FAIL: volunteer sees % user rows, want 1', n; end if;
  raise notice 'PASS  volunteer sees only their own user row';

  select count(*) into n from hour_entries;
  if n <> 1 then raise exception 'FAIL: volunteer sees % ledger rows, want 1', n; end if;
  raise notice 'PASS  volunteer sees only their own hours';

  select count(*) into n from scheduled_reminders;
  if n <> 0 then raise exception 'FAIL: volunteer sees % of another user''s reminders', n; end if;
  raise notice 'PASS  volunteer cannot read another user''s reminders';
end $$;

-- Cannot sign up on someone else's behalf.
do $$
begin
  begin
    insert into signups (shift_id, user_id, status)
    values ('cccccccc-0000-0000-0000-000000000001',
            '33333333-3333-3333-3333-333333333333', 'accepted');
    raise exception 'FAIL: volunteer inserted a signup for another user';
  exception when insufficient_privilege then
    raise notice 'PASS  volunteer cannot insert a signup for another user';
  end;
end $$;

-- Cannot write to the ledger at all: there is no insert policy.
do $$
begin
  begin
    insert into hour_entries (user_id, org_id, minutes, source)
    values ('22222222-2222-2222-2222-222222222222',
            'aaaaaaaa-0000-0000-0000-000000000001', 600, 'self');
    raise exception 'FAIL: volunteer wrote to the hours ledger';
  exception when insufficient_privilege then
    raise notice 'PASS  volunteer cannot insert into the hours ledger';
  end;
end $$;

-- Self-service status changes must stop at confirm and cancel. A volunteer who
-- can walk their own signup to checked_in and then completed mints their own
-- verified hours, which is the ledger's entire credibility.
do $$
declare s signup_status;
begin
  begin
    update signups set status = 'checked_in', checkin_method = 'qr'
    where id = 'dddddddd-0000-0000-0000-000000000001';
  exception when insufficient_privilege then
    raise notice 'PASS  volunteer cannot self-check-in';
    return;
  end;

  select status into s from signups where id = 'dddddddd-0000-0000-0000-000000000001';
  if s = 'checked_in' then
    raise exception 'FAIL: volunteer checked themselves in (status now %)', s;
  end if;
  raise notice 'PASS  volunteer cannot self-check-in';
end $$;

-- Views must not launder past RLS.
do $$
declare n integer;
begin
  select count(*) into n from shift_fill
  where opportunity_id in ('bbbbbbbb-0000-0000-0000-000000000001',
                           'bbbbbbbb-0000-0000-0000-000000000002',
                           'bbbbbbbb-0000-0000-0000-000000000003');
  if n <> 1 then
    raise exception 'FAIL: shift_fill exposes % shifts to a volunteer, want 1 (the published one)', n;
  end if;
  raise notice 'PASS  shift_fill respects RLS for a volunteer';
end $$;

reset role;

-- ===========================================================================
-- Coordinator (Eastside only)
-- ===========================================================================
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

do $$
declare n integer;
begin
  select count(*) into n from opportunities
  where org_id = 'aaaaaaaa-0000-0000-0000-000000000001' and status = 'draft';
  if n <> 1 then raise exception 'FAIL: coordinator sees % of their own drafts, want 1', n; end if;
  raise notice 'PASS  coordinator reads their own draft';

  select count(*) into n from opportunities
  where org_id = 'aaaaaaaa-0000-0000-0000-000000000002';
  if n <> 0 then raise exception 'FAIL: coordinator sees % opportunities of an org they do not run', n; end if;
  raise notice 'PASS  coordinator cannot read another org''s draft';

  select count(*) into n from signups
  where shift_id = 'cccccccc-0000-0000-0000-000000000001';
  if n <> 2 then raise exception 'FAIL: coordinator sees % signups on their shift, want 2', n; end if;
  raise notice 'PASS  coordinator reads the full roster of their shift';

  select count(*) into n from hour_entries
  where org_id = 'aaaaaaaa-0000-0000-0000-000000000001';
  if n <> 2 then raise exception 'FAIL: coordinator sees % ledger rows for their org, want 2', n; end if;
  raise notice 'PASS  coordinator reads their org''s hours';
end $$;

reset role;

-- ===========================================================================
-- Anonymous
-- ===========================================================================
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

do $$
declare n integer;
begin
  select count(*) into n from opportunities where status = 'published' and org_id in ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002');
  if n <> 1 then raise exception 'FAIL: anon sees % published opportunities, want 1', n; end if;
  raise notice 'PASS  anon can browse published listings';

  select count(*) into n from opportunities where status = 'draft' and org_id in ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002');
  if n <> 0 then raise exception 'FAIL: anon sees % drafts', n; end if;
  raise notice 'PASS  anon cannot read drafts';

end $$;

-- These three are blocked one layer earlier than RLS: anon holds no grant at
-- all, so the table is unreachable rather than merely filtered. Assert the
-- denial, since "zero rows" would be the weaker outcome.
do $$
begin
  begin
    perform count(*) from signups;
    raise exception 'FAIL: anon reached signups';
  exception when insufficient_privilege then
    raise notice 'PASS  anon has no grant on signups';
  end;

  begin
    perform count(*) from users;
    raise exception 'FAIL: anon reached users';
  exception when insufficient_privilege then
    raise notice 'PASS  anon has no grant on users';
  end;

  begin
    perform count(*) from hour_entries;
    raise exception 'FAIL: anon reached hour_entries';
  exception when insufficient_privilege then
    raise notice 'PASS  anon has no grant on the hours ledger';
  end;
end $$;

reset role;

rollback;
