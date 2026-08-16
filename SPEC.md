# TURNOUT — Implementation Spec

**Status:** ready to build · **Scope:** M1–M5 · **Schema:** `supabase/migrations/00000000000001_init.sql`
**Reference mock:** `design/turnout-home-screens.html` · **Original brief:** `design/original-brief.md`

Work the milestones in order. Each has acceptance criteria that must pass before the next
begins. Where this document and the mock disagree, this document wins; where this document
is silent, the mock is the answer.

---

## 1. What Turnout is

A dual-mode volunteer platform. One account, two modes — volunteer and organization —
toggled the way Airbnb toggles host and guest.

The industry loses one in three volunteers a year and nobody owns the commitment
lifecycle: signup → confirm → check-in → verified hours → impact feedback. Incumbents
(VolunteerMatch, Golden, POINT) are directories. They hand off at signup and never learn
whether the person showed. Turnout owns the whole arc.

Three things we win on:

1. **Show rate.** Confirm and reminder beats are first-class scheduled objects, not
   optional emails.
2. **Recurring shifts as real objects.** "Every Friday this month" is one tap. No
   incumbent does this; they model recurrence as a text field in a description.
3. **A verifiable hours ledger.** Append-only, exportable as a signed PDF. The volunteer's
   record is portable and belongs to them, not to the org that happened to host them.

**North-star metric:** first-shift → second-shift conversion. Every design decision that
trades against it loses. Day to day you steer on **show rate**, which moves first and is
felt by coordinators immediately — see §10.

---

## 2. Non-negotiable invariants

These are enforced in the database, not in application code. Code that tries to route
around them should fail loudly in development.

| # | Invariant | Enforcement |
|---|---|---|
| **I1** | Never a second account. One `users` row per human; `active_mode` column; coordinator permission comes from `org_members`. | Schema shape; no `coordinators` table exists. |
| **I2** | `signups.status` moves only along the legal transition graph. | `signups_guard_transition()` trigger + `signup_legal_transition()`. |
| **I3** | `hour_entries` is append-only. Corrections are compensating entries (negative `minutes`, `reverses` set), never edits. | `reject_ledger_mutation()` on UPDATE and DELETE; no RLS update policy. |
| **I4** | Volunteers see published opportunities and their own signups. Coordinators see their orgs' data. Nothing else. | RLS policies, verified by test, not by trusting the client. |
| **I5** | All timestamps stored UTC; rendered in the **shift's** local timezone, never the viewer's. | `timestamptz` columns; `opportunities.timezone`. |

I5 is the one that gets violated by accident. A volunteer who books a shift while
travelling must see the shift's local time, or they show up an hour off.

---

## 3. Stack and conventions

- **Next.js 15**, App Router, TypeScript strict. Server Components by default; `"use client"`
  only where interaction demands it.
- **Supabase** — Postgres, Auth, RLS, Realtime, Edge Functions.
- **Tailwind** with the design tokens in §5 as CSS custom properties, not Tailwind theme
  colors — the mode re-tint depends on runtime variable swapping.
- **Vercel** — hosting plus cron.
- **React Query** for client cache. No Redux. Server state stays on the server.
- **PWA first** — installable, web-push. Native wrapper is post-M5.
- **Resend** for email. **PostHog** for product analytics.

Conventions: `snake_case` in the database, `camelCase` in TypeScript, generated types via
`supabase gen types typescript` committed to `lib/database.types.ts` and regenerated in CI
(drift fails the build).

---

## 4. Repo layout

```
turnout/
  app/
    (auth)/          login/ signup/ onboarding/
    (volunteer)/     home/ discover/ schedule/ hours/ opp/[id]/ profile/
    (org)/           dashboard/ listings/ listings/new/ roster/[shiftId]/
                     applicants/ reports/ profile/
    api/
      checkin/route.ts             # QR + geofence check-in
      cron/materialize/route.ts    # rrule → shifts, daily
      cron/reminders/route.ts      # dispatcher, every 5 min
      cron/noshow/route.ts         # sweep, every 15 min
      hours/export/route.ts        # signed PDF
  components/
    mode-switch.tsx                # THE toggle. Owns body class + route swap.
    shift-card.tsx  fill-bar.tsx  ledger.tsx  roster-row.tsx  confirm-cta.tsx
    empty/                         # one component per designed empty state (§12.1)
  lib/
    supabase/  client.ts server.ts middleware.ts
    rrule.ts        # materialization window logic
    reminders.ts    # scheduling rules + nudge rate limit
    push.ts         # web-push helpers
    time.ts         # UTC ↔ shift-local, humanized dates
  supabase/migrations/
  design/
  SPEC.md
```

---

## 5. Design system

Lifted from the mock; these are the canonical values.

```css
--paper:  #F4F3EE;   --ink:    #1A211C;   --muted: #6B7268;
--line:   #DDDCD3;   --card:   #FFFFFF;   --amber: #FFB100;

/* volunteer (default) */
--accent: #2E6B46;   --accent-soft: #E4EEE7;
/* org — body.org */
--accent: #2B4C7E;   --accent-soft: #E3E9F2;

--radius: 16px;
```

**Type:** Bricolage Grotesque (display, headings, opportunity titles) · Public Sans (body,
UI) · IBM Plex Mono (numbers, hours, ledger — anything countable).

**The re-tint:** mode switching toggles `body.org`, which overrides `--accent` and
`--accent-soft`. Everything accent-colored follows automatically. Never hard-code either
accent in a component; always `var(--accent)`.

Amber is the signal color and is never decorative. It means *needs attention* — under-70%
fill bars, confirm-by deadlines, the check-in stamp. If amber appears where nothing is
wrong, that's a bug.

---

## 6. Data model

Full DDL is in the migration. What matters conceptually:

**`users`** — one row per human (I1). `active_mode` persists the last mode so refresh
restores it. `home_location` is a PostGIS point driving distance ranking.

**`orgs`** — public-readable (they're listings). `auto_accept` decides whether signups land
in `accepted` or `applied`. `verification_status` and `ein` exist now; verification is M6.

**`org_members`** — the only source of coordinator permission. Role `owner` or
`coordinator`. Owner can manage membership; both can run shifts.

**`opportunities`** — one of three kinds:
- `event` — one dated block, inserts a single shift on publish.
- `recurring` — carries an `rrule` and `duration_minutes`; shifts materialize forward.
- `project` — deadline and `estimated_hours`, often remote, usually application-gated.

**`shifts`** — the concrete dated block people actually sign up for.
`unique (opportunity_id, starts_at)` is the idempotency key that lets materialization
re-run safely.

**`signups`** — the lifecycle object, one per (shift, user). Every beat gets its own
timestamp column so funnel analysis needs no event log join. `cancelled_by_org`
distinguishes "they cancelled on me" from "I cancelled"; `excused_by` records who forgave
an absence.

**`hour_entries`** — append-only ledger (I3). Negative `minutes` with `reverses` set is how
a correction is made. `hour_entries_one_per_signup` (partial unique) stops double-minting.
`verification_tier` is generated, not stored by the caller — `attested` / `device` /
`self`, in descending order of how much weight the export puts on it.

**`scheduled_reminders`** — the dispatcher's queue. `unique (signup_id, kind)` makes
scheduling idempotent — re-running the scheduler never double-sends.

**`shift_fill`** view — capacity, filled, confirmed, waitlisted, ratio. The org dashboard
and roster both read from here rather than recomputing.

---

## 7. The signup state machine

This is the product. Everything else is chrome around it.

```
                ┌──────────┐
                │ applied  │  (org requires application)
                └────┬─────┘
       auto_accept   │
   ┌────────────────┐│┌──────────────┬─────────────┐
   ▼                ▼▼▼              ▼             ▼
┌──────────┐   ┌──────────┐    ┌──────────┐  ┌──────────┐
│waitlisted│──►│ accepted │───►│confirmed │  │ declined │
└────┬─────┘   └────┬─────┘    └────┬─────┘  └──────────┘
     │              │  │            │  │
     │              │  └────────────┼──┴──────┐
     │              ▼               ▼         ▼
     │         ┌──────────┐   ┌──────────┐  ┌──────────┐
     └────────►│cancelled │   │checked_in│  │ no_show  │
               └──────────┘   └────┬─────┘  └──────────┘
                                   ▼
                             ┌──────────┐
                             │completed │
                             └──────────┘
```

Legal transitions (mirrors `signup_legal_transition()` exactly — keep them in sync):

| From | To |
|---|---|
| `applied` | `accepted`, `waitlisted`, `declined`, `cancelled` |
| `waitlisted` | `accepted`, `cancelled`, `declined` |
| `accepted` | `confirmed`, `checked_in`, `cancelled`, `no_show`, `excused` |
| `confirmed` | `checked_in`, `cancelled`, `no_show`, `excused` |
| `checked_in` | `completed`, `no_show` |
| `no_show` | `excused` — the only edge out of a terminal state |
| `completed` / `excused` / `cancelled` / `declined` | terminal |

`accepted → checked_in` is deliberately legal: someone who never tapped confirm but
physically showed up gets checked in and credited. Reality outranks the funnel.

**Capacity and races.** Placement happens in `signups_place_on_insert()` with the shift row
locked. Two people racing for the last spot: one gets `accepted`, the other is already
`waitlisted` at position 1 by the time the insert returns. The UI never shows an error for
this — it shows "That spot just filled — you're first on the waitlist" (§12.2).

**Waitlist promotion** is FIFO by `waitlist_position`, fired by `signups_promote_waitlist()`
on any vacancy. Promotion schedules the confirm reminder like any other acceptance.

---

## 8. Milestones

### 8.0 — Why the lifecycle ships before discovery

The obvious order is discovery then lifecycle: let people find shifts, then run them. It's
wrong, and it's the most expensive thing to get wrong here.

Discovery is the marketplace half. With three organizations on the platform it is an empty
room — a volunteer opens the feed, sees two dog-walking shifts nine miles away, and never
returns. It cannot work before density exists, and density is months of sales away.

The lifecycle loop is the **single-player half**. A food bank with forty volunteers it
already has gets real value on day one — roster, check-in, grant-ready hours — with zero
other orgs on the platform and zero volunteers acquired through it. Volunteers arrive by
invite link. Nothing about that requires a marketplace.

So: build the tool, earn the density, then open the feed. Come for the tool, stay for the
network. This also makes the four-consecutive-weeks bar in §11 reachable months earlier,
because it never depended on discovery in the first place.

The corollary is a sales requirement, not an engineering one: **name a design partner before
M2 starts** and let their actual shift structure drive the listing composer. Five milestones
built before a single organization touches the product is the real risk here, and no amount
of spec detail reduces it.

### M1 — Foundation: auth, profile, mode toggle

Supabase project provisioned, init migration applied, magic-link + OAuth (Google, Apple)
auth, onboarding capturing name, city (geocoded to `home_location`) and interests, the
`mode-switch` component persisting `users.active_mode`, layout shells for both modes with
correct accent theming, per-mode bottom navs.

**Toggle placement — the Fiverr/Airbnb pattern.** The mode switch lives in the **Profile
section, not the persistent header.** Profile is the last item in the bottom nav in both
modes. Tapping it opens the profile screen; the switch sits at the top as a full-width card
carrying the accent of the *destination* mode as its visual cue.

Rationale: mode switching is a rare, deliberate act. A header toggle overweights it,
invites accidental flips, and spends the most valuable pixels on the screen on something
the user does once a week. The header stays clean — wordmark plus one contextual action.

> The mock renders the switch inside a bottom sheet opened from the header avatar. That was
> a prototyping convenience. **Build it in Profile.** The sheet's visual treatment — the
> mode card, the pill switch, the thumb animation — carries over; its entry point does not.

The toggle contract:
1. Update `active_mode` optimistically; reconcile on response.
2. Toggle `body.org`.
3. Play the re-tint, then route to the destination mode's home.
4. If the user has no `org_members` rows, the org entry point reads **"Set up your
   organization"** and routes to create-org instead of dashboard.
5. A small accent-colored dot on the profile nav icon indicates current mode at a glance —
   no persistent control needed.
6. Announce the change to screen readers: `"Organization mode"` / `"Volunteer mode"` via a
   polite live region.

**Accept**
- New user signs up and lands in volunteer home.
- Header contains no mode control anywhere in either mode.
- Profile switch flips mode with re-tint and route change.
- Non-member sees the setup path, not an empty dashboard.
- Hard refresh restores the last active mode.
- Reduced-motion users get an instant swap with no animation.

---

### M2 — Orgs and listings

Create-org flow: name, slug (auto from name, editable, uniqueness-checked live), mission,
location via geocode, cause tags, EIN stored with `verification_status = 'pending'`
(verification stubbed). Invite coordinators by email via `org_invites`.

Listing composer with a **kind picker first** — event / recurring shift / project — that
changes the rest of the form. Recurring: weekday picker + start time + duration →
generates an RRULE string, and always shows a plain-language preview
("Every Tue & Thu, 6:00–8:00 PM"). Never show a user a raw RRULE. Publish / pause /
archive.

**Materialization.** `cron/materialize` runs daily. For each published recurring
opportunity it rolls shifts forward to an **8-week horizon**, writing
`materialized_through`. Idempotent via `unique (opportunity_id, starts_at)` — use
`on conflict do nothing`, never a read-then-write check. Events insert their single shift
on publish. Pausing stops materialization but leaves existing shifts; archiving cancels
future shifts that have no signups and leaves the rest.

DST is the trap here: generate occurrences in the opportunity's local timezone, then
convert to UTC. Generating in UTC and adding 7 days drifts an hour twice a year.

**Accept**
- Coordinator creates all three kinds.
- A recurring listing shows 8 weeks of shifts immediately after publish.
- Re-running the cron creates zero duplicate rows (assert count before and after).
- A weekly 6 PM shift spanning a DST boundary stays at 6 PM local on both sides.
- RLS blocks a non-member from reading a draft (test as a second authenticated user, not
  as anon).

---

### M3 — The lifecycle loop

**This milestone is the company.** All four beats ship together; three of four is worth
nothing.

It runs before discovery deliberately (§8.0). Volunteers reach a shift here through an
**org invite link**, not a feed: the coordinator shares a link to an opportunity, the
volunteer signs up against it, and the entire loop runs. That is enough for one real
organization to run four consecutive weeks of real shifts — the bar set in §11 — with no
marketplace underneath it.

#### Confirm
On acceptance, schedule `confirm_48h` (T−48h) and `logistics_2h` (T−2h) in
`scheduled_reminders`. If acceptance happens inside 48h, schedule `confirm_48h` for
now + 10 minutes rather than skipping it. `cron/reminders` runs every 5 minutes and
dispatches due rows by web-push with email fallback. The confirm push deep-links to a
one-tap "I'm coming" → `accepted → confirmed`.

#### Check-in
Org roster screen per shift: every attendee row has a check-in button, and the screen
renders a shift QR code carrying a signed JWT (`shift_id` + `exp`, 12-hour expiry, signed
with a server-side secret). Volunteer scans → `POST /api/checkin` verifies signature and
that now is inside the shift window ±30 min → `confirmed|accepted → checked_in`.

Geofence assist: within 150 m of `opportunities.location` during the window, volunteer home
surfaces a "Check in now" card. Geofence is an *assist*, never a gate — a volunteer whose
GPS is confused must still be checkable-in by the coordinator.

Check-out on tap, or automatically at `ends_at`.

#### Hours
On `checked_in → completed`, mint an `hour_entries` row:
`minutes = clamp(checkout − checkin, 15, shift_duration + 30)`, `source` = the method used.
Coordinator manual entry is allowed with `verified_by` set. This is trigger-owned
(`signups_mint_hours`) so it cannot be forgotten by a code path.

**Every entry carries a verification tier**, generated from how it was earned:

| Tier | Means | Earned by |
|---|---|---|
| `attested` | A named coordinator vouched for it | `verified_by` set |
| `device` | A scan or a location fix | `qr`, `geofence` |
| `self` | The volunteer said so | `self`, `adjustment` |

This matters because a QR code is one screenshot away from forgery. If the ledger is going
to back court-ordered service or NHS hours, it has to be honest about the strength of each
line rather than flattening everything into a single total. The export **shows the mix**
("48 hours · 41 coordinator-attested"). The first time a school administrator catches a
fabricated total, the entire value proposition dies — so the product never claims more
than it can defend.

Volunteer hours screen: mono-type ledger, running totals, per-org breakdown, tier shown
per entry, and **Export PDF**.

#### Close the loop
`cron/noshow` runs every 15 minutes and sweeps shifts that ended 2+ hours ago:
`confirmed` never checked in → `no_show`; `checked_in` never checked out → `completed`
with checkout at `ends_at`. Then `post_event_thanks` fires with hours earned plus the org's
impact stat if one was logged ("You helped serve 340 meals"). The coordinator gets a prompt
to log an `impact_stats` metric on the roster screen once the shift ends.

#### 8.5 — Cancellation and correction

Two paths the original brief left out. Both are high-emotion moments, and both corrupt the
metrics if handled badly.

**The org cancels a shift.** The angriest moment in the product: twelve people rearranged a
Saturday. `cancel_shift(shift_id, reason)` stamps `shifts.cancelled_at`, releases every
open signup to `cancelled` with `cancelled_by_org = true`, queues an immediate
`shift_cancelled` notification for each person, and voids the pending confirm and logistics
reminders for a shift that is no longer happening. `cancelled_by_org` is permanent, so
"you cancelled" and "they cancelled" never read the same in the volunteer's own record.
Copy names the reason and the org, and offers the nearest alternative shift inline.

**The coordinator excuses an absence.** `no_show` is otherwise a permanent mark applied by
a cron sweep to someone whose kid got sick and who texted the coordinator about it. The
`excused` status is the only edge out of a terminal state, requires `excused_by`, and sits
in **neither** the numerator nor the denominator of show rate. Without it, coordinators
watch the product blame volunteers they know had good reasons, and stop trusting the one
number Turnout sells on. The roster screen offers "Excuse" on any `no_show` row for 7 days
after the shift.

**Accept**
- Full happy path end-to-end on two real phones, volunteer and coordinator.
- No-show sweep produces correct statuses across a mixed roster (confirmed-absent,
  checked-in-not-out, completed).
- The ledger rejects UPDATE and DELETE at the database level — assert the exception, don't
  assume.
- Excusing a `no_show` moves show rate up and does not mint hours.
- Cancelling a shift with 12 signups produces 12 notifications, 12 `cancelled_by_org` rows,
  and zero orphaned pending reminders.
- PDF export renders with correct totals, typography, and tier breakdown.
- A volunteer who never confirms but is checked in by the coordinator still gets hours.

---

### M4 — Discovery and signup

Now that shifts exist and orgs are running them, the feed has something in it.

Discover feed: published opportunities ranked by distance using the PostGIS `<->` operator
against `users.home_location`, filterable by cause tag, kind, and "this week". Remote
projects sort into their own band rather than pretending to have a distance.

Opportunity page by kind:
- **Recurring** — shift picker with **multi-select**. This is the differentiator: "every
  Friday this month" is one tap and inserts one signup per selected shift, in a single
  transaction. Partial failure rolls the whole set back.
- **Event** — single RSVP.
- **Project** — apply with answers against `opportunities.questions`.

Auto-accept orgs go straight to `accepted`; others land in `applied`. Capacity full →
`waitlisted` with position shown honestly ("2nd on the waitlist"). Cancel with a
confirmation step that names what's being cancelled.

**Accept**
- Volunteer books 4 Friday shifts in one action; 4 signups exist; the ledger of upcoming
  shifts reflects all 4.
- Capacity is respected under concurrent load (test: 10 parallel inserts on a 5-capacity
  shift → exactly 5 accepted, 5 waitlisted with positions 1–5, no duplicates).
- Cancelling an accepted signup promotes the first waitlisted person and schedules their
  confirm reminder.
- Volunteer home "Up next" matches the database.

---

### M5 — Org intelligence

Dashboard fill-rate cards from `shift_fill`, amber under 70%. "Nudge past volunteers" —
push/email to people who previously completed a shift on that opportunity, **max one nudge
per person per week**, enforced in `reminders.ts` against the `reminders_nudge_idx` index,
not in the UI. Applicant review queue. 30-day stats strip from `org_stats_30d`. CSV and PDF
report export for grant reporting (hours by program by month).

**Accept**
- Show rate matches a hand calculation from the signups table.
- A second nudge inside 7 days is refused at the library level (unit test, not a UI check).
- Grant report exports and opens correctly in Excel and Sheets.

---

### M6 — Trust layer (spec only, do not build)

Org verification against IRS Pub 78 / 990 data on EIN → `verified` badge. Volunteer identity
verification (Stripe Identity or Persona) → "Verified" on ledger exports. Background-check
vendor webhook writing into `signups.answers`. Columns and stubs exist in the schema; leave
them alone until M1–M5 are accepted.

---

## 9. API surface

| Route | Method | Auth | Contract |
|---|---|---|---|
| `/api/checkin` | POST | user | `{ token }` (QR JWT) or `{ shiftId, lat, lng }` (geofence). → `{ status, checkedInAt }`. 409 outside window, 403 bad signature. |
| `/api/hours/export` | POST | user | → signed PDF stream. |
| `/api/cron/materialize` | GET | `CRON_SECRET` | Daily. → `{ created, opportunities }`. |
| `/api/cron/reminders` | GET | `CRON_SECRET` | Every 5 min. Claims due rows `for update skip locked`. → `{ sent, failed }`. |
| `/api/cron/noshow` | GET | `CRON_SECRET` | Every 15 min. → `{ noShows, autoCompleted }`. |
| `rpc/cancel_shift` | RPC | coordinator | `(shift_id, reason)` → count notified. Releases signups, voids pending reminders. |
| `rpc/excuse_signup` | RPC | coordinator | `(signup_id, reason)` → `no_show → excused`. Available 7 days post-shift. |

All cron routes verify `Authorization: Bearer ${CRON_SECRET}` and are idempotent — assume
Vercel will occasionally invoke twice.

---

## 10. Cross-cutting requirements

**Push.** Web-push with VAPID. Permission is requested **only after the first successful
signup** — never on landing, never on login. A person who has committed to a shift
understands why we'd notify them. Every reminder has an email fallback; a push that fails
to deliver falls through to Resend in the same dispatcher pass.

**Notification budget.** Three pushes per shift × a weekly volunteer is twelve a month,
which is how a product that claims to respect people's time gets its notifications turned
off in the first fortnight. The dispatcher enforces, in `reminders.ts`:

- **Quiet hours.** Nothing dispatches between 21:00 and 08:00 *shift-local*. A reminder due
  inside that window is held to 08:00, except `shift_cancelled`, which always goes
  immediately — someone needs to know before they drive there.
- **Daily cap.** Maximum 3 notifications per user per day, counted against
  `reminders_budget_idx`. Over the cap, the lower-priority reminder is marked `skipped`
  rather than queued forever. Priority order: `shift_cancelled` > `confirm_48h` >
  `logistics_2h` > `post_event_thanks` > `nudge`.
- **Veteran suppression.** Skip `logistics_2h` for anyone who has completed the same
  opportunity three or more times. They know where the north gate is. This is the cheapest
  fatigue win available and it costs nothing in show rate.
- Rate limits live in the library, never in the UI. A screen that hides a button is not a
  rate limit.

**Timezones.** Store UTC. Render in the shift's timezone (I5). Reminder send times are
computed against shift-local time, so a T−48h reminder for a 9 AM Saturday shift lands at
9 AM Thursday *there*.

**Testing.**
- Vitest: `rrule.ts` window logic (including DST boundaries), `reminders.ts` scheduling and
  the nudge rate limit, the hours clamp.
- pgTAP: the transition trigger, enumerating **every** legal transition and a representative
  sample of illegal ones; the append-only ledger; the capacity race.
- Playwright: signup → book → confirm → check-in → hours, plus visual regression on both
  home screens, profile + switch, every empty state, and the check-in success state.

**Seed script.** `pnpm seed` creates 3 orgs, 12 opportunities across all kinds, 40 fake
volunteers, and signups in every status, so every screen has real-looking data on first
run. An empty-state screen and a full screen must both be reachable without hand-crafting
rows.

**Metrics (PostHog).** Volunteer side: `signup_created`, `signup_confirmed`, `checked_in`,
`no_show`, `excused`, `second_shift_booked`. Org side: `org_created`, `listing_published`,
`shift_materialized`, `roster_opened`, `checkin_performed`, `impact_logged`. Instrumented
from day one — the north star is unmeasurable retroactively.

A funnel instrumented on one side only cannot tell you which side is leaking. The original
brief listed volunteer events exclusively; if orgs publish listings nobody books, that is a
completely different problem from volunteers browsing listings that don't exist, and the
volunteer events alone cannot distinguish them.

**North star vs. operating metric.** Second-shift conversion stays the north star, but it
lags by weeks and it punishes orgs that run monthly rather than weekly — a volunteer who
would happily return has no shift to return to, and the metric reads that as churn. Operate
day to day on **show rate** (`confirmed → checked_in`): per-shift, immediate, felt directly
by coordinators, and the thing the product actually claims to fix. Watch show rate; report
second-shift.

**Performance floor.** LCP < 2 s on mid-range mobile. Every interactive element
keyboard-reachable. Reduced-motion respected on the mode transition.

---

## 11. Explicit non-goals

No payments, no donations, no corporate tier, no chat or DMs, no reviews or ratings, no
native apps, no multi-language, no free-text search (feed plus filters only), no admin
panel beyond org dashboards.

Resist all of these until M1–M5 acceptance passes **and** one real organization has run
four consecutive weeks of shifts through the system.

---

## 12. Quality floor — "complete product, minimum surface"

Scope stays M1–M5. Everything inside it ships at flagship quality. Each item below is an
acceptance criterion for its milestone, not a nice-to-have. No placeholder energy anywhere.

### 12.1 Empty states are product, not absence
- **Org mode, no org.** Full-bleed, illustration-quality. Headline: "Run your program from
  your pocket." Sub: what setup takes (2 minutes) and what they get — roster, check-in,
  grant-ready hours. One button.
- **Volunteer schedule, nothing booked.** "Your calendar is open. Something near you starts
  this week." Plus the top 2 nearby cards rendered inline — not a link to go find them.
- **Hours ledger at zero.** Show the ledger frame with 0s and the line "Every hour you serve
  is recorded here, verified, and yours to keep." The empty ledger teaches the value prop.
- **Discover, no results in filter.** Never "No results." Always the nearest relaxation:
  "Nothing for Animals this week — 4 opportunities next week," with a one-tap filter adjust.

### 12.2 Error states in product voice
- Every failure path has human copy, an action, and preserved input. No raw error strings,
  no toast-and-shrug.
- **Offline.** Check-in queues locally and syncs — volunteers are in basements and fields.
  Banner: "You're offline — your check-in is saved and will sync."
- **Capacity race.** The loser of a race sees "That spot just filled — you're first on the
  waitlist," already done. Not an error, not a retry.

### 12.3 Motion and feel
- **Mode re-tint:** 300 ms, cubic-bezier with slight overshoot on the switch thumb; content
  cross-slides 14 px. `prefers-reduced-motion` swaps all of it for an instant state change.
- **Check-in:** optimistic, sub-second perceived. Success is an amber pulse, a haptic
  (Vibration API), and the row settling into "In ✓". This moment is the product's heartbeat.
  It should feel like a stamp, not a spinner.
- **Confirm CTA:** physical depress, `scale(.97)` over 80 ms. All primary buttons share it.
- **Lists:** stagger in 30 ms apart, once, on first paint only. Never re-animate on tab
  return.

### 12.4 Copy standards
- Push notifications read like a good coordinator texts: "Tomorrow 9 AM — pantry shift at
  Eastside. Still in?" `[I'm in]` `[Can't make it]`. Two-button actionable pushes wherever
  the platform allows.
- Post-event push always leads with the volunteer's number: "2.5 hours logged. You helped
  serve 340 meals." Screenshot-worthy is the bar.
- No exclamation-point inflation. Warmth through specificity, not punctuation.
- Dates humanized within 7 days ("Tomorrow", "Thursday"), absolute after.

### 12.5 Perceived performance
- Skeletons match final layout exactly — zero layout shift on load. Ledger numbers count up
  on first render only.
- Tab navigation is instant (prefetched). Data revalidates in the background and never
  blocks paint with a spinner when any cached state exists.
- The QR roster screen renders offline from last sync. A coordinator in a park with no
  signal can still check people in.

### 12.6 Accessibility as craft
- Full keyboard path through booking and check-in. Visible focus states in the accent color.
- Mode announced to screen readers on switch. Fill bars carry
  `aria-valuetext="6 of 10 filled"`.
- All accent-on-paper combinations ≥ 4.5:1. Both accents were chosen to pass; verify in CI
  with axe rather than trusting it.

### 12.7 Details that read as trust
- The ledger PDF is typeset properly — same type system, org attestation lines, subtle paper
  texture. A document someone hands a school administrator with confidence. It reports the
  **verification mix**, not just a total ("48 hours · 41 coordinator-attested · 7 device").
  Overclaiming here is the one credibility mistake the product cannot recover from.
- Org verification pending state says what's happening: "Checking IRS records — usually
  under 24 h." Never a bare missing badge.
- 404, error, and maintenance pages all carry the design system. Nobody ever sees a default
  anything.

### 12.8 CI enforcement
- Playwright visual regression: both home screens, profile + switch, every empty state,
  check-in success.
- axe-core passes on every route.
- Lighthouse CI: performance ≥ 90 mobile on home screens; PWA installable check green.
- Supabase type drift fails the build.

---

## 13. Open decisions

Flagged rather than guessed. None block M1.

1. **Geocoding provider** — Mapbox, Google, or Nominatim. Affects cost and the create-org
   and onboarding flows. Needed by M2.
2. **QR JWT secret rotation** — single long-lived server secret vs. per-org keys. Per-org
   is better if orgs ever self-host displays. Needed by M3.
3. **PDF generation** — React-PDF (typography control, heavier bundle) vs. a rendering
   service. §12.7 sets a high bar; React-PDF is the safer bet. Needed by M3.
4. **"Signed" in "signed PDF summary"** — a cryptographic signature with a public verify
   endpoint, or a visual attestation with a verification URL. The second is far cheaper and
   probably enough for a school administrator, *given* that the export now reports its
   verification mix honestly rather than asking the reader to trust a bare total. Decide
   before building the export.
5. **Project hours** — projects have no shift window, so the clamp in M3 doesn't apply.
   Proposal: self-reported hours with coordinator approval, `source = 'self'` until
   `verified_by` is set. Needs a decision before projects can log hours at all.
