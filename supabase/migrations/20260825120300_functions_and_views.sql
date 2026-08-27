-- 20260825120300_functions_and_views.sql
-- Simple Gym Booking System — helpers, triggers, RPCs, and the availability view.
-- All objects live in the `gym` schema. SECURITY DEFINER functions pin
-- search_path to `gym` and fully-qualify auth.* / gym.* references.

-- ===========================================================================
-- 1. Role helpers (SECURITY DEFINER so RLS policies can read gym.profiles.role
--    without recursive RLS on gym.profiles itself).
--
--    Role source of truth = gym.profiles.role lookup (chosen over a JWT claim).
--    If the team later wires the Supabase custom access-token hook, swap the
--    body of these two functions to read the claim; nothing else changes.
-- ===========================================================================
create or replace function gym.current_app_role()
returns gym.user_role
language sql
stable
security definer
set search_path = gym
as $$
  select role from gym.profiles where id = auth.uid();
$$;

create or replace function gym.is_staff()
returns boolean
language sql
stable
security definer
set search_path = gym
as $$
  select coalesce(
    (select role = 'staff' from gym.profiles where id = auth.uid()),
    false
  );
$$;

comment on function gym.is_staff() is 'True when the calling user has gym.profiles.role = staff. Used by RLS policies.';

-- ===========================================================================
-- 2. updated_at maintenance.
-- ===========================================================================
create or replace function gym.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on gym.profiles;
create trigger profiles_set_updated_at
  before update on gym.profiles
  for each row execute function gym.set_updated_at();

drop trigger if exists session_templates_set_updated_at on gym.session_templates;
create trigger session_templates_set_updated_at
  before update on gym.session_templates
  for each row execute function gym.set_updated_at();

drop trigger if exists sessions_set_updated_at on gym.sessions;
create trigger sessions_set_updated_at
  before update on gym.sessions
  for each row execute function gym.set_updated_at();

-- ===========================================================================
-- 3. Auto-provision a gym.profiles row for every new auth user.
--    NOTE (shared project): auth.users is shared across all apps in BitBirrAI,
--    so this trigger fires for EVERY signup project-wide and will create a
--    gym.profiles row even for users of other apps. Accepted per coordinator
--    direction; flagged in the report. If that becomes noise, gate on app
--    metadata (e.g. raw_user_meta_data->>'app' = 'gym') here.
-- ===========================================================================
create or replace function gym.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = gym
as $$
begin
  insert into gym.profiles (id, email, full_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function gym.handle_new_user();

-- ===========================================================================
-- 4. gym.profiles.role immutability: a member cannot change their own role.
--    Only staff may change a role. Enforced here (not RLS) because a policy
--    cannot easily compare OLD.role vs NEW.role.
-- ===========================================================================
create or replace function gym.enforce_role_immutable()
returns trigger
language plpgsql
security definer
set search_path = gym
as $$
begin
  if new.role is distinct from old.role and not gym.is_staff() then
    raise exception 'role_change_not_allowed'
      using errcode = 'P0004',
            hint = 'Only staff may change a profile role.';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_role_immutable on gym.profiles;
create trigger profiles_role_immutable
  before update on gym.profiles
  for each row execute function gym.enforce_role_immutable();

-- ===========================================================================
-- 5. gym.book_session() — the ONLY sanctioned booking-create path (ADR-0002).
--    One transaction:
--      a) SELECT ... FOR UPDATE on the session row  -> serialises this
--         session's concurrent bookers (no overbooking under the last-spot
--         race).
--      b) count CONFIRMED bookings; reject 'session_full' if at/over capacity.
--      c) INSERT; the partial unique index rejects a duplicate active booking
--         as 'duplicate_booking'.
--    SECURITY DEFINER: bypasses bookings RLS for the insert, but member_id is
--    pinned to auth.uid() so a caller can only ever book as themselves.
-- ===========================================================================
create or replace function gym.book_session(p_session_id uuid)
returns gym.bookings
language plpgsql
security definer
set search_path = gym
as $$
declare
  v_member   uuid := auth.uid();
  v_capacity integer;
  v_count    integer;
  v_row      gym.bookings;
begin
  if v_member is null then
    raise exception 'not_authenticated' using errcode = 'P0100';
  end if;

  -- Guard: caller must have a profile row (FK would fail anyway; explicit is clearer).
  if not exists (select 1 from gym.profiles where id = v_member) then
    raise exception 'no_profile' using errcode = 'P0101';
  end if;

  -- (a) Lock the session row. Only scheduled sessions are bookable.
  select capacity into v_capacity
    from gym.sessions
   where id = p_session_id
     and status = 'scheduled'
   for update;

  if not found then
    raise exception 'session_not_available' using errcode = 'P0001';
  end if;

  -- (b) Count under the lock.
  select count(*) into v_count
    from gym.bookings
   where session_id = p_session_id
     and status = 'confirmed';

  if v_count >= v_capacity then
    raise exception 'session_full' using errcode = 'P0002';
  end if;

  -- (c) Insert. Partial unique index enforces no duplicate active booking.
  insert into gym.bookings (session_id, member_id, status)
  values (p_session_id, v_member, 'confirmed')
  returning * into v_row;

  return v_row;

exception
  when unique_violation then
    raise exception 'duplicate_booking' using errcode = 'P0003';
end;
$$;

comment on function gym.book_session(uuid) is
  'Atomic booking create. Errcodes: P0001 session_not_available, P0002 session_full, P0003 duplicate_booking, P0100 not_authenticated, P0101 no_profile.';

-- ===========================================================================
-- 6. gym.cancel_booking() — member cancels own booking (or staff cancels any).
--    Frees a spot immediately because availability is derived. Idempotent:
--    cancelling an already-cancelled booking is a no-op that returns the row.
-- ===========================================================================
create or replace function gym.cancel_booking(p_booking_id uuid)
returns gym.bookings
language plpgsql
security definer
set search_path = gym
as $$
declare
  v_member uuid := auth.uid();
  v_row    gym.bookings;
begin
  if v_member is null then
    raise exception 'not_authenticated' using errcode = 'P0100';
  end if;

  select * into v_row from gym.bookings where id = p_booking_id for update;

  if not found then
    raise exception 'booking_not_found' using errcode = 'P0102';
  end if;

  if v_row.member_id <> v_member and not gym.is_staff() then
    raise exception 'not_authorized' using errcode = 'P0103';
  end if;

  if v_row.status = 'cancelled' then
    return v_row;  -- idempotent
  end if;

  update gym.bookings
     set status = 'cancelled',
         cancelled_at = now()
   where id = p_booking_id
  returning * into v_row;

  return v_row;
end;
$$;

comment on function gym.cancel_booking(uuid) is
  'Soft-cancel a booking (owner or staff). Errcodes: P0100 not_authenticated, P0102 booking_not_found, P0103 not_authorized.';

-- ===========================================================================
-- 7. gym.cancel_session() — staff cancels a session and cascades its confirmed
--    bookings to cancelled, in one transaction.
-- ===========================================================================
create or replace function gym.cancel_session(p_session_id uuid)
returns gym.sessions
language plpgsql
security definer
set search_path = gym
as $$
declare
  v_row gym.sessions;
begin
  if not gym.is_staff() then
    raise exception 'not_authorized' using errcode = 'P0103';
  end if;

  update gym.sessions
     set status = 'cancelled'
   where id = p_session_id
  returning * into v_row;

  if not found then
    raise exception 'session_not_found' using errcode = 'P0104';
  end if;

  update gym.bookings
     set status = 'cancelled',
         cancelled_at = now()
   where session_id = p_session_id
     and status = 'confirmed';

  return v_row;
end;
$$;

comment on function gym.cancel_session(uuid) is
  'Staff-only: cancel a session and cascade confirmed bookings to cancelled.';

-- ===========================================================================
-- 8. gym.generate_sessions_from_template() — recurrence materialiser (staff).
--    For every day in [p_from, p_to] whose weekday matches the template,
--    create a scheduled session instance. Idempotent via ON CONFLICT on the
--    (template_id, starts_at) partial unique index, so re-running over an
--    overlapping window creates no duplicates. Returns the rows it inserted.
-- ===========================================================================
create or replace function gym.generate_sessions_from_template(
  p_template_id uuid,
  p_from        date,
  p_to          date
)
returns setof gym.sessions
language plpgsql
security definer
set search_path = gym
as $$
declare
  v_tmpl gym.session_templates;
begin
  if not gym.is_staff() then
    raise exception 'not_authorized' using errcode = 'P0103';
  end if;

  select * into v_tmpl
    from gym.session_templates
   where id = p_template_id and active;

  if not found then
    raise exception 'template_not_found_or_inactive' using errcode = 'P0105';
  end if;

  if p_to < p_from then
    raise exception 'invalid_date_window' using errcode = 'P0106';
  end if;

  -- Wrap the data-modifying INSERT in a CTE so RETURN QUERY runs a plain SELECT.
  return query
  with inserted as (
    insert into gym.sessions
        (template_id, activity, coach_name, starts_at, ends_at, capacity, status, created_by)
    select
        v_tmpl.id,
        v_tmpl.activity,
        v_tmpl.coach_name,
        (date_trunc('day', gs)::timestamp + v_tmpl.start_time) at time zone v_tmpl.timezone,
        (date_trunc('day', gs)::timestamp + v_tmpl.end_time)   at time zone v_tmpl.timezone,
        v_tmpl.default_capacity,
        'scheduled',
        v_tmpl.created_by
    from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as gs
    where extract(dow from gs)::int = v_tmpl.weekday
    on conflict (template_id, starts_at) do nothing
    returning *
  )
  select * from inserted;
end;
$$;

comment on function gym.generate_sessions_from_template(uuid, date, date) is
  'Staff-only recurrence materialiser. Idempotent per (template_id, starts_at). Returns inserted rows only.';

-- ===========================================================================
-- 9. gym.session_availability view — derived remaining/full (never stored).
--    Deliberately NOT security_invoker: it runs with the view owner's rights so
--    the confirmed-count subquery sees all bookings regardless of caller. It
--    exposes ONLY session columns + aggregate counts — never member identity —
--    so it is safe to grant to anon for the public catalogue. DO NOT add
--    member-identifying columns to this view.
-- ===========================================================================
create or replace view gym.session_availability as
select
  s.id,
  s.template_id,
  s.activity,
  s.coach_name,
  s.starts_at,
  s.ends_at,
  s.capacity,
  s.status,
  s.created_at,
  coalesce(b.confirmed_count, 0)                              as confirmed_count,
  greatest(s.capacity - coalesce(b.confirmed_count, 0), 0)    as remaining,
  (coalesce(b.confirmed_count, 0) >= s.capacity)              as is_full
from gym.sessions s
left join (
  select session_id, count(*) as confirmed_count
    from gym.bookings
   where status = 'confirmed'
   group by session_id
) b on b.session_id = s.id;

comment on view gym.session_availability is
  'Public catalogue read model: session columns + confirmed_count, remaining, is_full. No member PII. Runs as owner (not security_invoker) so counts are visible to anon.';

-- Down (manual rollback):
--   drop view if exists gym.session_availability;
--   drop function if exists gym.generate_sessions_from_template(uuid, date, date);
--   drop function if exists gym.cancel_session(uuid);
--   drop function if exists gym.cancel_booking(uuid);
--   drop function if exists gym.book_session(uuid);
--   drop trigger if exists profiles_role_immutable on gym.profiles;
--   drop function if exists gym.enforce_role_immutable();
--   drop trigger if exists on_auth_user_created on auth.users;
--   drop function if exists gym.handle_new_user();
--   drop trigger if exists sessions_set_updated_at on gym.sessions;
--   drop trigger if exists session_templates_set_updated_at on gym.session_templates;
--   drop trigger if exists profiles_set_updated_at on gym.profiles;
--   drop function if exists gym.set_updated_at();
--   drop function if exists gym.is_staff();
--   drop function if exists gym.current_app_role();
