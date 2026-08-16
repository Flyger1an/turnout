-- ============================================================================
-- Turnout — rebuild org_stats_30d
-- ============================================================================
-- Two defects, both found by seeding realistic volume and comparing the result
-- against the design mock's numbers.
--
-- 1. Cartesian product. hour_entries was joined on org_id only, alongside the
--    opportunities -> shifts -> signups chain, so every ledger row paired with
--    every signup row and sum(minutes) came out multiplied by the signup count.
--    Eastside reported 32,648 hours against a true 212. A single-org test
--    dataset would never have shown this: it needs both many signups and many
--    ledger rows before the multiplication is visible.
--
-- 2. "New volunteers" counted anyone who signed up inside the window, so a
--    ten-year veteran booking a Saturday shift registered as a new volunteer.
--    It now counts people whose *first* signup with this org falls in the
--    window, which is what the dashboard label claims.
--
-- Each measure is aggregated in its own CTE against its own grain, which is the
-- structural fix — a single flat join cannot produce three different grains
-- without one of them being wrong.
-- ============================================================================

drop view org_stats_30d;

create view org_stats_30d as
with hours_30d as (
  select org_id, sum(minutes) / 60.0 as hours
  from hour_entries
  where occurred_at > now() - interval '30 days'
  group by org_id
),
attendance_30d as (
  select o.org_id,
         count(*) filter (where g.status in ('checked_in', 'completed'))            as attended,
         count(*) filter (where g.status in ('checked_in', 'completed', 'no_show')) as expected
  from signups g
  join shifts s        on s.id = g.shift_id
  join opportunities o on o.id = s.opportunity_id
  where s.starts_at > now() - interval '30 days'
  group by o.org_id
),
first_signup as (
  select o.org_id, g.user_id, min(g.applied_at) as first_applied
  from signups g
  join shifts s        on s.id = g.shift_id
  join opportunities o on o.id = s.opportunity_id
  group by o.org_id, g.user_id
),
new_30d as (
  select org_id, count(*) as new_volunteers
  from first_signup
  where first_applied > now() - interval '30 days'
  group by org_id
)
select
  o.id                                    as org_id,
  coalesce(h.hours, 0)                    as hours,
  round(a.attended::numeric / nullif(a.expected, 0), 3) as show_rate,
  coalesce(n.new_volunteers, 0)::integer  as new_volunteers
from orgs o
left join hours_30d      h on h.org_id = o.id
left join attendance_30d a on a.org_id = o.id
left join new_30d        n on n.org_id = o.id;

-- Views do not respect the caller's RLS unless they opt in, and a rebuild
-- drops that setting along with the view.
alter view org_stats_30d set (security_invoker = on);

grant select on org_stats_30d to authenticated;
