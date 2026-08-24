-- Story 4.4 — the timeout-favors-the-author path (FR-15). A `held` Penalty whose appeal
-- deadline passes with no ruling voids to `dropped` and never converts to `owed` on its
-- own -- "the single most trust-critical rule in the product" (epic-4-context.md): if the
-- author is ever charged because the referee was simply busy, trust in the whole mechanism
-- breaks permanently.
--
-- A plain guarded `update ... where state = 'held'` -- AD-15's own shape, exercised here
-- for the first time. `held -> dropped` (this job) and `held -> owed` (a future Story 4.6
-- rejection ruling) racing the same row is exactly what that guard exists for: whichever
-- write reaches the row first changes its state away from `held`, and the loser's own
-- `where state = 'held'` then matches zero rows -- no exception, no double-resolution, and
-- no ordering has to be enforced by anything other than Postgres's own row lock.

create function public.void_expired_appeals()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  voided integer;
begin
  update public.penalty p
     set state = 'dropped'
    from public.appeal a
   where a.penalty_id = p.id
     and p.state = 'held'
     and a.deadline < now();

  get diagnostics voided = row_count;
  return voided;
end;
$$;

comment on function public.void_expired_appeals() is
  'FR-15: a held Penalty past its own appeal.deadline voids to dropped. The guard '
  '(where state = ''held'') is the whole safety property (AD-15) -- a raced ruling that '
  'already moved the same Penalty to owed or otherwise off held leaves this a no-op, not '
  'an error. Never converts a Penalty to owed; that direction is a referee''s ruling '
  '(Story 4.6) alone.';

revoke execute on function public.void_expired_appeals() from public, anon, authenticated;

-- Hourly, at :55 -- the one slot still free (:00 resolve-auto-checks, :05 gate-reminders,
-- :15 settle-days, :25 focus-prompts, :35 weekly-quota-reminders, :45 settle-weeks) and
-- deliberately the last slot in the hour, so an appeal's own deadline has every other
-- pass's hour to have already run before this one decides whether it was missed.
select cron.schedule(
  'void-expired-appeals',
  '55 * * * *',
  $$select public.void_expired_appeals()$$
);
