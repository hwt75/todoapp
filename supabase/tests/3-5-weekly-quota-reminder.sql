-- Story 3.5 — the reminder FR-4 always meant, finally built: silent while there is slack,
-- once daily once sessions remaining equals days remaining, twice daily once it exceeds
-- them.
--
-- The matrix under test:
--
--   * comfortable slack (more days left than sessions owed): silent;
--   * target already met (0 sessions owed): silent, same as comfortable;
--   * slack = 0: exactly one push, at the account's morning hour;
--   * slack < 0: a second push twelve hours later, on top of the first;
--   * slack = 0 never reaches the second slot, even at the second slot's own hour;
--   * a retried pass at the same hour is a no-op (dedupe holds);
--   * an archived commitment is excluded throughout;
--   * a commitment named with a phrase `push_body_is_sendable` bans is skipped, not fatal
--     to the whole pass — a second, ordinary commitment in the same pass still enqueues.
--
-- `week_start_day` is chosen per commitment, per run, so that `weekly_quota_progress`'s
-- `days_remaining` reads a controlled value no matter which real calendar day this file
-- happens to run on — the same technique `3-3-weekly-quota-progress.sql` uses, just solved
-- in the other direction (searching for the week_start_day that produces a target
-- days_remaining, via `week_days_remaining` itself, rather than computing days_remaining
-- from a fixed week_start_day).
--
-- `enqueue_weekly_quota_reminders()` reads `now()` and the account's own `morning_hour` —
-- no hour of its own to be told otherwise, the same as `enqueue_gate_reminders` and
-- `enqueue_focus_prompts`. `morning_hour` is set to the real current hour for the first
-- pass (so slot 0 fires now) and to twelve hours before it for the second (so slot 1 fires
-- now instead) — both real "now", so this file needs no wall-clock window the way
-- `3-2-focus-prompt.sql` does.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/3-5-weekly-quota-reminder.sql
--
-- One transaction, rolled back at the end. It loops over every doer account by role, the
-- same as `enqueue_gate_reminders` and `enqueue_focus_prompts`, so it carries the
-- live-doer guard: run against a local or branch database, never one with the author's own
-- account in it.

begin;

grant select on table public.profile to authenticated;
grant select, insert on table public.commitment to authenticated;
grant select, insert on table public.declaration to authenticated;
grant select on table public.weekly_quota_progress to authenticated;

do $$
declare
  v_user        uuid := gen_random_uuid();
  v_comfortable uuid;  -- target 1, days_remaining 6, nothing held -- slack 5, must stay silent
  v_met         uuid;  -- target 2, days_remaining 2, both held -- slack 2, met early, silent
  v_tight       uuid;  -- target 3, days_remaining 2, one held -- slack 0, once daily only
  v_overdue     uuid;  -- target 3, days_remaining 1, one held -- slack -1, once then twice
  v_poisoned    uuid;  -- same shape as v_tight, name poisons its own body
  v_archived    uuid;  -- target 3, days_remaining 1, nothing held, archived -- must never appear
  v_today       date;
  v_isodow      integer;
  v_hour        integer;
  v_wsd_6       integer;  -- week_start_day giving days_remaining = 6
  v_wsd_2       integer;  -- week_start_day giving days_remaining = 2
  v_wsd_1       integer;  -- week_start_day giving days_remaining = 1
  v_queued      integer;
  v_count       integer;
  v_body        text;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account. enqueue_weekly_quota_reminders() loops over '
      'every doer by role and would enqueue real outbox rows for it, off this file''s '
      'made-up timing. Run against a local or branch database instead.';
  end if;

  v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_isodow := extract(isodow from v_today)::integer;
  v_hour := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh')::integer;

  for i in 1..7 loop
    if public.week_days_remaining(v_today, i) = 6 then v_wsd_6 := i; end if;
    if public.week_days_remaining(v_today, i) = 2 then v_wsd_2 := i; end if;
    if public.week_days_remaining(v_today, i) = 1 then v_wsd_1 := i; end if;
  end loop;

  if v_wsd_6 is null or v_wsd_2 is null or v_wsd_1 is null then
    raise exception using message =
      'Could not find a week_start_day giving days_remaining of 6, 2 and 1 for today. '
      'week_days_remaining''s range is 0-6, so one of each must exist across 1-7.';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-3-5-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  update public.profile set role = 'doer', morning_hour = v_hour where id = v_user;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day)
  values (v_user, gen_random_uuid(), 'Reading', 'do', 'weekly_quota', 1, v_wsd_6)
  returning id into v_comfortable;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day)
  values (v_user, gen_random_uuid(), 'Meditation', 'do', 'weekly_quota', 2, v_wsd_2)
  returning id into v_met;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day)
  values (v_user, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', 3, v_wsd_2)
  returning id into v_tight;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day)
  values (v_user, gen_random_uuid(), 'Swim', 'do', 'weekly_quota', 3, v_wsd_1)
  returning id into v_overdue;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day)
  values (v_user, gen_random_uuid(), 'Read right now', 'do', 'weekly_quota', 3, v_wsd_2)
  returning id into v_poisoned;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day, archived_at)
  values (v_user, gen_random_uuid(), 'Archived quota', 'do', 'weekly_quota', 3, v_wsd_1, now())
  returning id into v_archived;

  -- One held declaration each for v_met (x2), v_tight, v_overdue and v_poisoned, landed on
  -- each commitment's own week_start day so weekly_held_count counts it. Mirrors
  -- 3-3-weekly-quota-progress.sql's own technique for landing a declaration inside a
  -- specific commitment's week.
  declare
    v_week_start_2 date := v_today - ((v_isodow - v_wsd_2 + 7) % 7);
    v_week_start_1 date := v_today - ((v_isodow - v_wsd_1 + 7) % 7);
  begin
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values
      (v_user, v_met, gen_random_uuid(), 'held',
       (v_week_start_2 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
      (v_user, v_met, gen_random_uuid(), 'held',
       (v_week_start_2 + 1 + interval '1 day' + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
      (v_user, v_tight, gen_random_uuid(), 'held',
       (v_week_start_2 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
      (v_user, v_overdue, gen_random_uuid(), 'held',
       (v_week_start_1 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
      (v_user, v_poisoned, gen_random_uuid(), 'held',
       (v_week_start_2 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');
  end;

  -- Ground truth: confirm the fixtures actually read the slack this file's steps depend on,
  -- before trusting enqueue_weekly_quota_reminders() to act on them correctly.
  if (select days_remaining - (target - held) from public.weekly_quota_progress
       where commitment_id = v_comfortable) <= 0 then
    raise exception using message = 'Fixture error: v_comfortable does not read positive slack.';
  end if;
  if (select days_remaining - (target - held) from public.weekly_quota_progress
       where commitment_id = v_met) <= 0 then
    raise exception using message = 'Fixture error: v_met does not read positive slack.';
  end if;
  if (select days_remaining - (target - held) from public.weekly_quota_progress
       where commitment_id = v_tight) <> 0 then
    raise exception using message = 'Fixture error: v_tight does not read slack = 0.';
  end if;
  if (select days_remaining - (target - held) from public.weekly_quota_progress
       where commitment_id = v_overdue) >= 0 then
    raise exception using message = 'Fixture error: v_overdue does not read negative slack.';
  end if;

  raise notice using message =
    'Fixtures ok: comfortable and met read positive slack, tight reads exactly 0, overdue '
    'reads negative.';

  -- -------------------------------------------------------------------------------
  -- 1. First pass, at the real current hour (slot 0 for every commitment: morning_hour was
  --    just set to it).
  -- -------------------------------------------------------------------------------
  v_queued := public.enqueue_weekly_quota_reminders();

  select count(*) into v_count from public.outbox
   where dedupe_key like 'weekly-' || v_user::text || '-' || v_comfortable::text || '-%';
  if v_count <> 0 then
    raise exception using message = format(
      'Comfortable slack (5) enqueued %s rows rather than 0.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key like 'weekly-' || v_user::text || '-' || v_met::text || '-%';
  if v_count <> 0 then
    raise exception using message = format(
      'A commitment with its target already met enqueued %s rows rather than 0.', v_count);
  end if;

  select count(*), max(payload ->> 'body') into v_count, v_body from public.outbox
   where dedupe_key = 'weekly-' || v_user::text || '-' || v_tight::text || '-' || v_today::text
                      || '-0';
  if v_count <> 1 then
    raise exception using message = format(
      'Slack = 0 enqueued %s rows at slot 0 rather than exactly 1.', v_count);
  end if;
  if v_body !~ '^Gym, 1 of 3, 2 days? left this week, as of \w+ \d{2}:\d{2}\.$' then
    raise exception using message = format('Slot-0 body read "%s", not the expected shape.', v_body);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key = 'weekly-' || v_user::text || '-' || v_overdue::text || '-' || v_today::text
                      || '-0';
  if v_count <> 1 then
    raise exception using message = format(
      'Slack < 0 enqueued %s rows at slot 0 rather than exactly 1.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key like 'weekly-' || v_user::text || '-' || v_overdue::text || '-%-1';
  if v_count <> 0 then
    raise exception using message = format(
      'Slot 1 fired on the first pass (%s rows) despite the current hour matching only '
      'slot 0.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key like 'weekly-' || v_user::text || '-' || v_poisoned::text || '-%';
  if v_count <> 0 then
    raise exception using message = format(
      'A commitment named to poison push_body_is_sendable enqueued %s rows rather than '
      'being skipped.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key like 'weekly-' || v_user::text || '-' || v_archived::text || '-%';
  if v_count <> 0 then
    raise exception using message = format(
      'An archived commitment enqueued %s rows. weekly_quota_progress already excludes '
      'archived_at, and this pipeline must not re-derive its own copy of that exclusion.',
      v_count);
  end if;

  raise notice using message =
    'Step 1 ok: comfortable and met slack stay silent, slack = 0 enqueues exactly one '
    'named, self-dated push at slot 0, slack < 0 enqueues slot 0 but not yet slot 1, a '
    'poisoned name is skipped without enqueuing, and an archived commitment never appears.';

  -- -------------------------------------------------------------------------------
  -- 2. A retried pass at the same hour is a no-op — dedupe holds, per AD-3's own promise
  --    that a cron schedule is not a promise to run exactly once.
  -- -------------------------------------------------------------------------------
  perform public.enqueue_weekly_quota_reminders();

  select count(*) into v_count from public.outbox
   where dedupe_key like 'weekly-' || v_user::text || '-%';
  if v_count <> 2 then
    raise exception using message = format(
      'After a retried pass at the same hour, %s rows exist rather than the 2 from step 1 '
      '(tight''s slot 0, overdue''s slot 0). Re-running the same hour must be a no-op.',
      v_count);
  end if;

  raise notice using message = 'Step 2 ok: a retried pass at the same hour enqueues nothing new.';

  -- -------------------------------------------------------------------------------
  -- 3. Twelve hours later (simulated by moving morning_hour back twelve hours, so the real
  --    current hour now equals morning_hour + 12): slack = 0 must still stay at one row —
  --    slot 1 is reachable only when slack < 0 — and slack < 0 must gain its second push.
  -- -------------------------------------------------------------------------------
  update public.profile set morning_hour = ((v_hour - 12) + 24) % 24 where id = v_user;

  perform public.enqueue_weekly_quota_reminders();

  select count(*) into v_count from public.outbox
   where dedupe_key like 'weekly-' || v_user::text || '-' || v_tight::text || '-%';
  if v_count <> 1 then
    raise exception using message = format(
      'Slack = 0 read %s total rows after the twelve-hours-later pass rather than staying '
      'at 1. It must never reach the second slot.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key = 'weekly-' || v_user::text || '-' || v_overdue::text || '-' || v_today::text
                      || '-1';
  if v_count <> 1 then
    raise exception using message = format(
      'Slack < 0 read %s rows at slot 1 after the twelve-hours-later pass rather than '
      'exactly 1.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key like 'weekly-' || v_user::text || '-' || v_overdue::text || '-%';
  if v_count <> 2 then
    raise exception using message = format(
      'Slack < 0 read %s rows total across both slots rather than 2.', v_count);
  end if;

  raise notice using message =
    'Step 3 ok: twelve hours later, slack = 0 still reads exactly one row total (never '
    'reaches slot 1), and slack < 0 gains its second push, two rows total across the day.';

  raise notice using message =
    'PASS. Comfortable slack and an already-met target stay silent; slack = 0 sends one '
    'named, self-dated push at the morning hour and never a second; slack < 0 sends a '
    'second twelve hours later; a repeated pass at the same hour is a no-op; a poisoned '
    'commitment name is skipped without harming any other row; an archived commitment '
    'never appears.';
end $$;

rollback;
