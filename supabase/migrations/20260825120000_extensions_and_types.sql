-- 20260825120000_extensions_and_types.sql
-- Simple Gym Booking System — schema, extensions, enum types.
--
-- TARGET: cloud-managed Supabase project BitBirrAI (ref kjxdclbzfmntnwpmpxcn),
-- a SHARED project (factory convention: one project, one Postgres schema per
-- app; auth.users is shared project-wide). ALL app objects live in the `gym`
-- schema so they never collide with other apps in the same project.
--
-- Reversible: see the `down` notes at the bottom of each migration.

-- Dedicated per-app schema. Everything below is gym.*-qualified.
create schema if not exists gym;

-- gen_random_uuid() is built into PostgreSQL 13+; pgcrypto is enabled explicitly
-- so intent is obvious. On Supabase Cloud extensions live in the `extensions`
-- schema (already on the default search_path). Column DEFAULTs resolve the
-- function OID at CREATE TABLE time, so they are safe regardless of later
-- per-function search_path.
create extension if not exists pgcrypto;

-- App-level role. Drives RLS. Set out-of-band by an admin (no self-serve staff).
do $$
begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'user_role' and n.nspname = 'gym'
  ) then
    create type gym.user_role as enum ('member', 'staff');
  end if;
end
$$;

-- Session instance lifecycle. NOTE: 'full' is deliberately NOT a value here.
-- Fullness is derived from live confirmed-booking counts (see the availability
-- view) so it can never drift. Matches ADR-0002.
do $$
begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'session_status' and n.nspname = 'gym'
  ) then
    create type gym.session_status as enum ('scheduled', 'cancelled');
  end if;
end
$$;

-- Booking lifecycle. Additive room for a future 'waitlisted' value.
do $$
begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'booking_status' and n.nspname = 'gym'
  ) then
    create type gym.booking_status as enum ('confirmed', 'cancelled');
  end if;
end
$$;

-- Down (manual rollback, run only after dependent objects are dropped):
--   drop type if exists gym.booking_status;
--   drop type if exists gym.session_status;
--   drop type if exists gym.user_role;
--   drop schema if exists gym;      -- only if empty
--   drop extension if exists pgcrypto;
