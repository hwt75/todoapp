-- Story 6.4 — midnight decides the day.
--
-- Stories 6.1 through 6.3 let a commitment carry an hour, let the author claim it on its own day,
-- and let a photo hang off that claim. Nothing read any of it. This migration is where the
-- machine starts reading it, and it is the only one in this epic that moves money.
--
-- Two changes to one seam:
--
--   1. A timed commitment's `held` is earned by evidence, not by the tap. `commitments_owing()`
--      -- the one read every settlement path shares -- reports what actually happened rather than
--      what was typed.
--   2. The deadline a commitment is judged against becomes its own. Until now one account-wide
--      `D+3` held every day open; a timed commitment's question dies at midnight of its own day.
--
-- Every consumer (settle_day, supersede_expiries, rule_appeal, apply_grace_days, the day summary,
-- the chain, the monthly measures) reads through that one function and needs no change. The two
-- that do not read through it -- the morning question's own count, and the weekly held-count --
-- are updated below for exactly that reason.
--
-- AD-8 is untouched: settlement is still the only writer of derived state. Nothing here writes a
-- verdict; it changes what the verdict is computed from and when it may be computed.


-- ---------------------------------------------------------------------------------
-- A deadline per commitment, not per account.
-- ---------------------------------------------------------------------------------

/* When a local day runs out, in one place.

   Half-open, and that is the whole content of it: `(p_day + 1)::timestamp` is the first instant
   of the next local day, so `now() >= day_ends_at(d)` is false at 23:59:59.999 on `d` and true
   at 00:00:00.000 after it. The same boundary `commitment_window_within_the_day` (20260828130000)
   and `declaration_derive_day()` (20260828140000) already use.

   Its own function rather than an expression repeated twice, because it is written twice below --
   once as a deadline a commitment is judged against, once inside `commitments_owing()` deciding
   whether a claim still has time to be proved -- and two copies of "when does a day end" is how
   they would eventually disagree by an hour. */
create function public.day_ends_at(p_day date)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select (p_day + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh';
$$;

comment on function public.day_ends_at(date) is
  'The instant p_day ends in Asia/Ho_Chi_Minh (AD-6) -- midnight opening the next day, so the '
  'comparison against it is half-open. Paired with day_begins_at().';

revoke execute on function public.day_ends_at(date) from public, anon, authenticated;


create function public.day_begins_at(p_day date)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select p_day::timestamp at time zone 'Asia/Ho_Chi_Minh';
$$;

comment on function public.day_begins_at(date) is
  'The instant p_day begins in Asia/Ho_Chi_Minh (AD-6). The other half of day_ends_at(), and '
  'written as its own function rather than day_ends_at(p_day - 1) because the reader of '
  'due_time_as_of() should not have to do that subtraction in their head.';

revoke execute on function public.day_begins_at(date) from public, anon, authenticated;


/* `declaration_deadline()` (20260819241000) stands exactly as it was and is still the rule for
   every untimed commitment: the morning hour on `p_day + 3`, 48 hours after the question is
   first asked. This wraps it rather than replacing it, so there is still one place that says
   what an untimed deadline is.

   A timed commitment's deadline is the instant its own local day ends, and there is nothing
   after it. A timed day cannot be answered late: the window
   refuses a tap outside it (20260828140000) and `evidence_derive_owner()` refuses a photo for
   a day that has ended (20260828150000). The only remedy for a missed one is a Grace Day, two
   per calendar month, and this migration does not change that cap. */
create function public.commitment_deadline(
  p_day date,
  p_morning_hour integer,
  p_due_time time
)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select case
           when p_due_time is null
             then public.declaration_deadline(p_day, p_morning_hour)
           else public.day_ends_at(p_day)
         end;
$$;

comment on function public.commitment_deadline(date, integer, time) is
  'When one commitment''s answer for p_day stops being accepted. An untimed commitment keeps '
  'declaration_deadline() -- the morning hour on p_day + 3. A commitment carrying a due_time is '
  'decided at midnight ending p_day (Asia/Ho_Chi_Minh, AD-6), because its claim window cannot '
  'reopen and its photo cannot arrive afterwards. A day holding both kinds closes each on its '
  'own clock.';

revoke execute on function public.commitment_deadline(date, integer, time)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- A time governs a day only if it governed the whole of it.
-- ---------------------------------------------------------------------------------

/* Read live, `due_time` re-judges the past. A day answered `held` under the untimed rule reads
   `slipped` the moment a time is added to that commitment, and the next hourly pass settles it
   `failed` with a penalty and a broken chain -- for a day answered correctly under the rule that
   was actually in force.

   This is the identical defect the Epic 4 retrospective (finding A1) fixed for `carries_penalty`
   in 20260827130000, one column away in the same select, and it gets the identical machinery: an
   append-only log written by a trigger, and one function that is the only door to it.

   **The rule here is stricter than `carries_penalty_as_of()`'s, deliberately.** That one reads the
   value at the instant the day closed, because what a miss costs is settled when the day ends.
   This one asks whether there was a window to hit, and a window can only govern a day it existed
   for the whole of:

     - changed part-way through the day -> the day is judged untimed. A time switched on at 15:00
       cannot govern a window that shut at 10:30, and a time switched off mid-day must not fail a
       day for a missing photo the app has stopped offering to take. Both directions fall back to
       the morning question, which is the only reading that never charges for a rule that was not
       in force.
     - otherwise -> the value in effect when the day began, falling back to the value the
       commitment was created with for any day at or before its own creation.

   The row's own creation entry is excluded from "changed part-way through" -- otherwise a
   commitment created at 09:00 with a time would be untimed on its own first day, and the claim it
   invites that evening would hold the day with no photo.

   `late_window_minutes` is not logged. It is read at exactly one instant -- the tap, by the person
   tapping (`declaration_derive_day()`) -- so the live value is the correct one and a history of it
   would have no reader. */
create table public.commitment_due_time_change (
  id uuid primary key default gen_random_uuid(),
  commitment_id uuid not null references public.commitment (id) on delete cascade,
  due_time time,
  -- `clock_timestamp()`, not `now()`: two entries written inside one transaction carry the
  -- identical `now()` and the log stops being orderable, which is the only thing it is for.
  -- `commitment_carries_penalty_change` uses `now()` because it predates the observation, not
  -- because ties are safe there.
  changed_at timestamptz not null default clock_timestamp()
);

comment on table public.commitment_due_time_change is
  'Append-only history of every value commitment.due_time has ever held, logged by
  commitment_log_due_time_change() below. Null is a value here, not an absence: it is how the log
  records a commitment that was untimed at that moment. Never read directly by application code --
  due_time_as_of() is the one door.';

create index commitment_due_time_change_lookup_idx
  on public.commitment_due_time_change (commitment_id, changed_at desc);

alter table public.commitment_due_time_change enable row level security;

-- An explicit deny rather than an absent policy, exactly as
-- commitment_carries_penalty_change carries: RLS with no policy already denies, but silence
-- reads as an oversight and this reads as a decision. AD-7.
create policy "commitment_due_time_change: no client may touch this"
  on public.commitment_due_time_change for all to authenticated, anon
  using (false)
  with check (false);

revoke all on table public.commitment_due_time_change from public, anon, authenticated;

create function public.commitment_log_due_time_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.commitment_due_time_change (commitment_id, due_time)
  values (new.id, new.due_time);

  return new;
end;
$$;

comment on function public.commitment_log_due_time_change() is
  'Logs every value due_time has ever held -- the initial one at row creation, and every change
  after. Fires only when the value actually changes (the trigger''s own WHEN clause on the update
  path), never once per unrelated update.';

revoke execute on function public.commitment_log_due_time_change()
  from public, anon, authenticated;

create trigger commitment_log_due_time_change_on_insert
  after insert on public.commitment
  for each row
  execute function public.commitment_log_due_time_change();

create trigger commitment_log_due_time_change_on_update
  after update of due_time on public.commitment
  for each row
  when (old.due_time is distinct from new.due_time)
  execute function public.commitment_log_due_time_change();

-- Backfill: one row per existing commitment, stamped at its own created_at with its current
-- due_time -- the best available approximation for a commitment whose true history before this
-- migration was never recorded. `due_time` itself only shipped yesterday (20260828130000) and no
-- edit of it has been settled against, so nothing here reconciles a real, disputed day.
insert into public.commitment_due_time_change (commitment_id, due_time, changed_at)
select id, due_time, created_at
  from public.commitment;

create function public.due_time_as_of(p_commitment_id uuid, p_day date)
returns time
language sql
stable
security definer
set search_path = ''
as $$
  select case
           -- Changed during the day itself, its own creation entry excepted: nothing governed
           -- the whole of p_day, so p_day is judged untimed.
           when exists (
             select 1
               from public.commitment_due_time_change ch
              where ch.commitment_id = p_commitment_id
                and ch.changed_at >= public.day_begins_at(p_day)
                and ch.changed_at < public.day_ends_at(p_day)
                and ch.changed_at > (
                  select min(first.changed_at)
                    from public.commitment_due_time_change first
                   where first.commitment_id = p_commitment_id
                )
           ) then null
           else coalesce(
             (select ch.due_time
                from public.commitment_due_time_change ch
               where ch.commitment_id = p_commitment_id
                 and ch.changed_at < public.day_begins_at(p_day)
               order by ch.changed_at desc
               limit 1),
             -- p_day is at or before the commitment's own creation: extrapolate the earliest
             -- known value backward, the same fallback carries_penalty_as_of() makes and for
             -- the same reason -- a fixed historical fact, not a live read.
             (select ch.due_time
                from public.commitment_due_time_change ch
               where ch.commitment_id = p_commitment_id
               order by ch.changed_at asc
               limit 1)
           )
         end;
$$;

comment on function public.due_time_as_of(uuid, date) is
  'The due_time that governed p_commitment_id through the whole of p_day, or null if none did --
  either because the commitment was untimed then, or because the time was changed part-way
  through p_day and so governed neither the window that had already passed nor a full day. The one
  door to commitment_due_time_change. Stricter than carries_penalty_as_of() on purpose: that reads
  the value at the instant the day closed, because a cost is settled when a day ends; this asks
  whether there was a window to hit, which is a question about the whole day.';

revoke execute on function public.due_time_as_of(uuid, date) from public, anon;

-- Granted to `authenticated` for exactly one caller: weekly_held_count(), which is
-- security_invoker and granted itself (20260820150000) so weekly_quota_progress can read it under
-- the client's own privileges. The exposure this adds -- someone holding another account's
-- commitment uuid could learn what time it carried -- is the same one weekly_held_count()'s own
-- grant already accepts for that account's held count, on the same unguessable key.
-- carries_penalty_as_of() stays revoked because it has no such caller.
grant execute on function public.due_time_as_of(uuid, date) to authenticated;


-- ---------------------------------------------------------------------------------
-- The one read every settlement path shares, now able to tell a proven day from a claimed one.
-- ---------------------------------------------------------------------------------

/* Dropped and recreated rather than replaced: `due_time` is a new OUT column, which changes the
   function's row type, and `create or replace` refuses that. Safe to drop because nothing that
   calls it is a tracked dependency -- every caller is a plpgsql body, whose references are
   resolved at execution time, and no view reads it.

   **The change in meaning, stated plainly.** `answer` was `declaration.answer` verbatim. It now
   passes through untouched for every untimed commitment and for every answer that is not a
   claim of `held`; a timed commitment's `held` has to be proven.

     - No declaration at all -> null, exactly as before. This is load-bearing: Silence detection
       (20260826090000) and the monthly answer-rate measures (20260826110000) both read
       `count(*)` against `count(answer)` over this function to decide whether a day was quiet.
       Synthesising a miss for a day the author ignored would say he spoke when he did not, and
       would break both.
     - An admitted `slipped` -> `slipped`. He said he missed it; a photo would not change that,
       and there is nothing to prove.
     - `held` with evidence -> `held`. The existence of an `evidence` row is acceptance: its own
       trigger has already refused a wrong-dated photo and a photo arriving after the day ended.
     - `held` with no evidence, day over -> `slipped`. He answered, and the answer is not the
       thing that holds a timed day. Reported as a miss rather than as silence so the day settles
       `failed` with a `missed` outcome and its summary still goes out -- an `expired` day sends
       none, and filing this as silence would put a day he actually engaged with into a history
       of days he did not.
     - `held` with no evidence, day still running -> null. The photo may still arrive. Nothing
       settles today anyway (`settle_due_days()` sweeps `today - 5 .. today - 1`), but the
       function answers honestly for any p_day rather than relying on its callers' choice. */
drop function public.commitments_owing(uuid, date);

create function public.commitments_owing(p_owner uuid, p_day date)
returns table (
  commitment_id uuid,
  carries_penalty boolean,
  answer public.declaration_answer,
  cadence public.commitment_cadence,
  due_time time
)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id,
         public.carries_penalty_as_of(c.id, p_day),
         case
           when t.due_time is null then d.answer
           when d.answer is distinct from 'held' then d.answer
           when exists (
             select 1 from public.evidence e where e.declaration_id = d.id
           ) then d.answer
           when now() >= public.day_ends_at(p_day) then 'slipped'::public.declaration_answer
           else null
         end,
         c.cadence,
         t.due_time
    from public.commitment c
    cross join lateral (select public.due_time_as_of(c.id, p_day) as due_time) t
    left join public.declaration d
           on d.commitment_id = c.id and d.for_day = p_day
   where c.owner_id = p_owner
     and c.cadence <> 'daily_hours_quota'
     -- Nothing is judged for a day it did not exist on. The same guard resolve_auto_checks()
     -- (20260824090000) and settle_week() (20260820150000) already carry, arriving here late:
     -- while every deadline was D+3 a brand-new commitment already cost two of the five days
     -- settle_due_days() sweeps, and with midnight it would cost all five.
     --
     -- Every fixture under supabase/tests/ had to learn to say when its commitments began --
     -- eighteen of them created a commitment moments before judging days that predate it, which
     -- is a state no real account can be in.
     and (c.created_at at time zone 'Asia/Ho_Chi_Minh')::date <= p_day
     and (c.archived_at is null
          or (c.archived_at at time zone 'Asia/Ho_Chi_Minh')::date > p_day)
     -- A Weekly Quota is judged at week close, and not doing it on a Tuesday is the shape of the
     -- commitment rather than a silence. While the morning gate asked about it daily there was an
     -- answer every day and the day had something to say; a timed one is not asked (the gate
     -- exclusion below), so an unclaimed day would sit here unanswered and settle the whole day
     -- `expired` -- no summary, a broken chain, and Story 5.2's intervention firing at an author
     -- who is on target for the week. A day it *was* claimed on still appears, held or slipped,
     -- because there is something to say about that one. weekly_held_count() remains the only
     -- thing that judges the quota itself.
     and not (c.cadence = 'weekly_quota' and t.due_time is not null and d.id is null);
$$;

comment on function public.commitments_owing(uuid, date) is
  'Every commitment p_owner owes an answer for on p_day, whether it was penalty-carrying AS OF
  THAT DAY (carries_penalty_as_of(), Epic 4 retrospective A1 fix, 2026-08-27), and what it
  actually did. Excludes daily_hours_quota (FR-2, judged by measured minutes) and a commitment
  archived on or before p_day, a commitment created after p_day, and a timed weekly_quota
  commitment on a day it was not claimed. cadence is read by settle_day/settle_week to exclude
  weekly_quota from the two counts that turn a miss into money; due_time is the value that governed
  p_day (due_time_as_of(), never the live column) and is read by the same callers to know which
  deadline this row is judged against (commitment_deadline()). Story 6.4: on a commitment that
  carried a due_time through p_day, a claim of held is reported as held only once evidence exists
  for it, and as slipped once the day it was made has ended without any -- the photo is what holds
  a timed day, not the tap. A commitment with no declaration at all still reports null, unchanged:
  that is what Silence detection and the answer-rate measures count.';

revoke execute on function public.commitments_owing(uuid, date) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Settlement, closing each commitment on its own clock.
-- ---------------------------------------------------------------------------------

/* Only the deadline gate changes; the counts, the AD-13 Auto-check guard, the verdict, the
   penalty, the frozen outcomes and the summary are all carried over verbatim from
   20260824100000_a_check_that_cannot_run_never_says_i_missed.sql and all of them read
   `o.answer`, which now tells them the truth about a timed commitment without being touched.

   The old gate was one account-wide question -- `answered < total and not past_deadline` --
   which is the same question asked per row when every row shares a deadline. Now they do not,
   so it is asked per row: hold the day while any commitment still owes an answer that could
   still arrive. For an account with no timed commitments the two are exactly equivalent.

   What this deliberately does NOT do is settle a day in pieces. A day mixing a forgotten photo
   with an unanswered gym commitment still waits for the gym commitment, because a settlement
   covers a day, not a commitment. The timed verdict is already fixed at midnight and cannot
   move; only the moment it is written down is shared with the rest of the day. */
create or replace function public.settle_day(p_day date, p_override boolean default false)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  invocation text := coalesce(current_setting('app.settlement_invocation', true), '');
  account record;
  total integer;
  answered integer;
  admitted integer;
  silent integer;
  held integer;
  survivor_id uuid;
  survivor text;
  survivor_chain integer;
  suggestion text;
  verdict public.day_verdict;
  inserted integer;
  new_settlement uuid;
  settled integer := 0;
begin
  if current_user in ('anon', 'authenticated') then
    raise exception 'settle_day is never callable from the application (AD-2)';
  end if;

  if invocation <> 'schedule' and not p_override then
    raise exception
      'settle_day ran outside its schedule with no override. Pass p_override => true, '
      'which is refused for the live doer account (AD-16).';
  end if;

  for account in
    select p.id, p.is_live_doer, p.morning_hour from public.profile p where p.role = 'doer'
  loop
    if p_override and account.is_live_doer then
      raise exception
        'settle_day refuses an override against the live doer account (AD-16). '
        'Only the schedule may settle it.';
    end if;

    select count(*),
           count(o.answer),
           count(*) filter (
             where o.carries_penalty and o.answer = 'slipped' and o.cadence <> 'weekly_quota'
           ),
           count(*) filter (
             where o.carries_penalty and o.answer is null and o.cadence <> 'weekly_quota'
           ),
           count(*) filter (where o.answer = 'held')
      into total, answered, admitted, silent, held
      from public.commitments_owing(account.id, p_day) o;

    continue when total = 0;

    -- AD-13: a day cannot settle while any of its owed, unanswered, Auto-check-linked
    -- commitments still has a pending check for it — bounded by auto_check_pending's own
    -- 96-hour grace window rather than held open indefinitely. Checked ahead of the deadline
    -- gate on purpose: an expired-but-Auto-check-pending day must still block, which is
    -- exactly the race Story 4.2 closed. Excludes weekly_quota the same way admitted/silent
    -- above do: a Weekly Quota commitment's own Auto-check protection is settle_week's guard,
    -- not this one — commitments_owing() does not exclude weekly_quota from its result set
    -- (only daily_hours_quota is excluded), so without this filter a stuck weekly-quota check
    -- would delay the whole day's settlement, notification and penalty freeze for every other,
    -- unrelated commitment on the account — a collateral cost that story never asked for.
    continue when exists (
      select 1 from public.commitments_owing(account.id, p_day) o
       where o.answer is null and o.cadence <> 'weekly_quota'
         and public.auto_check_pending(o.commitment_id, p_day)
    );

    -- The deadline, per commitment (Story 6.4). Hold the day while any single commitment still
    -- owes an answer that its own clock would still accept. An untimed commitment's clock is
    -- the account's morning hour on p_day + 3; a timed one's ran out at midnight.
    continue when exists (
      select 1 from public.commitments_owing(account.id, p_day) o
       where o.answer is null
         and now() < public.commitment_deadline(p_day, account.morning_hour, o.due_time)
    );

    verdict := case
      when answered < total then 'expired'
      when admitted > 0 then 'failed'
      else 'clean'
    end;

    insert into public.settlement (subject, period, kind, verdict, missed_count)
    values (account.id, p_day, 'day', verdict, admitted + silent)
    on conflict (subject, period, kind) where supersedes is null do nothing
    returning id into new_settlement;

    get diagnostics inserted = row_count;
    settled := settled + inserted;

    continue when new_settlement is null;

    if (admitted + silent) > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (account.id, new_settlement, public.penalty_amount_dong());
    end if;

    -- What each commitment did, frozen. This happens for an expired day too, and that is
    -- the point of `unanswered` being its own outcome: the chain has to break on silence,
    -- and the history has to say *why* it broke rather than filing it as a miss.
    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    select new_settlement, account.id, o.commitment_id,
           case o.answer
             when 'held' then 'held'
             when 'slipped' then 'missed'
             else 'unanswered'
           end::public.commitment_outcome
      from public.commitments_owing(account.id, p_day) o;

    -- No summary for a day that expired. The data is there and it is tempting, but a
    -- message saying "one of five today, start with X tomorrow" about a day he never
    -- answered is the product pretending it knows how his day went. It knows he did not say.
    continue when verdict = 'expired';

    -- One commitment that held, and one to start with tomorrow. Deliberately single values
    -- rather than lists: two suggestions is a to-do list, and a list of misses is the thing
    -- this message exists to replace.
    select c.id, c.name into survivor_id, survivor
      from public.commitments_owing(account.id, p_day) o
      join public.commitment c on c.id = o.commitment_id
     where o.answer = 'held'
     order by c.created_at
     limit 1;

    select c.name into suggestion
      from public.commitments_owing(account.id, p_day) o
      join public.commitment c on c.id = o.commitment_id
     order by (o.answer = 'slipped') desc, c.created_at
     limit 1;

    continue when suggestion is null;

    -- Read after the outcomes above are written, so the number includes the day being
    -- summarised: "day 12" means it has now held twelve days, not eleven and counting.
    select ch.current_days into survivor_chain
      from public.chain_current ch
     where ch.commitment_id = survivor_id;

    perform public.outbox_enqueue(
      account.id,
      'summary-' || account.id::text || '-' || p_day::text,
      jsonb_build_object(
        'title', 'Today',
        'body', public.day_summary_body(
                  held, total, p_day,
                  case when (admitted + silent) > 0 then public.penalty_amount_dong() end,
                  survivor, suggestion, survivor_chain),
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );
  end loop;

  return settled;
end;
$$;

revoke execute on function public.settle_day(date, boolean) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The expiry correction, on the same per-commitment clock.
-- ---------------------------------------------------------------------------------

/* Carried over from 20260820140000_weekly_quota_is_not_judged_daily.sql with two changes,
   both consequences of the deadline no longer being one value per account:

     1. `timely` is measured against each row's own deadline rather than one computed ahead of
        the loop. For an untimed commitment this is the identical number.
     2. `admitted` reads `o.answer` rather than the joined `d.answer`. The join is still needed
        for `answered_at` -- the instant, which commitments_owing() does not carry -- but *what
        the answer was worth* is the function's business now, and a timed claim whose photo
        never came reads `slipped` there while `d.answer` still says `held`.

   A timed commitment cannot be the reason a day is corrected: its answer cannot arrive after
   its own deadline, so an expired day containing an unanswered one stays expired forever, which
   is the correct outcome and needs no special case. */
create or replace function public.supersede_expiries()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_row record;
  morning integer;
  total integer;
  timely integer;
  admitted integer;
  correction uuid;
  corrected integer := 0;
begin
  for expired_row in
    select s.* from public.settlement_current s where s.verdict = 'expired'
  loop
    select p.morning_hour into morning from public.profile p where p.id = expired_row.subject;

    select count(*),
           count(*) filter (
             where d.id is not null
               and d.answered_at
                     < public.commitment_deadline(expired_row.period, morning, o.due_time)
           ),
           count(*) filter (
             where d.answered_at
                     < public.commitment_deadline(expired_row.period, morning, o.due_time)
               and o.answer = 'slipped' and o.carries_penalty
               and o.cadence <> 'weekly_quota'
           )
      into total, timely, admitted
      from public.commitments_owing(expired_row.subject, expired_row.period) o
      left join public.declaration d
             on d.commitment_id = o.commitment_id and d.for_day = expired_row.period;

    -- Still short an answer, or an answer that was genuinely late. The expiry stands and
    -- the remedy is a Grace Day, not a rewrite.
    continue when timely < total;

    insert into public.settlement (subject, period, kind, verdict, missed_count, supersedes)
    values (
      expired_row.subject,
      expired_row.period,
      expired_row.kind,
      (case when admitted > 0 then 'failed' else 'clean' end)::public.day_verdict,
      admitted,
      expired_row.id
    )
    returning id into correction;

    -- What each commitment did, frozen against the correction — the half that was
    -- missing. Every answer here is timely by the `continue` above, so the `else` arm is
    -- unreachable rather than lenient; it is written the same way `settle_day` writes it
    -- so the two cannot drift into disagreeing about what an outcome means.
    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    select correction, expired_row.subject, o.commitment_id,
           case o.answer
             when 'held' then 'held'
             when 'slipped' then 'missed'
             else 'unanswered'
           end::public.commitment_outcome
      from public.commitments_owing(expired_row.subject, expired_row.period) o;

    -- The correction carries its own penalty if he did admit a slip. The original's
    -- penalty stays in the table as history and stops counting, because `penalty_current`
    -- follows the chain.
    if admitted > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (expired_row.subject, correction, public.penalty_amount_dong());
    end if;

    corrected := corrected + 1;
  end loop;

  return corrected;
end;
$$;

revoke execute on function public.supersede_expiries() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The morning question, which no longer asks about a day that already ended.
-- ---------------------------------------------------------------------------------

/* The server-side half of the exclusion whose client-side half shipped in Story 6.2
   (`lib/declaration.ts`, `owesAMorningAnswer()`). `lib/declaration.ts` decides what the app
   *asks*; this decides what the push asks, and `commitments_owing()` above decides what is
   *true*. All three now agree.

   Only the `outstanding` count changes, and only by one `where` clause -- the same shape the
   `cadence <> 'daily_hours_quota'` exclusion beside it already has, and for a related reason:
   that question is answered by measured minutes, this one was answered at midnight.

   The Silence detection above it is deliberately left reading `commitments_owing()` unfiltered.
   A timed commitment the author ignored yesterday is exactly the kind of day Story 5.2 exists
   to notice, and it still counts as owing and unanswered there. */
create or replace function public.enqueue_gate_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  account record;
  local_now timestamp;
  local_hour integer;
  asked_day date;
  slot integer;
  outstanding integer;
  enqueued integer := 0;

  -- Story 2.9, restored 2026-08-26: named only when exactly one commitment is outstanding
  -- and its chain is actually running (see the stake computation below for both conditions).
  lone_commitment uuid;
  lone_chain integer;
  stake text;

  -- Story 5.2: Silence-streak detection. Re-derived every run, no counter column (matches
  -- supersede_expiries()/apply_grace_days()'s own convention) -- reset per account below so a
  -- stale value from a previous loop iteration can never leak into this one's decision.
  owing_total integer;
  owing_answered integer;
  quiet_yesterday boolean;
  quiet_day_before boolean;
  earlier_quiet_day date;
  new_episode_id uuid;

  -- Story 5.3: escalation. Read fresh every pass, independent of whether the block above
  -- opened a new episode this pass or found one already open from days ago.
  escalating_id uuid;
  escalating_started_day date;
  escalating_updated integer;
  escalating_elapsed integer;
begin
  local_now := now() at time zone 'Asia/Ho_Chi_Minh';
  local_hour := extract(hour from local_now)::integer;
  asked_day := local_now::date - 1;

  for account in
    select p.id, p.morning_hour from public.profile p where p.role = 'doer'
  loop
    -- Before the hour he agreed to, there is nothing to ask, and no day is old enough yet to
    -- judge quiet against.
    continue when local_hour < account.morning_hour;

    -- -----------------------------------------------------------------------------
    -- Silence-streak detection. A day is quiet when the account had commitments owing
    -- (commitments_owing(), the same read settle_day()/supersede_expiries() already use) and
    -- zero of them carry a declaration. Two consecutive quiet asked-days (asked_day and the
    -- one before it) with no active episode open one.
    -- -----------------------------------------------------------------------------
    new_episode_id := null;

    select count(*), count(o.answer) into owing_total, owing_answered
      from public.commitments_owing(account.id, asked_day) o;
    quiet_yesterday := owing_total > 0 and owing_answered = 0;

    select count(*), count(o.answer) into owing_total, owing_answered
      from public.commitments_owing(account.id, asked_day - 1) o;
    quiet_day_before := owing_total > 0 and owing_answered = 0;

    if quiet_yesterday and quiet_day_before then
      earlier_quiet_day := asked_day - 1;

      -- `on conflict (owner_id) where satisfied_at is null do nothing` targets
      -- silence_episode_one_active directly, mirroring outbox_enqueue()'s own
      -- dedupe-by-conflict shape: a second detection before the next asked-day advances (this
      -- same hour, or four hours later) is a no-op rather than a second row or a raised
      -- exception racing settlement's own writers.
      insert into public.silence_episode (owner_id, started_day, notified_at)
      values (account.id, earlier_quiet_day, now())
      on conflict (owner_id) where satisfied_at is null do nothing
      returning id into new_episode_id;

      if new_episode_id is not null then
        -- Self-dated like every other push this pass sends (Story 1.2's own rule, restated on
        -- gate-reminders' own body above) -- a push can arrive minutes late, and the intervention
        -- states its own account of "as of" rather than implying it is describing right now.
        perform public.outbox_enqueue(
          account.id,
          'silence-' || account.id::text || '-' || earlier_quiet_day::text,
          jsonb_build_object(
            'title', 'Two quiet days',
            'body', 'Two quiet days. This is the part where it usually ends. It doesn''t '
                    'have to. Open the app for what to do today, as of '
                    || to_char(local_now, 'HH24:MI') || '.',
            'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
          )
        );
      end if;
    end if;

    -- -----------------------------------------------------------------------------
    -- Story 5.3: escalate the active, unescalated episode (if any) once it reaches 4
    -- consecutive quiet days, counted from its own started_day. Guarded on
    -- `escalated_at is null` on both this read and the update below, so a concurrent second
    -- run of this same pass finds either nothing left to update (the update's own `where`
    -- matches zero rows) or nothing left to read (a prior run already stamped it) -- either
    -- way, no second email. No re-derivation of Silence itself: the episode being active
    -- (satisfied_at is null) already proves continuous silence since started_day, exactly the
    -- way 5.2's own detection above already established it.
    --
    -- The update's own `where` also repeats `satisfied_at is null`, not only
    -- `escalated_at is null`: a Declaration can land (declaration_satisfies_silence(), 5.2's
    -- own trigger) in the gap between this SELECT and the UPDATE below -- a different session
    -- entirely, since this whole function runs one account's iteration inside its own
    -- statement boundaries, not one enclosing transaction across the full account loop.
    -- Without this second guard, that race would still stamp escalated_at and send an email
    -- for an episode that was satisfied moments before, contradicting "any Declaration
    -- answered... cancels further escalation".
    -- -----------------------------------------------------------------------------
    escalating_id := null;

    select id, started_day into escalating_id, escalating_started_day
      from public.silence_episode
     where owner_id = account.id
       and satisfied_at is null
       and escalated_at is null;

    if escalating_id is not null and asked_day - escalating_started_day >= 3 then
      update public.silence_episode
         set escalated_at = now()
       where id = escalating_id
         and escalated_at is null
         and satisfied_at is null;

      get diagnostics escalating_updated = row_count;

      if escalating_updated > 0 then
        escalating_elapsed := asked_day - escalating_started_day + 1;

        -- Email, not push: a new `channel` on the same outbox (AD-3), never a parallel
        -- queue. The referee's own address is resolved server-side by email-worker, at send
        -- time, from auth.users -- never carried in this payload, and never the row's own
        -- owner_id (the doer, kept here only for FK/cascade/audit consistency with every
        -- other outbox row -- Design Notes). The body states the actual elapsed day count,
        -- never a hardcoded "four", and is self-dating like every other body this pass
        -- builds (push_body_is_sendable requires it) -- names only the day count, no amount,
        -- no missed commitment, per FR-18.
        perform public.outbox_enqueue(
          account.id,
          'silence-escalate-' || account.id::text || '-' || escalating_started_day::text,
          jsonb_build_object(
            'title', 'He has gone quiet',
            'body', 'He hasn''t opened this in ' || escalating_elapsed::text
                    || ' days. Nothing needs deciding — but he''d probably rather hear '
                    || 'from you than from the app, as of ' || to_char(local_now, 'HH24:MI')
                    || '.',
            'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
          ),
          'email'
        );
      end if;
    end if;

    -- While an owner has an active episode, routine gate-reminder pushes are skipped entirely
    -- -- every slot, every morning, not only the morning the episode opened above. The
    -- intervention replaces them; it never adds to them. The day-summary push is untouched --
    -- it is a different function (20260819250000) this pass never calls.
    continue when exists (
      select 1 from public.silence_episode s
       where s.owner_id = account.id and s.satisfied_at is null
    );

    slot := local_hour - account.morning_hour;
    continue when slot >= public.gate_reminder_slots();

    -- A commitment owes an answer when its cadence is settled by his word, it was not
    -- already archived before the day in question, and nothing has been filed for it.
    -- `daily_hours_quota` is excluded: FR-2 judges it against measured minutes, not a
    -- statement, and asking would invite a softer second answer.
    --
    -- Story 6.4: a commitment carrying a `due_time` is excluded for a related reason. Its
    -- question was asked and answered inside its own window and decided at midnight; asking
    -- again the next morning would offer a second, softer answer to a day already judged --
    -- and `declaration_derive_day()` would file that answer against today rather than
    -- yesterday, so it could not even reach the day being asked about.
    --
    -- The **live** column, deliberately, while settlement reads the frozen one
    -- (`due_time_as_of()`). These are different questions: what is *true* about a day is
    -- settled by the rule that governed it, but what is worth *asking* is settled by what the
    -- author can actually answer right now -- and `declaration_derive_day()` reads the live
    -- value too, so a commitment timed today can only be claimed today. A commitment that was
    -- untimed yesterday and timed this morning is therefore not asked about yesterday: the
    -- question would have no reachable answer, and an unanswerable prompt is worse than a
    -- missing one.
    --
    -- Story 2.9, restored: `array_agg(...)[1]`, not `min(c.id)` -- Postgres has no `min` for
    -- uuid. The aggregated id is only meaningful when `outstanding = 1`; with more than one
    -- it is an arbitrary row and the stake block below must never use it.
    select count(*), (array_agg(c.id))[1] into outstanding, lone_commitment
      from public.commitment c
     where c.owner_id = account.id
       and c.cadence <> 'daily_hours_quota'
       and c.due_time is null
       and (c.archived_at is null
            or (c.archived_at at time zone 'Asia/Ho_Chi_Minh')::date > asked_day)
       and not exists (
         select 1 from public.declaration d
          where d.commitment_id = c.id and d.for_day = asked_day
       );

    continue when outstanding = 0;

    -- Story 2.9, restored: names the chain at stake, never the money -- and only when exactly
    -- one commitment is being asked about (no honest composite of several different chains
    -- exists) and only when that chain is actually running (a chain at zero has nothing
    -- waiting).
    stake := '';
    if outstanding = 1 then
      select ch.current_days into lone_chain
        from public.chain_current ch
       where ch.commitment_id = lone_commitment;

      if coalesce(lone_chain, 0) > 0 then
        stake := 'Day ' || lone_chain::text || ' is waiting. ';
      end if;
    end if;

    -- The body states the time it was sent and describes a state as of that time. A push
    -- can arrive minutes late — Story 2.4a's payload rules exist for exactly this, and the
    -- outbox refuses a payload without its own timestamp.
    perform public.outbox_enqueue(
      account.id,
      'gate-' || account.id::text || '-' || asked_day::text || '-' || slot::text,
      jsonb_build_object(
        'title', 'Yesterday',
        'body', stake
                || outstanding::text
                || case when outstanding = 1 then ' commitment is' else ' commitments are' end
                || ' unanswered for ' || asked_day::text
                || ', as of ' || to_char(local_now, 'HH24:MI') || '.',
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );

    enqueued := enqueued + 1;
  end loop;

  return enqueued;
end;
$$;

revoke execute on function public.enqueue_gate_reminders() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The weekly quota counts proven days only.
-- ---------------------------------------------------------------------------------

/* The one place outside `commitments_owing()` that tallies a held day, and the reason it has to
   learn this rule directly: `weekly_quota_progress` (live) and `settle_week` (frozen) both read
   it, and `settle_week` pays out on it. Without this a timed Weekly Quota commitment could meet
   its target on claims no photo ever proved.

   Deliberately not routed through `commitments_owing()`: that function answers about one day
   for one owner, and this counts seven days for one commitment. Rewriting it in terms of the
   other would replace one shared rule with a loop.

   No midnight clause here, unlike `commitments_owing()`. A claim whose photo has not arrived
   yet simply is not counted, on the day it was made or afterwards -- which is the honest live
   answer for a week still running, and the correct frozen one for a week that has closed.

   Reads `due_time_as_of(commitment, that day)` rather than the live column, for the same reason
   `commitments_owing()` does: otherwise adding a time mid-week would silently drop every day
   already declared held that week, and `settle_week()` would freeze the reduced count.

   Still `security_invoker`-safe: `due_time_as_of()` is granted to `authenticated` for this one
   caller, and the `exists` reads evidence the caller owns, which their RLS policy already
   allows. */
create or replace function public.weekly_held_count(p_commitment_id uuid, p_week_start date)
returns integer
language sql
stable
set search_path = ''
as $$
  select count(*)::integer
    from public.declaration dec
   where dec.commitment_id = p_commitment_id
     and dec.answer = 'held'
     and dec.for_day >= p_week_start
     and dec.for_day < p_week_start + 7
     and (public.due_time_as_of(p_commitment_id, dec.for_day) is null
          or exists (
            select 1 from public.evidence e where e.declaration_id = dec.id
          ))
$$;

comment on function public.weekly_held_count(uuid, date) is
  'How many days a commitment was declared held within the 7 days starting p_week_start. '
  'The one counting rule read by both weekly_quota_progress (live, today''s week) and '
  'settle_week (frozen, a closed week) — never two copies (AD-8). Story 6.4: on a commitment '
  'carrying a due_time, a declared day counts only once evidence exists for it — the photo is '
  'what holds a timed day, and a quota met on unproven claims would be paid out by '
  'settle_week().';


-- ---------------------------------------------------------------------------------
-- A sensor and a photo are two answers to one question.
-- ---------------------------------------------------------------------------------

/* Story 6.2 left this open deliberately: `declaration_derive_day()` kept the previous-day
   derivation for every machine-filed row, including on a timed commitment, because settlement
   did not know about `due_time` yet and inventing behaviour for a judge that had not been
   written would have been worse than recording the question. This is that judge, so this is
   where it is answered.

   Refused rather than reconciled. Left legal, an Auto-check filing `held` the next morning
   would hold a day no photo ever proved -- exactly the hole this epic exists to close -- and
   one filing `slipped` would file a verdict for a day already decided at midnight, on a row
   that `resolve_auto_checks()` only reaches when no claim exists, which is a day that has
   already failed. Neither is a behaviour worth having.

   Its own constraint rather than folded into `commitment_time_needs_a_moment` or
   `commitment_auto_check_not_on_abstain`: those two exclude the same two kinds for unrelated
   reasons and this excludes a combination, not a kind. Same reason `canBeTimed()` is not
   `autoChecksPossible()`. */
/* A row already carrying both is possible: `due_time` shipped in 20260828130000 and nothing has
   refused the combination since. It fails this migration loudly rather than being repaired in
   passing -- unlinking someone's Auto-check or dropping their time without being asked is a
   silent change to what a commitment means. The message says which rows and what to do. */
do $$
declare
  v_offenders integer;
begin
  select count(*) into v_offenders
    from public.commitment
   where due_time is not null and auto_check_kind is not null;

  if v_offenders > 0 then
    raise exception using message = format(
      '%s commitment(s) carry both a due_time and an Auto-check, which Story 6.4 refuses. '
      'Decide each one by hand before applying this migration -- clear the Auto-check to keep '
      'the time, or clear the time to keep the sensor. This migration will not choose for you. '
      'select id, name, due_time, auto_check_kind from public.commitment '
      'where due_time is not null and auto_check_kind is not null;', v_offenders);
  end if;
end;
$$;

alter table public.commitment
  add constraint commitment_time_not_with_auto_check
    check (due_time is null or auto_check_kind is null);
