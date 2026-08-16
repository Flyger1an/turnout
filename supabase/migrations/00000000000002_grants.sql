-- ============================================================================
-- Turnout — table grants for the PostgREST roles
-- ============================================================================
-- The initial migration created policies but never granted the underlying
-- privileges, so every query from the app would have failed with
-- "permission denied for table ..." before RLS was ever consulted.
--
-- Grants and RLS are two different gates and both must be passed. These are
-- deliberately explicit rather than a blanket GRANT ... ON ALL TABLES: anything
-- RLS would have to deny is better not granted in the first place, and the
-- write grants below are exactly the writes the client is allowed to attempt.
-- ============================================================================

grant usage on schema public to anon, authenticated;

-- --------------------------------------------------------------------------
-- Public-facing reads. Browsing listings logged-out is intended (M4 discover).
-- --------------------------------------------------------------------------
grant select on orgs          to anon, authenticated;
grant select on opportunities to anon, authenticated;
grant select on shifts        to anon, authenticated;
grant select on impact_stats  to anon, authenticated;
grant select on shift_fill    to anon, authenticated;

-- --------------------------------------------------------------------------
-- Signed-in reads. RLS narrows each of these to self or to your org.
-- --------------------------------------------------------------------------
grant select on users               to authenticated;
grant select on org_members         to authenticated;
grant select on org_invites         to authenticated;
grant select on signups             to authenticated;
grant select on hour_entries        to authenticated;
grant select on scheduled_reminders to authenticated;
grant select on push_subscriptions  to authenticated;
grant select on sync_ops            to authenticated;
grant select on org_stats_30d       to authenticated;

-- --------------------------------------------------------------------------
-- Writes the client is allowed to attempt at all.
-- --------------------------------------------------------------------------
grant insert, update             on users              to authenticated;
grant insert, update             on orgs               to authenticated;
grant insert, update, delete     on org_members        to authenticated;
grant insert, update, delete     on org_invites        to authenticated;
grant insert, update, delete     on opportunities      to authenticated;
grant insert, update, delete     on shifts             to authenticated;
grant insert, update             on signups            to authenticated;
grant insert, update, delete     on impact_stats       to authenticated;
grant insert, update, delete     on push_subscriptions to authenticated;

-- Deliberately not granted to anyone but the service role:
--   hour_entries       — INSERT is the trigger's job; UPDATE/DELETE are refused
--                        by I3 anyway, and granting them invites the attempt.
--   scheduled_reminders— the dispatcher owns this queue.
--   sync_ops           — /api/checkin owns clamping and conflict resolution.
--   signups DELETE     — cancelling is a status transition, not a deletion;
--                        deleting would erase a no-show from the record.
