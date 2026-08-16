-- ============================================================================
-- Turnout — make views respect the caller's RLS
-- ============================================================================
-- Postgres views default to security_invoker = off, which means they execute as
-- the view's owner. Both views here are owned by postgres, so they read the
-- underlying tables with RLS bypassed and hand the result to whoever selected
-- from them. shift_fill was returning every shift in the database to any
-- authenticated user, drafts and other orgs' shifts included.
--
-- This is the failure mode I4 warns about: no error, no denial, just a row that
-- should never have left the database. Policies on the base tables are not
-- enough on their own — anything layered over them has to opt in.
-- ============================================================================

alter view shift_fill    set (security_invoker = on);
alter view org_stats_30d set (security_invoker = on);
