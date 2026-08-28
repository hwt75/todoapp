-- Story 6.2 — a claim lands on the day it was made.
--
-- `declaration_derive_day()` has subtracted a day unconditionally since 20260819200000: a
-- morning answer is about yesterday, and that is right for every commitment that has no
-- moment of its own. Story 6.1 gave some commitments a `due_time`, and those are answered on
-- their own day at the moment the thing is done. The subtraction has to branch.
--
-- Extended rather than replaced, for the reason 20260824120000 already gave: this is the one
-- `before insert` seam that sees every write into `declaration` regardless of who made it,
-- and a second trigger on the same table would run in name order with no reason to.
--
-- Three things are added and the existing two are preserved exactly:
--
--   1. The branch. A commitment carrying a `due_time` derives today; everything else keeps
--      `- 1`, unchanged, including every machine-filed row (see the note on that below).
--   2. A commitment the caller cannot see is refused. Not a new rule so much as a hole being
--      closed: `declaration`'s insert policy checks `auth.uid() = owner_id` and the caller's
--      role, and has never checked that `commitment_id` belongs to that owner. Now that the
--      function reads the commitment, RLS answers that question on the way past.
--   3. A claim outside its window is refused. See the note below on why refused rather than
--      recorded and judged later.
--
-- **Invoker rights, deliberately.** This function is not `security definer` and must not
-- become one. Reading `public.commitment` as the caller is what makes point 2 true: under RLS
-- a client sees only its own commitments, so a declaration naming someone else's gets
-- `not found` here. A `security definer` version would see every row and would have to
-- re-implement that ownership check by hand, which is the version that eventually gets it
-- wrong. The machine paths (`file_auto_check_result` and the settlement functions) are
-- already `security definer` themselves, so their own reads bypass RLS and find the row.

create or replace function public.declaration_derive_day()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_due       time;
  v_window    integer;
  v_local     timestamp;
  v_by_doer   boolean;
  v_opens_at  numeric;
  v_tapped_at numeric;
begin
  -- True only for a genuinely client-originated statement. `file_auto_check_result()` and the
  -- settlement functions are `security definer`, so they run as the function's owner and
  -- never as either of these roles. Read once here and used twice below: it decides both
  -- whether `filed_by` is forced and whether the window applies.
  v_by_doer := current_user in ('anon', 'authenticated');

  select c.due_time, c.late_window_minutes
    into v_due, v_window
    from public.commitment c
   where c.id = new.commitment_id;

  if not found then
    raise exception
      'A declaration must name a commitment that exists and belongs to you.';
  end if;

  v_local := new.answered_at at time zone 'Asia/Ho_Chi_Minh';

  -- An untimed commitment, or any machine-filed row: unchanged since 20260819200000.
  --
  -- Machine-filed rows keep the previous-day derivation even on a timed commitment. That
  -- combination is reachable -- a timed commitment may carry an Auto-check -- but nothing
  -- reads it yet, because settlement does not know about `due_time` until Story 6.4. Giving
  -- it a same-day meaning here would be inventing behaviour for a judge that has not been
  -- written; leaving it alone keeps this migration to the one thing it claims to change.
  -- Recorded as an open question on the spec rather than decided in passing.
  if v_due is null or not v_by_doer then
    new.for_day := v_local::date - 1;
    if v_by_doer then
      new.filed_by := 'doer';
    end if;
    return new;
  end if;

  -- A timed commitment is answered on its own day, at the moment the thing is done.
  new.for_day := v_local::date;
  new.filed_by := 'doer';

  -- Seconds from midnight on both sides rather than minutes, so a tap at 20:29:59.5 is
  -- inside a window that ends at 20:30 and a tap at 20:30:00.0 is not. `extract(epoch from
  -- <time>)` is seconds since midnight, which is also why this cannot be written as
  -- `v_due + make_interval(mins => v_window)`: time arithmetic wraps, and 23:30 plus an hour
  -- would compare as 00:30 rather than as past the end of the day (the same trap
  -- `commitment_window_within_the_day` avoids, 20260828130000).
  v_opens_at  := extract(epoch from v_due);
  v_tapped_at := extract(epoch from v_local::time);

  -- Half-open: the instant the window opens counts, the instant it closes does not.
  --
  -- Refused rather than recorded and judged late, which is the less obvious call. Recording
  -- it would be purer against AD-8 -- settlement is the only judge and `answered_at` already
  -- carries the moment -- but follow a tap at 00:05 through: the derivation above would name
  -- *tomorrow*, today would end with no claim at all and fail, and tomorrow's one allowed
  -- declaration (`declaration_one_per_commitment_day`) would already be spent on a claim made
  -- before tomorrow's window opened. Five minutes late would cost two days, and the author
  -- would learn it at day close. A refusal at the moment of the tap costs one day and says so
  -- immediately.
  if v_tapped_at < v_opens_at or v_tapped_at >= v_opens_at + (v_window * 60) then
    raise exception
      'This commitment could be claimed from % for % minutes. It is now %.',
      to_char(v_due, 'HH24:MI'), v_window, to_char(v_local, 'HH24:MI');
  end if;

  return new;
end;
$$;

revoke execute on function public.declaration_derive_day() from public, anon, authenticated;

comment on function public.declaration_derive_day() is
  'before insert trigger on public.declaration. Derives for_day from the instant the author '
  'tapped (AD-6): the previous local day for a commitment with no due_time, and the current '
  'local day for one with a due_time claimed by the doer. Refuses a commitment the caller '
  'cannot see, and refuses a doer''s claim falling outside that commitment''s late window. '
  'Invoker rights on purpose -- RLS is what makes the ownership check true.';
