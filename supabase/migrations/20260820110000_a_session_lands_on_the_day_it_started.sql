-- A focus session: the one kind of work that cannot be declared, finally measured.
--
-- `cadence = 'daily_hours_quota'` and `daily_minutes_target` have existed since
-- 20260819150000_commitment.sql. Both `commitments_owing()` and `enqueue_gate_reminders()`
-- deliberately exclude that cadence, with the comment that the timer answers it — and there
-- was no timer. So the one kind of work the author actually avoids could be created, was
-- asked nothing, was measured by nothing, and showed a target it had no way to reach.
--
-- This is the measurement. It is not a process: a session is a **recorded start instant and a
-- recorded stop instant**, one row written when he stops. Nothing runs anywhere, so nothing
-- can be killed, backgrounded, paused or invalidated — which is also why nothing here detects
-- inattention. A timer that polices is a timer he stops starting, and not starting is the only
-- real failure this story is about.
--
-- Shaped after `declaration` (20260819200000): a client-generated idempotency key, the instants
-- sent by the client, the day derived by a `before insert` trigger, select-own and insert-own
-- policies, and no update or delete policy at all.

create table public.focus_session (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profile (id) on delete cascade,
  commitment_id uuid not null references public.commitment (id) on delete cascade,

  -- AD-4: minted when *start* is tapped, carried through the stop, and reused by every retry.
  -- A session queued without a network and flushed twice is one session.
  idempotency_key uuid not null unique,

  -- Both instants come from the device, exactly as `declaration.answered_at` does. A session
  -- started in a tunnel is dated when it was started, not when it was delivered (AD-6).
  started_at timestamptz not null,
  stopped_at timestamptz not null,

  -- Derived by the trigger below. AD-6: no client ever sends a date.
  for_day date not null,

  /* The session's length, computed once and never by a client (AD-1).

     Immutable, unlike the day — subtracting two timestamptz values and taking the epoch of the
     interval does not consult a timezone — so this one *can* be a stored generated column where
     `for_day` cannot.

     Seconds rather than minutes on purpose. Flooring here would silently discard up to 59
     seconds per session, so three twenty-minute sittings could bank 59 minutes of an hour. The
     day's total is what the quota is judged against; it is the thing that must be right, and it
     is floored exactly once, in the view below. */
  duration_seconds integer generated always as (
    (extract(epoch from (stopped_at - started_at)))::integer
  ) stored,

  created_at timestamptz not null default now(),

  -- A stop that does not come after its start is a clock that moved backwards, not a session.
  -- Refused rather than clamped: spec 3-0 D1 settled that a value the database quietly changes
  -- is worse than a refusal, because nothing on the screen would ever say it happened.
  constraint focus_session_stops_after_it_starts check (stopped_at > started_at)
);

comment on table public.focus_session is
  'One sitting of timed work: when it started, when it stopped. An observation, never a verdict.';

comment on column public.focus_session.for_day is
  'The day the session *started* (AD-14). A session is never split across midnight.';

create index focus_session_owner_day_idx on public.focus_session (owner_id, for_day);
create index focus_session_commitment_day_idx on public.focus_session (commitment_id, for_day);

/* The day a session belongs to, and the two things a session may not be.

   **The day.** AD-14: an event belongs to the day containing its *start* instant. A session from
   23:50 to 00:20 is thirty minutes on the day it started and is never split — under a flat
   penalty, splitting it is the difference between a Failed Day and a clean one. This is the one
   place the rule differs from `declaration_derive_day()`, which subtracts a day because a
   declaration answers for yesterday. A session answers for itself.

   A trigger rather than a generated column for the reason that function gives at length: `at time
   zone` with a named zone is STABLE, not IMMUTABLE, and Postgres will not store a generated
   column computed from it.

   **The two refusals.** The row is already being looked up for nothing else, so it also checks
   what it is pointing at. The insert policy on this table constrains `owner_id` and nothing else,
   so RLS alone would happily accept a session whose owner is the caller but whose commitment is
   somebody else's — and would accept minutes banked against a commitment that is judged on the
   author's word rather than on measurement, which is a second, softer record of a thing the
   declaration already settles.

   `security definer` so those two checks are the trigger's own rather than a side effect of
   whatever the caller happens to be able to read. Under invoker rights the ownership refusal
   would come from RLS on `commitment` filtering the lookup to nothing, which is the right answer
   arrived at by accident and a different answer for a caller with different grants. */
create function public.focus_session_derive_day()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target record;
begin
  select c.owner_id, c.cadence
    into target
    from public.commitment c
   where c.id = new.commitment_id;

  if not found or target.owner_id <> new.owner_id then
    raise exception
      'A focus session may only be banked against a commitment the same account owns.';
  end if;

  if target.cadence <> 'daily_hours_quota' then
    raise exception
      'A focus session may only be banked against a Put hours in commitment. This one is %, '
      'which is settled by the morning declaration and must not carry a second, softer record.',
      target.cadence;
  end if;

  new.for_day := (new.started_at at time zone 'Asia/Ho_Chi_Minh')::date;
  return new;
end;
$$;

create trigger focus_session_derive_day
  before insert on public.focus_session
  for each row execute function public.focus_session_derive_day();

-- Reachable at /rest/v1/rpc otherwise. A trigger fires regardless of EXECUTE grants; the
-- advisor caught exactly this on an earlier migration's trigger function.
revoke execute on function public.focus_session_derive_day() from public, anon, authenticated;


/* What a day has banked, per commitment.

   Summed in seconds and floored **once**, at the day. This is the seam Story 3.2 reads for the
   progress bar and the not-started prompt, and Story 3.4 for the verdict; nothing recomputes it.

   `seconds` is exposed beside `minutes` for one narrow reason: while a stopped session is still
   sitting in the offline queue, the screen adds its length to what this returns so it does not
   appear to lose time it has already been told about. Adding *minutes* there would floor twice
   and lose up to another 59 seconds; adding seconds and flooring once agrees with this view
   exactly. That sum is only ever displayed — it is never sent anywhere (AD-1).

   `security_invoker` so the view is read under the caller's own policies rather than the view
   owner's. Without it, a view over an RLS table is a way around RLS. */
create view public.focus_day_minutes
with (security_invoker = true)
as
select s.owner_id,
       s.commitment_id,
       s.for_day,
       sum(s.duration_seconds)::bigint as seconds,
       floor(sum(s.duration_seconds)::numeric / 60)::integer as minutes
  from public.focus_session s
 group by s.owner_id, s.commitment_id, s.for_day;

comment on view public.focus_day_minutes is
  'Minutes banked per commitment per day. Summed in seconds and floored once, at the day.';

alter table public.focus_session enable row level security;

create policy "focus session: read own"
  on public.focus_session
  for select
  to authenticated
  using ((select auth.uid()) = owner_id);

create policy "focus session: bank own"
  on public.focus_session
  for insert
  to authenticated
  with check ((select auth.uid()) = owner_id and public.role_from_table() = 'doer');

-- No update policy and no delete policy, on purpose, and for the same reason `declaration` has
-- none. A session is a statement that this much time was spent starting at that instant. There
-- is nothing to amend: a session banked wrong is a session that was tapped wrong, and the
-- honest remedy is another session rather than an edit that quietly rewrites the record.
--
-- It is also what makes the offline queue safe. The client inserts one row at stop and never
-- corrects it, so a start tapped offline and a stop tapped offline arrive as a single write —
-- rather than as an update to a row that does not exist yet.
