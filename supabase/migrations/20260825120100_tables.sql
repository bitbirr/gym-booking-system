-- 20260825120100_tables.sql
-- Simple Gym Booking System — core tables (all in the `gym` schema).
--
-- Tables: gym.profiles, gym.session_templates, gym.sessions, gym.bookings.
-- Money-free domain, so no numeric columns. All timestamps are timestamptz.
-- The auth.users reference stays as-is (SHARED across the project).
-- FKs use RESTRICT on booking references to preserve history (soft-cancel,
-- never hard-delete a booked session or member). Reconciles data-model §3.

-- ---------------------------------------------------------------------------
-- gym.profiles: 1:1 with the shared auth.users. App-level identity + role.
-- Populated automatically by a trigger on auth.users (see functions migration).
-- ---------------------------------------------------------------------------
create table if not exists gym.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text,
  email       text,
  role        gym.user_role not null default 'member',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table  gym.profiles is 'App identity + role, 1:1 with shared auth.users. role is not self-writable (enforced by trigger + RLS).';
comment on column gym.profiles.role is 'member | staff. Set out-of-band by an admin; drives RLS.';

-- ---------------------------------------------------------------------------
-- gym.session_templates: recurrence source. A template describes a weekly slot;
-- dated instances are materialised into gym.sessions over a date window by
-- gym.generate_sessions_from_template(). One-off sessions have no template.
-- ---------------------------------------------------------------------------
create table if not exists gym.session_templates (
  id                uuid primary key default gen_random_uuid(),
  activity          text not null,
  coach_name        text,
  weekday           smallint not null,                 -- 0=Sunday .. 6=Saturday (matches PostgreSQL extract(dow))
  start_time        time not null,
  end_time          time not null,
  timezone          text not null default 'UTC',       -- IANA tz used to place start_time/end_time on a calendar day
  default_capacity  integer not null,
  active            boolean not null default true,
  created_by        uuid references gym.profiles (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint session_templates_weekday_ck  check (weekday between 0 and 6),
  constraint session_templates_time_ck     check (end_time > start_time),
  constraint session_templates_capacity_ck check (default_capacity > 0)
);

comment on table  gym.session_templates is 'Recurring-slot definition. Instances are generated into gym.sessions over a date window.';
comment on column gym.session_templates.weekday  is '0=Sunday .. 6=Saturday, matching PostgreSQL extract(dow from ...).';
comment on column gym.session_templates.timezone is 'IANA timezone used to combine the day with start_time/end_time into a timestamptz.';

-- ---------------------------------------------------------------------------
-- gym.sessions: a single scheduled, bookable occurrence with a capacity.
-- template_id is NULL for one-off sessions. 'full' is NOT stored (derived).
-- ---------------------------------------------------------------------------
create table if not exists gym.sessions (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid references gym.session_templates (id) on delete set null,
  activity     text not null,
  coach_name   text,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  capacity     integer not null,
  status       gym.session_status not null default 'scheduled',
  created_by   uuid references gym.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint sessions_time_ck     check (ends_at > starts_at),
  constraint sessions_capacity_ck check (capacity > 0)
);

comment on table  gym.sessions is 'Bookable session instance. template_id NULL = one-off. status is scheduled|cancelled; fullness is derived, never stored.';

-- ---------------------------------------------------------------------------
-- gym.bookings: a member's reservation of a session. Soft-cancel only.
-- RESTRICT on both FKs preserves history; cancellation is a status change.
-- ---------------------------------------------------------------------------
create table if not exists gym.bookings (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references gym.sessions (id) on delete restrict,
  member_id     uuid not null references gym.profiles (id) on delete restrict,
  status        gym.booking_status not null default 'confirmed',
  created_at    timestamptz not null default now(),
  cancelled_at  timestamptz,
  constraint bookings_cancelled_at_ck
    check ((status = 'cancelled') = (cancelled_at is not null))
);

comment on table  gym.bookings is 'Member reservation. confirmed|cancelled only. Created via gym.book_session() RPC; cancelled via gym.cancel_booking().';
comment on constraint bookings_cancelled_at_ck on gym.bookings is 'cancelled_at is set iff status = cancelled.';

-- Down (manual rollback):
--   drop table if exists gym.bookings;
--   drop table if exists gym.sessions;
--   drop table if exists gym.session_templates;
--   drop table if exists gym.profiles;
