-- Epic 4 retrospective (2026-08-27), action item 1 -- `epic-4-context.md`'s own documented
-- FR-2a invariant, "Turning a Penalty off on a commitment with a pending Appeal resolves that
-- Appeal in the author's favor immediately," had no implementation anywhere: the only trigger
-- on `public.commitment` was `commitment_touch_updated_at`, and nothing reacted to
-- `carries_penalty` flipping to `false`.
--
-- `deferred-work.md`'s own Story-4.4 entry dismissed this exact hazard on the stated premise
-- that "no UI path exposes editing `carries_penalty` post-creation." That premise is false:
-- `components/commitment-form.tsx` renders as an editable "Edit commitment" form (the money
-- checkbox included) whenever `initial` is supplied, and `components/commitment-list.tsx`
-- saves that edit straight through `.update(...)`. Without this fix, a `held` Penalty just
-- sits on the ordinary ruling/timeout path regardless of the toggle -- and if the referee
-- rules "He didn't" first, it converts to `owed` on a commitment that no longer carries money
-- at all.
--
-- The guard is the same AD-15 shape `void_expired_appeals()`/`rule_appeal()` already use: a
-- plain `update ... where state = 'held'`. A raced referee ruling or timeout that already
-- moved the same Penalty off `held` leaves this a no-op, never an error -- whichever writer
-- reaches the row first wins, exactly like every other terminal transition on this table.

create function public.commitment_carries_penalty_off_ends_appeal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.carries_penalty or not old.carries_penalty then
    return new;
  end if;

  update public.penalty p
     set state = 'dropped'
    from public.appeal a
   where a.penalty_id = p.id
     and a.commitment_id = new.id
     and p.state = 'held';

  return new;
end;
$$;

comment on function public.commitment_carries_penalty_off_ends_appeal() is
  'FR-2a: turning carries_penalty off (true -> false) on a commitment with a held Penalty '
  'behind a pending Appeal resolves that Appeal in the author''s favor immediately -- the '
  'same held -> dropped guarded transition (AD-15) void_expired_appeals() uses for a timeout. '
  'A no-op for every other update (carries_penalty unchanged, or already false, or turning '
  'on), and a no-op if the Penalty already moved off held via a ruling or timeout that won '
  'the race first.';

revoke execute on function public.commitment_carries_penalty_off_ends_appeal()
  from public, anon, authenticated;

create trigger commitment_carries_penalty_off_ends_appeal
  after update on public.commitment
  for each row
  execute function public.commitment_carries_penalty_off_ends_appeal();

comment on trigger commitment_carries_penalty_off_ends_appeal on public.commitment is
  'FR-2a: closes the gap epic-4-context.md''s own Requirements & Constraints documented but '
  'no story ever built (found by the 2026-08-27 Epic 4 retrospective, finding A2).';
