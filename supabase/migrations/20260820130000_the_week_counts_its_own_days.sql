-- A weekly quota that counts down, finally reading the columns it was given.
--
-- `weekly_target` and `week_start_day` have existed on `commitment` since
-- 20260819150000_commitment.sql, and a Weekly Quota commitment has been asked for an ordinary
-- Declaration every day exactly like a Daily one since 20260819200000_declaration.sql. Nothing
-- has ever summed those answers into a week's standing — the Today row shows only the setup
-- target (`3×`), by design (`commitment-row.tsx` refuses to show a progress it cannot know).
--
-- This is the sum. One view, following the precedent `focus_day_minutes` set for the other
-- quota (AD-8): the count and the days-remaining figure both come from here, never from a
-- client-side tally of raw `declaration` rows.
--
-- **D1: "days remaining" excludes today, and the formula is derived, not assumed.**
-- `EXPERIENCE.md` KF-6 gives two numbers: Thursday reads "3 days remaining," Saturday reads
-- "1 day remaining." With `week_start_day = 1` (Monday, ISO), Thursday is the week's 4th day
-- and Saturday its 6th — `7 − 4 = 3` and `7 − 6 = 1`. Both match exactly, which is what
-- `week_days_remaining` computes below and `supabase/tests/3-3-weekly-quota-progress.sql`
-- checks against both numbers directly, plus a non-Monday `week_start_day`.
--
-- What this migration deliberately does not build: the escalating reminder that also reads
-- this view (FR-4) is a separate, independently shippable piece with its own migration, cron
-- schedule and copy — deferred to its own spec, recorded in `deferred-work.md` with its design
-- already carried over. No function here writes anywhere, sends anything, or is invoked by
-- `pg_cron`.

/* Days from tomorrow through the end of this account's own week, wherever it starts.
   `p_week_start_day` is ISO-8601 day numbering, 1 = Monday, matching the column it reads.

   `extract(isodow from date)` is immutable for a plain `date` (no timezone to resolve), unlike
   `at time zone` with a named zone — so this can be `immutable` rather than needing a trigger's
   help the way `declaration_derive_day()` does. */
create function public.week_days_remaining(p_day date, p_week_start_day integer)
returns integer
language sql
immutable
set search_path = ''
as $$
  select 6 - ((extract(isodow from p_day)::integer - p_week_start_day + 7) % 7)
$$;

comment on function public.week_days_remaining(date, integer) is
  'Days from tomorrow through the end of the week (D1). Verified in '
  '3-3-weekly-quota-progress.sql against EXPERIENCE.md KF-6: Thursday reads 3, Saturday reads '
  '1, with week_start_day = 1 (Monday) — and against a Friday-start week besides.';

-- Revoked from `public` and `anon` — the default grant every new function gets unless it is
-- taken back — and granted to `authenticated` alone, deliberately unlike every other helper
-- function this migration's own precedents (`focus_prompt_hour`, `minutes_as_clock`) keep
-- entirely out of reach. Those are called only from inside a `security definer` function that
-- runs as its owner, so a client grant would add nothing but RPC exposure. `weekly_quota_
-- progress` below is a plain view, `security_invoker`, so its query — including this call —
-- runs under the *caller's own* privileges once a real account reads it (AD-8's own point: the
-- view is what a client is meant to read). Without the grant every read of that view fails with
-- "permission denied for function week_days_remaining" rather than an RLS-empty result, which
-- is the wrong way for this to be unreachable — and there is nothing in a pure function of two
-- plain values for `anon`, unauthenticated, to learn by calling it directly.
revoke execute on function public.week_days_remaining(date, integer) from public, anon;
grant execute on function public.week_days_remaining(date, integer) to authenticated;


/* Every open Weekly Quota commitment's live position against this week: how many qualifying
   days it has held, its target, and the days left to close the gap.

   **Held** counts `declaration` rows answered `held`, for this commitment, whose `for_day`
   falls within the week containing today — the same week `week_days_remaining` measures
   against. A Weekly Quota commitment is judged by *counting qualifying days*, each filed
   through the ordinary Declaration exactly like a Daily commitment (epic-3-context.md); there
   is no separate observation table to read.

   **The week's start** is derived the same way `week_days_remaining` derives days left:
   walking back from today by however many days separate today's ISO weekday from
   `week_start_day`. Stored per commitment because a gym week and a work week may reasonably
   start on different days (`20260819150000_commitment.sql`'s own comment).

   `security_invoker` so the view is read under the caller's own policies rather than the view
   owner's — RLS on `commitment` and `declaration` alone is what scopes every row to its own
   account; this view adds no filter of its own beyond cadence and archival. Without
   `security_invoker` a view over RLS tables is a way around RLS, exactly as `focus_day_minutes`
   and `chain_current` already say. */
create view public.weekly_quota_progress
with (security_invoker = true)
as
with today as (
  select (now() at time zone 'Asia/Ho_Chi_Minh')::date as d
),
weeks as (
  select c.id as commitment_id,
         c.owner_id,
         c.weekly_target as target,
         c.week_start_day,
         t.d as today,
         t.d - ((extract(isodow from t.d)::integer - c.week_start_day + 7) % 7) as week_start
    from public.commitment c
    cross join today t
   where c.cadence = 'weekly_quota'
     and c.archived_at is null
)
select w.owner_id,
       w.commitment_id,
       w.target,
       coalesce(held.count, 0)::integer as held,
       public.week_days_remaining(w.today, w.week_start_day) as days_remaining
  from weeks w
  left join lateral (
    select count(*)::integer as count
      from public.declaration dec
     where dec.commitment_id = w.commitment_id
       and dec.answer = 'held'
       and dec.for_day >= w.week_start
       and dec.for_day < w.week_start + 7
  ) held on true;

comment on view public.weekly_quota_progress is
  'Live position for every open Weekly Quota commitment: qualifying days held this week, the '
  'target, and days remaining (D1). The one source Story 3.3''s Today pill reads — no '
  'client-side tally of raw declaration rows (AD-8).';
