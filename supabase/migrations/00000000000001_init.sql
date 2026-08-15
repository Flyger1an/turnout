-- ============================================================================
-- Turnout — initial schema
-- ============================================================================
-- Enforces the four DB-level invariants from SPEC.md §2:
--   I1  One account, two modes. No second user row for coordinators.
--   I2  signups.status moves only along the legal transition graph (trigger).
--   I3  hour_entries is append-only. UPDATE and DELETE are rejected.
--   I4  Visibility is enforced by RLS, not by application code.
-- ============================================================================

create extension if not exists postgis;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type app_mode            as enum ('volunteer', 'org');
create type org_role            as enum ('owner', 'coordinator');
create type verification_status as enum ('unverified', 'pending', 'verified', 'rejected');
create type opportunity_kind    as enum ('event', 'recurring', 'project');
create type opportunity_status  as enum ('draft', 'published', 'paused', 'archived');
create type signup_status       as enum (
  'applied', 'waitlisted', 'accepted', 'confirmed',
  'checked_in', 'completed', 'no_show', 'cancelled', 'declined'
);
create type hour_source         as enum ('qr', 'geofence', 'coordinator', 'self', 'adjustment');
create type reminder_kind       as enum ('confirm_48h', 'logistics_2h', 'post_event_thanks', 'nudge');
create type reminder_status     as enum ('pending', 'sent', 'failed', 'skipped', 'cancelled');

-- ---------------------------------------------------------------------------
-- users — one row per human, regardless of how many orgs they coordinate (I1)
-- ---------------------------------------------------------------------------
create table users (
  id             uuid primary key references auth.users (id) on delete cascade,
  email          text not null unique,
  full_name      text,
  avatar_url     text,
  city           text,
  home_location  geography(Point, 4326),
  interests      text[] not null default '{}',
  active_mode    app_mode not null default 'volunteer',
  timezone       text not null default 'America/New_York',
  onboarded_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index users_home_location_idx on users using gist (home_location);

-- ---------------------------------------------------------------------------
-- orgs
-- ---------------------------------------------------------------------------
create table orgs (
  id                  uuid primary key default gen_random_uuid(),
  slug                text not null unique,
  name                text not null,
  mission             text,
  logo_url            text,
  address             text,
  location            geography(Point, 4326),
  timezone            text not null default 'America/New_York',
  cause_tags          text[] not null default '{}',
  ein                 text,
  verification_status verification_status not null default 'unverified',
  verification_note   text,              -- M6: surfaced in the pending state (§13.7)
  auto_accept         boolean not null default true,
  created_by          uuid not null references users (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index orgs_location_idx on orgs using gist (location);

-- ---------------------------------------------------------------------------
-- org_members — the only source of coordinator permission (I1)
-- ---------------------------------------------------------------------------
create table org_members (
  org_id     uuid not null references orgs (id) on delete cascade,
  user_id    uuid not null references users (id) on delete cascade,
  role       org_role not null default 'coordinator',
  invited_by uuid references users (id),
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);

create index org_members_user_idx on org_members (user_id);

-- Pending email invites for coordinators who have no account yet (M2).
create table org_invites (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs (id) on delete cascade,
  email      text not null,
  role       org_role not null default 'coordinator',
  token      text not null unique default encode(gen_random_bytes(24), 'hex'),
  invited_by uuid not null references users (id),
  accepted_at timestamptz,
  expires_at timestamptz not null default now() + interval '14 days',
  created_at timestamptz not null default now(),
  unique (org_id, email)
);

-- ---------------------------------------------------------------------------
-- opportunities — event | recurring | project
-- ---------------------------------------------------------------------------
create table opportunities (
  id                   uuid primary key default gen_random_uuid(),
  org_id               uuid not null references orgs (id) on delete cascade,
  kind                 opportunity_kind not null,
  status               opportunity_status not null default 'draft',
  title                text not null,
  description          text,
  cause_tags           text[] not null default '{}',
  address              text,
  location             geography(Point, 4326),
  timezone             text not null default 'America/New_York',
  is_remote            boolean not null default false,
  capacity             integer not null default 1 check (capacity > 0),
  -- recurring only
  rrule                text,
  duration_minutes     integer check (duration_minutes > 0),
  materialized_through timestamptz,
  -- project only
  deadline             date,
  estimated_hours      numeric(5,1),
  -- application gate
  requires_application boolean not null default false,
  questions            jsonb not null default '[]'::jsonb,
  published_at         timestamptz,
  created_by           uuid not null references users (id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint recurring_needs_rrule check (
    kind <> 'recurring' or (rrule is not null and duration_minutes is not null)
  ),
  constraint located_unless_remote check (is_remote or location is not null)
);

create index opportunities_location_idx on opportunities using gist (location);
create index opportunities_discover_idx on opportunities (status, kind)
  where status = 'published';
create index opportunities_org_idx on opportunities (org_id);

-- ---------------------------------------------------------------------------
-- shifts — one concrete dated block. Events have exactly one.
-- ---------------------------------------------------------------------------
create table shifts (
  id             uuid primary key default gen_random_uuid(),
  opportunity_id uuid not null references opportunities (id) on delete cascade,
  starts_at      timestamptz not null,
  ends_at        timestamptz not null,
  capacity       integer check (capacity > 0),   -- null => inherit opportunity.capacity
  cancelled_at   timestamptz,
  note           text,
  created_at     timestamptz not null default now(),

  constraint shift_ends_after_start check (ends_at > starts_at),
  -- Idempotency key for cron/materialize (SPEC §9.2). Re-running creates zero rows.
  unique (opportunity_id, starts_at)
);

create index shifts_window_idx on shifts (starts_at) where cancelled_at is null;
create index shifts_opportunity_idx on shifts (opportunity_id, starts_at);

-- ---------------------------------------------------------------------------
-- signups — the lifecycle object. Status is trigger-guarded (I2).
-- ---------------------------------------------------------------------------
create table signups (
  id                uuid primary key default gen_random_uuid(),
  shift_id          uuid not null references shifts (id) on delete cascade,
  user_id           uuid not null references users (id) on delete cascade,
  status            signup_status not null default 'applied',
  answers           jsonb not null default '{}'::jsonb,  -- M6 leaves room for bg-check payloads
  waitlist_position integer,
  applied_at        timestamptz not null default now(),
  accepted_at       timestamptz,
  confirmed_at      timestamptz,
  checked_in_at     timestamptz,
  checked_out_at    timestamptz,
  closed_at         timestamptz,        -- completed | no_show | cancelled | declined
  cancel_reason     text,
  checkin_method    hour_source,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  unique (shift_id, user_id)
);

create index signups_user_idx on signups (user_id, status);
create index signups_shift_idx on signups (shift_id, status);
create index signups_waitlist_idx on signups (shift_id, waitlist_position)
  where status = 'waitlisted';

-- ---------------------------------------------------------------------------
-- hour_entries — append-only verifiable ledger (I3)
-- ---------------------------------------------------------------------------
create table hour_entries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users (id) on delete restrict,
  org_id      uuid not null references orgs (id) on delete restrict,
  shift_id    uuid references shifts (id) on delete restrict,
  signup_id   uuid references signups (id) on delete restrict,
  minutes     integer not null check (minutes <> 0),  -- negative = compensating entry
  source      hour_source not null,
  verified_by uuid references users (id),
  note        text,
  reverses    uuid references hour_entries (id),      -- set on compensating entries
  occurred_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

create index hour_entries_user_idx on hour_entries (user_id, occurred_at desc);
create index hour_entries_org_idx on hour_entries (org_id, occurred_at desc);
create unique index hour_entries_one_per_signup
  on hour_entries (signup_id) where reverses is null and signup_id is not null;

-- ---------------------------------------------------------------------------
-- scheduled_reminders — the dispatcher's queue (M4)
-- ---------------------------------------------------------------------------
create table scheduled_reminders (
  id          uuid primary key default gen_random_uuid(),
  signup_id   uuid references signups (id) on delete cascade,
  user_id     uuid not null references users (id) on delete cascade,
  org_id      uuid references orgs (id) on delete cascade,
  kind        reminder_kind not null,
  send_at     timestamptz not null,
  status      reminder_status not null default 'pending',
  attempts    integer not null default 0,
  sent_at     timestamptz,
  channel     text,          -- 'push' | 'email'
  error       text,
  created_at  timestamptz not null default now(),

  -- One reminder of a kind per signup. Makes the scheduler idempotent.
  unique (signup_id, kind)
);

-- Partial index: the dispatcher's only query, every 5 minutes.
create index reminders_due_idx on scheduled_reminders (send_at)
  where status = 'pending';
-- Nudge rate limiting (M5: max 1 per person per week).
create index reminders_nudge_idx on scheduled_reminders (user_id, org_id, created_at)
  where kind = 'nudge';

-- ---------------------------------------------------------------------------
-- push_subscriptions — web-push endpoints (one row per device)
-- ---------------------------------------------------------------------------
create table push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users (id) on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz
);

-- ---------------------------------------------------------------------------
-- impact_stats — what the coordinator logged; feeds the post-event push
-- ---------------------------------------------------------------------------
create table impact_stats (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs (id) on delete cascade,
  shift_id   uuid references shifts (id) on delete cascade,
  label      text not null,             -- 'meals served'
  value      numeric not null,
  unit       text,
  logged_by  uuid not null references users (id),
  created_at timestamptz not null default now()
);

create index impact_stats_shift_idx on impact_stats (shift_id);

-- ============================================================================
-- Triggers
-- ============================================================================

-- updated_at ---------------------------------------------------------------
create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger users_touch         before update on users         for each row execute function touch_updated_at();
create trigger orgs_touch          before update on orgs          for each row execute function touch_updated_at();
create trigger opportunities_touch before update on opportunities for each row execute function touch_updated_at();
create trigger signups_touch       before update on signups       for each row execute function touch_updated_at();

-- I3: append-only ledger ----------------------------------------------------
create or replace function reject_ledger_mutation() returns trigger
language plpgsql as $$
begin
  raise exception
    'hour_entries is append-only; % rejected. Insert a compensating entry with reverses = <id>.', tg_op
    using errcode = 'restrict_violation';
end $$;

create trigger hour_entries_no_update before update on hour_entries
  for each row execute function reject_ledger_mutation();
create trigger hour_entries_no_delete before delete on hour_entries
  for each row execute function reject_ledger_mutation();

-- I2: signup transition graph ----------------------------------------------
-- The single authority on lifecycle movement. Application code never bypasses.
create or replace function signup_legal_transition(from_s signup_status, to_s signup_status)
returns boolean language sql immutable as $$
  select (from_s, to_s) in (
    ('applied',    'accepted'),   ('applied',   'waitlisted'), ('applied',   'declined'),
    ('applied',    'cancelled'),
    ('waitlisted', 'accepted'),   ('waitlisted','cancelled'),  ('waitlisted','declined'),
    ('accepted',   'confirmed'),  ('accepted',  'checked_in'), ('accepted',  'cancelled'),
    ('accepted',   'no_show'),
    ('confirmed',  'checked_in'), ('confirmed', 'cancelled'),  ('confirmed', 'no_show'),
    ('checked_in', 'completed'),  ('checked_in','no_show')
  );
$$;

create or replace function signups_guard_transition() returns trigger
language plpgsql as $$
begin
  if new.status = old.status then
    return new;
  end if;

  if not signup_legal_transition(old.status, new.status) then
    raise exception 'illegal signup transition % -> % (signup %)', old.status, new.status, old.id
      using errcode = 'check_violation';
  end if;

  -- Stamp the clock for whichever beat just landed.
  new.accepted_at    := coalesce(new.accepted_at,    case when new.status = 'accepted'   then now() end);
  new.confirmed_at   := coalesce(new.confirmed_at,   case when new.status = 'confirmed'  then now() end);
  new.checked_in_at  := coalesce(new.checked_in_at,  case when new.status = 'checked_in' then now() end);
  if new.status in ('completed', 'no_show', 'cancelled', 'declined') then
    new.closed_at := coalesce(new.closed_at, now());
  end if;

  -- Leaving the waitlist clears the queue position.
  if old.status = 'waitlisted' then
    new.waitlist_position := null;
  end if;

  return new;
end $$;

create trigger signups_guard before update on signups
  for each row execute function signups_guard_transition();

-- Capacity + waitlist placement --------------------------------------------
-- Runs inside the writer's transaction with the shift row locked, so two
-- clients racing for the last spot can't both win (SPEC §13.2, capacity race).
create or replace function shift_effective_capacity(p_shift_id uuid)
returns integer language sql stable as $$
  select coalesce(s.capacity, o.capacity)
  from shifts s
  join opportunities o on o.id = s.opportunity_id
  where s.id = p_shift_id;
$$;

create or replace function signups_place_on_insert() returns trigger
language plpgsql as $$
declare
  cap      integer;
  occupied integer;
begin
  perform 1 from shifts where id = new.shift_id for update;

  cap := shift_effective_capacity(new.shift_id);

  select count(*) into occupied
  from signups
  where shift_id = new.shift_id
    and status in ('accepted', 'confirmed', 'checked_in', 'completed');

  if new.status in ('accepted', 'confirmed') and occupied >= cap then
    new.status := 'waitlisted';
    select coalesce(max(waitlist_position), 0) + 1 into new.waitlist_position
    from signups where shift_id = new.shift_id and status = 'waitlisted';
  elsif new.status = 'waitlisted' and new.waitlist_position is null then
    select coalesce(max(waitlist_position), 0) + 1 into new.waitlist_position
    from signups where shift_id = new.shift_id and status = 'waitlisted';
  elsif new.status = 'accepted' then
    new.accepted_at := coalesce(new.accepted_at, now());
  end if;

  return new;
end $$;

create trigger signups_place before insert on signups
  for each row execute function signups_place_on_insert();

-- FIFO waitlist promotion on a vacancy.
create or replace function signups_promote_waitlist() returns trigger
language plpgsql as $$
declare
  cap      integer;
  occupied integer;
  next_id  uuid;
begin
  if new.status not in ('cancelled', 'declined', 'no_show') then
    return null;
  end if;

  cap := shift_effective_capacity(new.shift_id);

  select count(*) into occupied
  from signups
  where shift_id = new.shift_id
    and status in ('accepted', 'confirmed', 'checked_in', 'completed');

  if occupied >= cap then
    return null;
  end if;

  select id into next_id
  from signups
  where shift_id = new.shift_id and status = 'waitlisted'
  order by waitlist_position
  limit 1
  for update skip locked;

  if next_id is not null then
    update signups set status = 'accepted' where id = next_id;
  end if;

  return null;
end $$;

create trigger signups_promote after update of status on signups
  for each row execute function signups_promote_waitlist();

-- Mint the ledger entry on completion (M4, Hours) --------------------------
create or replace function signups_mint_hours() returns trigger
language plpgsql as $$
declare
  v_org_id   uuid;
  v_minutes  integer;
  v_duration integer;
  v_start    timestamptz;
  v_end      timestamptz;
begin
  if new.status <> 'completed' or old.status = 'completed' then
    return null;
  end if;

  select o.org_id, s.starts_at, s.ends_at,
         extract(epoch from (s.ends_at - s.starts_at)) / 60
    into v_org_id, v_start, v_end, v_duration
  from shifts s
  join opportunities o on o.id = s.opportunity_id
  where s.id = new.shift_id;

  -- clamp(checkout - checkin, 15 min, shift duration + 30 min)
  v_minutes := greatest(
    15,
    least(
      v_duration + 30,
      coalesce(
        (extract(epoch from (coalesce(new.checked_out_at, v_end) - coalesce(new.checked_in_at, v_start))) / 60)::integer,
        v_duration
      )
    )
  );

  insert into hour_entries (user_id, org_id, shift_id, signup_id, minutes, source, occurred_at)
  values (new.user_id, v_org_id, new.shift_id, new.id, v_minutes,
          coalesce(new.checkin_method, 'coordinator'), v_start)
  on conflict do nothing;

  return null;
end $$;

create trigger signups_mint after update of status on signups
  for each row execute function signups_mint_hours();

-- ============================================================================
-- Views
-- ============================================================================

create view shift_fill as
select
  s.id                as shift_id,
  s.opportunity_id,
  o.org_id,
  s.starts_at,
  s.ends_at,
  coalesce(s.capacity, o.capacity) as capacity,
  count(*) filter (where g.status in ('accepted','confirmed','checked_in','completed')) as filled,
  count(*) filter (where g.status in ('confirmed','checked_in','completed'))            as confirmed,
  count(*) filter (where g.status = 'waitlisted')                                       as waitlisted,
  round(
    count(*) filter (where g.status in ('accepted','confirmed','checked_in','completed'))::numeric
    / nullif(coalesce(s.capacity, o.capacity), 0), 3
  ) as fill_ratio
from shifts s
join opportunities o on o.id = s.opportunity_id
left join signups g on g.shift_id = s.id
where s.cancelled_at is null
group by s.id, s.opportunity_id, o.org_id, s.starts_at, s.ends_at, s.capacity, o.capacity;

-- Org 30-day strip: hours, show rate, new volunteers (M5).
create view org_stats_30d as
select
  o.id as org_id,
  coalesce(sum(h.minutes) filter (where h.occurred_at > now() - interval '30 days'), 0) / 60.0 as hours,
  round(
    count(*) filter (where g.status in ('checked_in','completed') and sh.starts_at > now() - interval '30 days')::numeric
    / nullif(count(*) filter (where g.status in ('checked_in','completed','no_show') and sh.starts_at > now() - interval '30 days'), 0),
    3
  ) as show_rate,
  count(distinct g.user_id) filter (where g.applied_at > now() - interval '30 days') as new_volunteers
from orgs o
left join opportunities opp on opp.org_id = o.id
left join shifts sh        on sh.opportunity_id = opp.id
left join signups g        on g.shift_id = sh.id
left join hour_entries h   on h.org_id = o.id
group by o.id;

-- ============================================================================
-- RLS (I4)
-- ============================================================================

create or replace function is_org_member(p_org_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from org_members
    where org_id = p_org_id and user_id = auth.uid()
  );
$$;

create or replace function is_org_owner(p_org_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from org_members
    where org_id = p_org_id and user_id = auth.uid() and role = 'owner'
  );
$$;

-- Does the current user coordinate the org that owns this shift?
create or replace function coordinates_shift(p_shift_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from shifts s
    join opportunities o  on o.id = s.opportunity_id
    join org_members  m   on m.org_id = o.org_id
    where s.id = p_shift_id and m.user_id = auth.uid()
  );
$$;

alter table users               enable row level security;
alter table orgs                enable row level security;
alter table org_members         enable row level security;
alter table org_invites         enable row level security;
alter table opportunities       enable row level security;
alter table shifts              enable row level security;
alter table signups             enable row level security;
alter table hour_entries        enable row level security;
alter table scheduled_reminders enable row level security;
alter table push_subscriptions  enable row level security;
alter table impact_stats        enable row level security;

-- users: self only. (Coordinator-visible volunteer fields come from a
-- security-definer RPC, not a broad policy — see SPEC §7.3.)
create policy users_self_read   on users for select using (id = auth.uid());
create policy users_self_write  on users for update using (id = auth.uid()) with check (id = auth.uid());
create policy users_self_insert on users for insert with check (id = auth.uid());

-- orgs: public read (they're listings); members write.
create policy orgs_public_read on orgs for select using (true);
create policy orgs_insert      on orgs for insert with check (created_by = auth.uid());
create policy orgs_update      on orgs for update using (is_org_member(id));

create policy org_members_read   on org_members for select using (user_id = auth.uid() or is_org_member(org_id));
create policy org_members_write  on org_members for all    using (is_org_owner(org_id)) with check (is_org_owner(org_id));
create policy org_invites_manage on org_invites for all    using (is_org_member(org_id)) with check (is_org_member(org_id));

-- opportunities: published are public; drafts are members-only.
create policy opportunities_read on opportunities for select
  using (status = 'published' or is_org_member(org_id));
create policy opportunities_write on opportunities for all
  using (is_org_member(org_id)) with check (is_org_member(org_id));

create policy shifts_read on shifts for select using (
  exists (
    select 1 from opportunities o
    where o.id = shifts.opportunity_id
      and (o.status = 'published' or is_org_member(o.org_id))
  )
);
create policy shifts_write on shifts for all using (coordinates_shift(id)) with check (true);

-- signups: own rows, or rows on a shift you coordinate.
create policy signups_read on signups for select
  using (user_id = auth.uid() or coordinates_shift(shift_id));
create policy signups_insert on signups for insert
  with check (user_id = auth.uid());
create policy signups_update on signups for update
  using (user_id = auth.uid() or coordinates_shift(shift_id));

-- hour_entries: insert is service-role / trigger only. No update or delete
-- policy exists at all — belt and braces alongside the triggers.
create policy hours_read on hour_entries for select
  using (user_id = auth.uid() or is_org_member(org_id));

create policy reminders_read on scheduled_reminders for select using (user_id = auth.uid());
create policy push_self      on push_subscriptions  for all    using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy impact_read  on impact_stats for select using (true);
create policy impact_write on impact_stats for all
  using (is_org_member(org_id)) with check (is_org_member(org_id));

-- ---------------------------------------------------------------------------
-- New auth user -> users row
-- ---------------------------------------------------------------------------
create or replace function handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.users (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();
