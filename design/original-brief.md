# TURNOUT — Implementation Spec (Claude Code-ready)

> Paste this file into the repo root as `SPEC.md`. Work milestones in order; each has acceptance criteria that must pass before moving on. The schema referenced throughout is `turnout-schema.sql` (commit it as `supabase/migrations/00000000000001_init.sql`).

---

## 0. Context for the agent

Turnout is a dual-mode volunteer platform: one account, toggle between **volunteer mode** and **org mode** (Airbnb host/guest pattern). The product thesis: the industry loses 1 in 3 volunteers per year and nobody owns the commitment lifecycle (signup → confirm → check-in → verified hours → impact feedback). We win on show-rate, recurring shifts as first-class objects, and an append-only verifiable hours ledger.

**Non-negotiable invariants:**
1. Never a second account. One `users` row, `active_mode` column, permissions via `org_members`.
2. Signup status transitions only through the DB trigger's legal graph. Never bypass with raw updates.
3. `hour_entries` is append-only. Corrections are compensating entries, never edits.
4. Volunteers see only published opportunities + their own signups. Coordinators see only their orgs' data. Enforced by RLS, not just app code.
5. All timestamps stored UTC, rendered in the shift's local timezone.

**Stack:** Next.js 15 (App Router, TS strict), Supabase (Postgres + Auth + RLS + Edge Functions + Realtime), Tailwind, Vercel. PWA first (installable, push via web-push); native wrapper later. No Redux; server components + React Query for client state.

**Design system:** paper `#F4F3EE`, ink `#1A211C`, volunteer accent `#2E6B46`, org accent `#2B4C7E`, signal amber `#FFB100`. Type: Bricolage Grotesque (display), Public Sans (body), IBM Plex Mono (numbers/hours). Mode toggle re-tints the whole UI via CSS custom properties on `<body>` (`body.org` overrides `--accent`). Reference mock: `turnout-home-screens.html`.

---

## 1. Repo layout

```
turnout/
  app/
    (auth)/login, signup, onboarding/
    (volunteer)/home, discover, schedule, hours, opp/[id]/
    (org)/dashboard, listings, listings/new, roster/[shiftId], applicants, reports/
    api/
      checkin/route.ts          # QR + geofence check-in
      cron/materialize/route.ts # shift generation from rrules
      cron/reminders/route.ts   # reminder dispatcher
      cron/noshow/route.ts      # sweep unclosed signups after shift end
  components/
    mode-switch.tsx             # THE toggle; lives in Profile screen; owns body class + route swap
    shift-card.tsx, fill-bar.tsx, ledger.tsx, roster-row.tsx, confirm-cta.tsx
  lib/
    supabase/ (client.ts, server.ts, middleware.ts)
    rrule.ts                    # wrap rrule.js; materialization window logic
    reminders.ts                # reminder scheduling rules
    push.ts                     # web-push helpers
  supabase/
    migrations/
    functions/                  # edge functions if needed
  SPEC.md
```

---

## 2. Milestones

### M1 — Foundation (auth, profile, mode toggle)
Build: Supabase project, apply init migration, magic-link + OAuth auth, onboarding (name, city, interests), `mode-switch` component persisting `users.active_mode`, layout shells for both modes with correct accent theming, bottom navs per mode.

**Toggle placement (Fiverr/Airbnb pattern):** the mode switch lives in the Profile section, NOT the persistent header. Profile is the last item in the bottom nav in both modes. Tapping it opens the profile screen; the mode switch sits at the top as a full-width card ("Switch to organization mode" / "Switch to volunteer mode") with the accent color of the destination mode as its visual cue. Rationale: mode switching is a rare, deliberate act; a header toggle overweights it, invites accidental flips, and steals the most valuable pixel real estate from the current mode's tasks. The header stays clean: wordmark + contextual action only.

The toggle contract: flipping mode (a) updates `active_mode` optimistically, (b) toggles `body.org` class, (c) plays the re-tint transition and routes to that mode's home, (d) if user has no `org_members` rows, the org-mode entry point reads "Set up your organization" and routes to the create-org flow instead, (e) a subtle mode indicator (accent-colored dot on the profile nav icon) confirms current mode at a glance without a persistent control.

**Accept:** new user signs up, lands in volunteer home; header contains no mode control; profile screen switch flips mode with re-tint + route; org entry shows setup flow for non-members; refresh restores last mode.

### M2 — Orgs & listings
Build: create org flow (name, slug, mission, location via geocode, cause tags, EIN field stored but verification stubbed to `pending`), invite coordinators by email, listing composer for all three kinds with a **kind picker first** (event / recurring shift / project) that changes the form. Recurring shift form: weekday picker + time + duration → generate RRULE string; show plain-language preview ("Every Tue & Thu, 6:00–8:00 PM"). Publish/pause/archive.

Shift materialization: `cron/materialize` runs daily (Vercel cron), rolls each published recurring opportunity's shifts forward to an 8-week horizon, idempotent via the `(opportunity_id, starts_at)` unique constraint. Events insert their single shift on publish.

**Accept:** coordinator creates all three kinds; recurring listing shows 8 weeks of shifts; cron re-run creates zero duplicates; RLS blocks a non-member from reading a draft.

### M3 — Discovery & signup (volunteer side)
Build: discover feed = published opportunities ranked by distance (PostGIS `<->` on `home_location`), filterable by cause tag, kind, and "this week". Opportunity page: shift picker for recurring (multi-select — the "every Friday this month" one-tap enrollment the incumbents can't do; inserts one signup per selected shift), single RSVP for events, apply-with-answers for projects. Auto-accept orgs skip to `accepted`; capacity full → `waitlisted` with position shown. Cancel with confirmation.

**Accept:** volunteer books 4 Friday shifts in one action; capacity respected; waitlist promotes FIFO on a cancellation; volunteer home "Up next" reflects reality.

### M4 — The lifecycle loop (the product)
This milestone is the company. Build all four beats:

**Confirm.** On signup acceptance, schedule `confirm_48h` (T-48h) and `logistics_2h` (T-2h) in `scheduled_reminders`. `cron/reminders` runs every 5 min, dispatches due rows via web-push + email fallback (Resend). Confirm push deep-links to a one-tap "I'm coming" that transitions `accepted → confirmed`.

**Check-in.** Roster screen (org mode) per shift: each attendee row has a check-in button; also render a shift QR (signed JWT: shift_id + exp). Volunteer scans → `POST /api/checkin` verifies signature + shift window (±30 min) → `confirmed/accepted → checked_in`. Geofence assist: if within 150 m of `opportunities.location` during the window, volunteer home surfaces a "Check in now" card. Check-out on tap or auto at `ends_at`.

**Hours.** On `checked_in → completed`, mint an `hour_entries` row: minutes = clamp(checkout − checkin, 15 min, shift duration + 30 min), source = method used. Coordinator manual entry allowed with `verified_by` set. Volunteer hours screen: mono-type ledger, totals, per-org breakdown, **Export PDF** (signed summary with org names and attestation line) — this is the portable record.

**Close the loop.** `cron/noshow` sweeps 2 h after `ends_at`: `confirmed` never checked in → `no_show`; `checked_in` never out → `completed` at shift end. Post-event: `post_event_thanks` push with hours earned + org impact stat if the coordinator logged one ("You helped serve 340 meals"). Coordinator prompt to log an `impact_stats` metric appears on the roster screen after end.

**Accept:** full happy path works end-to-end on two phones (volunteer + coordinator); no-show sweep correct; ledger rejects updates/deletes at the DB level; PDF export renders.

### M5 — Org intelligence
Build: dashboard fill-rate cards from the `shift_fill` view with amber warning under 70% filled; "Nudge past volunteers" (push/email to previously-completed volunteers of that opportunity, max 1 nudge per person per week — enforce in `reminders.ts`); applicant review queue; 30-day stats strip (hours, show rate, new volunteers); CSV + PDF report export for grants (hours by program by month).

**Accept:** show rate matches manual calculation from signups; nudge respects rate limit; grant report exports.

### M6 — Trust layer (post-MVP, spec now)
Org verification via IRS Pub 78 / 990 data match on EIN → `verified` badge. Volunteer identity verification (Stripe Identity or Persona) → "Verified" badge on ledger exports. Background-check vendor webhook slot on `signups.answers`. Do not build in MVP; leave columns and stubs.

---

## 3. Cross-cutting requirements

**Push:** web-push with VAPID; permission requested only after first successful signup (never on landing). Every reminder must have an email fallback.

**Timezones:** store UTC; `shifts` render in org's timezone (derive from location); reminder send times computed against shift-local time.

**Testing:** Vitest unit tests for `rrule.ts` window logic and reminder scheduling rules; Playwright happy-path (signup → book → confirm → check-in → hours). The signup transition trigger gets a pgTAP test enumerating every legal and a sample of illegal transitions.

**Seed script:** `pnpm seed` creates 3 orgs, 12 opportunities across all kinds, 40 fake volunteers, and signups in every state so every screen has data on first run.

**Metrics events (PostHog):** `signup_created`, `signup_confirmed`, `checked_in`, `no_show`, `second_shift_booked`. North-star: first-shift → second-shift conversion. Instrument from day one.

**Perf/quality floor:** LCP < 2 s on mid-range mobile; all interactive elements keyboard-reachable; reduced-motion respected on the mode transition.

---

## 4. Explicit non-goals for MVP

No payments, no donations, no corporate tier, no chat/DMs, no reviews/ratings, no native apps, no multi-language, no search (feed + filters only), no admin panel beyond org dashboards. Resist all of these until M1–M5 accept criteria pass and one real org has run four consecutive weeks of shifts through the system.

---

## 5. Quality floor addendum — "complete product, minimum surface"

Scope stays M1–M5. Everything inside that scope ships at flagship quality. This section is binding; treat each item as an acceptance criterion for its milestone. No placeholder energy anywhere.

### 5.1 Empty states are product, not absence
Every screen has a designed empty state that sells the next action in product voice:
- Org mode, no org: full-bleed illustration-quality screen. Headline: "Run your program from your pocket." Sub: what setup takes (2 minutes), what they get (roster, check-in, grant-ready hours). One button.
- Volunteer schedule, nothing booked: "Your calendar is open. Something near you starts this week." + top 2 nearby cards inline, not a link away.
- Hours ledger at zero: show the ledger frame with 0s and the line "Every hour you serve is recorded here, verified, and yours to keep." The empty ledger teaches the value prop.
- Discover with no results in filter: never "No results." Always the nearest relaxation: "Nothing for Animals this week — 4 opportunities next week" with a one-tap filter adjust.

### 5.2 Error states in product voice
- Every failure path has copy written for a human, an action, and preserved input. No raw error strings, no toast-and-shrug.
- Offline: check-in queues locally and syncs (volunteers are in basements and fields); banner reads "You're offline — your check-in is saved and will sync."
- Capacity race (two people grab the last spot): loser sees "That spot just filled — you're first on the waitlist" already done, not an error.

### 5.3 Motion and feel
- Mode re-tint: 300 ms, custom cubic-bezier with slight overshoot on the switch thumb; content cross-slides 14 px. `prefers-reduced-motion` swaps all of it for instant state change.
- Check-in: optimistic UI, sub-second perceived; success = amber pulse + haptic (Vibration API) + the row settling into "In ✓". This moment is the product's heartbeat; it should feel like a stamp, not a spinner.
- Confirm CTA press: physical button depress (scale .97, 80 ms). All primary buttons share it.
- List entries stagger in 30 ms apart, once, on first paint only. Never re-animate on tab return.

### 5.4 Copy standards
- Push notifications are written like a good coordinator texts: "Tomorrow 9 AM — pantry shift at Eastside. Still in?" [I'm in] [Can't make it]. Two-button actionable pushes wherever the platform allows.
- Post-event push always leads with the volunteer's number: "2.5 hours logged. You helped serve 340 meals." Screenshot-worthy is the bar.
- No exclamation-point inflation. Warmth through specificity, not punctuation.
- Dates humanized within 7 days ("Tomorrow", "Thursday"), absolute after.

### 5.5 Perceived performance
- Skeletons match final layout exactly (no layout shift on load); ledger numbers count up on first render only.
- Navigation between tabs is instant (prefetched); data revalidates in background, never blocks paint with a spinner if any cached state exists.
- QR roster screen renders offline from last sync — a coordinator at a park with no signal can still check people in.

### 5.6 Accessibility as craft
- Full keyboard path through booking and check-in flows; visible focus states in accent color.
- Mode announced to screen readers on switch ("Organization mode"). Fill bars carry aria-valuetext ("6 of 10 filled").
- Contrast: all accent-on-paper combos ≥ 4.5:1 (both accents chosen to pass; verify in CI with axe).

### 5.7 The details that read as trust
- Ledger PDF export: typeset properly (same type system), org attestation lines, subtle paper texture, a document someone hands a school administrator with confidence.
- Org verification pending state shows what's happening ("Checking IRS records — usually under 24 h"), never a bare badge absence.
- 404 and error pages carry the design system. The maintenance page too. Nobody ever sees a default anything.

### 5.8 CI enforcement
- Playwright visual regression on: both home screens, profile + switch, empty states, check-in success state.
- axe-core pass required on every route.
- Lighthouse CI: performance ≥ 90 mobile on home screens, PWA installable check green.
