# Architecture — Simple Gym Booking System

Status: Proposed (initial architecture). Owner: Product Architect.
Date: 2026-08-25. Target: MVP shippable in 3–5 weeks, budget ~$5–9k.

This document is the technical picture for the MVP. It defines components,
the stack, the trust model, the API surface, and the non-functional plan
(with the capacity / no-double-book correctness strategy called out
explicitly). Significant one-way-door decisions are recorded as ADRs under
`docs/adr/`. The entity model for the data engineer lives in
`docs/data-model.md`.

---

## 1. Scope recap

In scope (the 6 backlog items):

1. Member-facing view of available sessions (date, time, coach/activity,
   capacity, remaining spots).
2. Booking flow — member selects a session and confirms a reservation.
3. Member booking lookup and cancellation.
4. Staff view to create, edit, cancel, and manage session capacity.
5. Booking status handling (confirmed, cancelled, full).
6. Validation to prevent duplicate bookings and bookings past capacity —
   including the concurrency race when two members book the last spot.

Out of scope for MVP: payments, waitlists, push/SMS/email notifications,
native mobile apps, external gym-system integrations. The architecture keeps
seams for these (see §9) but ships none of them.

---

## 2. Chosen stack (one line)

**Next.js (App Router, TypeScript) + Supabase (self-hosted PostgreSQL 17.6,
Auth, RLS) on the existing single Ubuntu VPS behind Traefik; capacity
correctness enforced in a single PostgreSQL transactional function.**

Rationale and rejected options are in `docs/adr/0001-stack-selection.md`.

| Layer | Choice | Trade-off / why | What would change it |
|---|---|---|---|
| Frontend | Next.js 15 (App Router), TypeScript, React Server Components | One framework covers UI + server API; huge hiring pool; SSR gives fast first paint for the class list. Trade-off: RSC/App Router has a learning curve vs. plain SPA. | If the team has zero React skill, SvelteKit is the fallback (same full-stack shape). |
| Styling / UI | Tailwind CSS + shadcn/ui | Fast to assemble accessible components in a 3–5 week window; no design-system build cost. Trade-off: opinionated markup. | A pre-existing house component library. |
| Backend / API | Next.js Route Handlers + Server Actions (Node runtime) | No separate service to deploy; backend and frontend ship as one container. Trade-off: couples web and API lifecycles. | If a second consumer (mobile app) appears, extract API into a standalone service. |
| Auth | Supabase Auth (email + password, magic-link optional) | Built into the house stack, gives JWT + RLS integration for free. Trade-off: identity requirements are unconfirmed (see assumption A1). | Firm SSO / membership-provider requirement from the gym. |
| Database | Supabase PostgreSQL 17.6 (self-hosted) | House standard; strong transactional guarantees are exactly what the capacity race needs. Trade-off: single-VPS = single failure domain. | Multi-region or managed HA requirement. |
| Data access | `supabase-js` from server + a small set of Postgres RPC functions for writes | RLS enforces ownership; RPC gives atomic booking. Trade-off: business logic split between TS and SQL. | Heavier domain logic would justify a real ORM/service layer. |
| Hosting | Existing Ubuntu VPS, Docker, Traefik reverse proxy + TLS | Zero new infra spend; reuses agency ops. Trade-off: shared host, no autoscale. | Traffic beyond a single node. |
| CI/CD | GitHub Actions → build image → deploy to VPS | Boring, proven. | — |

Automation (n8n) and vectors (Qdrant) from the house stack are **not used**
in the MVP. n8n is a natural home for later notification workflows (§9).

---

## 3. Component overview

```mermaid
flowchart TD
  subgraph Client["Browser (Member / Staff)"]
    UI["Next.js App Router UI<br/>React Server + Client Components"]
  end

  subgraph Edge["Ubuntu VPS · Traefik (TLS, routing)"]
    subgraph App["Next.js container (Node runtime)"]
      RH["Route Handlers /api/*<br/>+ Server Actions"]
      MW["Middleware<br/>session + role gate"]
    end
  end

  subgraph Supabase["Supabase (self-hosted)"]
    AUTH["Auth (GoTrue)<br/>JWT, users"]
    PG[("PostgreSQL 17.6<br/>tables + RLS + RPC")]
  end

  UI -->|HTTPS| MW --> RH
  UI -->|auth calls| AUTH
  RH -->|"supabase-js (user JWT)"| PG
  RH -->|"book_session() RPC"| PG
  AUTH -. issues JWT .-> UI
  PG <-. validates JWT / RLS .- AUTH

  classDef ext fill:#eef,stroke:#88a;
  class Supabase,AUTH,PG ext;
```

Responsibilities:

- **Next.js UI** — renders the session catalogue (SSR for speed and SEO-ish
  shareability), the booking and my-bookings pages, and the staff management
  screens. Client components handle interactivity (confirm dialogs, optimistic
  cancel).
- **Middleware** — reads the Supabase session cookie, refreshes it, and gates
  `/staff/**` routes to users whose role is `staff`.
- **Route Handlers / Server Actions** — the trust boundary. All writes go
  through here so the app never trusts client-supplied capacity/status. Reads
  can go direct to Postgres under RLS.
- **Supabase Auth** — issues JWTs, owns the `auth.users` table.
- **PostgreSQL** — the source of truth and the correctness authority. RLS
  enforces "a member sees only their bookings"; the `book_session` RPC
  enforces capacity atomically.

---

## 4. Data flow (the two flows that matter)

### 4.1 Browse available sessions (item 1)

1. Server Component fetches `sessions` joined with a live confirmed-booking
   count (via the `session_availability` view) filtered to future,
   non-cancelled sessions.
2. Rendered server-side; `remaining = capacity - confirmed_count`. A session
   with `remaining <= 0` renders as **Full** (booking disabled).
3. Public read: browsing does not require login (assumption A2); booking does.

### 4.2 Book a session — the critical path (items 2, 5, 6)

The booking is **never** a client-computed "count then insert". It is a single
atomic server call:

1. Client confirms → Server Action calls Postgres RPC `book_session(session_id)`
   with the caller's JWT.
2. Inside one transaction the function:
   - `SELECT ... FOR UPDATE` on the target `sessions` row (serialises all
     concurrent bookers of that session);
   - counts current `confirmed` bookings for the session;
   - rejects with `session_full` if `confirmed_count >= capacity`;
   - inserts the booking as `confirmed`, protected by a **partial unique index**
     on `(session_id, member_id) WHERE status = 'confirmed'` which rejects a
     duplicate active booking with `duplicate_booking`.
3. On success the row is committed; the browse count reflects it immediately.
4. Errors map to typed results the UI shows as "This class is now full" /
   "You already have a spot in this class".

This is the whole no-double-book / no-overbook guarantee. See
`docs/adr/0002-capacity-enforcement.md` for why the lock + partial-unique-index
combination is chosen over triggers or app-level checks.

Cancellation (item 3) sets the booking to `cancelled`, freeing a spot. Because
the unique index is partial on `status = 'confirmed'`, a member can re-book the
same class after cancelling without collision.

---

## 5. API surface (high-level)

All under the Next.js app. Writes are Server Actions / Route Handlers behind
auth; reads that are member-scoped rely on RLS. Shape, not final signatures.

| # | Concern | Method + path | Auth | Notes |
|---|---|---|---|---|
| 1 | List sessions | `GET /api/sessions?from&to&activity` | public | Reads `session_availability` view; includes `remaining`. |
| 1 | Session detail | `GET /api/sessions/:id` | public | Single session + availability. |
| 2 | Create booking | `POST /api/bookings` `{ session_id }` | member | Calls `book_session` RPC; returns `confirmed` \| `session_full` \| `duplicate_booking`. |
| 3 | My bookings | `GET /api/bookings/me` | member | RLS restricts to caller. |
| 3 | Cancel booking | `POST /api/bookings/:id/cancel` | member (owner) | Sets `cancelled`; RLS + ownership check. |
| 4 | Create session | `POST /api/staff/sessions` | staff | |
| 4 | Edit session | `PATCH /api/staff/sessions/:id` | staff | Capacity edits allowed; see §6 note on shrinking below current count. |
| 4 | Cancel session | `POST /api/staff/sessions/:id/cancel` | staff | Marks session cancelled; bookings cascade to `cancelled`. |
| 4 | Roster | `GET /api/staff/sessions/:id/bookings` | staff | Who is booked. |
| 5 | Status | derived, not a separate endpoint | — | `full` is computed (`remaining<=0`), not stored on the session; booking rows store `confirmed`/`cancelled`. |

Status model note (item 5): booking rows carry `confirmed` or `cancelled`.
"Full" is a **property of a session** (capacity reached), computed from the
live count — not a booking status and not persisted, so it can never drift.

---

## 6. Trust & auth model

Two principals: **member** and **staff**. One identity system (Supabase Auth);
role lives in a `profiles.role` column (`'member' | 'staff'`), surfaced as a
JWT claim via a custom access-token hook so RLS and middleware can read it
without an extra query.

Trust boundaries:

- The **browser is untrusted.** Capacity, status, and ownership are never
  decided client-side. The client may *request* a booking; only the RPC decides.
- **Route Handlers / Server Actions** are the enforcement point for writes and
  the only place the service role could ever be used (it is not needed for the
  member paths — those run under the user JWT so RLS applies).
- **RLS is the backstop**, on by default for every table:
  - `sessions`: `SELECT` public (or authenticated, per A2); `INSERT/UPDATE/
    DELETE` only for `role = 'staff'`.
  - `bookings`: a member may `SELECT`/`INSERT`/`UPDATE` only rows where
    `member_id = auth.uid()`; staff may `SELECT` all (roster).
  - `profiles`: a user reads/updates only their own row; role is not
    self-writable.
- **Staff routes** are additionally gated in middleware (`/staff/**`) so
  non-staff never render those pages — defence in depth, not the primary
  control (RLS is).

Capacity-shrink edge (item 4): staff lowering capacity below the current
confirmed count does **not** auto-cancel anyone. The session simply shows 0
remaining and over its new nominal capacity; the roster reveals it. Auto-bumping
members is a policy decision flagged for human confirmation (Q3).

Privacy (constraint): member PII is limited to name + email in `profiles`.
RLS prevents member-to-member visibility. See ADR-0003 and the security note in
§10 about the committed `.env`.

Full rationale: `docs/adr/0003-auth-approach.md`.

---

## 7. Non-functional plan

### 7.1 Correctness (the core concern)

Covered in §4.2 and ADR-0002. Summary of guarantees:

- **No overbooking:** row lock + in-transaction count check.
- **No duplicate active booking:** partial unique index (defends even if app
  logic is wrong or a request is replayed).
- **No status drift:** "full" is derived, never stored.
- The DB is the single authority; every write path funnels through it.

### 7.2 Scale & performance

- Expected load is small (single gym: hundreds of members, tens of concurrent
  bookers at a class-drop). A single VPS + Postgres handles this comfortably.
- The only hot row is a popular session during its booking window; the
  `FOR UPDATE` lock serialises just that session's bookers — contention is
  bounded and brief.
- Indexes: `sessions(starts_at)` for the catalogue query; partial unique index
  on bookings (above); `bookings(session_id) WHERE status='confirmed'` for the
  count. Details in `docs/data-model.md`.
- Availability via a `session_availability` **view** (or later a materialised
  view if the count query gets hot). Start with a plain view; measure first.

### 7.3 Cost

- Reuses existing VPS + Supabase + Traefik → effectively $0 new infra.
- Budget goes to build time, not run cost. Fits $5–9k comfortably as a
  single-developer 3–5 week build.

### 7.4 Failure modes

| Failure | Effect | Mitigation |
|---|---|---|
| Two members book the last spot simultaneously | One wins, one gets `session_full` | Row lock + count in one txn (by design) |
| Duplicate submit / double-click / retry | At most one confirmed booking | Partial unique index (idempotent-ish) |
| VPS down | Full outage (single node) | Accepted for MVP; document RTO; nightly Postgres backup |
| Postgres data loss | Bookings lost | Automated daily backups + PITR if Supabase WAL retention allows; verify restore |
| Supabase Auth down | No login; browsing (public) still works | Accepted; browsing degrades gracefully |
| Long-running booking txn | Brief lock hold | Keep RPC minimal; short statement timeout |

---

## 8. Proposed repo structure & build sequence

### 8.1 Repo structure (target — not scaffolded yet)

```
gym-booking-system/
  ARCHITECTURE.md
  README.md
  .env.example                # committed template; real .env must be gitignored (see §10)
  docs/
    data-model.md
    adr/
      0001-stack-selection.md
      0002-capacity-enforcement.md
      0003-auth-approach.md
  supabase/
    migrations/                # SQL owned by the data engineer
    seed.sql
  src/
    app/
      (public)/                # catalogue, session detail
        sessions/
      (member)/                # my-bookings, book confirm
      (staff)/                 # staff/sessions management
      api/                     # route handlers (bookings, staff)
      layout.tsx
    components/                # shadcn/ui + app components
    lib/
      supabase/                # server & browser clients
      auth/                    # role helpers, middleware guard
      bookings/                # server actions calling RPC
    types/                     # generated DB types
  middleware.ts
  package.json
```

### 8.2 Build sequence — vertical slices, ordered by risk then value

Each slice is shippable end to end (DB → API → UI). Riskiest correctness work
goes first while there is schedule slack.

| Order | Slice | Backlog items | Why here |
|---|---|---|---|
| 0 | Foundation: repo scaffold, Supabase clients, auth wiring, `profiles.role`, RLS baseline | (enables all) | Everything depends on it; proves auth + RLS early. |
| 1 | **Booking correctness core**: `sessions`/`bookings` schema, partial unique index, `book_session` RPC + concurrency test | 6, then 2, 5 | The one-way-door risk. Build and load-test the race first. |
| 2 | Member catalogue (SSR list + detail with `remaining`/Full) | 1 | Unlocks the primary user journey; read-only, low risk. |
| 3 | Booking flow UI on top of slice 1 | 2, 5 | Wires the proven RPC to the UI. |
| 4 | My-bookings + cancel | 3 | Completes the member loop; exercises RLS ownership. |
| 5 | Staff management (create/edit/cancel sessions, capacity, roster) | 4 | Higher surface area, but depends on stable schema from slice 1. |
| 6 | Polish: empty/full states, validation copy, backups verified, deploy via Traefik | 5, NFRs | Hardening before handoff. |

Order rationale: item 6 (correctness) is the only true one-way door in the
build, so it is slice 1 — a wrong data-layer decision here is expensive to
reverse after data exists. Reads (item 1) are cheap and reversible, so they
follow. Staff tooling (item 4) is broad but low-risk once the schema is fixed.

---

## 9. Seams left for out-of-scope features

- **Waitlists**: `bookings.status` is an enum; adding `waitlisted` + a promote
  step on cancellation is additive. The RPC is the natural place.
- **Notifications**: booking/cancel events can emit to **n8n** (house stack) via
  a webhook or a Postgres `NOTIFY`/outbox table — no app rewrite.
- **Payments**: a `payment_status` column on bookings and a pre-confirm hook;
  the confirm step already funnels through one RPC.
- **Mobile app**: the API is already HTTP + JWT; extract Route Handlers into a
  standalone service if a second consumer appears.

Design-for-deletion: every out-of-scope concern is one table column or one new
handler away, and none is load-bearing now.

---

## 10. Security note (action required)

The repository's `.env` currently contains **live secrets** (Supabase service
role key, OpenAI, Slack, Notion, Asana tokens) and appears to be tracked in
git. Before engineering starts: rotate those keys, remove `.env` from history,
commit a `.env.example` template, and add `.env` to `.gitignore`. Flagged to
the security lead. This is unrelated to the app design but is a real exposure.

---

## 11. Decisions: one-way vs two-way doors

One-way doors (decide carefully — recorded as ADRs):

- Capacity/no-double-book enforcement at the data layer (ADR-0002). Reversing
  after live bookings exist means data migration and risk to correctness.
- Database = self-hosted Supabase PostgreSQL (ADR-0001). Storage engine is
  costly to swap once data and RLS policies exist.
- Auth = Supabase Auth with role-as-claim (ADR-0003). Identity provider swaps
  touch every protected path.

Two-way doors (decide fast, iterate):

- Styling/component kit, folder layout, view vs materialised view, exact
  endpoint signatures, SSR-vs-client split per page. All cheap to change.

---

## 12. Assumptions

- **A1** — Identity is email + password via Supabase Auth (magic link optional).
  Requirements were unconfirmed; this is the pragmatic default. Confirm with
  the gym (Q1).
- **A2** — Browsing the catalogue is public (no login); only booking requires an
  account. Confirm (Q2).
- **A3** — One gym / one location for MVP; sessions are single-occurrence rows
  (no recurring-series generator). Recurrence is a fast-follow.
- **A4** — Staff accounts are provisioned manually (role set by an admin), not
  self-serve.

Open questions for a human before engineering: see the handoff summary (Q1–Q3).
