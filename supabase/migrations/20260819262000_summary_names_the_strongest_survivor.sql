-- The day summary names the survivor that has held longest, not the oldest one.
--
-- Story 2.8 picked the surviving commitment by `created_at`, because that was the only order
-- available — nothing counted chains, so one survivor was as good as another. Chains exist
-- now, and seeing the real data made the weakness obvious: on a day where a three-day chain
-- and a seven-day chain both survived, the message was naming whichever happened to be
-- created first.
--
-- The clause exists to put the strongest available evidence in front of him on the evening of
-- a bad day. "No fap held though — day 7" does that. "Gym held though — day 1", when a
-- seven-day chain was sitting right there, does not.
--
-- Ties still fall back to `created_at`, so the choice stays deterministic and a re-run
-- produces the same sentence.

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
           count(*) filter (where o.carries_penalty and o.answer = 'slipped'),
           count(*) filter (where o.carries_penalty and o.answer is null),
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

    -- What each commitment did, frozen. This happens for an expired day too, and that is the
    -- point of `unanswered` being its own outcome: the chain has to break on silence, and the
    -- history has to say *why* it broke rather than filing it as a miss.
    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    select new_settlement, account.id, o.commitment_id,
           case o.answer
             when 'held' then 'held'
             when 'slipped' then 'missed'
             else 'unanswered'
           end::public.commitment_outcome
      from public.commitments_owing(account.id, p_day) o;

    -- No summary for a day that expired. The data is there and it is tempting, but a message
    -- saying "one of five today, start with X tomorrow" about a day he never answered is the
    -- product pretending it knows how his day went. It knows he did not say.
    continue when verdict = 'expired';

    -- The survivor with the longest chain, read after the outcomes above are written so the
    -- number includes the day being summarised: `day 12` means it has now held twelve days,
    -- not eleven and counting.
    select c.name, ch.current_days into survivor, survivor_chain
      from public.commitments_owing(account.id, p_day) o
      join public.commitment c on c.id = o.commitment_id
      left join public.chain_current ch on ch.commitment_id = c.id
     where o.answer = 'held'
     order by coalesce(ch.current_days, 0) desc, c.created_at
     limit 1;

    -- One thing to start with tomorrow, preferring something that was missed. Deliberately a
    -- single value: two suggestions is a to-do list, and a list of misses is the thing this
    -- message exists to replace.
    select c.name into suggestion
      from public.commitments_owing(account.id, p_day) o
      join public.commitment c on c.id = o.commitment_id
     order by (o.answer = 'slipped') desc, c.created_at
     limit 1;

    continue when suggestion is null;

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
