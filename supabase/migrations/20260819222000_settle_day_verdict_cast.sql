-- Fixes a type error in `settle_day`: a CASE expression resolves to `text`, and Postgres
-- will not implicitly cast that to an enum in an INSERT.
--
-- A plain literal in the same position works, which is why `kind` was fine and `verdict`
-- was not — and why it looked correct while being wrong. The migration applied cleanly and
-- only failed when a pass actually had a day to settle.

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
  missed integer;
  inserted integer;
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

  for account in select p.id, p.is_live_doer from public.profile p where p.role = 'doer' loop
    if p_override and account.is_live_doer then
      raise exception
        'settle_day refuses an override against the live doer account (AD-16). '
        'Only the schedule may settle it.';
    end if;

    select count(*),
           count(o.answer),
           count(*) filter (where o.answer = 'slipped' and o.carries_penalty)
      into total, answered, missed
      from public.commitments_owing(account.id, p_day) o;

    continue when total = 0 or answered < total;

    insert into public.settlement (subject, period, kind, verdict, missed_count)
    values (
      account.id,
      p_day,
      'day',
      (case when missed > 0 then 'failed' else 'clean' end)::public.day_verdict,
      missed
    )
    on conflict (subject, period, kind) do nothing;

    get diagnostics inserted = row_count;
    settled := settled + inserted;
  end loop;

  return settled;
end;
$$;
