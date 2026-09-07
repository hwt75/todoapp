-- Epic 6 retrospective item 38: a claim is judged by what was in force when it was tapped.
--
-- `declaration_derive_day()` read the live `commitment` row to decide whether a tap answered its
-- own day or the day before. A claim tapped in airplane mode carries only its instant, so clearing
-- the time from another device before the queue flushed re-pointed a same-day claim onto the
-- previous day: it answered a day nobody had spoken about, spent that day's one allowed
-- declaration, and left the day actually claimed with no answer to fail at close.
--
-- Story 6.4 already settled the general form of this. `due_time_as_of()` (20260829090000:216) is
-- the door settlement judges days through, precisely so a settings edit cannot re-judge a day that
-- has already happened. The derivation now asks the same door.
--
-- Reading the time historically exposes that `late_window_minutes` never was. Its own comment
-- justified that -- "read at exactly one instant, the tap, by the person tapping" -- and for an
-- online tap that is still true. For a queued one it is not: by the time the row arrives the live
-- value may have moved, and because the schema forces the window null whenever the time is null
-- (20260828130000:31), a claim on a day whose time was later cleared would meet a null window,
-- compare null, and be accepted at any hour of the day. So the window joins the time in the log.


-- ---------------------------------------------------------------------------------
-- The window joins the time in the log.
-- ---------------------------------------------------------------------------------

alter table public.commitment_due_time_change
  add column late_window_minutes integer;

comment on column public.commitment_due_time_change.late_window_minutes is
  'The late_window_minutes that stood alongside due_time at that instant. Logged from Epic 6
  retrospective item 38: a claim flushed out of a queue is judged long after the tap, so the live
  value is no longer the one the author was shown. Null is a value here exactly as it is for
  due_time -- the schema keeps the two null together -- except on rows written before this column
  existed, where it means the window was never recorded and a claim on that day is refused rather
  than judged against a guess.';

-- Best available approximation for history written before this column existed, and deliberately
-- narrow: only where the log row carried a time and the commitment still carries a window. A row
-- whose commitment has since gone untimed is left null, because nothing anywhere records what its
-- window was, and inventing one would be the only outcome that can charge for a day wrongly.
update public.commitment_due_time_change ch
   set late_window_minutes = c.late_window_minutes
  from public.commitment c
 where c.id = ch.commitment_id
   and ch.due_time is not null
   and c.late_window_minutes is not null;

create or replace function public.commitment_log_due_time_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.commitment_due_time_change (commitment_id, due_time, late_window_minutes)
  values (new.id, new.due_time, new.late_window_minutes);

  return new;
end;
$$;

comment on function public.commitment_log_due_time_change() is
  'Logs every value due_time and late_window_minutes have ever held together -- the initial pair at
  row creation, and every change to either after. Fires only when one of them actually changes (the
  trigger''s own WHEN clause on the update path), never once per unrelated update.';

-- Widened to the window column. A window-only edit has to leave a row, or the history this migration
-- exists to read would have a hole in exactly the case it was added for.
drop trigger commitment_log_due_time_change_on_update on public.commitment;

create trigger commitment_log_due_time_change_on_update
  after update of due_time, late_window_minutes on public.commitment
  for each row
  when (old.due_time is distinct from new.due_time
        or old.late_window_minutes is distinct from new.late_window_minutes)
  execute function public.commitment_log_due_time_change();


-- ---------------------------------------------------------------------------------
-- A window-only edit must not re-judge the day it was made on.
-- ---------------------------------------------------------------------------------

/* `due_time_as_of()` calls a day untimed when the log carries a change inside it, because a time
   that appeared at 15:00 governed neither the window that shut at 10:30 nor a whole day. That rule
   counted *rows*, which was the same thing as counting time changes until the line above started
   writing rows for a window edit too. Left alone, widening a window at noon would have quietly
   turned that day untimed -- re-judging a day settlement may already have closed, for an edit that
   never touched the time at all.

   So the rule now counts only entries where `due_time` actually moved from the entry before it.
   For every history written before this migration the two readings are identical, which is the
   point: this changes which rows are considered, never which days are timed. */
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
           -- governed the whole of p_day, so p_day is judged untimed.
           when exists (
             select 1
               from history h
              where h.entry > 1
                and h.due_time is distinct from h.previous_due_time
                and h.changed_at >= public.day_begins_at(p_day)
                and h.changed_at <  public.day_ends_at(p_day)
           ) then null
           else coalesce(
             (select h.due_time
                from history h
               where h.changed_at < public.day_begins_at(p_day)
               order by h.changed_at desc
               limit 1),
             -- p_day is at or before the commitment's own creation: extrapolate the earliest
             -- known value backward, the same fallback carries_penalty_as_of() makes and for
             -- the same reason -- a fixed historical fact, not a live read.
             (select h.due_time
                from history h
               order by h.changed_at asc
               limit 1)
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
  moved -- a window edit leaves a row but does not re-judge its own day.';

revoke execute on function public.due_time_as_of(uuid, date) from public, anon;
grant execute on function public.due_time_as_of(uuid, date) to authenticated;


-- ---------------------------------------------------------------------------------
-- The window in force at one instant.
-- ---------------------------------------------------------------------------------

/* Deliberately not the same question `due_time_as_of()` asks. Which day a tap belongs to is a
   question about a whole day, because a window that existed for half of it governed none of it.
   How long the window was is a question about one instant -- the tap -- because that is the window
   the author was actually shown when he decided whether he was in time.

   The two readings agree for every online tap, which is why nothing about today's behaviour moves:
   the value in force at the tap *is* the live value when the tap is the same moment as the write.
   They part only for a queued claim, and there this is the one that is not a lie.

   Falls back to the earliest entry for an instant at or before the commitment's own creation, the
   same backward extrapolation `due_time_as_of()` makes, and for the same reason. */
create function public.late_window_at(p_commitment_id uuid, p_at timestamptz)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when exists (
             select 1
               from public.commitment_due_time_change h
              where h.commitment_id = p_commitment_id
                and h.changed_at <= p_at
           ) then (
             select h.late_window_minutes
               from public.commitment_due_time_change h
              where h.commitment_id = p_commitment_id
                and h.changed_at <= p_at
              order by h.changed_at desc
              limit 1
           )
           else (
             select h.late_window_minutes
               from public.commitment_due_time_change h
              where h.commitment_id = p_commitment_id
              order by h.changed_at asc
              limit 1
           )
         end;
$$;

comment on function public.late_window_at(uuid, timestamptz) is
  'How many minutes the claim window stayed open at p_at, from commitment_due_time_change. Null
  means the window at that instant was never recorded -- either the commitment was untimed then, or
  the entry predates item 38 -- and a caller judging a claim must refuse rather than compare against
  it, because a null window makes the comparison null and every hour of the day reads as open. An
  existence test rather than a coalesce, so "the recorded value is null" is never mistaken for "no
  entry applies" and answered with the creation value.';

revoke execute on function public.late_window_at(uuid, timestamptz) from public, anon;

-- Granted for the same one caller and the same exposure due_time_as_of()'s own grant already
-- accepts: declaration_derive_day() runs with invoker rights on purpose, so it can only reach the
-- log through a function the caller may execute.
grant execute on function public.late_window_at(uuid, timestamptz) to authenticated;


-- ---------------------------------------------------------------------------------
-- What the client believed when the author tapped.
-- ---------------------------------------------------------------------------------

alter table public.declaration
  add column claimed_timed boolean;

comment on column public.declaration.claimed_timed is
  'What the client believed this commitment was when the author tapped: true for a claim made from
  Today against a window, false for an answer to the morning question, null for a row queued before
  item 38 shipped or filed by the machine. An assertion, never a value: the trigger checks it
  against the log and refuses a mismatch, so a client that lies can only produce a refusal or agree
  with what is already recorded. Null means "not asserted" and is derived exactly as before -- an
  item sitting in an older client''s queue must still land.';


-- ---------------------------------------------------------------------------------
-- The derivation.
-- ---------------------------------------------------------------------------------

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
  v_governed  boolean;
  v_opens_at  numeric;
  v_tapped_at numeric;
begin
  -- True only for a genuinely client-originated statement. `file_auto_check_result()` and the
  -- settlement functions are `security definer`, so they run as the function's owner and
  -- never as either of these roles. Read once here and used twice below: it decides both
  -- whether `filed_by` is forced and whether the window applies.
  v_by_doer := current_user in ('anon', 'authenticated');

  -- Read as the caller, and kept as its own statement now that the time and the window come from
  -- `security definer` readers that see every row. This is what makes a declaration naming another
  -- account's commitment fail on RLS rather than on an ownership expression someone has to
  -- maintain -- and if it were dropped, the two functions below would answer happily about a
  -- commitment the caller cannot see.
  if not exists (select 1 from public.commitment c where c.id = new.commitment_id) then
    raise exception
      'A declaration must name a commitment that exists and belongs to you.';
  end if;

  v_local := new.answered_at at time zone 'Asia/Ho_Chi_Minh';

  -- Any machine-filed row: unchanged since 20260819200000. It answers for the previous day even on
  -- a timed commitment, and it asserts nothing -- the assertion is a statement about what a person
  -- was shown, and no person was.
  if not v_by_doer then
    new.for_day := v_local::date - 1;
    new.claimed_timed := null;
    return new;
  end if;

  new.filed_by := 'doer';

  -- The same door settlement judges days through (Story 6.4), rather than the live column. A tap
  -- that has already happened cannot be re-pointed by an edit made afterwards.
  v_due := public.due_time_as_of(new.commitment_id, v_local::date);
  v_governed := v_due is not null;

  -- The client says what it believed; the log says what was true. Where they disagree the honest
  -- answer is neither -- filing it would answer a day the author never spoke about, and spend that
  -- day's one allowed declaration doing it.
  if new.claimed_timed is true and not v_governed then
    raise exception
      'This was claimed for %, but that commitment''s time was changed during that day, so no '
      'window governed the whole of it. Answer for it in the next morning''s question instead.',
      v_local::date;
  end if;

  if new.claimed_timed is false and v_governed then
    raise exception
      'This was answered as a morning question, but the commitment carried a claim window all '
      'through %. Reopen the app and it will be asked for the right day.',
      v_local::date;
  end if;

  -- An untimed commitment, or a day no time governed: unchanged since 20260819200000.
  if not v_governed then
    new.for_day := v_local::date - 1;
    return new;
  end if;

  -- A timed commitment is answered on its own day, at the moment the thing is done.
  new.for_day := v_local::date;

  -- The window the author was shown when he tapped, not the one the commitment carries now.
  v_window := public.late_window_at(new.commitment_id, new.answered_at);

  if v_window is null then
    raise exception
      'The claim window that governed % was never recorded, so this claim cannot be judged '
      'against it. Answer for that day in the morning question instead.',
      v_local::date;
  end if;

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
  'tapped (AD-6): the previous local day for a commitment no time governed that day, and the '
  'current local day for one a time did, claimed by the doer. Since Epic 6 retrospective item 38 '
  'both the time and the window come from commitment_due_time_change -- due_time_as_of() for the '
  'day, late_window_at() for the instant -- so a claim queued offline is judged by what was in '
  'force when it was tapped rather than by whatever the commitment carries when the queue '
  'finally flushes. Refuses a commitment the caller cannot see, a claimed_timed assertion the log '
  'contradicts, a day whose window was never recorded, and a doer''s claim falling outside that '
  'window. Invoker rights on purpose -- RLS is what makes the ownership check true.';
