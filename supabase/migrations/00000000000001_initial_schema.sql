-- ============================================================================
-- Turnout — initial schema
-- ============================================================================
-- Enforces the four DB-level invariants from SPEC.md §2:
--   I1  One account, two modes. No second user row for coordinators.
--   I2  signups.status moves only along the legal transition graph (trigger).
--   I3  hour_entries is append-only. UPDATE and DELETE are rejected.
--   I4  Visibility is enforced by RLS, not by application code.
-- ============================================================================

-- postgis only. gen_random_uuid() is core since PG13, so pgcrypto is not
-- required and is deliberately not depended on: on hosted Supabase it lives in
-- the extensions schema and is not on the migration's search_path.
create extension if not exists postgis;

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
  'checked_in', 'completed', 'no_show', 'excused', 'cancelled', 'declined'
);
create type hour_source         as enum ('qr', 'geofence', 'coordinator', 'self', 'adjustment');
create type reminder_kind       as enum (
  'confirm_48h', 'logistics_2h', 'post_event_thanks', 'nudge', 'shift_cancelled'
);
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
  -- Which org this person is currently acting as. Null until they join or
  -- create one. Coordinating for a church and a food bank is ordinary, and
  -- org_members has always supported it — this is the column that makes the
  -- UI able to (SPEC M1, org switcher). FK added after orgs exists.
  active_org_id  uuid,
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
  verification_note   text,              -- M6: surfaced in the pending state (§12.7)
  auto_accept         boolean not null default true,
  created_by          uuid not null references users (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index orgs_location_idx on orgs using gist (location);

alter table users
  add constraint users_active_org_fk
  foreign key (active_org_id) references orgs (id) on delete set null;

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
  -- Two core-Postgres v4 UUIDs, hyphens stripped: 64 hex chars from the same
  -- CSPRNG pgcrypto would have used, without depending on pgcrypto being
  -- resolvable from the migration's search_path (it is not, on hosted).
  token      text not null unique default
               replace(gen_random_uuid()::text, '-', '') ||
               replace(gen_random_uuid()::text, '-', ''),
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
  -- Idempotency key for cron/materialize (SPEC M2). Re-running creates zero rows.
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
  closed_at         timestamptz,        -- completed | no_show | excused | cancelled | declined
  cancel_reason     text,
  -- Set when the org cancelled the shift out from under the volunteer, so the
  -- "you cancelled" and "they cancelled" cases never read the same (SPEC §8.5).
  cancelled_by_org  boolean not null default false,
  excused_by        uuid references users (id),
  excused_reason    text,
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
  -- Strength of evidence behind this entry. The PDF export shows the mix rather
  -- than flattening everything into one number (SPEC §12.7): a QR scan is a
  -- screenshot away from forgery, a coordinator attestation is not.
  verification_tier text generated always as (
    case
      when verified_by is not null           then 'attested'
      when source in ('qr', 'geofence')      then 'device'
      else                                        'self'
    end
  ) stored,
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
-- Per-user notification budget: the dispatcher counts today's sends against the
-- daily cap before dispatching anything (SPEC §10, notification budget).
create index reminders_budget_idx on scheduled_reminders (user_id, sent_at)
  where status = 'sent';

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
-- sync_ops — idempotency ledger for offline check-in replay (SPEC M3, offline)
-- ---------------------------------------------------------------------------
-- A check-in performed in a basement is a fact that happened before the network
-- did. The device mints client_op_id at the moment of the tap; the primary key
-- makes replay free, so the client can retry forever without asking whether it
-- already succeeded.
create table sync_ops (
  client_op_id uuid primary key,
  user_id      uuid not null references users (id) on delete cascade,
  signup_id    uuid references signups (id) on delete set null,
  kind         text not null check (kind in ('checkin', 'checkout')),
  occurred_at  timestamptz not null,     -- device clock at the tap, server-clamped
  received_at  timestamptz not null default now(),
  outcome      text not null default 'applied'
                 check (outcome in ('applied', 'noop', 'rejected')),
  detail       text
);

create index sync_ops_user_idx on sync_ops (user_id, received_at desc);

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

-- Active org must be an org you actually belong to ---------------------------
-- Without this, active_org_id is a client-supplied claim about identity. RLS
-- would still refuse the data, but the UI would render a header for an org the
-- person has no relationship with, which is worse than an error.
create or replace function users_validate_active_org() returns trigger
language plpgsql as $$
begin
  if new.active_org_id is not null
     and not exists (
       select 1 from org_members
       where org_id = new.active_org_id and user_id = new.id
     )
  then
    raise exception 'user % is not a member of org %', new.id, new.active_org_id
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;

create trigger users_active_org_check before insert or update of active_org_id on users
  for each row execute function users_validate_active_org();

-- Losing a membership must not strand someone in a phantom org. Repoint to any
-- remaining membership, otherwise clear it and let them fall back to volunteer.
create or replace function org_members_clear_active() returns trigger
language plpgsql as $$
begin
  update users u
     set active_org_id = (
       select m.org_id from org_members m
       where m.user_id = old.user_id
       order by m.created_at
       limit 1
     )
   where u.id = old.user_id
     and u.active_org_id = old.org_id;
  return null;
end $$;

create trigger org_members_clear_active_trg after delete on org_members
  for each row execute function org_members_clear_active();

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
    ('accepted',   'no_show'),    ('accepted',  'excused'),
    ('confirmed',  'checked_in'), ('confirmed', 'cancelled'),  ('confirmed', 'no_show'),
    ('confirmed',  'excused'),
    ('checked_in', 'completed'),  ('checked_in','no_show'),
    -- The only edge out of a terminal state. A coordinator excusing an absence
    -- after the fact is a correction, not a lifecycle move: someone texted that
    -- their kid was sick and the sweep had already fired. Without this the
    -- volunteer carries a permanent mark and the org's show rate lies.
    ('no_show',    'excused')
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
  if new.status in ('completed', 'no_show', 'excused', 'cancelled', 'declined') then
    new.closed_at := coalesce(new.closed_at, now());
  end if;

  -- Excusing is a coordinator act and must say who. Guards the case where an
  -- excuse is written by a code path that forgot to attribute it.
  if new.status = 'excused' and new.excused_by is null then
    raise exception 'excused requires excused_by (signup %)', old.id
      using errcode = 'not_null_violation';
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
-- clients racing for the last spot can't both win (SPEC §12.2, capacity race).
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
  if new.status not in ('cancelled', 'declined', 'no_show', 'excused') then
    return null;
  end if;

  -- Nothing to promote into once the shift has started.
  if exists (select 1 from shifts where id = new.shift_id and starts_at <= now()) then
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
  v_raw      integer;
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
  --
  -- A coordinator catching up on the roster after the shift stamps checked_in_at
  -- later than ends_at, which makes the raw span negative and would floor an
  -- honest two-hour shift at the 15-minute minimum. A non-positive span carries
  -- no information about attendance, so fall back to the shift's own length.
  v_raw := (extract(epoch from (
              coalesce(new.checked_out_at, v_end) - coalesce(new.checked_in_at, v_start)
            )) / 60)::integer;

  if v_raw is null or v_raw <= 0 then
    v_raw := v_duration;
  end if;

  v_minutes := greatest(15, least(v_duration + 30, v_raw));

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
-- 'excused' appears in neither the numerator nor the denominator of show rate:
-- an absence the coordinator forgave is not a broken promise, and counting it
-- would make the one number the product sells on the one number coordinators
-- learn to distrust.
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
alter table sync_ops            enable row level security;
alter table impact_stats        enable row level security;

-- users: self only. A coordinator needs a roster row's name and shift count,
-- which arrives via a security-definer RPC scoped to that shift — never by
-- widening this policy to "any user who shares an org with me".
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
-- Read-only to the client; writes go through /api/checkin under the service role
-- so the server owns clamping and conflict resolution.
create policy sync_ops_read on sync_ops for select using (user_id = auth.uid());
create policy push_self      on push_subscriptions  for all    using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy impact_read  on impact_stats for select using (true);
create policy impact_write on impact_stats for all
  using (is_org_member(org_id)) with check (is_org_member(org_id));

-- ---------------------------------------------------------------------------
-- Org-initiated shift cancellation (SPEC §8.5)
-- ---------------------------------------------------------------------------
-- The highest-anger moment in the product. Cancelling a shift releases every
-- open signup and queues an immediate notification for each affected person;
-- `cancelled_by_org` keeps "you cancelled" and "they cancelled" distinguishable
-- forever, which matters both for copy and for not blaming the volunteer in
-- their own record.
create or replace function cancel_shift(p_shift_id uuid, p_reason text)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_org_id  uuid;
  v_count   integer;
begin
  if not coordinates_shift(p_shift_id) then
    raise exception 'not authorised to cancel shift %', p_shift_id
      using errcode = 'insufficient_privilege';
  end if;

  select o.org_id into v_org_id
  from shifts s
  join opportunities o on o.id = s.opportunity_id
  where s.id = p_shift_id;

  update shifts
     set cancelled_at = coalesce(cancelled_at, now()),
         note = coalesce(p_reason, note)
   where id = p_shift_id;

  with released as (
    update signups
       set status           = 'cancelled',
           cancelled_by_org = true,
           cancel_reason    = p_reason
     where shift_id = p_shift_id
       and status in ('applied', 'waitlisted', 'accepted', 'confirmed')
    returning id, user_id
  ),
  queued as (
    insert into scheduled_reminders (signup_id, user_id, org_id, kind, send_at)
    select r.id, r.user_id, v_org_id, 'shift_cancelled', now()
    from released r
    on conflict (signup_id, kind) do nothing
    returning 1
  )
  select count(*) into v_count from queued;

  -- Any reminder that would have fired for a shift that is no longer happening.
  update scheduled_reminders
     set status = 'cancelled'
   where status = 'pending'
     and kind in ('confirm_48h', 'logistics_2h', 'post_event_thanks')
     and signup_id in (select id from signups where shift_id = p_shift_id);

  return v_count;
end $$;

-- Coordinator forgives an absence. Open for 7 days after the shift ends, after
-- which the record settles for good.
create or replace function excuse_signup(p_signup_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_shift_id uuid;
  v_ends_at  timestamptz;
begin
  select g.shift_id, s.ends_at into v_shift_id, v_ends_at
  from signups g join shifts s on s.id = g.shift_id
  where g.id = p_signup_id;

  if not coordinates_shift(v_shift_id) then
    raise exception 'not authorised to excuse signup %', p_signup_id
      using errcode = 'insufficient_privilege';
  end if;

  if v_ends_at < now() - interval '7 days' then
    raise exception 'excuse window closed for signup %', p_signup_id
      using errcode = 'check_violation';
  end if;

  update signups
     set status = 'excused', excused_by = auth.uid(), excused_reason = p_reason
   where id = p_signup_id;
end $$;

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
