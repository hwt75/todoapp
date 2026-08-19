-- ---------------------------------------------------------------------------------
-- A correction is a new row, and the ledger is the fold of the chain (AD-9).
--
-- The `(subject, period, kind)` uniqueness from AD-5 still holds for *original* verdicts.
-- A correction carries `supersedes` and is exempt, because AD-5 forbids re-settling a
-- period, not recording that an earlier settlement was wrong.
-- ---------------------------------------------------------------------------------

alter table public.settlement
  add column supersedes uuid references public.settlement (id) on delete restrict;

comment on column public.settlement.supersedes is
  'Set on a correction. The original row is never touched; the ledger folds the chain (AD-9).';

alter table public.settlement drop constraint settlement_once;

-- One original verdict per period, as before.
create unique index settlement_once_original
  on public.settlement (subject, period, kind)
  where supersedes is null;

-- And at most one correction per original, so a chain cannot fork.
create unique index settlement_once_correction
  on public.settlement (supersedes)
  where supersedes is not null;

/* The current state of every settled period: the end of each supersession chain.

   `security_invoker` so the view is read under the caller's own policies rather than the
   view owner's — without it, a view over an RLS table is a way around RLS. */
create view public.settlement_current
with (security_invoker = true)
as
select s.*
  from public.settlement s
 where not exists (select 1 from public.settlement c where c.supersedes = s.id);

/* Penalties that still stand. A penalty attached to a superseded verdict is history, not
   debt — it stays in the table so the trace survives, and it stops counting. */
create view public.penalty_current
with (security_invoker = true)
as
select p.*
  from public.penalty p
  join public.settlement_current s on s.id = p.settlement_id;


-- ---------------------------------------------------------------------------------
-- The deadline.
-- ---------------------------------------------------------------------------------

/* A declaration for day D is requested at the morning hour on D+1 and expires at that same
   hour on D+3 — 48 hours later, wall-clock, in Asia/Ho_Chi_Minh (AD-6).

   Not extended for being unreachable. The remedy for a genuinely impossible two days is a
   Grace Day applied from the ledger afterwards, which is a recorded act with a count,
   rather than a clock that quietly stretches for whoever asks. */
create function public.declaration_deadline(p_day date, p_morning_hour integer)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select ((p_day + 3)::timestamp + make_interval(hours => p_morning_hour))
         at time zone 'Asia/Ho_Chi_Minh';
$$;

revoke execute on function public.declaration_deadline(date, integer) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Settlement, now able to close a day on the clock.
-- ---------------------------------------------------------------------------------

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
  past_deadline boolean;
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
           count(*) filter (where o.carries_penalty and o.answer = 'slipped'),
           count(*) filter (where o.carries_penalty and o.answer is null)
      into total, answered, admitted, silent
      from public.commitments_owing(account.id, p_day) o;

    continue when total = 0;

    past_deadline := now() >= public.declaration_deadline(p_day, account.morning_hour);

    -- A day closes when he has answered everything, or when the clock has run out on what
    -- he has not. Before both, it stays open — visibly, rather than being decided against
    -- him early.
    continue when answered < total and not past_deadline;

    verdict := case
      -- Closed on the clock rather than on his word. A different fact about him from an
      -- admitted slip, and the ledger must not merge the two.
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

    -- An expired day costs exactly what an admitted one costs. Cheaper would make silence
    -- cheaper than honesty, which is the failure this is named after; dearer would punish
    -- being unreachable.
    if new_settlement is not null and (admitted + silent) > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (account.id, new_settlement, public.penalty_amount_dong());
    end if;
  end loop;

  return settled;
end;
$$;

revoke execute on function public.settle_day(date, boolean) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Supersession.
-- ---------------------------------------------------------------------------------

/* Takes back an expiry when the answers turn out to have been given in time.

   AD-5 ignores *late-arriving events* for a settled period. An answer given at 07:31 on day
   two and delivered on day four is not a late event — it is a timely event delivered late,
   and `answered_at` is the difference. That is the whole reason the offline queue preserves
   the tap instant rather than stamping the send.

   Only a fully explained silence is taken back: every commitment that went unanswered must
   now carry a declaration made before the deadline. A partial arrival leaves the expiry
   standing, because the day did still close on the clock. */
create function public.supersede_expiries()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_row record;
  morning integer;
  deadline timestamptz;
  total integer;
  timely integer;
  admitted integer;
  corrected integer := 0;
begin
  for expired_row in
    select s.* from public.settlement_current s where s.verdict = 'expired'
  loop
    select p.morning_hour into morning from public.profile p where p.id = expired_row.subject;
    deadline := public.declaration_deadline(expired_row.period, morning);

    select count(*),
           count(*) filter (where d.id is not null and d.answered_at < deadline),
           count(*) filter (
             where d.answered_at < deadline and d.answer = 'slipped' and o.carries_penalty
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
    );

    -- The correction carries its own penalty if he did admit a slip. The original's penalty
    -- stays in the table as history and stops counting, because `penalty_current` follows
    -- the chain.
    if admitted > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      select expired_row.subject, s.id, public.penalty_amount_dong()
        from public.settlement s
       where s.supersedes = expired_row.id;
    end if;

    corrected := corrected + 1;
  end loop;

  return corrected;
end;
$$;

revoke execute on function public.supersede_expiries() from public, anon, authenticated;


-- Superseding runs with settlement, on the same schedule, in the same spirit: it decides
-- and never sends.
create or replace function public.settle_due_days()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  day_to_settle date;
  settled integer := 0;
begin
  perform set_config('app.settlement_invocation', 'schedule', true);

  -- Wider than the three days settlement needs, because an expiry cannot be decided until
  -- the deadline has passed and a day is only reachable for four.
  for day_to_settle in
    select generate_series(today - 5, today - 1, interval '1 day')::date
  loop
    settled := settled + public.settle_day(day_to_settle);
  end loop;

  settled := settled + public.supersede_expiries();

  return settled;
end;
$$;

revoke execute on function public.settle_due_days() from public, anon, authenticated;
