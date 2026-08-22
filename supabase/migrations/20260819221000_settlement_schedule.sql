-- Settlement's own schedule, separate from the outbox worker's.

/* Settles the days that are ready.

   **Why a lookback rather than a single day.** A day cannot close at midnight — nobody has
   answered for it yet; the question is not even asked until the morning hour. So settlement
   runs often and settles whatever has become complete since it last looked. Three days back
   means an answer given late still closes its own day rather than leaving it open forever,
   and every already-settled day in that window is a no-op by AD-5.

   The window is not the same thing as the FR-9 expiry, which turns an unanswered declaration
   into a miss after 48 hours. That belongs to Story 2.7, and until it exists a day nobody
   answered simply stays open — visibly, rather than being quietly decided against him.

   This is also the only place `app.settlement_invocation` is set. A manual caller has to
   pass an override instead, and the override is refused for the live doer account (AD-16). */
create function public.settle_due_days()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  day_to_settle date;
  settled integer := 0;
begin
  perform set_config('app.settlement_invocation', 'schedule', true);

  for day_to_settle in
    select generate_series(today - 3, today - 1, interval '1 day')::date
  loop
    settled := settled + public.settle_day(day_to_settle);
  end loop;

  return settled;
end;
$$;

revoke execute on function public.settle_due_days() from public, anon, authenticated;

-- Hourly, at quarter past, so it does not share a minute with the gate reminder at :05 or
-- the outbox worker every minute. Nothing depends on that separation; it just makes a
-- pg_cron log readable when something goes wrong.
select cron.schedule(
  'settle-days',
  '15 * * * *',
  $$select public.settle_due_days()$$
);
