-- The third independent reminder pipeline. FR-4's own half of Story 3.3, split out at
-- authoring time and finally built here (Story 3.5).
--
-- Silent while there is slack, one push a day once sessions remaining equals days
-- remaining, a second once the pace has already slipped past what a day at a time can
-- recover. It never says "miss" or "fail" — a Weekly Quota commitment cannot fail
-- mid-week (FR-2); only `settle_week` (3.4) ever writes a verdict. This decides only
-- whether and how often to say something.
--
-- It enqueues. It never sends — AD-3 keeps every outbound effect behind the outbox, and
-- the worker on its own schedule is what turns a row into a notification.

/* Enqueues one reminder per (account, commitment, slot) still owed one today.

   Reads `weekly_quota_progress` (AD-8, 3.3) rather than re-deriving `held`/`days_remaining`
   — the one counting rule this pipeline defers to entirely, same as `settle_week` defers to
   `weekly_held_count`. Joined back to `commitment` only for `name`, which the view does not
   expose.

   `slack = days_remaining - (target - held)` decides the tier:
     slack > 0  -- comfortable, nothing sent
     slack = 0  -- slot 0 only, at the account's own morning_hour
     slack < 0  -- slot 0 and, twelve hours later, slot 1 too

   The dedupe key carries the day and the slot, not the tier: a commitment crossing
   between slack = 0 and slack < 0 as the week moves (or a late `held` declaration
   landing inside 2.7's window and pulling it back) never collides with or skips a key it
   already used for that day. */
create function public.enqueue_weekly_quota_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  local_now timestamp;
  local_hour integer;
  today date;
  weekday text;
  clock text;
  progress record;
  slack integer;
  slot integer;
  body text;
  enqueued integer := 0;
begin
  local_now := now() at time zone 'Asia/Ho_Chi_Minh';
  local_hour := extract(hour from local_now)::integer;
  today := local_now::date;
  weekday := to_char(local_now, 'FMDay');
  clock := to_char(local_now, 'HH24:MI');

  for progress in
    select wqp.owner_id, wqp.commitment_id, c.name, wqp.target, wqp.held, wqp.days_remaining,
           p.morning_hour
      from public.weekly_quota_progress wqp
      join public.commitment c on c.id = wqp.commitment_id
      join public.profile p on p.id = wqp.owner_id and p.role = 'doer'
  loop
    slack := progress.days_remaining - (progress.target - progress.held);

    -- Comfortable pace: silent, per FR-4 and UX-DR1 (a Tuesday gap must not read as a
    -- Friday failure).
    continue when slack > 0;

    if local_hour = progress.morning_hour then
      slot := 0;
    elsif slack < 0 and local_hour = (progress.morning_hour + 12) % 24 then
      slot := 1;
    else
      continue;
    end if;

    body := progress.name || ', ' || progress.held::text || ' of ' || progress.target::text
            || ', ' || progress.days_remaining::text || ' day'
            || case when progress.days_remaining = 1 then '' else 's' end
            || ' left this week, as of ' || weekday || ' ' || clock || '.';

    -- Checked before enqueueing rather than left to the table's own check constraint —
    -- a commitment name is freeform text the author typed, so it can accidentally
    -- contain a banned phrase, and Story 3.2's own review found what an unhandled
    -- exception here does: it unwinds this whole function and rolls back every row
    -- already enqueued this pass, for every account processed before this one. A plain
    -- `continue` skips only the one poisoned commitment.
    continue when not public.push_body_is_sendable(body);

    perform public.outbox_enqueue(
      progress.owner_id,
      'weekly-' || progress.owner_id::text || '-' || progress.commitment_id::text
        || '-' || today::text || '-' || slot::text,
      jsonb_build_object(
        'title', 'This week',
        'body', body,
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );

    enqueued := enqueued + 1;
  end loop;

  return enqueued;
end;
$$;

revoke execute on function public.enqueue_weekly_quota_reminders() from public, anon, authenticated;

-- Hourly, at 35 past — the one remaining slot in the existing 05/15/25/35/45 rotation
-- (gate-reminders, settle-days, focus-prompts, settle-weeks).
select cron.schedule(
  'weekly-quota-reminders',
  '35 * * * *',
  $$select public.enqueue_weekly_quota_reminders()$$
);
