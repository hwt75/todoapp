-- Epic 4 retrospective (2026-08-27), finding A1, action item 27 -- a systemic characteristic
-- since Epic 2's settle_day(), not an Epic-4-specific defect, but real: `carries_penalty` is a
-- plain mutable column with no history, and several server functions read its *live* value at
-- various times well after the day they are judging -- commitments_owing() (used by
-- settle_day()/settle_week()) at declaration_deadline, up to ~71 hours later;
-- file_auto_check_result() at the next hourly resolve_auto_checks() pass, up to ~24 hours
-- later. Neither reflects what the flag actually was during the day itself. An author who
-- anticipates or notices a genuine miss can toggle the flag off before either read fires, then
-- back on, and the day's own money-relevant fact silently follows whatever the flag reads at
-- read time instead of what it was when the day happened.
--
-- The fix: a day's own fact, once the day has closed, must never be rewritable by anything
-- that happens afterward -- the identical principle `declaration.filed_by` and
-- `penalty.amount_dong` already apply elsewhere in this schema (freeze a fact at the moment it
-- is established, never re-derive it later). `commitment_carries_penalty_change` is an
-- append-only log of every value `carries_penalty` has ever held, from the row's own creation
-- onward; `carries_penalty_as_of(commitment_id, day)` reads the value in effect at the instant
-- day D closed (midnight D+1, Asia/Ho_Chi_Minh) -- once that instant has passed, no later
-- change can move it. Human decision (2026-08-27): implement now rather than defer, since the
-- fix is additive and no live doer account exists yet to have any history to reconcile.
--
-- appeal_hold_penalty() is deliberately left untouched (human decision, same session): once
-- commitments_owing() reads the frozen value, a Penalty's own existence already encodes "this
-- day was genuinely penalty-carrying as of settlement" -- appeal_hold_penalty()'s own
-- carries_penalty re-check becomes a defense-in-depth guard rather than the load-bearing one,
-- and leaving it as a live read keeps this migration's diff smaller without weakening anything
-- a Penalty already had to exist to reach.

create table public.commitment_carries_penalty_change (
  id uuid primary key default gen_random_uuid(),
  commitment_id uuid not null references public.commitment (id) on delete cascade,
  carries_penalty boolean not null,
  changed_at timestamptz not null default now()
);

comment on table public.commitment_carries_penalty_change is
  'Append-only history of every value commitment.carries_penalty has ever held, logged by
  commitment_log_carries_penalty_change() below. Never read directly by application code --
  carries_penalty_as_of() is the one door.';

create index commitment_carries_penalty_change_lookup_idx
  on public.commitment_carries_penalty_change (commitment_id, changed_at desc);

alter table public.commitment_carries_penalty_change enable row level security;

-- An explicit deny rather than an absent policy -- mirrors outbox's own "no client may
-- touch this" (20260819180000): RLS with no policy already denies, but silence reads as an
-- oversight and this reads as a decision. The grants below are what actually keeps the
-- table out of the API; this is the second lock. AD-7.
create policy "commitment_carries_penalty_change: no client may touch this"
  on public.commitment_carries_penalty_change for all to authenticated, anon
  using (false)
  with check (false);

revoke all on table public.commitment_carries_penalty_change from public, anon, authenticated;

create function public.commitment_log_carries_penalty_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.commitment_carries_penalty_change (commitment_id, carries_penalty)
  values (new.id, new.carries_penalty);

  return new;
end;
$$;

comment on function public.commitment_log_carries_penalty_change() is
  'Logs every value carries_penalty has ever held -- the initial one at row creation, and
  every change after. Fires only when the value actually changes (the trigger''s own WHEN
  clause on the update path), never once per unrelated update.';

revoke execute on function public.commitment_log_carries_penalty_change()
  from public, anon, authenticated;

create trigger commitment_log_carries_penalty_change_on_insert
  after insert on public.commitment
  for each row
  execute function public.commitment_log_carries_penalty_change();

create trigger commitment_log_carries_penalty_change_on_update
  after update of carries_penalty on public.commitment
  for each row
  when (old.carries_penalty is distinct from new.carries_penalty)
  execute function public.commitment_log_carries_penalty_change();

-- Backfill: one row per existing commitment, stamped at its own created_at with its current
-- carries_penalty -- the best available approximation for a commitment whose true history
-- before this migration was never recorded. No live doer account exists yet, so nothing here
-- reconciles against a real, disputed day.
insert into public.commitment_carries_penalty_change (commitment_id, carries_penalty, changed_at)
select id, carries_penalty, created_at
  from public.commitment;

create function public.carries_penalty_as_of(p_commitment_id uuid, p_day date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select carries_penalty
       from public.commitment_carries_penalty_change
      where commitment_id = p_commitment_id
        and changed_at <= ((p_day + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh')
      order by changed_at desc
      limit 1),
    -- p_day predates the row's own earliest tracked history (its own created_at, backfilled
    -- or logged) -- extrapolate the earliest known value backward rather than reading NULL/
    -- false. This is not a live read: it is still one fixed, historical fact (the first
    -- value this commitment ever held), the same for every caller regardless of when they
    -- ask, and cannot be moved by anything a later toggle does.
    (select carries_penalty
       from public.commitment_carries_penalty_change
      where commitment_id = p_commitment_id
      order by changed_at asc
      limit 1)
  );
$$;

comment on function public.carries_penalty_as_of(uuid, date) is
  'FR-2a/A1 fix: whether p_commitment_id carried a Penalty as of the instant p_day closed
  (midnight p_day+1, Asia/Ho_Chi_Minh) -- the value in effect through the day, frozen the
  moment the day itself ended. A change made after that instant can never move it, however
  much later commitments_owing()/file_auto_check_result()/settle_week() actually read it. For
  a day before this commitment''s own earliest tracked history, falls back to that earliest
  known value (extrapolated backward, itself a fixed historical fact, not a live read) rather
  than NULL/false -- covers a commitment judged for a day at or before its own creation, the
  same already-documented edge case auto_check_pending()''s own created_at guard exists for.
  NULL only if p_commitment_id has no history at all, which the backfill above and the
  insert-trigger together make unreachable for any commitment this schema ever created.';

revoke execute on function public.carries_penalty_as_of(uuid, date) from public, anon, authenticated;

-- commitments_owing(): the one read every settlement path shares (settle_day, settle_week's
-- own AD-13 guard), now frozen by day rather than live. Return signature unchanged from
-- 20260820140000_weekly_quota_is_not_judged_daily.sql (commitment_id, carries_penalty,
-- answer, cadence) -- create or replace is safe here since the OUT-parameter row type is
-- identical, only the carries_penalty expression itself changes.
create or replace function public.commitments_owing(p_owner uuid, p_day date)
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
         public.carries_penalty_as_of(c.id, p_day),
         d.answer,
         c.cadence
    from public.commitment c
    left join public.declaration d
           on d.commitment_id = c.id and d.for_day = p_day
   where c.owner_id = p_owner
     and c.cadence <> 'daily_hours_quota'
     and (c.archived_at is null
          or (c.archived_at at time zone 'Asia/Ho_Chi_Minh')::date > p_day);
$$;

comment on function public.commitments_owing(uuid, date) is
  'Every commitment p_owner owes an answer for on p_day, and whether it was penalty-carrying
  AS OF THAT DAY (carries_penalty_as_of(), Epic 4 retrospective A1 fix, 2026-08-27) --
  excludes daily_hours_quota (FR-2, judged by measured minutes) and a commitment archived on
  or before p_day. cadence carried since 20260820140000, read by settle_day/settle_week to
  exclude weekly_quota from the two counts that turn a miss into money.';

revoke execute on function public.commitments_owing(uuid, date) from public, anon, authenticated;

-- file_auto_check_result(): the 'missed' branch's own live carries_penalty read, frozen the
-- identical way.
create or replace function public.file_auto_check_result(
  p_commitment_id uuid,
  p_owner_id uuid,
  p_result public.auto_check_result
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_carries_penalty boolean;
  v_target_day date;
begin
  if p_result = 'held' then
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (p_owner_id, p_commitment_id, gen_random_uuid(), 'held', now())
    on conflict (commitment_id, for_day) do nothing;
    return;
  end if;

  if p_result = 'missed' then
    -- resolve_auto_checks() only ever resolves "yesterday" for the account it is running
    -- for -- the same day this filing itself will land on once declaration_derive_day()'s
    -- own -1 offset applies to `now()` below.
    v_target_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
    v_carries_penalty := public.carries_penalty_as_of(p_commitment_id, v_target_day);

    if coalesce(v_carries_penalty, false) then
      insert into public.declaration
        (owner_id, commitment_id, idempotency_key, answer, answered_at, filed_by)
      values
        (p_owner_id, p_commitment_id, gen_random_uuid(), 'slipped', now(), 'auto_check')
      on conflict (commitment_id, for_day) do nothing;
    end if;
    return;
  end if;

  -- `unavailable`, or an unmatched/null result — file nothing, same as always.
end;
$$;

comment on function public.file_auto_check_result(uuid, uuid, public.auto_check_result) is
  'Files declaration(answer=held) on held, and declaration(answer=slipped, filed_by=''auto_check'') '
  'on missed when the commitment was penalty-carrying AS OF THE DAY BEING FILED FOR
  (carries_penalty_as_of(), Epic 4 retrospective A1 fix, 2026-08-27 -- previously read
  carries_penalty live, at filing time, letting a toggle made between the day closing and this
  filing change the outcome) -- both only when that day is still undeclared. missed with no
  Penalty, unavailable, and a null/unmatched result all file nothing. Never calls
  outbox_enqueue (UX-DR29).';

revoke execute on function public.file_auto_check_result(uuid, uuid, public.auto_check_result)
  from public, anon, authenticated;

-- settle_week()'s own Weekly Quota shortfall check carries the identical live-read bug,
-- independently of commitments_owing() -- `quota.carries_penalty` was read straight off
-- `commitment` at settlement time (up to 8 days after the week's own last day, per this
-- function's own `continue when today < p_period + 8` gate), the same live-vs-frozen gap
-- commitments_owing() had for Daily/Weekly-Quota-via-daily commitments. Frozen the same way,
-- anchored to the week's own last day (p_period + 6) -- the instant the week itself closed.
create or replace function public.settle_week(p_period date, p_override boolean default false)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  invocation text := coalesce(current_setting('app.settlement_invocation', true), '');
  today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  account record;
  quota record;
  total_commitments integer;
  held_sum integer;
  target_sum integer;
  shortfall_count integer;
  shortfall_name text;
  admitted integer;
  verdict public.day_verdict;
  inserted integer;
  new_settlement uuid;
  settled integer := 0;
begin
  if current_user in ('anon', 'authenticated') then
    raise exception 'settle_week is never callable from the application (AD-2)';
  end if;

  if invocation <> 'schedule' and not p_override then
    raise exception
      'settle_week ran outside its schedule with no override. Pass p_override => true, '
      'which is refused for the live doer account (AD-16).';
  end if;

  for account in select p.id, p.is_live_doer from public.profile p where p.role = 'doer' loop
    if p_override and account.is_live_doer then
      raise exception
        'settle_week refuses an override against the live doer account (AD-16). '
        'Only the schedule may settle it.';
    end if;

    continue when today < p_period + 8;

    continue when exists (
      select 1
        from public.commitment c
        cross join generate_series(p_period, p_period + 6, interval '1 day') as day_series(d)
       where c.owner_id = account.id
         and c.cadence = 'weekly_quota'
         and c.archived_at is null
         and c.week_start_day = extract(isodow from p_period)::integer
         and (c.created_at at time zone 'Asia/Ho_Chi_Minh')::date < p_period + 7
         and public.auto_check_pending(c.id, day_series.d::date)
    );

    total_commitments := 0;
    held_sum := 0;
    target_sum := 0;
    shortfall_count := 0;
    shortfall_name := null;
    admitted := 0;

    -- carries_penalty read via carries_penalty_as_of(c.id, p_period + 6) -- Epic 4
    -- retrospective A1 fix, 2026-08-27 -- the value in effect as of the week's own last day,
    -- not whatever the flag reads today, up to 8 days later.
    for quota in
      select c.id, c.name, public.carries_penalty_as_of(c.id, p_period + 6) as carries_penalty,
             c.weekly_target,
             public.weekly_held_count(c.id, p_period) as held
        from public.commitment c
       where c.owner_id = account.id
         and c.cadence = 'weekly_quota'
         and c.archived_at is null
         and c.week_start_day = extract(isodow from p_period)::integer
         and (c.created_at at time zone 'Asia/Ho_Chi_Minh')::date < p_period + 7
    loop
      total_commitments := total_commitments + 1;
      held_sum := held_sum + quota.held;
      target_sum := target_sum + quota.weekly_target;

      if quota.held < quota.weekly_target then
        shortfall_count := shortfall_count + 1;
        shortfall_name := quota.name;

        if quota.carries_penalty then
          admitted := admitted + 1;
        end if;
      end if;
    end loop;

    continue when total_commitments = 0;

    verdict := case when admitted > 0 then 'failed' else 'clean' end;

    insert into public.settlement (subject, period, kind, verdict, missed_count)
    values (account.id, p_period, 'week', verdict, admitted)
    on conflict (subject, period, kind) where supersedes is null do nothing
    returning id into new_settlement;

    get diagnostics inserted = row_count;
    settled := settled + inserted;

    continue when new_settlement is null;

    if admitted > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (account.id, new_settlement, public.penalty_amount_dong());
    end if;

    perform public.outbox_enqueue(
      account.id,
      'week-' || account.id::text || '-' || p_period::text,
      jsonb_build_object(
        'title', 'This week',
        'body', public.week_summary_body(
                  held_sum, target_sum, p_period,
                  case when admitted > 0 then public.penalty_amount_dong() end,
                  shortfall_count,
                  case when shortfall_count = 1 then shortfall_name end),
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );
  end loop;

  return settled;
end;
$$;

comment on function public.settle_week(date, boolean) is
  'Judges every Weekly Quota commitment whose week ends at p_period + 6. carries_penalty is
  read via carries_penalty_as_of(c.id, p_period + 6) (Epic 4 retrospective A1 fix,
  2026-08-27) -- the value in effect as of the week''s own last day, never whatever the flag
  reads at settlement time, up to 8 days later.';

revoke execute on function public.settle_week(date, boolean) from public, anon, authenticated;
