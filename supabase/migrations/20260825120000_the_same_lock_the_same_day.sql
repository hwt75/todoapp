-- Independent review of Story 5.1 (2026-08-25) found two ways a Grace Day could still be
-- spent for nothing, despite the iteration-1 fix that made Grace Days and Appeals mutually
-- exclusive on the same day (20260825110000). Both close the identical class of gap: the
-- existence of a `grace_day` row for a given (owner_id, for_day) has to be checked, and
-- serialized against, everywhere else can claim that day's Penalty -- not only the one
-- caller iteration-1 happened to fix first.
--
-- 1. `appeal_hold_penalty()` never took `grace_day_validate()`'s own per-account advisory
--    lock, so the two triggers did not actually serialize against each other under real
--    concurrency (two devices/tabs), only under sequential commits within one session --
--    which is all a single `do $$ ... $$` SQL test transaction can ever exercise. Under
--    true concurrency: a Grace Day insert and an Appeal insert for the same (owner_id,
--    for_day), submitted from two separate transactions both in flight at once, each read
--    the *other's* uncommitted state as absent -- `grace_day_validate()`'s own EXISTS-style
--    checks never ran against `appeal` at all, and `appeal_hold_penalty()`'s new EXISTS
--    check against `grace_day` (added by 20260825110000) sees nothing yet, since the other
--    transaction has not committed. Both can then commit: a `grace_day` row *and* a `held`
--    Penalty exist for the same day simultaneously -- exactly the "Grace Day consumed for
--    nothing" failure mode the iteration-1 fix exists to close, just reachable through real
--    concurrency rather than the sequential ordering its own I/O Matrix rows describe.
--    Fixed by taking the identical `pg_advisory_xact_lock(hashtext(owner_id::text))` as the
--    first statement here too -- the same lock key `grace_day_validate()` already takes,
--    so the two triggers now genuinely serialize per account, whichever fires first.
--
-- 2. `mark_penalty_collected()` (Story 4.7) had no awareness of `grace_day` at all. The
--    "Grace Day spent, then Collected before the fold-in runs" direction does not even need
--    concurrency -- the fold-in delay is up to an hour wide, and a referee collecting an
--    owed Penalty is ordinary, expected behaviour, not a race. `grace_day_validate()`
--    already refuses the reverse order (a `collected` Penalty never reads `owed`, so a
--    Grace Day can never be spent on one), but nothing stopped collection from happening
--    *after* a Grace Day was already spent and still waiting on the next `:15` pass --
--    `apply_grace_days()` would then find the Penalty no longer `owed`, silently no-op
--    (its own documented, correct behaviour for a lost race), and the Grace Day would be
--    gone with nothing forgiven. Fixed with the same "a grace_day row for this day means
--    it is already spoken for" guard `appeal_hold_penalty()` already established.

create or replace function public.appeal_hold_penalty()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_carries boolean;
  v_filed_by public.declaration_filed_by;
  v_settlement_id uuid;
  v_outcome public.commitment_outcome;
  v_penalty record;
begin
  -- Same lock, same key, as grace_day_validate() -- the two triggers now genuinely
  -- serialize per account rather than merely per sequential commit. Held for the rest of
  -- this transaction, released automatically on commit or rollback.
  perform pg_advisory_xact_lock(hashtext(new.owner_id::text));

  select owner_id, carries_penalty into v_owner, v_carries
    from public.commitment where id = new.commitment_id;

  if not found or v_owner <> new.owner_id then
    raise exception 'Appeal commitment does not belong to the appealing account.';
  end if;

  if not v_carries then
    raise exception 'Only a Penalty-carrying commitment can be appealed.';
  end if;

  -- Story 5.1: the two mechanisms cannot both claim the same day. Checked here, before the
  -- eligibility reads below, so the message names the actual reason rather than a
  -- downstream symptom of it. Now genuinely race-free against a concurrent Grace Day insert
  -- for the same account, thanks to the lock above.
  if exists (
    select 1 from public.grace_day g
     where g.owner_id = new.owner_id and g.for_day = new.for_day
  ) then
    raise exception
      'A Grace Day has already been spent on this day. It cannot also be appealed.';
  end if;

  select sc.settlement_id, sc.outcome into v_settlement_id, v_outcome
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
   where sc.commitment_id = new.commitment_id and s.period = new.for_day
     and s.kind = 'day' and s.subject = new.owner_id and s.verdict = 'failed'
     and not exists (select 1 from public.settlement c where c.supersedes = s.id);

  if not found or v_outcome <> 'missed' then
    raise exception 'No machine miss on record for this commitment/day.';
  end if;

  select filed_by into v_filed_by from public.declaration
   where commitment_id = new.commitment_id and for_day = new.for_day;

  if v_filed_by is distinct from 'auto_check' then
    raise exception 'Only a machine-filed miss can be appealed.';
  end if;

  select id, state into v_penalty from public.penalty where settlement_id = v_settlement_id;

  if not found or v_penalty.state <> 'owed' then
    raise exception 'This day''s Penalty is not appealable.';
  end if;

  new.settlement_id := v_settlement_id;
  new.penalty_id := v_penalty.id;
  new.deadline := public.appeal_deadline(now());

  update public.penalty set state = 'held' where id = v_penalty.id and state = 'owed';

  if not found then
    raise exception 'This day''s Penalty was claimed by another appeal first.';
  end if;

  return new;
end;
$$;

comment on function public.appeal_hold_penalty() is
  'before insert security definer trigger on public.appeal. Takes the same per-account '
  'advisory lock grace_day_validate() takes, first, so the two triggers genuinely serialize '
  '(2026-08-25 independent review of Story 5.1). Validates ownership, that no Grace Day '
  'already claims this day, that the day''s CURRENT (un-superseded) settlement reads '
  'verdict = failed with a missed outcome for this commitment, that the day''s own '
  'declaration was filed by the machine (not the author), and that the linked Penalty is '
  'still owed -- then derives settlement_id/penalty_id/deadline and holds the Penalty, '
  'atomically. Any failure raises; there is no silent no-op insert.';

revoke execute on function public.appeal_hold_penalty() from public, anon, authenticated;


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
  -- means it is already spoken for" guard appeal_hold_penalty() already enforces. Without
  -- this, a Grace Day spent on a day, followed by the referee marking that same Penalty
  -- collected before the next hourly fold-in runs, would consume the Grace Day for nothing
  -- -- apply_grace_days() finds the Penalty no longer owed and silently no-ops, correctly,
  -- but nothing was ever forgiven. No concurrency needed for this direction: the fold-in
  -- delay is up to an hour wide, and collecting an owed Penalty is ordinary referee
  -- behaviour, not a race.
  if exists (
    select 1 from public.grace_day g
     where g.owner_id = v_owner and g.for_day = v_for_day
  ) then
    raise exception
      'A Grace Day has already been spent on this day. It cannot also be collected.';
  end if;

  update public.penalty
     set state = 'collected'
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
  '5.1 -- mirrors appeal_hold_penalty()''s own guard), then the single guarded transition '
  'owed -> collected -- a double-click, or a call against a Penalty that is already '
  'collected, still held, or otherwise not owed, finds zero rows and is refused, never '
  'silently ignored. No settlement write, no settlement_commitment write, no outbox call.';

revoke execute on function public.mark_penalty_collected(uuid) from public, anon;
grant execute on function public.mark_penalty_collected(uuid) to authenticated;
