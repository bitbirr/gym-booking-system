# ADR-0001: Stack selection

Status: Accepted
Date: 2026-08-25
Deciders: Product Architect (with data-lead and security-lead to confirm)
Door: One-way (storage/framework are costly to reverse after data + code exist)

## Context

We must ship the Simple Gym Booking System MVP (6 backlog items) in 3–5 weeks
on a ~$5–9k budget with a small team. The agency runs a self-hosted stack:
Supabase (PostgreSQL 17.6, Auth, RLS), Qdrant, n8n, Traefik on a single Ubuntu
VPS. The core technical risk is transactional correctness (no overbooking, no
duplicate bookings, including a concurrency race), which is a database concern.
Member PII needs privacy controls. We favour boring, proven technology and the
smallest surface a short MVP can carry.

## Options

1. **Next.js (App Router, TS) + Supabase Postgres, one deployable.**
   Full-stack React; server actions/route handlers as the API; Supabase for
   DB + Auth + RLS. Reuses the house VPS/Traefik.
2. **SvelteKit + Supabase.** Same full-stack shape, lighter client runtime,
   smaller hiring pool and fewer off-the-shelf components.
3. **Separate SPA (React) + standalone Node/Express (or NestJS) API +
   Postgres.** Clean service boundary, but two deployables and more glue for a
   3–5 week build.
4. **Django (Python) + Postgres + templates/HTMX.** Batteries-included,
   excellent transactional ORM; but diverges from the house Supabase/JS stack
   and its Auth/RLS integration.
5. Non-Postgres datastore (e.g. Mongo/Dynamo). Rejected outright: the capacity
   guarantee wants strong single-node ACID transactions; document stores make
   the race harder, and it breaks the house standard.

## Decision

Choose **Option 1: Next.js (App Router, TypeScript) + self-hosted Supabase
PostgreSQL 17.6 (Auth + RLS), deployed as a single Node container behind
Traefik on the existing VPS.** UI with Tailwind + shadcn/ui. Writes go through
Server Actions / Route Handlers; the critical booking write is a Postgres RPC.
n8n and Qdrant are unused in the MVP.

## Consequences

Positive:
- One framework, one deployable — least moving parts for a short timeline.
- Postgres gives exactly the transactional primitives the correctness concern
  needs (row locks, partial unique indexes, functions).
- Supabase Auth + RLS deliver member/staff isolation with little custom code.
- Zero new infra spend; reuses agency ops (VPS, Traefik, backups).
- Large hiring pool for React/Next.js and SQL.

Negative / trade-offs:
- Web and API share a lifecycle; a second consumer (mobile) would need the API
  extracted later (seam noted in ARCHITECTURE §9).
- App Router / RSC has a learning curve; mitigated by keeping data logic in the
  DB and lib layer, not scattered in components.
- Single VPS is one failure domain (accepted for MVP; see NFR failure modes).

Would change the decision: a hard requirement for a separately consumed API up
front, a team with no JS/React skill (→ SvelteKit or Django), or a mandated
managed-HA database (→ managed Postgres, same schema).

## Amendment — 2026-08-26 (hosting: self-hosted → cloud-managed)

Deciders: User directive ("use cloud hosted supabase and qdrant db for shared
memory").

**Change.** The database/auth is now **cloud-managed Supabase**, not the
self-hosted VPS instance. Shared cross-agent memory uses **cloud-hosted
Qdrant** (a factory-infra concern, unused by the gym app itself).

- Cloud project: **BitBirrAI** — ref `kjxdclbzfmntnwpmpxcn`, org BitBirr,
  region eu-west-1, PostgreSQL 17.6.1. API URL
  `https://kjxdclbzfmntnwpmpxcn.supabase.co`. Client uses the publishable key
  `sb_publishable_AaILsCWxPfJiyhVO8BtS6w_8fwSfBWT` (public; the service-role
  key stays server-only and out of git).
- **Schema isolation.** BitBirrAI is a *shared* cloud project (the factory's
  convention is one project, per-app Postgres schema — cf. the `SUPABASE_SCHEMA`
  env var; Supabase `auth.users` is shared project-wide). The gym app therefore
  lives in a dedicated **`gym`** schema, exposed to PostgREST, rather than
  `public`, to avoid table collisions with sibling projects (barber-shop, etc.).

**Why the decision otherwise stands.** Everything that made Option 1 correct —
Postgres row locks, the partial unique index, the transactional `book_session`
RPC, Auth + RLS — is identical on cloud-managed Supabase. Only the deploy
target and connection config change; the schema/migrations are portable SQL.

**Consequences of the change.** Positive: managed HA/backups, no VPS DB ops,
the "mandated managed-HA database" escape hatch above is now the chosen path.
Trade-off: shared `auth.users` means gym members and other factory apps' users
share one identity pool (accepted under the shared-project convention; revisit
if per-app identity isolation becomes a requirement — that would mean a
dedicated Supabase project). Migrations must be applied to the cloud project
via the devops mutation workflow, never ad hoc.
