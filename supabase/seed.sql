-- ============================================================================
-- Turnout — seed data
-- ============================================================================
-- Runs automatically on `supabase db reset`. SPEC §10 asks for 3 orgs, 12
-- opportunities across all kinds, 40 volunteers, and signups in every status,
-- so that every screen has real-looking data on first run and both a full
-- screen and an empty state are reachable without hand-crafting rows.
--
-- Beyond that, the numbers here are reverse-engineered from the design mock
-- (design/turnout-home-screens.html) so the reference screens render exactly:
-- Sam's 48 hours and 6-week streak, the 6-of-10 amber fill bar, the full Tue
-- restock, three applicants, and 212 hours / 91% show rate / 14 new volunteers
-- over the last 30 days. That makes the seed the executable version of the
-- design reference and gives visual regression (§12.8) a deterministic target.
--
-- One deliberate incoherence: the "up next" shift is always tomorrow so the
-- volunteer home renders the mock's "Tomorrow · 9:00–11:30 AM" copy, while its
-- title says Saturday. The screen matters more than the noun.
--
-- Login locally by magic link — the stack's mail catcher is at
-- http://127.0.0.1:54324. No passwords are stored here.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Refuse to run anywhere but the local stack. `supabase db reset --linked`
-- would otherwise inject 40 fake volunteers into a real project.
-- ---------------------------------------------------------------------------
do $$
begin
  if current_setting('app.settings.jwt_secret', true)
     is distinct from 'super-secret-jwt-token-with-at-least-32-characters-long' then
    raise exception
      'refusing to seed: this is not the local dev stack (jwt_secret is not the CLI default)';
  end if;
end $$;

truncate table auth.users cascade;

-- ---------------------------------------------------------------------------
-- Geography. Sam sits in Seattle; org offsets reproduce the mock's distances.
-- ---------------------------------------------------------------------------
-- 1 mile ~ 0.0145 degrees of latitude.
create or replace function seed_pt(miles_north numeric) returns geography
language sql immutable as $$
  select st_point(-122.3321, 47.6062 + (miles_north * 0.0145))::geography;
$$;

-- ---------------------------------------------------------------------------
-- People. handle_new_auth_user() mirrors each into public.users.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-4000-8000-000000000001', 'dana@turnout.dev',    now(),
   '{"full_name":"Dana Whitfield"}'),
  ('00000000-0000-4000-8000-000000000002', 'sam@turnout.dev',     now(),
   '{"full_name":"Sam Reyes"}'),
  ('00000000-0000-4000-8000-000000000003', 'jordan@turnout.dev',  now(),
   '{"full_name":"Jordan Kim"}'),
  ('00000000-0000-4000-8000-000000000004', 'maya@turnout.dev',    now(),
   '{"full_name":"Maya Torres"}'),
  -- The empty-state account: no org, no signups, no hours.
  ('00000000-0000-4000-8000-000000000005', 'newcomer@turnout.dev', now(),
   '{"full_name":"Alex Nkemdirim"}');

-- 35 more volunteers, for 40 in total.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select ('00000000-0000-4000-8000-0000000001' || lpad(i::text, 2, '0'))::uuid,
       'volunteer' || i || '@turnout.dev',
       now(),
       jsonb_build_object('full_name', 'Volunteer ' || i)
from generate_series(1, 35) i;

update users set
  city          = 'Seattle',
  home_location = seed_pt(0),
  timezone      = 'America/Los_Angeles',
  onboarded_at  = now() - interval '6 months',
  interests     = array['food','environment','animals'];

update users set interests = array['food','community'] where email = 'sam@turnout.dev';
update users set onboarded_at = now() - interval '2 days', interests = '{}'
  where email = 'newcomer@turnout.dev';

-- ---------------------------------------------------------------------------
-- Organizations
-- ---------------------------------------------------------------------------
insert into orgs (id, slug, name, mission, address, location, timezone,
                  cause_tags, ein, verification_status, auto_accept, created_by) values
  ('10000000-0000-4000-8000-000000000001', 'eastside-food-bank', 'Eastside Food Bank',
   'Nobody in this county eats less because of a delivery truck.',
   'North gate entrance, 1400 Eastside Ave', seed_pt(1.2), 'America/Los_Angeles',
   array['food','community'], '91-1234567', 'verified', true,
   '00000000-0000-4000-8000-000000000001'),

  ('10000000-0000-4000-8000-000000000002', 'parks-alliance', 'Parks Alliance',
   'The trails stay open because people show up on Thursdays.',
   'River trailhead lot', seed_pt(3.4), 'America/Los_Angeles',
   array['environment'], '91-2345678', 'verified', true,
   '00000000-0000-4000-8000-000000000001'),

  ('10000000-0000-4000-8000-000000000003', 'haven-shelter', 'Haven Shelter',
   'Every dog walked today is a dog that sleeps tonight.',
   '88 Haven Way', seed_pt(0.8), 'America/Los_Angeles',
   array['animals'], '91-3456789', 'pending', true,
   '00000000-0000-4000-8000-000000000001'),

  ('10000000-0000-4000-8000-000000000004', 'sunrise-kitchen', 'Sunrise Kitchen',
   'Hot meals, delivered by neighbours.',
   '12 Sunrise Blvd', seed_pt(2.1), 'America/Los_Angeles',
   array['food'], null, 'unverified', false,
   '00000000-0000-4000-8000-000000000001');

-- Dana coordinates Eastside and Parks: exercises the org switcher (M1).
insert into org_members (org_id, user_id, role) values
  ('10000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001', 'owner'),
  ('10000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001', 'coordinator');

update users set active_org_id = '10000000-0000-4000-8000-000000000001'
where id = '00000000-0000-4000-8000-000000000001';

-- ---------------------------------------------------------------------------
-- Opportunities: 12, across all three kinds
-- ---------------------------------------------------------------------------
insert into opportunities (id, org_id, kind, status, title, description, cause_tags,
                           address, location, timezone, is_remote, capacity, rrule,
                           duration_minutes, deadline, estimated_hours,
                           requires_application, published_at, created_by) values
  -- Eastside
  ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   'recurring', 'published', 'Saturday pantry shift',
   'Sorting, bagging, and handing out boxes at the north gate.', array['food'],
   'North gate entrance', seed_pt(1.2), 'America/Los_Angeles', false, 10,
   'FREQ=WEEKLY;BYDAY=SA', 150, null, null, false, now() - interval '6 months',
   '00000000-0000-4000-8000-000000000001'),

  ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   'recurring', 'published', 'Tuesday restock',
   'Evening warehouse restock before the Wednesday run.', array['food'],
   'Warehouse bay 3', seed_pt(1.2), 'America/Los_Angeles', false, 8,
   'FREQ=WEEKLY;BYDAY=TU', 120, null, null, false, now() - interval '6 months',
   '00000000-0000-4000-8000-000000000001'),

  ('20000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
   'project', 'published', 'Design a fundraiser flyer',
   'One-page flyer for the winter drive. Print and social sizes.', array['skills'],
   null, null, 'America/Los_Angeles', true, 2, null, null,
   (now() + interval '10 days')::date, 4.0, true, now() - interval '9 days',
   '00000000-0000-4000-8000-000000000001'),

  ('20000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000001',
   'event', 'draft', 'Holiday meal box packing',
   'Not announced yet — waiting on the pallet delivery date.', array['food'],
   'Warehouse bay 1', seed_pt(1.2), 'America/Los_Angeles', false, 24, null, null,
   null, null, false, null, '00000000-0000-4000-8000-000000000001'),

  -- Parks Alliance
  ('20000000-0000-4000-8000-000000000005', '10000000-0000-4000-8000-000000000002',
   'recurring', 'published', 'River trail cleanup',
   'Litter sweep and drainage clearing along the lower loop.', array['environment'],
   'River trailhead lot', seed_pt(3.4), 'America/Los_Angeles', false, 12,
   'FREQ=WEEKLY;BYDAY=TH', 120, null, null, false, now() - interval '4 months',
   '00000000-0000-4000-8000-000000000001'),

  ('20000000-0000-4000-8000-000000000006', '10000000-0000-4000-8000-000000000002',
   'event', 'published', 'Tree planting day',
   'Two hundred saplings along the east ridge. Gloves provided.', array['environment'],
   'East ridge staging area', seed_pt(3.6), 'America/Los_Angeles', false, 40, null, null,
   null, null, false, now() - interval '3 weeks', '00000000-0000-4000-8000-000000000001'),

  ('20000000-0000-4000-8000-000000000007', '10000000-0000-4000-8000-000000000002',
   'project', 'published', 'Trail map redesign',
   'Redraw the trail map for the new kiosk panels.', array['skills'],
   null, null, 'America/Los_Angeles', true, 1, null, null,
   (now() + interval '30 days')::date, 12.0, true, now() - interval '2 weeks',
   '00000000-0000-4000-8000-000000000001'),

  -- Haven Shelter
  ('20000000-0000-4000-8000-000000000008', '10000000-0000-4000-8000-000000000003',
   'recurring', 'published', 'Dog walking, morning block',
   'Two loops each, before the kennels are cleaned.', array['animals'],
   '88 Haven Way', seed_pt(0.8), 'America/Los_Angeles', false, 6,
   'FREQ=WEEKLY;BYDAY=MO,WE,FR', 90, null, null, false, now() - interval '5 months',
   '00000000-0000-4000-8000-000000000001'),

  ('20000000-0000-4000-8000-000000000009', '10000000-0000-4000-8000-000000000003',
   'event', 'published', 'Adoption fair',
   'Setup, greeting, and paperwork at the spring fair.', array['animals'],
   'Civic plaza', seed_pt(0.9), 'America/Los_Angeles', false, 16, null, null,
   null, null, false, now() - interval '1 week', '00000000-0000-4000-8000-000000000001'),

  ('20000000-0000-4000-8000-00000000000a', '10000000-0000-4000-8000-000000000003',
   'project', 'published', 'Shelter photo shoot',
   'Portraits of twelve long-stay dogs for the adoption listings.', array['skills'],
   null, null, 'America/Los_Angeles', true, 1, null, null,
   (now() + interval '21 days')::date, 6.0, true, now() - interval '5 days',
   '00000000-0000-4000-8000-000000000001'),

  -- Sunrise Kitchen
  ('20000000-0000-4000-8000-00000000000b', '10000000-0000-4000-8000-000000000004',
   'recurring', 'published', 'Meal delivery drivers',
   'Six stops per route, own vehicle, mileage reimbursed.', array['food'],
   '12 Sunrise Blvd', seed_pt(2.1), 'America/Los_Angeles', false, 10,
   'FREQ=WEEKLY;BYDAY=SU', 120, null, null, false, now() - interval '2 months',
   '00000000-0000-4000-8000-000000000001'),

  ('20000000-0000-4000-8000-00000000000c', '10000000-0000-4000-8000-000000000004',
   'event', 'published', 'Community dinner',
   'Serving line and cleanup for the monthly sit-down dinner.', array['food'],
   '12 Sunrise Blvd', seed_pt(2.1), 'America/Los_Angeles', false, 20, null, null,
   null, null, false, now() - interval '10 days', '00000000-0000-4000-8000-000000000001');

-- ---------------------------------------------------------------------------
-- Shifts. Weekly series from 13 weeks back to 8 weeks forward, anchored so the
-- pantry shift always lands tomorrow.
-- ---------------------------------------------------------------------------
create or replace function seed_series(
  p_opp uuid, p_anchor timestamptz, p_minutes integer, p_cap integer default null
) returns void language sql as $$
  insert into shifts (opportunity_id, starts_at, ends_at, capacity)
  select p_opp,
         p_anchor + (k * interval '7 days'),
         p_anchor + (k * interval '7 days') + (p_minutes * interval '1 minute'),
         p_cap
  from generate_series(-20, 8) k
  on conflict (opportunity_id, starts_at) do nothing;
$$;

-- Saturday pantry: tomorrow 09:00 local. Past shifts ran bigger crews.
select seed_series('20000000-0000-4000-8000-000000000001',
                   (date_trunc('day', now()) + interval '1 day 9 hours'), 150);
update shifts set capacity = 14
where opportunity_id = '20000000-0000-4000-8000-000000000001' and starts_at < now();

select seed_series('20000000-0000-4000-8000-000000000002',
                   (date_trunc('day', now()) + interval '3 days 18 hours'), 120);
update shifts set capacity = 14
where opportunity_id = '20000000-0000-4000-8000-000000000002' and starts_at < now();

select seed_series('20000000-0000-4000-8000-000000000005',
                   (date_trunc('day', now()) + interval '6 days 18 hours'), 120);
select seed_series('20000000-0000-4000-8000-000000000008',
                   (date_trunc('day', now()) + interval '2 days 8 hours'), 90);
select seed_series('20000000-0000-4000-8000-00000000000b',
                   (date_trunc('day', now()) + interval '5 days 10 hours'), 120);

-- Today's roster shift, which the org home checks people into.
insert into shifts (id, opportunity_id, starts_at, ends_at, capacity)
values ('30000000-0000-4000-8000-000000000001',
        '20000000-0000-4000-8000-000000000002',
        date_trunc('day', now()) + interval '9 hours',
        date_trunc('day', now()) + interval '11 hours', 8);

-- One-off events.
insert into shifts (opportunity_id, starts_at, ends_at)
values ('20000000-0000-4000-8000-000000000006',
        date_trunc('day', now()) + interval '12 days 9 hours',
        date_trunc('day', now()) + interval '12 days 14 hours'),
       ('20000000-0000-4000-8000-000000000009',
        date_trunc('day', now()) + interval '9 days 10 hours',
        date_trunc('day', now()) + interval '9 days 15 hours'),
       ('20000000-0000-4000-8000-00000000000c',
        date_trunc('day', now()) + interval '16 days 17 hours',
        date_trunc('day', now()) + interval '16 days 20 hours');

-- Projects carry a single nominal block against their deadline.
insert into shifts (opportunity_id, starts_at, ends_at)
select id, (deadline - interval '1 day')::timestamptz,
           (deadline - interval '1 day')::timestamptz + interval '4 hours'
from opportunities where kind = 'project';

-- ===========================================================================
-- Signups
-- ===========================================================================

-- --- Tomorrow's pantry shift: 6 of 10 filled, 4 confirmed --------------------
-- Sam is filled-but-unconfirmed, which is what puts "Confirm I'm coming" on
-- the volunteer home and keeps the org's confirmed count at 4.
insert into signups (shift_id, user_id, status, applied_at, accepted_at, confirmed_at)
select s.id, u.id, 'confirmed', now() - interval '9 days', now() - interval '9 days', now() - interval '2 days'
from shifts s
join users u on u.email in ('volunteer1@turnout.dev','volunteer2@turnout.dev',
                            'volunteer3@turnout.dev','volunteer4@turnout.dev')
where s.opportunity_id = '20000000-0000-4000-8000-000000000001'
  and s.starts_at > now()
order by s.starts_at limit 4;

insert into signups (shift_id, user_id, status, applied_at, accepted_at)
select s.id, u.id, 'accepted', now() - interval '5 days', now() - interval '5 days'
from shifts s
join users u on u.email in ('sam@turnout.dev','volunteer5@turnout.dev')
where s.opportunity_id = '20000000-0000-4000-8000-000000000001'
  and s.starts_at > now()
order by s.starts_at limit 2;

-- --- Tuesday restock: full at 8, 7 confirmed --------------------------------
insert into signups (shift_id, user_id, status, applied_at, accepted_at, confirmed_at)
select s.id, u.id,
       case when row_number() over (order by u.email) <= 7 then 'confirmed' else 'accepted' end::signup_status,
       now() - interval '12 days', now() - interval '12 days',
       case when row_number() over (order by u.email) <= 7 then now() - interval '3 days' end
from (select id from shifts
      where opportunity_id = '20000000-0000-4000-8000-000000000002' and starts_at > now()
      order by starts_at limit 1) s
join users u on u.email in ('volunteer6@turnout.dev','volunteer7@turnout.dev',
                            'volunteer8@turnout.dev','volunteer9@turnout.dev',
                            'volunteer10@turnout.dev','volunteer11@turnout.dev',
                            'volunteer12@turnout.dev','volunteer13@turnout.dev')
on conflict do nothing;

-- --- Today's roster: Sam in, Jordan confirmed, Maya not confirmed -----------
insert into signups (shift_id, user_id, status, applied_at, accepted_at, confirmed_at,
                     checked_in_at, checkin_method) values
  ('30000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002',
   'checked_in', now() - interval '8 days', now() - interval '8 days',
   now() - interval '2 days', date_trunc('day', now()) + interval '9 hours', 'qr'),
  ('30000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000003',
   'confirmed', now() - interval '3 days', now() - interval '3 days',
   now() - interval '1 day', null, null),
  ('30000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000004',
   'accepted', now() - interval '4 days', now() - interval '4 days', null, null, null);

-- --- Sam's other upcoming commitment: River trail cleanup, confirmed --------
insert into signups (shift_id, user_id, status, applied_at, accepted_at, confirmed_at)
select s.id, '00000000-0000-4000-8000-000000000002', 'confirmed',
       now() - interval '11 days', now() - interval '11 days', now() - interval '4 days'
from shifts s
where s.opportunity_id = '20000000-0000-4000-8000-000000000005' and s.starts_at > now()
order by s.starts_at limit 1;

-- --- Three applicants waiting on Dana: 2 pantry, 1 flyer -------------------
insert into signups (shift_id, user_id, status, applied_at, answers)
select s.id, u.id, 'applied', now() - interval '1 day',
       '{"why":"A friend volunteers here and said good things."}'
from (select id from shifts
      where opportunity_id = '20000000-0000-4000-8000-000000000001' and starts_at > now()
      order by starts_at offset 1 limit 1) s
join users u on u.email in ('volunteer14@turnout.dev','volunteer15@turnout.dev');

insert into signups (shift_id, user_id, status, applied_at, answers)
select s.id, '00000000-0000-4000-8000-000000000003'::uuid, 'applied', now() - interval '2 days',
       '{"portfolio":"https://example.com/work","tools":"Figma, Illustrator"}'
from shifts s where s.opportunity_id = '20000000-0000-4000-8000-000000000003' limit 1;

-- --- A waitlist, so the queue is visible somewhere -------------------------
insert into signups (shift_id, user_id, status, applied_at)
select s.id, u.id, 'waitlisted', now() - interval '2 days'
from (select id from shifts
      where opportunity_id = '20000000-0000-4000-8000-000000000008' and starts_at > now()
      order by starts_at limit 1) s
join users u on u.email in ('volunteer16@turnout.dev','volunteer17@turnout.dev');

-- --- A declined application and a cancellation, for status coverage --------
insert into signups (shift_id, user_id, status, applied_at, closed_at)
select s.id, u.id, 'declined', now() - interval '6 days', now() - interval '5 days'
from (select id from shifts
      where opportunity_id = '20000000-0000-4000-8000-000000000007' limit 1) s
join users u on u.email = 'volunteer18@turnout.dev';

insert into signups (shift_id, user_id, status, applied_at, closed_at, cancel_reason)
select s.id, u.id, 'cancelled', now() - interval '7 days', now() - interval '3 days',
       'Work travel came up'
from (select id from shifts
      where opportunity_id = '20000000-0000-4000-8000-00000000000b' and starts_at > now()
      order by starts_at limit 1) s
join users u on u.email = 'volunteer19@turnout.dev';

-- --- An excused absence, so show rate has something to exclude -------------
insert into signups (shift_id, user_id, status, applied_at, closed_at,
                     excused_by, excused_reason)
select s.id, u.id, 'excused', now() - interval '20 days', now() - interval '13 days',
       '00000000-0000-4000-8000-000000000001', 'Texted ahead — childcare fell through'
from (select id from shifts
      where opportunity_id = '20000000-0000-4000-8000-000000000005'
        and starts_at < now() order by starts_at desc limit 1) s
join users u on u.email = 'volunteer20@turnout.dev';

-- ===========================================================================
-- Eastside history: 212 hours, 91% show rate, 14 new volunteers over 30 days
-- ===========================================================================
-- 100 people-shifts across the last four weeks: 91 attended, 9 did not, which
-- is the 91% exactly. Volunteers 1-14 are the "new" cohort, so their applied_at
-- falls inside the window and nobody else's does.

create temporary table seed_hist as
with past_shifts as (
  select s.id, s.starts_at, row_number() over (order by s.starts_at) - 1 as sn
  from shifts s
  join opportunities o on o.id = s.opportunity_id
  where o.org_id = '10000000-0000-4000-8000-000000000001'
    and s.starts_at between now() - interval '30 days' and now() - interval '1 hour'
    and s.id <> '30000000-0000-4000-8000-000000000001'
),
-- Sam attended the four most recent Saturdays.
sam as (
  select p.id as shift_id, '00000000-0000-4000-8000-000000000002'::uuid as user_id,
         p.starts_at, true as is_sam
  from past_shifts p
  join shifts s on s.id = p.id
  where s.opportunity_id = '20000000-0000-4000-8000-000000000001'
  order by p.starts_at desc limit 4
),
others as (
  select p.id as shift_id,
         ('00000000-0000-4000-8000-0000000001' ||
          lpad((((p.sn * 12 + j) % 35) + 1)::text, 2, '0'))::uuid as user_id,
         p.starts_at, false as is_sam
  from past_shifts p
  cross join generate_series(0, 11) j
)
select *, row_number() over (order by starts_at, user_id) as rn
from (select * from sam union all select * from others) x;

-- 96 non-Sam rows; every 11th is a no-show, giving 9 against 91 attended.
insert into signups (shift_id, user_id, status, applied_at, accepted_at,
                     confirmed_at, checked_in_at, checked_out_at, closed_at, checkin_method)
select h.shift_id, h.user_id,
       case when not h.is_sam and h.rn % 11 = 1 then 'no_show' else 'completed' end::signup_status,
       -- Twelve first-timers here; Jordan and Maya arrive via today's roster,
       -- which is what brings the dashboard's new-volunteer count to 14.
       case when h.user_id in (
              select ('00000000-0000-4000-8000-0000000001' || lpad(i::text,2,'0'))::uuid
              from generate_series(1,12) i)
            then now() - interval '10 days'
            else now() - interval '45 days' end,
       h.starts_at - interval '5 days',
       h.starts_at - interval '2 days',
       case when h.is_sam or h.rn % 11 <> 1 then h.starts_at end,
       case when h.is_sam or h.rn % 11 <> 1 then h.starts_at + interval '2 hours' end,
       h.starts_at + interval '3 hours',
       case when h.is_sam or h.rn % 11 <> 1 then 'qr'::hour_source end
from seed_hist h
on conflict (shift_id, user_id) do nothing;

-- 91 ledger entries summing to 12 720 minutes = 212 hours exactly:
-- 76 at 120 and 15 at 240, the longer ones being double shifts.
-- Sam is held at 120 throughout so his all-time total stays controllable; the
-- double shifts are drawn from everyone else.
insert into hour_entries (user_id, org_id, shift_id, signup_id, minutes, source, occurred_at)
select g.user_id, '10000000-0000-4000-8000-000000000001', g.shift_id, g.id,
       case
         when g.user_id = '00000000-0000-4000-8000-000000000002' then 120
         when row_number() over (
                partition by (g.user_id = '00000000-0000-4000-8000-000000000002'::uuid)
                order by g.applied_at, g.id) <= 15 then 240
         else 120
       end,
       'qr', s.starts_at
from signups g
join shifts s on s.id = g.shift_id
join opportunities o on o.id = s.opportunity_id
where o.org_id = '10000000-0000-4000-8000-000000000001'
  and g.status = 'completed'
  and s.starts_at > now() - interval '30 days';

-- ---------------------------------------------------------------------------
-- Sam's older record: 48 hours total across 3 orgs, 6-week streak
-- ---------------------------------------------------------------------------
-- Eastside Saturdays for weeks 5-6 and 8-13 — the gap at week 7 is what makes
-- the streak read 6 rather than 12.
insert into signups (shift_id, user_id, status, applied_at, accepted_at, confirmed_at,
                     checked_in_at, checked_out_at, closed_at, checkin_method)
select s.id, '00000000-0000-4000-8000-000000000002', 'completed',
       now() - interval '10 months', s.starts_at - interval '5 days',
       s.starts_at - interval '2 days', s.starts_at, s.starts_at + interval '2 hours',
       s.starts_at + interval '3 hours', 'qr'
from shifts s
where s.opportunity_id = '20000000-0000-4000-8000-000000000001'
  and s.starts_at < now() - interval '30 days'
  and s.starts_at > now() - interval '95 days'
  and date_trunc('week', s.starts_at) <> date_trunc('week', now() - interval '42 days')
on conflict do nothing;

-- Parks and Haven, six completed shifts each.
insert into signups (shift_id, user_id, status, applied_at, accepted_at, confirmed_at,
                     checked_in_at, checked_out_at, closed_at, checkin_method)
select s.id, '00000000-0000-4000-8000-000000000002', 'completed',
       now() - interval '8 months', s.starts_at - interval '5 days',
       s.starts_at - interval '2 days', s.starts_at, s.starts_at + interval '2 hours',
       s.starts_at + interval '3 hours', 'coordinator'
from (
  select s.id, s.starts_at,
         row_number() over (partition by o.org_id order by s.starts_at desc) as rn
  from shifts s
  join opportunities o on o.id = s.opportunity_id
  where o.org_id in ('10000000-0000-4000-8000-000000000002',
                     '10000000-0000-4000-8000-000000000003')
    and s.starts_at < now() - interval '60 days'
) s
where s.rn <= 6
on conflict do nothing;

-- Sam's older ledger, sized so his all-time total lands on exactly 48 hours.
insert into hour_entries (user_id, org_id, shift_id, signup_id, minutes, source,
                          verified_by, occurred_at)
select g.user_id, o.org_id, g.shift_id, g.id, 120,
       case when o.org_id = '10000000-0000-4000-8000-000000000001'
            then 'qr'::hour_source else 'coordinator'::hour_source end,
       case when o.org_id = '10000000-0000-4000-8000-000000000001'
            then null else '00000000-0000-4000-8000-000000000001'::uuid end,
       s.starts_at
from signups g
join shifts s on s.id = g.shift_id
join opportunities o on o.id = s.opportunity_id
where g.user_id = '00000000-0000-4000-8000-000000000002'
  and g.status = 'completed'
  and s.starts_at < now() - interval '30 days';

-- ---------------------------------------------------------------------------
-- Impact stats and a pending reminder
-- ---------------------------------------------------------------------------
insert into impact_stats (org_id, shift_id, label, value, unit, logged_by)
select '10000000-0000-4000-8000-000000000001', s.id, 'meals served', 340, 'meals',
       '00000000-0000-4000-8000-000000000001'
from shifts s
where s.opportunity_id = '20000000-0000-4000-8000-000000000001'
  and s.starts_at < now()
order by s.starts_at desc limit 1;

insert into scheduled_reminders (signup_id, user_id, org_id, kind, send_at)
select g.id, g.user_id, '10000000-0000-4000-8000-000000000001', 'confirm_48h',
       s.starts_at - interval '48 hours'
from signups g
join shifts s on s.id = g.shift_id
where g.user_id = '00000000-0000-4000-8000-000000000002'
  and g.status = 'accepted' and s.starts_at > now()
on conflict do nothing;

drop function seed_pt(numeric);
drop function seed_series(uuid, timestamptz, integer, integer);

-- ---------------------------------------------------------------------------
-- What the mock claims, measured against what was actually seeded
-- ---------------------------------------------------------------------------
do $$
declare
  v_hours    numeric;
  v_rate     numeric;
  v_new      integer;
  v_sam      numeric;
  v_orgs     integer;
  v_fill     text;
begin
  select round(hours, 1), show_rate, new_volunteers into v_hours, v_rate, v_new
  from org_stats_30d where org_id = '10000000-0000-4000-8000-000000000001';

  select round(sum(minutes) / 60.0, 1), count(distinct org_id)
    into v_sam, v_orgs
  from hour_entries where user_id = '00000000-0000-4000-8000-000000000002';

  select f.filled || ' of ' || f.capacity || ' filled, ' || f.confirmed || ' confirmed'
    into v_fill
  from shift_fill f
  join shifts s on s.id = f.shift_id
  where s.opportunity_id = '20000000-0000-4000-8000-000000000001'
    and s.starts_at > now()
  order by s.starts_at limit 1;

  raise notice '--------------------------------------------------';
  raise notice 'Eastside, last 30 days: % hours, % show rate, % new', v_hours, v_rate, v_new;
  raise notice '  mock says:            212 hours, 0.910, 14';
  raise notice 'Tomorrow''s pantry:     %', v_fill;
  raise notice '  mock says:            6 of 10 filled, 4 confirmed';
  raise notice 'Sam: % hours across % orgs', v_sam, v_orgs;
  raise notice '  mock says:            48 hours across 3 orgs';
  raise notice '--------------------------------------------------';
  raise notice 'Sign in by magic link at http://127.0.0.1:54324';
  raise notice '  dana@turnout.dev     coordinator, 2 orgs';
  raise notice '  sam@turnout.dev      the volunteer the mock is drawn around';
  raise notice '  newcomer@turnout.dev every empty state';
end $$;
