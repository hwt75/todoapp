-- Story 4.4 — found in independent review, after the story's own migrations had already
-- reached the live project: `appeal_hold_penalty()`'s eligibility lookup read the wrong
-- settlement, in two ways at once.
--
-- (1) `s.supersedes is null` was written to mean "the current settlement for this day," but
-- that is only true for a day that was never corrected. `settlement_current`
-- (20260819241000_expiry_and_supersession.sql:31-36) defines "current" as the row nothing
-- else points back to — for a day `supersede_expiries()` has corrected, that is the
-- *correction* row (`supersedes is not null`), not the original. The trigger's own filter
-- picked the original every time, which for a corrected day is history, not the day that
-- stands. Its `settlement_commitment` can still happen to read `missed` (frozen before the
-- correction ran) even though a *separate* penalty was created for the correction and is the
-- only one `penalty_current` — and therefore the Ledger, and `outstandingTotal` — ever reads.
-- An appeal filed against that stale row did not fail loudly: it found a real, `owed`
-- historical penalty, held *that* one, and left the live penalty the author actually owes
-- completely untouched. He would have seen "held" in the Appeal screen while the Ledger kept
-- naming the same money as owed — silently breaking the one promise this story exists to
-- keep.
--
-- (2) The query never checked `s.verdict` at all. A day can close `expired` (silence from
-- some *other* commitment) while still freezing one commitment's own machine-filed `missed`
-- and creating an `owed` Penalty from it (`settle_day`'s own "an expired day costs exactly
-- what an admitted one costs" -- 20260819241000). `expired` is a fact about the clock, not
-- about the machine's word (20260819241000_expiry_and_supersession.sql:129-135, "a different
-- fact about him from an admitted slip, and the ledger must not merge the two") — Appeal
-- exists to contest what the machine *said*, which only has standing on a day that closed on
-- someone's word (`failed`), never on a day that closed on someone else's silence. Left
-- unchecked, an eligible-looking appeal against an `expired` day's Penalty would succeed
-- server-side while the Ledger's own `expired` rendering (`lib/ledger.ts`'s
-- `ledgerPillLabel`/`ledgerPillFamily`, `components/ledger.tsx`'s aria-label) has no branch
-- that ever reflects `held`/`dropped` for that verdict — the pill would keep reading
-- "Expired ... owed X" forever, regardless of what the appeal actually did.
--
-- One fix closes both: read the settlement that is genuinely current (mirroring
-- `settlement_current`'s own "nothing supersedes it" definition directly, rather than adding
-- a `security invoker` view dependency inside a `security definer` trigger body) and require
-- `verdict = 'failed'`. `lib/ledger.ts`'s own `appealable` gate is narrowed to match in the
-- same round, so the Contest affordance and the trigger that judges it agree on scope again.
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
  select owner_id, carries_penalty into v_owner, v_carries
    from public.commitment where id = new.commitment_id;

  if not found or v_owner <> new.owner_id then
    raise exception 'Appeal commitment does not belong to the appealing account.';
  end if;

  if not v_carries then
    raise exception 'Only a Penalty-carrying commitment can be appealed.';
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
  'before insert security definer trigger on public.appeal. Validates ownership, that the '
  'day''s CURRENT (un-superseded) settlement reads verdict = failed with a missed outcome '
  'for this commitment, that the day''s own declaration was filed by the machine (not the '
  'author), and that the linked Penalty is still owed -- then derives '
  'settlement_id/penalty_id/deadline and holds the Penalty, atomically. Reads the current '
  'settlement directly (mirrors settlement_current''s own "nothing supersedes it" '
  'definition) rather than the original, and requires verdict = failed rather than merely a '
  'missed outcome, so a corrected day is read correctly and an expired day (closed on '
  'silence, not on anyone''s word) is never appealable. Any failure raises; there is no '
  'silent no-op insert.';
