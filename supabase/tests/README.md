# pgTAP suite

Run with the Supabase CLI against a local stack:

```bash
supabase test db
```

`lifecycle.test.sql` is 140 assertions:

| Group | Count | What it pins |
|---|---|---|
| Transition graph | 90 | Every ordered pair of statuses, legal and illegal, against `signup_legal_transition` |
| Legal edges | 19 | Each legal transition driven through the trigger on a real row |
| Illegal edges | 17 | Skipped beats, backwards moves, every terminal state, and excusal without attribution |
| Hours clamp | 5 | Measured, below floor, above cap, no checkout, retroactive check-in |
| Capacity | 6 | Overflow to waitlist, contiguous positions, FIFO promotion, position cleared |
| Ledger | 3 | UPDATE and DELETE refused; compensating entry allowed |

The 90-pair group is the reason to prefer this over a sampled test: it fails if
anyone adds an edge to the function without deciding it belongs there.

Non-pgTAP scripts live in `supabase/checks/` so `supabase test db` does not try
to parse them as TAP output.
