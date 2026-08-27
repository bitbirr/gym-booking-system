# ADR-0003: Authentication and authorization approach

Status: Accepted (with an assumption to confirm)
Date: 2026-08-25
Deciders: Product Architect (security-lead to confirm trust model)
Door: One-way (identity provider swaps touch every protected path)

## Context

The system has two principals: **members** (book/cancel their own bookings) and
**staff** (manage sessions, view rosters). Member PII (name, email) needs
privacy controls; a member must never see another member's data. Concrete
identity requirements from the gym are **not yet confirmed**, so we pick a
pragmatic default and record it as an assumption. The house stack provides
Supabase Auth, which integrates natively with PostgreSQL Row-Level Security.

## Options

1. **Supabase Auth (email + password, optional magic link) + `profiles.role`
   column + RLS.** Native to the stack; JWT carries identity; RLS enforces
   ownership in the database.
2. **Custom auth (bcrypt + own session table).** Full control, but reinvents a
   solved problem and adds security surface in a 3–5 week build. Rejected.
3. **Third-party IdP (Auth0/Clerk).** Good DX, but adds cost and a dependency
   outside the self-hosted house stack; overkill for one gym. Rejected for MVP.
4. **SSO / membership-provider integration.** Possibly desired by the gym, but
   unspecified. Deferred; the seam (Supabase Auth supports OAuth/SAML later)
   keeps this open.

## Decision

Choose **Option 1**. Single identity system: **Supabase Auth with email +
password** (magic link optional). Authorization by a `role` on `profiles`
(`'member' | 'staff'`), promoted into the JWT via a custom access-token hook so
both middleware and RLS can read the role without an extra query.

Enforcement is layered:
- **RLS is the primary control** (default-deny on every table):
  - `bookings`: member sees/creates/updates only rows where
    `member_id = auth.uid()`; staff may `SELECT` all for rosters.
  - `sessions`: read per assumption A2 (public browse); write only `staff`.
  - `profiles`: self read/update only; `role` is not self-writable.
- **Server Actions / Route Handlers** run member paths under the user JWT so
  RLS always applies; the service-role key is reserved for admin tasks only and
  never exposed to the browser.
- **Middleware** gates `/staff/**` routes as defence in depth (not the primary
  control).

Staff accounts are provisioned by an admin (role set out-of-band); no self-serve
staff signup.

## Consequences

Positive:
- Minimal custom auth code; leans on a maintained, house-standard system.
- Ownership and privacy enforced in the database, so a mistake in the app layer
  cannot leak another member's bookings.
- Role-as-claim keeps authorization checks cheap and consistent across
  middleware and SQL.

Negative / trade-offs:
- Ties the app to Supabase Auth; swapping IdPs later is a one-way-door touch
  across protected paths (mitigated because RLS keys off `auth.uid()`/claims,
  not a specific provider's user shape).
- `role` in a JWT claim means role changes take effect on token refresh, not
  instantly — acceptable for staff/member (rare changes).
- Custom access-token hook is a small piece of Supabase-specific config to test.

Assumption to confirm (A1/A2): email+password default and public browsing. If
the gym mandates SSO or a members-only catalogue, revisit before build.

Related: the committed `.env` exposes a live service-role key and other tokens
(ARCHITECTURE §10) — rotate and gitignore before engineering starts.
