-- ============================================================================
-- Turnout — invariant smoke test
-- ============================================================================
-- Exercises the DB-enforced invariants from SPEC.md §2 plus the lifecycle
-- machinery. Every negative case catches one specific SQLSTATE, so a wrong
-- error is a failure rather than a silent pass.
--
--   docker exec -i supabase_db_turnout psql -U postgres -d postgres \
--     < supabase/tests/invariants.sql
--
-- Ends with a rollback: leaves no rows behind.
-- ============================================================================

begin;

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email)
values ('11111111-1111-1111-1111-111111111111', 'coordinator@test.local'),
       ('22222222-2222-2222-2222-222222222222', 'volunteer@test.local'),
       ('33333333-3333-3333-3333-333333333333', 'other@test.local');

do $$
declare n integer;
begin
  select count(*) into n from public.users
  where id in ('11111111-1111-1111-1111-111111111111',
               '22222222-2222-2222-2222-222222222222',
               '33333333-3333-3333-3333-333333333333');
  if n <> 3 then
    raise exception 'FAIL: handle_new_auth_user did not mirror all 3 users (got %)', n;
  end if;
  raise notice 'PASS  auth.users -> public.users trigger';
end $$;

insert into orgs (id, slug, name, created_by)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'eastside', 'Eastside Food Bank',
        '11111111-1111-1111-1111-111111111111'),
       ('aaaaaaaa-0000-0000-0000-000000000002', 'parks', 'Parks Alliance',
        '11111111-1111-1111-1111-111111111111');

insert into org_members (org_id, user_id, role)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'owner');

-- ---------------------------------------------------------------------------
-- active_org_id must be a real membership (M1, org switcher)
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update users set active_org_id = 'aaaaaaaa-0000-0000-0000-000000000002'
    where id = '11111111-1111-1111-1111-111111111111';
    raise exception 'FAIL: active_org_id accepted a non-membership';
  exception when insufficient_privilege then
    raise notice 'PASS  active_org_id rejects a non-membership';
  end;
end $$;

update users set active_org_id = 'aaaaaaaa-0000-0000-0000-000000000001'
where id = '11111111-1111-1111-1111-111111111111';

-- Second membership, then revoke the active one: must repoint, not strand.
insert into org_members (org_id, user_id, role)
values ('aaaaaaaa-0000-0000-0000-000000000002',
        '11111111-1111-1111-1111-111111111111', 'coordinator');

delete from org_members
where org_id = 'aaaaaaaa-0000-0000-0000-000000000001'
  and user_id = '11111111-1111-1111-1111-111111111111';

do $$
declare v uuid;
begin
  select active_org_id into v from users
  where id = '11111111-1111-1111-1111-111111111111';
  if v is distinct from 'aaaaaaaa-0000-0000-0000-000000000002' then
    raise exception 'FAIL: active org not repointed after revoke (got %)', v;
  end if;
  raise notice 'PASS  revoked membership repoints active_org_id';
end $$;

-- Put the owner back on Eastside for the rest of the run.
insert into org_members (org_id, user_id, role)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'owner');

-- ---------------------------------------------------------------------------
-- Opportunity + a capacity-1 shift
-- ---------------------------------------------------------------------------
insert into opportunities (id, org_id, kind, status, title, capacity, is_remote, created_by)
values ('bbbbbbbb-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000001',
        'event', 'published', 'Saturday pantry shift', 1, true,
        '11111111-1111-1111-1111-111111111111');

insert into shifts (id, opportunity_id, starts_at, ends_at)
values ('cccccccc-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001',
        now() - interval '3 hours', now() - interval '1 hour');

-- ---------------------------------------------------------------------------
-- Capacity: the second accepted signup lands on the waitlist, not in the shift
-- ---------------------------------------------------------------------------
insert into signups (id, shift_id, user_id, status)
values ('dddddddd-0000-0000-0000-000000000001',
        'cccccccc-0000-0000-0000-000000000001',
        '22222222-2222-2222-2222-222222222222', 'accepted');

insert into signups (id, shift_id, user_id, status)
values ('dddddddd-0000-0000-0000-000000000002',
        'cccccccc-0000-0000-0000-000000000001',
        '33333333-3333-3333-3333-333333333333', 'accepted');

do $$
declare s signup_status; p integer;
begin
  select status, waitlist_position into s, p from signups
  where id = 'dddddddd-0000-0000-0000-000000000002';
  if s <> 'waitlisted' or p <> 1 then
    raise exception 'FAIL: overflow signup is %/% not waitlisted/1', s, p;
  end if;
  raise notice 'PASS  capacity overflow becomes waitlisted at position 1';
end $$;

-- ---------------------------------------------------------------------------
-- I2: the transition graph
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update signups set status = 'completed'
    where id = 'dddddddd-0000-0000-0000-000000000001';
    raise exception 'FAIL: accepted -> completed was allowed';
  exception when check_violation then
    raise notice 'PASS  illegal transition accepted -> completed rejected';
  end;
end $$;

update signups set status = 'confirmed'
where id = 'dddddddd-0000-0000-0000-000000000001';
update signups set status = 'checked_in', checkin_method = 'qr'
where id = 'dddddddd-0000-0000-0000-000000000001';
update signups set status = 'completed'
where id = 'dddddddd-0000-0000-0000-000000000001';

do $$
declare n integer; m integer; t text;
begin
  select count(*), max(minutes), max(verification_tier) into n, m, t
  from hour_entries where signup_id = 'dddddddd-0000-0000-0000-000000000001';
  if n <> 1 then
    raise exception 'FAIL: expected exactly 1 hour_entry, got %', n;
  end if;
  if m <> 120 then
    raise exception 'FAIL: expected 120 minutes for a 2h shift, got %', m;
  end if;
  if t <> 'device' then
    raise exception 'FAIL: qr check-in should tier as device, got %', t;
  end if;
  raise notice 'PASS  completion mints one hour_entry (% min, tier %)', m, t;
end $$;

-- ---------------------------------------------------------------------------
-- Hours, normal path: an explicit check-in/out span is used as measured, not
-- swallowed by the retroactive fallback above.
-- ---------------------------------------------------------------------------
insert into shifts (id, opportunity_id, starts_at, ends_at)
values ('cccccccc-0000-0000-0000-000000000002',
        'bbbbbbbb-0000-0000-0000-000000000001',
        now() - interval '9 hours', now() - interval '7 hours');

insert into signups (id, shift_id, user_id, status, checked_in_at)
values ('dddddddd-0000-0000-0000-000000000003',
        'cccccccc-0000-0000-0000-000000000002',
        '11111111-1111-1111-1111-111111111111', 'accepted',
        now() - interval '8 hours 30 minutes');

update signups set status = 'checked_in', checkin_method = 'coordinator'
where id = 'dddddddd-0000-0000-0000-000000000003';

update signups set checked_out_at = now() - interval '7 hours'
where id = 'dddddddd-0000-0000-0000-000000000003';

update signups set status = 'completed'
where id = 'dddddddd-0000-0000-0000-000000000003';

do $$
declare m integer; t text;
begin
  select minutes, verification_tier into m, t
  from hour_entries where signup_id = 'dddddddd-0000-0000-0000-000000000003';
  if m <> 90 then
    raise exception 'FAIL: measured 90-minute attendance recorded as %', m;
  end if;
  if t <> 'self' then
    raise exception 'FAIL: unverified coordinator entry should tier self, got %', t;
  end if;
  raise notice 'PASS  measured attendance recorded as % min (tier %)', m, t;
end $$;

-- ---------------------------------------------------------------------------
-- I3: append-only ledger
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update hour_entries set minutes = 999
    where signup_id = 'dddddddd-0000-0000-0000-000000000001';
    raise exception 'FAIL: hour_entries accepted an UPDATE';
  exception when restrict_violation then
    raise notice 'PASS  hour_entries rejects UPDATE';
  end;

  begin
    delete from hour_entries
    where signup_id = 'dddddddd-0000-0000-0000-000000000001';
    raise exception 'FAIL: hour_entries accepted a DELETE';
  exception when restrict_violation then
    raise notice 'PASS  hour_entries rejects DELETE';
  end;
end $$;

-- ---------------------------------------------------------------------------
-- excused: requires attribution, and is the only edge out of a terminal state
-- ---------------------------------------------------------------------------
update signups set status = 'accepted' where id = 'dddddddd-0000-0000-0000-000000000002';
update signups set status = 'confirmed' where id = 'dddddddd-0000-0000-0000-000000000002';
update signups set status = 'no_show'   where id = 'dddddddd-0000-0000-0000-000000000002';

do $$
begin
  begin
    update signups set status = 'excused'
    where id = 'dddddddd-0000-0000-0000-000000000002';
    raise exception 'FAIL: excused accepted without excused_by';
  exception when not_null_violation then
    raise notice 'PASS  excused requires excused_by';
  end;
end $$;

update signups
   set status = 'excused', excused_by = '11111111-1111-1111-1111-111111111111'
 where id = 'dddddddd-0000-0000-0000-000000000002';

do $$
begin
  begin
    update signups set status = 'accepted'
    where id = 'dddddddd-0000-0000-0000-000000000002';
    raise exception 'FAIL: excused was not terminal';
  exception when check_violation then
    raise notice 'PASS  excused is terminal';
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Views resolve and show rate excludes the excused absence
-- ---------------------------------------------------------------------------
do $$
declare r numeric; f integer;
begin
  select filled into f from shift_fill
  where shift_id = 'cccccccc-0000-0000-0000-000000000001';

  select show_rate into r from org_stats_30d
  where org_id = 'aaaaaaaa-0000-0000-0000-000000000001';

  if r is distinct from 1.000 then
    raise exception 'FAIL: show rate should be 1.000 with the no-show excused, got %', r;
  end if;
  raise notice 'PASS  shift_fill filled=%, show_rate=% (excused excluded)', f, r;
end $$;

-- ---------------------------------------------------------------------------
-- Compensating entry: the sanctioned way to correct the ledger
-- ---------------------------------------------------------------------------
insert into hour_entries (user_id, org_id, shift_id, minutes, source, reverses)
select user_id, org_id, shift_id, -minutes, 'adjustment', id
from hour_entries where signup_id = 'dddddddd-0000-0000-0000-000000000001';

do $$
declare total integer;
begin
  select coalesce(sum(minutes), -1) into total from hour_entries
  where user_id = '22222222-2222-2222-2222-222222222222';
  if total <> 0 then
    raise exception 'FAIL: compensating entry did not net to zero (got %)', total;
  end if;
  raise notice 'PASS  compensating entry nets the ledger to zero';
end $$;

rollback;
