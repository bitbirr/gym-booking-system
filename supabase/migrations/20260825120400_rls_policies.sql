-- 20260825120400_rls_policies.sql
-- Simple Gym Booking System — schema/grants + Row-Level Security (gym schema).
--
-- Model: default-deny. anon + authenticated may browse the catalogue
-- (gym.sessions, gym.session_templates, gym.session_availability). A member
-- reads/writes only their own bookings and profile. Staff manage
-- templates/sessions and read all bookings/profiles (rosters). Booking
-- create/cancel funnel through the SECURITY DEFINER RPCs, which bypass RLS but
-- pin identity to auth.uid().
--
-- SHARED-PROJECT note: on Supabase Cloud, anon/authenticated/service_role are
-- project-wide roles. For a custom schema they need explicit USAGE on `gym`
-- (they only get `public` by default). PostgREST must also be told to expose
-- `gym` (Settings → API → Exposed schemas / db-schema config) — see README.

-- ---------------------------------------------------------------------------
-- Schema usage. Without USAGE on gym, no role below can see any object in it.
-- ---------------------------------------------------------------------------
grant usage on schema gym to anon, authenticated, service_role;

-- Public catalogue reads.
grant select on gym.sessions            to anon, authenticated;
grant select on gym.session_templates   to anon, authenticated;
grant select on gym.session_availability to anon, authenticated;

-- Authenticated users interact with their own data / staff-managed data.
grant select, insert, update on gym.bookings          to authenticated;
grant select, update           on gym.profiles         to authenticated;
grant insert, update, delete   on gym.sessions         to authenticated;  -- narrowed to staff by RLS
grant insert, update, delete   on gym.session_templates to authenticated; -- narrowed to staff by RLS

-- Server/admin path (staff provisioning, back-office). service_role bypasses
-- RLS but still needs table privileges in a custom schema. Never exposed to
-- the browser.
grant select, insert, update, delete on gym.profiles          to service_role;
grant select, insert, update, delete on gym.session_templates to service_role;
grant select, insert, update, delete on gym.sessions          to service_role;
grant select, insert, update, delete on gym.bookings          to service_role;
grant select                         on gym.session_availability to service_role;

-- Helper + RPC execution.
grant execute on function gym.is_staff()          to anon, authenticated;
grant execute on function gym.current_app_role()  to anon, authenticated;
grant execute on function gym.book_session(uuid)                              to authenticated;
grant execute on function gym.cancel_booking(uuid)                            to authenticated;
grant execute on function gym.cancel_session(uuid)                            to authenticated, service_role;
grant execute on function gym.generate_sessions_from_template(uuid, date, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Enable RLS (default-deny) on every user-facing table.
-- ---------------------------------------------------------------------------
alter table gym.profiles          enable row level security;
alter table gym.session_templates enable row level security;
alter table gym.sessions          enable row level security;
alter table gym.bookings          enable row level security;

-- ===========================================================================
-- gym.profiles
--   SELECT: own row, or any row for staff (rosters need member names).
--   UPDATE: own row only; role immutability enforced by trigger.
--   INSERT/DELETE: none (rows created by the auth trigger; delete cascades
--   from auth.users). No self-serve insert/delete.
-- ===========================================================================
drop policy if exists profiles_select_self_or_staff on gym.profiles;
create policy profiles_select_self_or_staff on gym.profiles
  for select to authenticated
  using (id = auth.uid() or gym.is_staff());

drop policy if exists profiles_update_self on gym.profiles;
create policy profiles_update_self on gym.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- ===========================================================================
-- gym.session_templates
--   SELECT: public catalogue (anon + authenticated).
--   INSERT/UPDATE/DELETE: staff only.
-- ===========================================================================
drop policy if exists templates_select_public on gym.session_templates;
create policy templates_select_public on gym.session_templates
  for select to anon, authenticated
  using (true);

drop policy if exists templates_write_staff on gym.session_templates;
create policy templates_write_staff on gym.session_templates
  for all to authenticated
  using (gym.is_staff())
  with check (gym.is_staff());

-- ===========================================================================
-- gym.sessions
--   SELECT: public catalogue (anon + authenticated).
--   INSERT/UPDATE/DELETE: staff only.
-- ===========================================================================
drop policy if exists sessions_select_public on gym.sessions;
create policy sessions_select_public on gym.sessions
  for select to anon, authenticated
  using (true);

drop policy if exists sessions_write_staff on gym.sessions;
create policy sessions_write_staff on gym.sessions
  for all to authenticated
  using (gym.is_staff())
  with check (gym.is_staff());

-- ===========================================================================
-- gym.bookings
--   SELECT: own rows, or all for staff (roster).
--   INSERT: own rows only (backstop; the sanctioned path is book_session()).
--   UPDATE: own rows, or any for staff (backstop; sanctioned path is
--           cancel_booking()). WITH CHECK keeps a member from reassigning a
--           booking to someone else.
--   DELETE: none — soft-cancel only.
-- ===========================================================================
drop policy if exists bookings_select_own_or_staff on gym.bookings;
create policy bookings_select_own_or_staff on gym.bookings
  for select to authenticated
  using (member_id = auth.uid() or gym.is_staff());

drop policy if exists bookings_insert_own on gym.bookings;
create policy bookings_insert_own on gym.bookings
  for insert to authenticated
  with check (member_id = auth.uid());

drop policy if exists bookings_update_own_or_staff on gym.bookings;
create policy bookings_update_own_or_staff on gym.bookings
  for update to authenticated
  using (member_id = auth.uid() or gym.is_staff())
  with check (member_id = auth.uid() or gym.is_staff());

-- Down (manual rollback):
--   drop policy if exists bookings_update_own_or_staff on gym.bookings;
--   drop policy if exists bookings_insert_own on gym.bookings;
--   drop policy if exists bookings_select_own_or_staff on gym.bookings;
--   drop policy if exists sessions_write_staff on gym.sessions;
--   drop policy if exists sessions_select_public on gym.sessions;
--   drop policy if exists templates_write_staff on gym.session_templates;
--   drop policy if exists templates_select_public on gym.session_templates;
--   drop policy if exists profiles_update_self on gym.profiles;
--   drop policy if exists profiles_select_self_or_staff on gym.profiles;
--   alter table gym.bookings          disable row level security;
--   alter table gym.sessions          disable row level security;
--   alter table gym.session_templates disable row level security;
--   alter table gym.profiles          disable row level security;
--   revoke usage on schema gym from anon, authenticated, service_role;
