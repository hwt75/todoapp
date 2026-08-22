-- The evening summary, enqueued by settlement in the same transaction as the verdict
-- (AD-3). Settlement never calls out; the worker on its own schedule delivers it.
--
-- **The copy rules live in two places and that is a real cost.** `lib/summary.ts` holds
-- them as tested functions; this builds the sentence, because settlement runs here. They
-- are kept in step by hand and by `lib/summary.test.ts` asserting the shape this produces.
-- The seam is weak and is recorded in deferred-work.md — the honest fix is for a surface to
-- need the summary, at which point one side becomes the source and the other reads it.
--
-- Three rules from EXPERIENCE.md are structural rather than stylistic, so they are visible
-- in the SQL rather than left to whoever edits the string:
--   1. Never itemise the misses. There is deliberately no aggregation of missed names here.
--   2. The amount once, after the fact.
--   3. Exactly one suggestion, naming a specific commitment.

create function public.day_summary_body(
  p_held integer,
  p_total integer,
  p_day date,
  p_amount bigint,
  p_survivor text,
  p_suggestion text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select concat_ws(' ',
    -- Counts as words, the way they are said aloud.
    initcap((array['none','one','two','three','four','five','six','seven','eight','nine','ten'])[
      least(p_held, 10) + 1]),
    'of',
    (array['none','one','two','three','four','five','six','seven','eight','nine','ten'])[
      least(p_total, 10) + 1],
    'on ' || to_char(p_day, 'FMDay') || '.',

    -- The amount, once. Null on a clean day, and concat_ws drops it.
    case when p_amount is not null
         then 'That''s ' || to_char(p_amount, 'FM999G999G999') || '₫.'
    end,

    -- Something that held, named. Never a list of what did not.
    case when p_survivor is not null then p_survivor || ' held though.' end,

    case when p_survivor is not null and p_survivor = p_suggestion
         then 'Start there tomorrow.'
         else 'Start with ' || p_suggestion || ' tomorrow.'
    end
  );
$$;

revoke execute on function public.day_summary_body(integer, integer, date, bigint, text, text)
  from public, anon, authenticated;


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

    -- No summary for a day that expired. The data is there and it is tempting, but a
    -- message saying "one of five today, start with X tomorrow" about a day he never
    -- answered is the product pretending it knows how his day went. It knows he did not say.
    continue when verdict = 'expired';

    -- One commitment that held, and one to start with tomorrow. Deliberately single values
    -- rather than lists: two suggestions is a to-do list, and a list of misses is the thing
    -- this message exists to replace.
    select c.name into survivor
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

    perform public.outbox_enqueue(
      account.id,
      'summary-' || account.id::text || '-' || p_day::text,
      jsonb_build_object(
        'title', 'Today',
        'body', public.day_summary_body(
                  held, total, p_day,
                  case when (admitted + silent) > 0 then public.penalty_amount_dong() end,
                  survivor, suggestion),
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );
  end loop;

  return settled;
end;
$$;

revoke execute on function public.settle_day(date, boolean) from public, anon, authenticated;
