-- Epic 5 retrospective (2026-08-26), action item 1 — closing a race the prior fix's own
-- commit message claimed was closed but never actually was.
--
-- `20260825120000_the_same_lock_the_same_day.sql` set out to serialize Grace Day spending
-- against Penalty collection on the same account, and its own comments say the fix reached
-- both `appeal_hold_penalty()` and `mark_penalty_collected()`. Reading the shipped function,
-- only `appeal_hold_penalty()` actually took the advisory lock (its own trigger already had
-- `new.owner_id` on hand as the first statement). `mark_penalty_collected()` gained the
-- `grace_day`-existence guard from that same migration, but never the lock guarding it -- the
-- unlocked existence check races a concurrent `grace_day` insert exactly the way the original
-- migration describes, just on the collection side instead of the appeal side.
--
-- `mark_penalty_collected(p_penalty_id)` isn't a trigger, so the owner isn't known until the
-- first read resolves it (unlike `appeal_hold_penalty()`'s `new.owner_id`) -- the lock is taken
-- immediately once `v_owner` is in hand, still strictly before the `grace_day` read it exists
-- to guard.

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

  -- The fix this migration adds: the same lock, same key, grace_day_validate() and
  -- appeal_hold_penalty() already take -- held for the rest of this transaction, so a
  -- concurrent grace_day insert for this same account now genuinely waits behind whichever
  -- transaction got here first, instead of both reading the other's uncommitted state as
  -- absent and both proceeding.
  perform pg_advisory_xact_lock(hashtext(v_owner::text));

  -- Story 5.1 (2026-08-25 independent review): the same "a grace_day row for this day
  -- means it is already spoken for" guard appeal_hold_penalty() already enforces. Now
  -- actually race-safe against a concurrent grace_day insert, not only sequentially safe.
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
  'first, before any row is read, then a distinct "No such penalty." for a bogus id, then '
  '(2026-08-26 retro fix) the same per-account pg_advisory_xact_lock grace_day_validate() and '
  'appeal_hold_penalty() take, then a refusal if a Grace Day already claims this day '
  '(2026-08-25 independent review of Story 5.1, now actually race-safe), then the single '
  'guarded transition owed -> collected, stamping collected_at in the same update (Story 5.4) '
  '-- a double-click, or a call against a Penalty that is already collected, still held, or '
  'otherwise not owed, finds zero rows and is refused, never silently ignored.';

revoke execute on function public.mark_penalty_collected(uuid) from public, anon;
grant execute on function public.mark_penalty_collected(uuid) to authenticated;
