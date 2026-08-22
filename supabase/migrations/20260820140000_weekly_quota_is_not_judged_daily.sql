-- A live defect, found while building Story 3.3, fixed before Story 3.4.
--
-- `commitments_owing()` excludes `daily_hours_quota` (FR-2 judges it against measured
-- minutes, never a statement) but never excluded `weekly_quota` — so a Weekly Quota
-- commitment with `carries_penalty = true` was judged, and could be penalized, on any
-- single day it was not declared `held`, directly contradicting FR-2: "A Weekly Quota
-- Commitment is judged only at Week Close; being at 0 of 3 mid-week is never a miss."
-- Traced and recorded against spec-3-3-a-weekly-quota-that-counts-down in
-- deferred-work.md, in both `settle_day()` and `supersede_expiries()`.
--
-- This is not the same shape as `daily_hours_quota`'s own exclusion. The declaration
-- itself still has to be recorded, still has to hold the day open until answered, and
-- still has to freeze into `settlement_commitment` — Story 2.9's day-chain and Story
-- 3.3's own `weekly_quota_progress` view both read exactly those rows, and dropping a
-- Weekly Quota commitment out of `commitments_owing()` entirely would silently break
-- both. So the commitment stays in the set; `cadence` is added to the row instead, and
-- only the two counts that turn a miss into money (`admitted`, `silent`) exclude it.
-- Week Close (Story 3.4) is where FR-2's real weekly verdict belongs — this only stops
-- the wrong one from landing daily in the meantime.

drop function public.commitments_owing(uuid, date);

create function public.commitments_owing(p_owner uuid, p_day date)
returns table (
  commitment_id uuid,
  carries_penalty boolean,
  answer public.declaration_answer,
  cadence public.commitment_cadence
)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id,
         c.carries_penalty,
         d.answer,
         c.cadence
    from public.commitment c
    left join public.declaration d
           on d.commitment_id = c.id and d.for_day = p_day
   where c.owner_id = p_owner
     -- FR-2 judges an hours quota against measured minutes, not a statement. Asking for a
     -- declaration would invite a softer second answer to a question the timer answers.
     and c.cadence <> 'daily_hours_quota'
     -- A commitment archived after the day is still judged for it: the day predates the
     -- archive, and a hole in the ledger is worse than one extra judgement.
     and (c.archived_at is null
          or (c.archived_at at time zone 'Asia/Ho_Chi_Minh')::date > p_day);
$$;

revoke execute on function public.commitments_owing(uuid, date) from public, anon, authenticated;


-- settle_day: unchanged except `admitted` and `silent`, which now exclude a Weekly
-- Quota commitment's own slip or silence. It still counts toward `total`/`answered` (an
-- unanswered one still holds the day open) and its outcome is still frozen into
-- `settlement_commitment` exactly as before — only the money and the `failed` verdict
-- stop being triggered by it alone.
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

    past_deadline := now() >= public.declaration_deadline(p_day, account.morning_hour);
    continue when answered < total and not past_deadline;

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


-- supersede_expiries(): the same exclusion, so a corrected day agrees with settle_day
-- about what counts toward a penalty rather than drifting the moment an expiry is
-- involved.
create or replace function public.supersede_expiries()
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
  correction uuid;
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
