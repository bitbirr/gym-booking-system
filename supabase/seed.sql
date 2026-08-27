-- supabase/seed.sql
-- Local-dev seed for the `gym` schema. Runs as the superuser during
-- `supabase db reset`, so it bypasses RLS and the staff-only guards.
-- NOT for production / the cloud BitBirrAI project.
--
-- We cannot seed members/bookings here because those require real auth.users
-- rows (created by Supabase Auth). To exercise the booking path locally:
--   1. Sign up a user in Studio (http://localhost:54323) or via the API — the
--      on_auth_user_created trigger auto-creates their gym.profiles row.
--   2. Promote to staff if needed:
--        update gym.profiles set role = 'staff' where email = 'you@example.com';
--   3. Call select gym.book_session('<session-id>'); as that user (JWT).

-- ---------------------------------------------------------------------------
-- Two recurring templates. Fixed UUIDs so re-seeding is stable.
-- weekday: 0=Sun .. 6=Sat (PostgreSQL dow). 1=Mon, 3=Wed.
-- ---------------------------------------------------------------------------
insert into gym.session_templates
  (id, activity, coach_name, weekday, start_time, end_time, timezone, default_capacity, active)
values
  ('11111111-1111-1111-1111-111111111111', 'Vinyasa Yoga', 'Amina',  1, '07:00', '08:00', 'UTC', 12, true),
  ('22222222-2222-2222-2222-222222222222', 'Spin',         'Yonas',  3, '18:00', '18:45', 'UTC', 20, true)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Materialise instances for the next 21 days from each active template.
-- This mirrors gym.generate_sessions_from_template() but without the is_staff()
-- guard (seed runs as superuser). Idempotent via the (template_id, starts_at)
-- partial unique index.
-- ---------------------------------------------------------------------------
insert into gym.sessions
  (template_id, activity, coach_name, starts_at, ends_at, capacity, status)
select
  t.id,
  t.activity,
  t.coach_name,
  (date_trunc('day', gs)::timestamp + t.start_time) at time zone t.timezone,
  (date_trunc('day', gs)::timestamp + t.end_time)   at time zone t.timezone,
  t.default_capacity,
  'scheduled'
from gym.session_templates t
cross join generate_series(
  current_date::timestamp,
  (current_date + 21)::timestamp,
  interval '1 day'
) as gs
where t.active
  and extract(dow from gs)::int = t.weekday
on conflict (template_id, starts_at) do nothing;

-- ---------------------------------------------------------------------------
-- One-off session (no template) — a small workshop, tomorrow.
-- ---------------------------------------------------------------------------
insert into gym.sessions
  (template_id, activity, coach_name, starts_at, ends_at, capacity, status)
values
  (null, 'Mobility Workshop', 'Sara',
   ((current_date + 1)::timestamp + time '10:00') at time zone 'UTC',
   ((current_date + 1)::timestamp + time '11:30') at time zone 'UTC',
   8, 'scheduled')
on conflict do nothing;
