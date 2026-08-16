-- ============================================================================
-- Turnout — restrict volunteer self-service on signups
-- ============================================================================
-- The original signups_update policy had a USING clause and no WITH CHECK, so
-- Postgres reused USING for the new row: any status a volunteer could name was
-- accepted as long as they owned the signup. Combined with the transition graph
-- (accepted -> checked_in -> completed, all legal) and signups_mint_hours, a
-- volunteer could walk their own signup to completed and mint themselves a
-- verified hour_entry without ever attending. That is the one attack the hours
-- ledger cannot survive, since its whole value is being trustworthy to a third
-- party reading the export.
--
-- Self-service is exactly two verbs: "I'm coming" and "I can't make it".
-- Everything else — check-in, check-out, completion, no-show, excusal — belongs
-- to a coordinator or to the server, which reach the row via the service role
-- and are unaffected by this policy.
-- ============================================================================

drop policy signups_update on signups;

create policy signups_update on signups for update
  using (
    user_id = auth.uid() or coordinates_shift(shift_id)
  )
  with check (
    coordinates_shift(shift_id)
    or (user_id = auth.uid() and status in ('confirmed', 'cancelled'))
  );
