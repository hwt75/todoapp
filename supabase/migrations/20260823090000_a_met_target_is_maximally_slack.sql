-- Code review (2026-08-23) on spec-3-5: a commitment that met its target exactly, on the
-- last day of its own week, was not silent. `slack := days_remaining - (target - held)`
-- reads as `0 - 0 = 0` when `held = target` and `days_remaining = 0` — the spec's own claim
-- that a met target "reads as maximally slack, not zero" only actually holds when `held`
-- strictly overshoots `target`, or when `days_remaining > 0`. `continue when slack > 0` let
-- that boundary through, so a doer who finished a Weekly Quota commitment on the week's last
-- day still got a push like "Gym, 3 of 3, 0 days left this week..." at his morning hour.
--
-- Fixed by checking the met-or-exceeded case directly, ahead of and independent from
-- `slack`, rather than trusting `slack` to always read positive once a target is met.

create or replace function public.enqueue_weekly_quota_reminders()
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
    -- Met or exceeded: always silent. Checked directly rather than left to slack > 0, which
    -- reads 0 (not positive) exactly when held = target and days_remaining = 0 — the week's
    -- last day.
    continue when progress.held >= progress.target;

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
