-- Day Close. The first thing in this system that decides anything.
--
-- One plpgsql function, one transaction, invoked directly by pg_cron (AD-2). No settlement
-- logic crosses an HTTP boundary: a pass either completes or rolls back entirely, and there
-- is no hop where a job can die after writing a verdict but before finishing.
--
-- It writes a verdict and nothing else. Money is Story 2.6, chains are 2.9, and it enqueues
-- no notification at all — FR-10 keeps the author from learning mid-day that the day is
-- already lost, because once he knows, the rest of it has no stakes.

create type public.settlement_kind as enum ('day');
create type public.day_verdict as enum ('clean', 'failed');

/* Which account may never be settled by hand (AD-16).

   A column rather than a config value, because the protection is needed exactly when
   someone is running SQL against production directly — the moment an environment setting
   would not be loaded. */
alter table public.profile
  add column is_live_doer boolean not null default false;

comment on column public.profile.is_live_doer is
  'The author''s real account. Settlement refuses every manual override against it (AD-16).';

create table public.settlement (
  id uuid primary key default gen_random_uuid(),
  subject uuid not null references public.profile (id) on delete cascade,
  period date not null,
  kind public.settlement_kind not null,

  verdict public.day_verdict not null,
  missed_count integer not null default 0,
  settled_at timestamptz not null default now(),

  -- AD-5. This constraint is the whole guard: a re-run is a no-op because the insert
  -- conflicts, not because something checked first and hoped nothing changed in between.
  -- Cron runs overlap, get retried and get triggered by hand, and under a flat penalty each
  -- of those is a chance to charge twice for one day.
  constraint settlement_once unique (subject, period, kind)
);

comment on table public.settlement is
  'One row per subject, period and kind. Append-only in practice: a settled period is never re-settled (AD-5).';

create index settlement_subject_period_idx on public.settlement (subject, period);

alter table public.settlement enable row level security;

create policy "settlement: read own"
  on public.settlement for select to authenticated
  using ((select auth.uid()) = subject);

-- No insert, update or delete policy. Verdicts have exactly one writer and it is settlement
-- (AD-8). A client that could write one could decide its own day.


-- ---------------------------------------------------------------------------------
-- The rule about who owes an answer, in one place.
--
-- It already existed twice — in `lib/declaration.ts` for the client and inside
-- `enqueue_gate_reminders`. A third copy here would be three places that must agree about
-- which cadences are declared and how archiving interacts with a past day. The reminder is
-- rewritten below to call this, so SQL has one copy. The client keeps its own because it
-- decides what to *ask*, not what is *true*.
-- ---------------------------------------------------------------------------------

create function public.commitments_owing(p_owner uuid, p_day date)
returns table (commitment_id uuid, carries_penalty boolean, answer public.declaration_answer)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id,
         c.carries_penalty,
         d.answer
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


-- ---------------------------------------------------------------------------------
-- Settlement.
-- ---------------------------------------------------------------------------------

/* Closes one day for every doer whose declarations for it are complete.

   **On the AD-16 guard and what it is worth.** The scheduled job sets
   `app.settlement_invocation` before calling; a manual caller must pass `p_override`
   instead, and the override is refused for the live doer account. Someone with SQL access
   could set the session variable themselves — this is not a defence against a determined
   operator, and pretending otherwise would be worse than saying so. It is a defence
   against the actual risk: iterating on settlement against the one live project and
   writing a real verdict into a ledger that by design cannot be quietly cleaned up. */
create function public.settle_day(p_day date, p_override boolean default false)
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

    -- Nothing to judge, or not everything has been answered. An unanswered declaration
    -- leaves the day open; its expiry to a miss under FR-9 belongs to Story 2.7.
    continue when total = 0 or answered < total;

    -- A Failed Day costs exactly one Penalty regardless of how many commitments were
    -- missed, so the count is recorded for the record rather than for arithmetic.
    insert into public.settlement (subject, period, kind, verdict, missed_count)
    values (
      account.id,
      p_day,
      'day',
      case when missed > 0 then 'failed' else 'clean' end,
      missed
    )
    on conflict (subject, period, kind) do nothing;

    get diagnostics inserted = row_count;
    settled := settled + inserted;
  end loop;

  return settled;
end;
$$;

revoke execute on function public.settle_day(date, boolean) from public, anon, authenticated;


-- Rewrite the reminder to use the shared rule rather than its own copy.
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
begin
  local_now := now() at time zone 'Asia/Ho_Chi_Minh';
  local_hour := extract(hour from local_now)::integer;
  asked_day := local_now::date - 1;

  for account in
    select p.id, p.morning_hour from public.profile p where p.role = 'doer'
  loop
    continue when local_hour < account.morning_hour;

    slot := local_hour - account.morning_hour;
    continue when slot >= public.gate_reminder_slots();

    select count(*) filter (where o.answer is null)
      into outstanding
      from public.commitments_owing(account.id, asked_day) o;

    continue when outstanding = 0;

    perform public.outbox_enqueue(
      account.id,
      'gate-' || account.id::text || '-' || asked_day::text || '-' || slot::text,
      jsonb_build_object(
        'title', 'Yesterday',
        'body', outstanding::text
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
