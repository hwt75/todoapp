-- A time switched off stays off.
--
-- `due_time_as_of()` documents its fallback precisely: the value in effect when the day began,
-- "falling back to the value the commitment was created with for any day at or before its own
-- creation" (20260829090000:150). The implementation was a `coalesce` of those two subqueries,
-- and a coalesce cannot tell "no entry applies" from "the entry that applies says null".
--
-- So when the entry in force at day start was the one that switched the time *off*, the first
-- subquery answered null -- correctly -- and the coalesce read that as no answer and fell through
-- to the creation value. A commitment switched back to untimed went on being judged timed on every
-- day after the switch: it demanded a photo the app no longer offers to take, and the day settled
-- `failed` with a penalty and a broken chain for a rule that was no longer in force.
--
-- This is the same defect class as the one `due_time_as_of()` was written to fix -- a past day
-- judged by a rule that was not in force then -- reintroduced by the shape of the fallback rather
-- than by the rule. The repair is an existence test, exactly as `late_window_at()` is written
-- (20260907100000), and its own comment says why in the same words.
--
-- **Nothing already settled changes.** Checked against the live project before this was written:
-- every commitment there carries exactly one `commitment_due_time_change` entry -- its own
-- creation -- so no due_time has ever been switched off, and the branch this corrects has never
-- been reached by real data. It is fixed now precisely because that is still true.

create or replace function public.due_time_as_of(p_commitment_id uuid, p_day date)
returns time
language sql
stable
security definer
set search_path = ''
as $$
  with history as (
    select ch.due_time,
           ch.changed_at,
           lag(ch.due_time) over (order by ch.changed_at) as previous_due_time,
           row_number() over (order by ch.changed_at)     as entry
      from public.commitment_due_time_change ch
     where ch.commitment_id = p_commitment_id
  )
  select case
           -- The time itself changed during the day, its own creation entry excepted: nothing
           -- governed the whole of p_day, so p_day is judged untimed. Only entries where
           -- `due_time` actually moved count, so a late-window edit does not re-judge its own
           -- day (20260907100000).
           when exists (
             select 1
               from history h
              where h.entry > 1
                and h.due_time is distinct from h.previous_due_time
                and h.changed_at >= public.day_begins_at(p_day)
                and h.changed_at <  public.day_ends_at(p_day)
           ) then null

           -- An entry was in force when the day began: its value is the answer, including when
           -- that value is null because the time had been switched off. This is the branch the
           -- coalesce got wrong.
           when exists (
             select 1
               from history h
              where h.changed_at < public.day_begins_at(p_day)
           ) then (
             select h.due_time
               from history h
              where h.changed_at < public.day_begins_at(p_day)
              order by h.changed_at desc
              limit 1
           )

           -- p_day is at or before the commitment's own creation: extrapolate the earliest known
           -- value backward, the same fallback carries_penalty_as_of() makes and for the same
           -- reason -- a fixed historical fact, not a live read.
           else (
             select h.due_time
               from history h
              order by h.changed_at asc
              limit 1
           )
         end;
$$;

comment on function public.due_time_as_of(uuid, date) is
  'The due_time that governed p_commitment_id through the whole of p_day, or null if none did --
  either because the commitment was untimed then, or because the time was changed part-way through
  p_day and so governed neither the window that had already passed nor a full day. The one door to
  commitment_due_time_change. Stricter than carries_penalty_as_of() on purpose: that reads the value
  at the instant the day closed, because a cost is settled when a day ends; this asks whether there
  was a window to hit, which is a question about the whole day. Since item 38 the log also carries
  late_window_minutes, so "changed part-way through" counts only entries where due_time itself
  moved -- a window edit leaves a row but does not re-judge its own day. Three explicit branches
  rather than a coalesce, so a switched-off time reads as untimed on every later day instead of
  falling through to the value the commitment was created with.';

revoke execute on function public.due_time_as_of(uuid, date) from public, anon;
grant execute on function public.due_time_as_of(uuid, date) to authenticated;
