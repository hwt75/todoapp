-- Money. The first and last thing this product does with it is write down that one person
-- owes another, and later that it was paid.
--
-- NFR5, in schema form: there is no payment integration, no stored instrument, no balance
-- this system can move, and no code path that transfers value. A penalty is discharged
-- only by the Referee marking it collected, and nothing here may ever settle a debt on its
-- own.

/* The amount, named once.

   500,000 VND per Failed Day, as an integer number of đồng. Never a float: a rounding
   error in a number that only grows is a number that eventually disagrees with itself, and
   this one is a claim against a real person. */
create function public.penalty_amount_dong()
returns bigint
language sql
immutable
set search_path = ''
as $$ select 500000::bigint $$;

/* Only `owed` exists.

   `expired` arrives with Story 2.7, `dropped` with 4.4, `collected` with 4.7 and `waived`
   with 5.1 — each added by the story that makes it reachable, so no screen ever renders a
   state nothing can produce. */
create type public.penalty_state as enum ('owed');

create table public.penalty (
  id uuid primary key default gen_random_uuid(),
  subject uuid not null references public.profile (id) on delete cascade,

  -- The decision that caused it, not the date. A settlement carries the subject, the period
  -- and the missed count, so "why do I owe this" is a chain of foreign keys rather than a
  -- join on two loose values that can disagree.
  settlement_id uuid not null references public.settlement (id) on delete cascade,

  amount_dong bigint not null,
  state public.penalty_state not null default 'owed',
  created_at timestamptz not null default now(),

  -- FR-13: a Failed Day generates one Penalty regardless of how many commitments were
  -- missed. Two rows for one 500,000 would either double the visible debt or show two
  -- half-penalties that do not exist.
  constraint penalty_one_per_settlement unique (settlement_id),

  constraint penalty_amount_positive check (amount_dong > 0)
);

comment on table public.penalty is
  'One row per Failed Day. Append-only (AD-9): a grace day, won appeal or expiry adds a new row referencing this one, never an update.';

create index penalty_subject_idx on public.penalty (subject);

alter table public.penalty enable row level security;

create policy "penalty: read own"
  on public.penalty for select to authenticated
  using ((select auth.uid()) = subject);

-- No insert, update or delete policy. Derived state has exactly one writer and it is
-- settlement (AD-8), and a client that could write a penalty could forgive its own.


/* Settlement, now writing the penalty in the same transaction as the verdict.

   Same transaction on purpose (AD-3's reasoning applied inward): a pass that rolls back
   takes both, so there is never a failed day with no penalty nor a penalty for a day that
   did not survive. */
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
    on conflict (subject, period, kind) do nothing
    returning id into new_settlement;

    get diagnostics inserted = row_count;
    settled := settled + inserted;

    -- `new_settlement` is null when the period was already settled, which is the AD-5
    -- no-op: no second verdict, and therefore no second penalty either.
    if new_settlement is not null and missed > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (account.id, new_settlement, public.penalty_amount_dong());
    end if;
  end loop;

  return settled;
end;
$$;
