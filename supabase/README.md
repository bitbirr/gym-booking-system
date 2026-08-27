# Supabase — Simple Gym Booking System

PostgreSQL schema, RLS, and RPCs for the gym booking MVP. **All app objects live
in a dedicated `gym` schema.** See `../ARCHITECTURE.md`, `../docs/data-model.md`,
and `../docs/adr/0002-capacity-enforcement.md` / `0003-auth-approach.md`.

## Target: cloud-managed Supabase (BitBirrAI)

| Item | Value |
|---|---|
| Project | **BitBirrAI** |
| Ref | `kjxdclbzfmntnwpmpxcn` (eu-west-1, PostgreSQL 17.6.1) |
| API URL | `https://kjxdclbzfmntnwpmpxcn.supabase.co` |
| Publishable (anon) key | `sb_publishable_AaILsCWxPfJiyhVO8BtS6w_8fwSfBWT` |
| App schema | `gym` |

This is a **shared** cloud project (factory convention: one project, one Postgres
schema per app; `auth.users` is shared project-wide). Everything this app owns is
namespaced under `gym` so it never collides with other apps in the project. The
same migration files run locally under `supabase db reset` and against the cloud
project via the devops workflow.

### Expose `gym` to the API (required)

PostgREST only serves schemas on its exposed list. Add `gym` in **Settings → API
→ Exposed schemas** (or the `db-schema` / `[api] schemas` config). Then the
client must pin the schema:

```ts
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,   // sb_publishable_... (anon)
  { db: { schema: process.env.SUPABASE_SCHEMA ?? 'gym' } }
)
```

RPCs are called as usual (`supabase.rpc('book_session', { p_session_id })`); with
`db.schema = 'gym'` they resolve to `gym.book_session`. Public config lives in the
repo-root `.env.example`; the service-role key is server-only and never committed.

## Migration order

| File | Contents |
|---|---|
| `20260825120000_extensions_and_types.sql` | `create schema gym`; `pgcrypto`; enums `gym.user_role`, `gym.session_status`, `gym.booking_status`. |
| `20260825120100_tables.sql` | `gym.profiles`, `gym.session_templates`, `gym.sessions`, `gym.bookings`. |
| `20260825120200_indexes_and_constraints.sql` | Partial unique index (no-double-book), count/lookup/date indexes, template dedupe index. |
| `20260825120300_functions_and_views.sql` | Role helpers, `updated_at`/new-user/role-immutability triggers, `gym.book_session`, `gym.cancel_booking`, `gym.cancel_session`, `gym.generate_sessions_from_template`, `gym.session_availability` view. |
| `20260825120400_rls_policies.sql` | `gym` schema usage grants + table/function grants + RLS policies. |
| `seed.sql` | Local-dev templates + generated sessions + a one-off session. |

Each migration ends with a commented `Down` block for manual rollback. Never
edit an applied migration — add a new timestamped one.

## Apply locally

Requires Docker + the Supabase CLI. From the repo root:

```bash
# one-time, if supabase/config.toml is absent
supabase init

supabase start          # boot the local stack (Postgres, Auth, Studio, ...)
supabase db reset       # drop, re-run ALL migrations in order, then run seed.sql
```

`supabase db reset` rebuilds the schema from scratch and applies `seed.sql`;
these are the exact files that will ship to cloud. Studio is at
http://localhost:54323. For local API testing, add `gym` to the local exposed
schemas (in `supabase/config.toml` under `[api] schemas = ["public", "gym"]`).

To add a new migration:

```bash
supabase migration new <name>   # creates supabase/migrations/<ts>_<name>.sql
# edit it, then:
supabase db reset               # verify from clean state
```

## Try the correctness path locally

1. Sign up a user in Studio (Authentication → Users) — the `on_auth_user_created`
   trigger auto-creates their `gym.profiles` row (role `member`).
2. As that user (their JWT), book a seeded session:
   ```sql
   select gym.book_session('<session-id>');
   ```
3. Inspect availability (public read model):
   ```sql
   select id, activity, starts_at, capacity, confirmed_count, remaining, is_full
   from gym.session_availability order by starts_at;
   ```
4. Promote a user to staff to test management RPCs:
   ```sql
   update gym.profiles set role = 'staff' where email = 'you@example.com';
   select gym.generate_sessions_from_template(
     '11111111-1111-1111-1111-111111111111', current_date, current_date + 30);
   ```

The ADR-0002 gate is a concurrency test: fire N > capacity simultaneous
`book_session` calls at one session and assert exactly `capacity` confirmed rows,
the rest `session_full`; plus a duplicate-submit test asserting one confirmed
row. That test belongs with the backend engineer's suite.

## Prod path (do NOT run from here)

Production is the cloud BitBirrAI project. Any change goes through
**devops-engineer's** mutation workflow — authorize → preflight → verified
`pg_dump` backup → apply → verify → rollback-ready. Do not run
`apply_migration` / `execute_sql` against the cloud project from this repo.

Two prod-specific notes:

- **Indexes on populated tables:** the initial index migration uses plain
  `CREATE INDEX` (safe on empty tables). For any later index against a table that
  already holds rows, create it `CONCURRENTLY` in its own migration that is not
  wrapped in a transaction.
- **`security_invoker` view:** `gym.session_availability` intentionally runs with
  the view owner's rights so anon can see confirmed counts. Confirm the view
  owner (the migration role) can read `gym.bookings`, and never add
  member-identifying columns to it.

## Design decisions worth knowing

- **All app objects are in `gym`.** `auth.users` stays shared. The
  `on_auth_user_created` trigger fires on the shared `auth.users`, so it creates a
  `gym.profiles` row for **every** signup project-wide — see the note in the
  functions migration about optionally gating on app metadata.
- **Role source of truth = `gym.profiles.role` lookup** via the `SECURITY
  DEFINER` helpers `gym.is_staff()` / `gym.current_app_role()` (not a JWT claim).
  To switch to a custom access-token claim later, change only those two function
  bodies.
- **`gym.book_session()` is the only sanctioned booking-create path** (ADR-0002):
  locks the session row (`FOR UPDATE`), counts confirmed bookings, inserts — one
  transaction. The partial unique index `bookings_one_active_per_member` is the
  second guarantee (no duplicate active booking).
- **"Full" is derived, never stored** — see `gym.session_availability`
  (`remaining`, `is_full`). Matches ADR-0002.
