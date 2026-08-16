-- ============================================================================
-- Turnout — pgTAP suite for the signup lifecycle (SPEC.md §10)
-- ============================================================================
--   supabase test db
--
-- Covers, in order:
--   1. signup_legal_transition over the entire 90-pair cross product, so the
--      graph is pinned exhaustively rather than sampled.
--   2. The trigger actually enforcing each of the 19 legal transitions on a
--      real row — a correct function proves nothing if it is not wired up.
--   3. A sample of illegal transitions through the trigger, including every
--      terminal state.
--   4. The hours clamp at all four boundaries.
--   5. Capacity, waitlist ordering, and FIFO promotion.
--   6. The append-only ledger.
-- ============================================================================

begin;

create extension if not exists pgtap with schema extensions;

select * from no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'coordinator@tap.local'),
  ('22222222-2222-2222-2222-222222222222', 'volunteer@tap.local');

insert into orgs (id, slug, name, created_by)
values ('aaaaaaaa-0000-0000-0000-00000000000a', 'tap-org', 'TAP Org',
        '11111111-1111-1111-1111-111111111111');

insert into org_members (org_id, user_id, role)
values ('aaaaaaaa-0000-0000-0000-00000000000a',
        '11111111-1111-1111-1111-111111111111', 'owner');

-- Capacity 100 so placement never interferes with transition tests.
insert into opportunities (id, org_id, kind, status, title, capacity, is_remote, created_by)
values ('bbbbbbbb-0000-0000-0000-00000000000a',
        'aaaaaaaa-0000-0000-0000-00000000000a',
        'event', 'published', 'TAP opportunity', 100, true,
        '11111111-1111-1111-1111-111111111111');

create sequence tap_shift_seq;

-- Builds a signup already sitting in the requested state, on a shift of its
-- own so nothing bleeds between cases.
create function tap_mk(p_state signup_status) returns uuid
language plpgsql as $$
declare
  v_shift uuid;
  v_id    uuid;
  v_n     integer := nextval('tap_shift_seq');
begin
  insert into shifts (opportunity_id, starts_at, ends_at)
  values ('bbbbbbbb-0000-0000-0000-00000000000a',
          now() + (v_n * interval '1 hour') + interval '30 days',
          now() + (v_n * interval '1 hour') + interval '30 days 2 hours')
  returning id into v_shift;

  -- Reachable directly by insert.
  if p_state in ('applied', 'waitlisted', 'accepted') then
    insert into signups (shift_id, user_id, status)
    values (v_shift, '22222222-2222-2222-2222-222222222222', p_state)
    returning id into v_id;
    return v_id;
  end if;

  -- declined is only legal out of applied or waitlisted, never out of accepted.
  if p_state = 'declined' then
    insert into signups (shift_id, user_id, status)
    values (v_shift, '22222222-2222-2222-2222-222222222222', 'applied')
    returning id into v_id;
    update signups set status = 'declined' where id = v_id;
    return v_id;
  end if;

  insert into signups (shift_id, user_id, status)
  values (v_shift, '22222222-2222-2222-2222-222222222222', 'accepted')
  returning id into v_id;

  if p_state = 'confirmed' then
    update signups set status = 'confirmed' where id = v_id;
  elsif p_state = 'checked_in' then
    update signups set status = 'checked_in' where id = v_id;
  elsif p_state = 'no_show' then
    update signups set status = 'no_show' where id = v_id;
  elsif p_state = 'completed' then
    update signups set status = 'checked_in' where id = v_id;
    update signups set status = 'completed'  where id = v_id;
  elsif p_state = 'cancelled' then
    update signups set status = 'cancelled' where id = v_id;
  elsif p_state = 'excused' then
    update signups set status = 'excused',
        excused_by = '11111111-1111-1111-1111-111111111111' where id = v_id;
  end if;

  return v_id;
end $$;

-- ===========================================================================
-- 1. The graph, exhaustively: 90 ordered pairs
-- ===========================================================================
select is(
  signup_legal_transition(p.f, p.t),
  exists (
    select 1 from (values
      ('applied','accepted'),   ('applied','waitlisted'), ('applied','declined'),
      ('applied','cancelled'),
      ('waitlisted','accepted'),('waitlisted','cancelled'),('waitlisted','declined'),
      ('accepted','confirmed'), ('accepted','checked_in'), ('accepted','cancelled'),
      ('accepted','no_show'),   ('accepted','excused'),
      ('confirmed','checked_in'),('confirmed','cancelled'),('confirmed','no_show'),
      ('confirmed','excused'),
      ('checked_in','completed'),('checked_in','no_show'),
      ('no_show','excused')
    ) as legal(f, t)
    where legal.f = p.f::text and legal.t = p.t::text
  ),
  format('%s -> %s', p.f, p.t)
)
from (
  select a.s as f, b.s as t
  from   (select unnest(enum_range(null::signup_status)) as s) a
  cross join (select unnest(enum_range(null::signup_status)) as s) b
  where  a.s <> b.s
) p;

-- ===========================================================================
-- 2. The trigger honours every legal transition (19)
-- ===========================================================================
select lives_ok(
  format('update signups set status = %L where id = %L', t.to_s, tap_mk(t.from_s)),
  format('trigger allows %s -> %s', t.from_s, t.to_s)
)
from (values
  ('applied'::signup_status,   'accepted'::signup_status),
  ('applied',   'waitlisted'), ('applied',   'declined'), ('applied',  'cancelled'),
  ('waitlisted','accepted'),   ('waitlisted','cancelled'),('waitlisted','declined'),
  ('accepted',  'confirmed'),  ('accepted',  'checked_in'),('accepted', 'cancelled'),
  ('accepted',  'no_show'),
  ('confirmed', 'checked_in'), ('confirmed', 'cancelled'), ('confirmed','no_show'),
  ('checked_in','completed'),  ('checked_in','no_show')
) as t(from_s, to_s);

-- The three excused edges need attribution, so they are written separately.
select lives_ok(
  format('update signups set status = ''excused'', excused_by = %L where id = %L',
         '11111111-1111-1111-1111-111111111111', tap_mk(s)),
  format('trigger allows %s -> excused', s)
)
from unnest(array['accepted'::signup_status, 'confirmed', 'no_show']) as s;

-- ===========================================================================
-- 3. Illegal transitions are refused (check_violation)
-- ===========================================================================
select throws_ok(
  format('update signups set status = %L where id = %L', t.to_s, tap_mk(t.from_s)),
  '23514', null::text,
  format('trigger refuses %s -> %s', t.from_s, t.to_s)
)
from (values
  -- skipping beats
  ('applied'::signup_status,   'confirmed'::signup_status),
  ('applied',    'checked_in'), ('applied',   'completed'), ('applied',  'no_show'),
  ('waitlisted', 'confirmed'),  ('waitlisted','checked_in'),
  ('accepted',   'completed'),
  ('confirmed',  'completed'),
  -- going backwards
  ('confirmed',  'accepted'),   ('checked_in','confirmed'),
  -- every terminal state is terminal
  ('completed',  'checked_in'), ('completed', 'cancelled'),
  ('cancelled',  'accepted'),   ('declined',  'accepted'),
  ('excused',    'accepted'),   ('excused',   'no_show')
) as t(from_s, to_s);

-- Attribution is mandatory on the one edge out of a terminal state.
select throws_ok(
  format('update signups set status = ''excused'' where id = %L', tap_mk('no_show')),
  '23502', null::text,
  'excused without excused_by is refused'
);

-- ===========================================================================
-- 4. The hours clamp at each boundary
-- ===========================================================================
create function tap_hours(p_in interval, p_out interval) returns integer
language plpgsql as $$
declare
  v_shift uuid;
  v_id    uuid;
  v_n     integer := nextval('tap_shift_seq');
  v_start timestamptz := now() - interval '10 days' + (v_n * interval '1 hour');
begin
  -- A two-hour shift: duration 120, so the cap is 150 and the floor is 15.
  insert into shifts (opportunity_id, starts_at, ends_at)
  values ('bbbbbbbb-0000-0000-0000-00000000000a', v_start, v_start + interval '2 hours')
  returning id into v_shift;

  insert into signups (shift_id, user_id, status, checked_in_at)
  values (v_shift, '22222222-2222-2222-2222-222222222222', 'accepted',
          case when p_in is null then null else v_start + p_in end)
  returning id into v_id;

  update signups set status = 'checked_in' where id = v_id;
  update signups set checked_out_at =
    case when p_out is null then null else v_start + p_out end
  where id = v_id;
  update signups set status = 'completed' where id = v_id;

  return (select minutes from hour_entries where signup_id = v_id);
end $$;

select is(tap_hours(interval '0 min',  interval '90 min'),  90,
  'measured 90-minute attendance is recorded as measured');
select is(tap_hours(interval '0 min',  interval '5 min'),   15,
  'attendance under the floor is raised to 15 minutes');
select is(tap_hours(interval '-30 min', interval '150 min'), 150,
  'attendance over the cap is held at duration + 30');
select is(tap_hours(interval '0 min',  null),               120,
  'no checkout falls back to the shift duration');
select is(tap_hours(interval '4 hours', null),              120,
  'retroactive check-in after the shift falls back to duration, not the floor');

-- ===========================================================================
-- 5. Capacity, waitlist order, FIFO promotion
-- ===========================================================================
insert into opportunities (id, org_id, kind, status, title, capacity, is_remote, created_by)
values ('bbbbbbbb-0000-0000-0000-00000000000b',
        'aaaaaaaa-0000-0000-0000-00000000000a',
        'event', 'published', 'Two seats', 2, true,
        '11111111-1111-1111-1111-111111111111');

insert into shifts (id, opportunity_id, starts_at, ends_at)
values ('cccccccc-0000-0000-0000-00000000000b',
        'bbbbbbbb-0000-0000-0000-00000000000b',
        now() + interval '20 days', now() + interval '20 days 2 hours');

-- Five people, two seats.
insert into auth.users (id, email)
select ('44444444-0000-0000-0000-00000000000' || i)::uuid, 'racer' || i || '@tap.local'
from generate_series(1, 5) i;

insert into signups (shift_id, user_id, status)
select 'cccccccc-0000-0000-0000-00000000000b',
       ('44444444-0000-0000-0000-00000000000' || i)::uuid, 'accepted'
from generate_series(1, 5) i;

select is(
  (select count(*)::integer from signups
   where shift_id = 'cccccccc-0000-0000-0000-00000000000b' and status = 'accepted'),
  2, 'capacity 2 admits exactly two');

select is(
  (select count(*)::integer from signups
   where shift_id = 'cccccccc-0000-0000-0000-00000000000b' and status = 'waitlisted'),
  3, 'the overflow lands on the waitlist');

select results_eq(
  $$select waitlist_position from signups
    where shift_id = 'cccccccc-0000-0000-0000-00000000000b' and status = 'waitlisted'
    order by waitlist_position$$,
  $$values (1), (2), (3)$$,
  'waitlist positions are contiguous and ordered'
);

-- Vacancy promotes the head of the queue, and only the head.
update signups set status = 'cancelled'
where shift_id = 'cccccccc-0000-0000-0000-00000000000b'
  and user_id = '44444444-0000-0000-0000-000000000001';

select is(
  (select count(*)::integer from signups
   where shift_id = 'cccccccc-0000-0000-0000-00000000000b' and status = 'accepted'),
  2, 'a vacancy is refilled, not left open');

select is(
  (select status::text from signups
   where shift_id = 'cccccccc-0000-0000-0000-00000000000b'
     and user_id = '44444444-0000-0000-0000-000000000003'),
  'accepted', 'promotion is FIFO: position 1 goes first');

select is(
  (select waitlist_position from signups
   where shift_id = 'cccccccc-0000-0000-0000-00000000000b'
     and user_id = '44444444-0000-0000-0000-000000000003'),
  null, 'a promoted signup no longer holds a queue position');

-- ===========================================================================
-- 6. The append-only ledger (I3)
-- ===========================================================================
select throws_ok(
  $$update hour_entries set minutes = 999
    where id = (select id from hour_entries limit 1)$$,
  '23001', null::text, 'hour_entries refuses UPDATE');

select throws_ok(
  $$delete from hour_entries where id = (select id from hour_entries limit 1)$$,
  '23001', null::text, 'hour_entries refuses DELETE');

select lives_ok(
  $$insert into hour_entries (user_id, org_id, minutes, source, reverses)
    select user_id, org_id, -minutes, 'adjustment', id
    from hour_entries where reverses is null limit 1$$,
  'a compensating entry is the sanctioned correction');

select * from finish();

rollback;
