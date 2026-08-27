# ADR-0002: Capacity enforcement and no-double-booking at the data layer

Status: Accepted
Date: 2026-08-25
Deciders: Product Architect (data-lead to implement the migration)
Door: One-way (correctness rule over live booking data; expensive to reverse)

## Context

This is the core correctness requirement (backlog item 6). Two rules must hold
under concurrency:

1. **No overbooking** — confirmed bookings for a session must never exceed its
   capacity, even when many members book the last spot at the same instant.
2. **No duplicate active booking** — a member cannot hold two confirmed
   bookings for the same session, even with double-clicks, retries, or replays.

The failure we must prevent is the classic read-then-write race: two requests
both read "1 spot left", both pass an app-level check, and both insert.

## Options

### For overbooking

A. **App-level count then insert.** Read count in the app, compare to capacity,
   insert. Simple but has a TOCTOU race; unsafe. Rejected as the primary
   guarantee.
B. **Optimistic: `INSERT ... SELECT` with a `WHERE (count) < capacity` guard**
   (conditional insert in one statement). Atomic and lock-light, but the count
   subquery under concurrent inserts needs `SERIALIZABLE` or careful predicate
   locking to be airtight, and retries on serialization failure.
C. **Pessimistic row lock**: in a Postgres function, `SELECT capacity FROM
   sessions WHERE id = :id FOR UPDATE`, then count confirmed bookings, then
   insert if room — all in one transaction. Serialises only that session's
   concurrent bookers.
D. **Denormalised `booked_count` column** updated by trigger with a
   `CHECK (booked_count <= capacity)`. Fast reads, but the counter can drift and
   the trigger logic is another place to get wrong.

### For duplicate bookings

E. App-level "already booked?" check. Racy; rejected as the guarantee.
F. **Partial unique index** `UNIQUE (session_id, member_id) WHERE status =
   'confirmed'`. Database-enforced; correct under concurrency; allows re-booking
   after cancellation because cancelled rows are outside the index.

## Decision

- Overbooking: **Option C** — a `SECURITY DEFINER` Postgres function
  `book_session(p_session_id)` that runs in one transaction:
  1. `SELECT capacity ... FOR UPDATE` on the session row (lock),
  2. count `confirmed` bookings for the session,
  3. raise `session_full` if at/over capacity,
  4. insert the booking as `confirmed`.
- Duplicate bookings: **Option F** — the partial unique index, which the same
  insert relies on; a violation surfaces as `duplicate_booking`.

The function is the **only** sanctioned write path for creating a booking. The
application never inserts into `bookings` directly for the create path.

## Consequences

Positive:
- Correctness lives in one place, enforced by the database, not by careful
  application code. It holds even if a future caller is buggy or a request is
  retried.
- The row lock scopes contention to a single session; unrelated bookings run
  fully concurrently. Load is small, so lock hold time is negligible.
- The partial unique index doubles as the defence for double-submits and lets a
  member cancel and re-book cleanly.
- No denormalised counter to drift; "full" is always derived from the truth.

Negative / trade-offs:
- Business logic is split: booking creation lives in SQL, not TypeScript. This
  is a deliberate trade — correctness beats co-location. Documented so future
  engineers look in the migration, not the app, for the rule.
- `SECURITY DEFINER` functions must be written carefully (set `search_path`,
  validate `auth.uid()`), a security-review item.
- A brief lock on hot sessions; acceptable at this scale, revisit only if a
  single session ever sees thousands of simultaneous bookers.

Testing requirement (gate for slice 1): a concurrency test that fires N > 
capacity simultaneous `book_session` calls and asserts exactly `capacity`
confirmed rows and the rest `session_full`, plus a duplicate-submit test
asserting exactly one confirmed row.

Would change the decision: extreme write contention on single rows (→ Option B
with serialization-failure retries, or sharded counters) — not expected here.
