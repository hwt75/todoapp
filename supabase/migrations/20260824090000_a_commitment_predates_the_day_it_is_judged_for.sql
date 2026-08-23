-- Code review (2026-08-24) on spec-4-1: `resolve_auto_checks()` had no guard against
-- judging a commitment for a day before it existed. Linking Account elsewhere on a
-- commitment created today would still have this pass resolve it against yesterday and
-- bump `auto_check_last_checked_at` for a day that predates the commitment entirely.
--
-- Fixed by mirroring `settle_due_weeks`'s own guard
-- (20260820150000_the_week_closes_and_settles.sql:258,
-- `(c.created_at at time zone 'Asia/Ho_Chi_Minh')::date < p_period + 7`): a commitment
-- cannot be judged for a day it didn't exist on.

create or replace function public.resolve_auto_checks()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_day date := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  linked record;
  result public.auto_check_result;
  processed integer := 0;
begin
  for linked in
    select c.id, c.owner_id, c.auto_check_kind
      from public.commitment c
     where c.auto_check_kind is not null
       and c.archived_at is null
       -- Mirrors `settle_due_weeks`'s own guard: a commitment cannot be judged for a day
       -- before it existed.
       and (c.created_at at time zone 'Asia/Ho_Chi_Minh')::date <= target_day
       and not exists (
         select 1 from public.declaration d
          where d.commitment_id = c.id and d.for_day = target_day
       )
  loop
    result := case linked.auto_check_kind
      when 'account_elsewhere' then public.resolve_account_elsewhere(linked.id)
    end;

    perform public.file_auto_check_result(linked.id, linked.owner_id, result);

    update public.commitment
       set auto_check_last_checked_at = now()
     where id = linked.id
       and auto_check_kind is not null;

    processed := processed + 1;
  end loop;

  return processed;
end;
$$;

revoke execute on function public.resolve_auto_checks() from public, anon, authenticated;
