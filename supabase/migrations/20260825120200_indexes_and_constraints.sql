-- 20260825120200_indexes_and_constraints.sql
-- Simple Gym Booking System — indexes and the load-bearing correctness index.
-- All objects live in the `gym` schema.
--
-- These CREATE INDEX statements are plain (not CONCURRENTLY) because this is the
-- initial schema against empty tables. For a PROD change against a table that
-- already holds data, add indexes CONCURRENTLY in a separate, non-transactional
-- migration (see supabase/README.md → "Prod path").

-- ---------------------------------------------------------------------------
-- CORRECTNESS (backlog item 6): at most one CONFIRMED booking per (session,
-- member). Cancelled rows fall outside the partial index, so a member can
-- cancel and re-book cleanly. This is half of the no-double-book guarantee;
-- the other half is the row lock inside gym.book_session().
-- ---------------------------------------------------------------------------
create unique index if not exists bookings_one_active_per_member
  on gym.bookings (session_id, member_id)
  where status = 'confirmed';

-- Fast confirmed-count for the availability view and the book_session() count.
create index if not exists bookings_confirmed_by_session
  on gym.bookings (session_id)
  where status = 'confirmed';

-- My-bookings lookup (backlog item 3).
create index if not exists bookings_by_member
  on gym.bookings (member_id);

-- Catalogue queries filtered by date range (backlog item 1).
create index if not exists sessions_starts_at
  on gym.sessions (starts_at);

-- Browse future, scheduled sessions efficiently.
create index if not exists sessions_status_starts_at
  on gym.sessions (status, starts_at);

-- Recurrence: dedupe materialised instances so re-running the generator over an
-- overlapping window is idempotent (ON CONFLICT DO NOTHING keys off this).
-- Partial: only template-generated rows participate; one-off sessions (NULL
-- template_id) are unconstrained.
create unique index if not exists sessions_template_starts_at_uq
  on gym.sessions (template_id, starts_at)
  where template_id is not null;

-- Down (manual rollback):
--   drop index if exists gym.sessions_template_starts_at_uq;
--   drop index if exists gym.sessions_status_starts_at;
--   drop index if exists gym.sessions_starts_at;
--   drop index if exists gym.bookings_by_member;
--   drop index if exists gym.bookings_confirmed_by_session;
--   drop index if exists gym.bookings_one_active_per_member;
