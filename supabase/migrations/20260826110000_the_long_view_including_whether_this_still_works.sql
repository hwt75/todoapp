-- Story 5.4 — The long view, including whether this still works (FR-24).
--
-- A month can look fine on the Today screen (no debt showing, no red) while the mechanism
-- underneath has quietly died: the Referee has stopped ruling or collecting, or Silence has
-- become routine. This closes the two schema gaps that block the report's own "divergence is
-- the only evidence" requirement -- `penalty` never stamped when a Penalty was collected, and
-- `appeal` never stamped when the Referee ruled -- and adds the one new aggregation this story
-- structurally needs: SM-6/SM-3's own "was this commitment owed an answer on this day" reads,
-- which only `commitments_owing()` (revoked from `authenticated`) can answer.
--
-- Every other PRD §8 measure (chains, penalties, silence episodes, appeal outcomes, referee
-- activity) is a plain client read of an existing or lightly extended table/view -- no other
-- new SQL exists for this story.

-- ---------------------------------------------------------------------------------
-- `penalty.collected_at`. Nullable: null until `mark_penalty_collected()` stamps it, the
-- instant the referee's own `owed -> collected` transition actually happens -- never
-- backfilled, never inferred from `settled_at` or any other column.
-- ---------------------------------------------------------------------------------

alter table public.penalty add column collected_at timestamptz;

comment on column public.penalty.collected_at is
  'Story 5.4: stamped by mark_penalty_collected() alongside state -> collected. Null while '
  'owed/held/dropped/voided/waived -- SM-C1''s own "Penalties Collected" figure reads this '
  'column directly rather than inferring collection from state alone, so a future state that '
  'also happens to be named something collection-adjacent can never be silently counted.';

-- `penalty_current` (20260820150000) is `select p.*, s.kind, s.period ...` -- `p.*` is
-- expanded and frozen at `create or replace view` time, so the `collected_at` column just
-- added above does not reach the view on its own. `create or replace view` also refuses to
-- change the name of an existing output *column position* -- and `alter table ... add
-- column` always appends the new column at the end of the base table, so a naive `p.*, s.kind,
-- s.period` here would try to rename position 7 from `kind` to `collected_at` (Postgres error
-- 42P16: "cannot change name of view column"). Every pre-existing column is therefore spelled
-- out explicitly, in its original order, with `collected_at` appended strictly last --
-- genuinely only ever adding a column, never renaming one -- so
-- `components/monthly-report.tsx`'s own "collected" read (`penalty_current.collected_at`) --
-- and SM-C1/SM-5, which both depend on it -- do not fail with "column does not exist" against
-- a real PostgREST instance.
create or replace view public.penalty_current
with (security_invoker = true)
as
select p.id, p.subject, p.settlement_id, p.amount_dong, p.state, p.created_at,
       s.kind, s.period,
       p.collected_at
  from public.penalty p
  join public.settlement_current s on s.id = p.settlement_id;

comment on view public.penalty_current is
  'Penalties that still stand (AD-9). Carries kind and period from its settlement so a '
  'reader can tell a day''s penalty from a week''s without a second query. Story 5.4: '
  'collected_at appended last (Postgres refuses to rename an existing view column position, '
  'and alter table always appends a new column at the end of the base table).';

create or replace function public.mark_penalty_collected(p_penalty_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exists boolean;
  v_owner uuid;
  v_for_day date;
begin
  if public.role_from_table() is distinct from 'referee' then
    raise exception 'Only the referee may mark a Penalty collected.';
  end if;

  select s.subject, s.period into v_owner, v_for_day
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where p.id = p_penalty_id;

  v_exists := found;

  if not v_exists then
    raise exception 'No such penalty.';
  end if;

  -- Story 5.1 (2026-08-25 independent review): the same "a grace_day row for this day
  -- means it is already spoken for" guard appeal_hold_penalty() already enforces.
  if exists (
    select 1 from public.grace_day g
     where g.owner_id = v_owner and g.for_day = v_for_day
  ) then
    raise exception
      'A Grace Day has already been spent on this day. It cannot also be collected.';
  end if;

  -- Story 5.4: collected_at stamped in the same guarded update as the state transition --
  -- one write, so a penalty can never read state = 'collected' with collected_at still null.
  update public.penalty
     set state = 'collected', collected_at = now()
   where id = p_penalty_id and state = 'owed';

  if not found then
    raise exception
      'This penalty has already been resolved -- collected already, or no longer owed.';
  end if;
end;
$$;

comment on function public.mark_penalty_collected(uuid) is
  'FR-21. The only way a debt is ever discharged: role_from_table() = ''referee'' checked '
  'first, before any row is read, then a distinct "No such penalty." for a bogus id, then a '
  'refusal if a Grace Day already claims this day (2026-08-25 independent review of Story '
  '5.1), then the single guarded transition owed -> collected, now also stamping '
  'collected_at in the same update (Story 5.4, SM-C1''s own "Penalties Collected" figure) -- '
  'a double-click, or a call against a Penalty that is already collected, still held, or '
  'otherwise not owed, finds zero rows and is refused, never silently ignored.';

revoke execute on function public.mark_penalty_collected(uuid) from public, anon;
grant execute on function public.mark_penalty_collected(uuid) to authenticated;


-- ---------------------------------------------------------------------------------
-- `appeal.ruled_at`. Nullable: null while an appeal is still `held` (unruled). Stamped by
-- `rule_appeal()` on *both* branches -- reject and approve -- so SM-5 (referee still active)
-- never has to infer a rejection's own timing from an absent column the way
-- `referee-appeal-detail.tsx` already has to infer `penaltyState` from settlement movement.
-- A timed-out appeal (`void_expired_appeals()`, held -> dropped) leaves this null on purpose:
-- nobody ruled it, the clock did, and SM-5 is specifically about the Referee's own
-- participation.
-- ---------------------------------------------------------------------------------

alter table public.appeal add column ruled_at timestamptz;

comment on column public.appeal.ruled_at is
  'Story 5.4: stamped by rule_appeal() on both the reject and the approve branch. Null while '
  'held (unruled) or dropped (timed out -- nobody ruled it). SM-5''s own "referee still '
  'active" boolean reads this column (any appeal.ruled_at in-month) alongside '
  'penalty.collected_at, since a timeout carries no Referee action to count.';

create or replace function public.rule_appeal(p_appeal_id uuid, p_approved boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appeal record;
  v_amount bigint;
  v_admitted integer;
  v_silent integer;
  v_verdict public.day_verdict;
  v_correction uuid;
begin
  if public.role_from_table() is distinct from 'referee' then
    raise exception 'Only the referee may rule on an appeal.';
  end if;

  if p_approved is null then
    raise exception 'p_approved must not be null.';
  end if;

  select * into v_appeal from public.appeal where id = p_appeal_id;

  if not found then
    raise exception 'No such appeal.';
  end if;

  if not p_approved then
    -- "He didn't": the guarded transition alone, identical shape to
    -- void_expired_appeals()'s own held -> dropped. No settlement change (I/O Matrix: "Reject").
    update public.penalty
       set state = 'owed'
     where id = v_appeal.penalty_id and state = 'held'
    returning amount_dong into v_amount;

    if not found then
      raise exception
        'This appeal has already been resolved -- by an earlier ruling or by timing out.';
    end if;

    -- Story 5.4: the ruling's own timestamp, stamped once this branch has actually won its
    -- own guarded transition above -- a race loser never reaches this statement.
    update public.appeal set ruled_at = now() where id = p_appeal_id;

    perform public.outbox_enqueue(
      v_appeal.owner_id,
      'ruling-' || p_appeal_id::text,
      jsonb_build_object(
        'title', 'The referee ruled',
        'body', public.appeal_ruling_body(false, v_appeal.for_day, v_amount),
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );

    return;
  end if;

  -- "He did it": the same guarded transition, voiding rather than reverting -- the race
  -- guard is this update alone; everything below only ever runs for the single call that
  -- actually won it.
  update public.penalty
     set state = 'voided'
   where id = v_appeal.penalty_id and state = 'held'
  returning amount_dong into v_amount;

  if not found then
    raise exception
      'This appeal has already been resolved -- by an earlier ruling or by timing out.';
  end if;

  -- Story 5.4: stamped on this branch too, same place in the sequence (right after the
  -- winning guarded transition) as the reject branch above, so the two branches read as the
  -- same rule rather than one remembering the stamp and the other not.
  update public.appeal set ruled_at = now() where id = p_appeal_id;

  select count(*) filter (
           where o.carries_penalty and o.answer = 'slipped' and o.cadence <> 'weekly_quota'
             and o.commitment_id <> v_appeal.commitment_id
         ),
         count(*) filter (
           where o.carries_penalty and o.answer is null and o.cadence <> 'weekly_quota'
             and o.commitment_id <> v_appeal.commitment_id
         )
    into v_admitted, v_silent
    from public.commitments_owing(v_appeal.owner_id, v_appeal.for_day) o;

  v_verdict := case when v_admitted + v_silent > 0 then 'failed' else 'clean' end;

  insert into public.settlement (subject, period, kind, verdict, missed_count, supersedes)
  values (
    v_appeal.owner_id, v_appeal.for_day, 'day', v_verdict, v_admitted + v_silent,
    v_appeal.settlement_id
  )
  returning id into v_correction;

  insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
  select v_correction, v_appeal.owner_id, o.commitment_id,
         case
           when o.commitment_id = v_appeal.commitment_id then 'held'
           when o.answer = 'held' then 'held'
           when o.answer = 'slipped' then 'missed'
           else 'unanswered'
         end::public.commitment_outcome
    from public.commitments_owing(v_appeal.owner_id, v_appeal.for_day) o;

  if (v_admitted + v_silent) > 0 then
    insert into public.penalty (subject, settlement_id, amount_dong)
    values (v_appeal.owner_id, v_correction, public.penalty_amount_dong());
  end if;

  perform public.outbox_enqueue(
    v_appeal.owner_id,
    'ruling-' || p_appeal_id::text,
    jsonb_build_object(
      'title', 'The referee ruled',
      'body', public.appeal_ruling_body(true, v_appeal.for_day, v_amount),
      'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    )
  );
end;
$$;

comment on function public.rule_appeal(uuid, boolean) is
  'FR-20. The referee''s ruling on a Held Penalty: role_from_table() = ''referee'' checked '
  'first, before any row is read. Reject (held -> owed) changes only the Penalty. Approve '
  '(held -> voided) also inserts a corrective settlement. Story 5.4: both branches now also '
  'stamp appeal.ruled_at, once each branch has already won its own guarded transition -- a '
  'race loser never reaches that statement, so ruled_at is only ever set by the ruling that '
  'actually took effect. Either path is the single guarded transition void_expired_appeals() '
  'already uses (AD-15): a raced timeout or a second ruling call finds zero rows and raises, '
  'never silently no-ops. Enqueues one outbox notification to the author in the same '
  'transaction (AD-3), keyed by appeal id so a race loser never double-enqueues.';

revoke execute on function public.rule_appeal(uuid, boolean) from public, anon;
grant execute on function public.rule_appeal(uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------------------
-- `commitment_answer_rate_for_month(p_month)`. The one new RPC this story needs: SM-6
-- (declaration answer rate) and SM-3 (per-commitment completion) both need "was this
-- commitment owed an answer on this day", logic `commitments_owing()` already owns and the
-- client cannot reach directly (`revoke execute ... from authenticated`,
-- 20260819220000). `security definer`, resolving `auth.uid()` internally -- never a
-- client-supplied owner -- the same reasoning `apply_grace_days()`'s own caller-derived
-- scoping gives, applied to a function callable directly by `authenticated` rather than one
-- only the schedule invokes.
--
-- Sums `commitments_owing()`'s own `count(*)`/`count(answer)` shape -- the exact one
-- `enqueue_gate_reminders()`'s `quiet_yesterday`/`quiet_day_before` block already uses,
-- 20260826090000 -- across every calendar day in `p_month`, grouped by commitment. `p_month`
-- is the caller-supplied month boundary (the month itself, any date inside it), not a
-- comparison against a stored `timestamptz` column, so it needs no `at time zone` conversion
-- here -- `lib/monthly-report.ts` is what derives the correct Asia/Ho_Chi_Minh calendar month
-- before calling this (`grace_day_validate()`'s own idiom, mirrored client-side).
-- ---------------------------------------------------------------------------------

create function public.commitment_answer_rate_for_month(p_month date)
returns table (commitment_id uuid, asked integer, answered integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner uuid := auth.uid();
  v_month_start date := date_trunc('month', p_month)::date;
  v_month_end date := (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date;
begin
  if v_owner is null then
    raise exception 'commitment_answer_rate_for_month requires an authenticated caller.';
  end if;

  -- Without this, a null p_month propagates silently: date_trunc('month', null) is null,
  -- generate_series(null, null, ...) returns zero rows (never an error), and the caller
  -- would read back an empty result indistinguishable from "nothing was ever asked" rather
  -- than the malformed call it actually was -- unlike the auth.uid() guard above, which
  -- already raises explicitly for its own null case.
  if p_month is null then
    raise exception 'commitment_answer_rate_for_month requires a non-null p_month.';
  end if;

  return query
    select o.commitment_id,
           count(*)::integer as asked,
           count(o.answer)::integer as answered
      from generate_series(v_month_start, v_month_end, interval '1 day') as days(day)
      cross join public.commitments_owing(v_owner, days.day::date) as o
     group by o.commitment_id;
end;
$$;

comment on function public.commitment_answer_rate_for_month(date) is
  'SM-6/SM-3 (Story 5.4): per-commitment asked/answered counts for every day in p_month, '
  'summing commitments_owing()''s own count(*)/count(answer) shape across the whole month '
  'rather than one day. security definer resolving auth.uid() internally -- never a '
  'client-supplied owner -- because commitments_owing() itself is revoked from authenticated '
  'and this is the one place SM-6/SM-3 can reach it. Excludes daily_hours_quota and a '
  'pre-archive day exactly as commitments_owing() always has; never re-derives those '
  'exclusions. Includes a weekly_quota commitment''s own asked/answered days unfiltered -- '
  'unlike settle_day()''s admitted/silent counts, an answer-rate measure has no reason to '
  'exclude a cadence that is still asked daily and can still be declared held.';

revoke execute on function public.commitment_answer_rate_for_month(date) from public, anon;
grant execute on function public.commitment_answer_rate_for_month(date) to authenticated;
