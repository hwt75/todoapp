-- Epic 4 retrospective (2026-08-27), finding A1, action item 27 — carries_penalty_as_of() and
-- the three call sites it now feeds (commitments_owing(), file_auto_check_result(),
-- settle_week()'s own Weekly Quota loop). None of this had a test before this file: the whole
-- point is a fact that must survive a change made *after* it — a plain "does settle_day charge
-- a penalty" test would still pass against the old, live-reading code, since it never toggles
-- anything mid-scenario.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/carries_penalty_freezes_by_day.sql
--
-- One transaction, rolled back at the end. Nothing persists.

begin;

do $$
declare
  -- Step 1: carries_penalty_as_of() in isolation, against a directly-controlled history —
  -- no settlement machinery, just the function's own day-boundary arithmetic.
  v_user1      uuid := gen_random_uuid();
  v_c1         uuid;
  v_yesterday  date;
  v_today      date;

  -- Step 2: settle_day() charges a penalty for a day that closed penalty-carrying, even
  -- though the flag reads false by the time settle_day actually runs.
  v_user2      uuid := gen_random_uuid();
  v_c2         uuid;
  v_penalty2   uuid;

  -- Step 3: the opposite direction — settle_day() never charges a penalty for a day that
  -- closed penalty-free, even though the flag reads true by the time settle_day runs.
  v_user3      uuid := gen_random_uuid();
  v_c3         uuid;
  v_verdict3   public.day_verdict;
  v_penalty3   uuid;

  -- Step 4: file_auto_check_result()'s own 'missed' branch reads the frozen value.
  v_user4      uuid := gen_random_uuid();
  v_c4         uuid;

  -- Step 5: settle_week()'s own Weekly Quota loop reads the frozen value, anchored to the
  -- week's own last day.
  v_user5      uuid := gen_random_uuid();
  v_c5         uuid;
  v_period5    date;
  v_isodow5    integer;
  v_settlement5 uuid;

  v_state      public.penalty_state;
  v_verdict    public.day_verdict;
  v_count      integer;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day/settle_week refuse every '
      'override (AD-16). Run against a local or branch database instead.';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'carries-penalty-freeze-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user1, v_user2, v_user3, v_user4, v_user5]) as t(id);

  v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_yesterday := v_today - 1;

  -- =================================================================================
  -- Step 1: carries_penalty_as_of() against a directly-controlled history. Backdates the
  -- commitment's own creation-logged row so "as of yesterday" and "as of today" can be
  -- tested without waiting for real days to pass.
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user1, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c1;

  -- Replace the auto-logged creation row (stamped "now") with one dated ten days back, so
  -- the commitment reads as having been penalty-carrying since before either day this step
  -- checks.
  delete from public.commitment_carries_penalty_change where commitment_id = v_c1;
  insert into public.commitment_carries_penalty_change (commitment_id, carries_penalty, changed_at)
  values (v_c1, true, now() - interval '10 days');

  if public.carries_penalty_as_of(v_c1, v_yesterday) <> true then
    raise exception 'Step 1 FAILED: expected true before any toggle, got false/null.';
  end if;

  -- Toggled off "now" (today) — through the real UPDATE path, so the real trigger logs it.
  update public.commitment set carries_penalty = false where id = v_c1;

  if public.carries_penalty_as_of(v_c1, v_yesterday) <> true then
    raise exception using message = format(
      'Step 1 FAILED: yesterday''s own frozen value changed after a toggle made today, '
      'got %s -- expected true, unaffected, since yesterday had already closed before '
      'this toggle happened.', public.carries_penalty_as_of(v_c1, v_yesterday));
  end if;

  if public.carries_penalty_as_of(v_c1, v_today) <> false then
    raise exception using message = format(
      'Step 1 FAILED: today''s own value (not yet closed) should reflect a toggle made '
      'today, got %s -- expected false.', public.carries_penalty_as_of(v_c1, v_today));
  end if;

  raise notice 'Step 1 ok: carries_penalty_as_of() freezes a closed day''s own value and '
    'is unaffected by a later toggle, while a not-yet-closed day still reflects one.';

  -- =================================================================================
  -- Step 2: settle_day() charges a penalty for a day that closed penalty-carrying, even
  -- though the flag reads false by the time settle_day actually runs (finding A1's own
  -- exploit scenario).
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user2, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c2;

  -- now() is transaction-stable in Postgres, not statement-stable -- without backdating the
  -- creation-logged row, it and the toggle below would log the identical changed_at instant,
  -- leaving carries_penalty_as_of() to break the tie arbitrarily. Backdated two days, safely
  -- before both v_yesterday's own boundary and the toggle that follows -- a same-transaction
  -- test-fixture necessity, not a production concern (two real requests never share one now()).
  update public.commitment_carries_penalty_change
     set changed_at = now() - interval '2 days'
   where commitment_id = v_c2;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user2, v_c2, gen_random_uuid(), 'slipped', now());

  -- Toggled off after the miss was recorded, before settlement -- exactly the scenario
  -- finding A1 described.
  update public.commitment set carries_penalty = false where id = v_c2;

  -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
  -- This fixture creates its commitments moments before judging days that predate them, which is
  -- a state no real account can reach — so it now says when they began. Order-preserving, so
  -- every created_at comparison downstream reads the same way, and idempotent, so a second call
  -- further down this file does not age them twice.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_yesterday, true);

  select p.id, p.state into v_penalty2, v_state
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_user2 and s.period = v_yesterday and s.kind = 'day';

  if v_penalty2 is null or v_state <> 'owed' then
    raise exception using message = format(
      'Step 2 FAILED: expected a real owed Penalty for a day that closed penalty-carrying, '
      'got penalty=%s state=%s -- the later toggle must not have erased it.',
      v_penalty2, coalesce(v_state::text, '<null>'));
  end if;

  raise notice 'Step 2 ok: settle_day() still charges the Penalty a day genuinely earned, '
    'even though carries_penalty reads false by the time settlement actually runs.';

  -- =================================================================================
  -- Step 3: the opposite direction — settle_day() never charges a penalty for a day that
  -- closed penalty-free, even though the flag reads true by the time settle_day runs.
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user3, gen_random_uuid(), 'Gym', 'do', 'daily', false)
  returning id into v_c3;

  update public.commitment_carries_penalty_change
     set changed_at = now() - interval '2 days'
   where commitment_id = v_c3;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user3, v_c3, gen_random_uuid(), 'slipped', now());

  -- Toggled on after the miss, before settlement — must not retroactively invent a charge.
  update public.commitment set carries_penalty = true where id = v_c3;

  perform public.settle_day(v_yesterday, true);

  select verdict into v_verdict3
    from public.settlement
   where subject = v_user3 and period = v_yesterday and kind = 'day';

  select p.id into v_penalty3
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_user3 and s.period = v_yesterday and s.kind = 'day';

  if v_verdict3 <> 'clean' or v_penalty3 is not null then
    raise exception using message = format(
      'Step 3 FAILED: expected verdict clean and no Penalty for a day that closed '
      'penalty-free, got verdict=%s penalty=%s -- the later toggle must not have '
      'retroactively invented a charge.', coalesce(v_verdict3::text, '<null>'), v_penalty3);
  end if;

  raise notice 'Step 3 ok: settle_day() never invents a charge for a day that genuinely '
    'closed penalty-free, even though carries_penalty reads true by settlement time.';

  -- =================================================================================
  -- Step 4: file_auto_check_result()'s own 'missed' branch reads the frozen value —
  -- toggled off today, before filing for yesterday.
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user4, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-4')
  returning id into v_c4;

  update public.commitment_carries_penalty_change
     set changed_at = now() - interval '2 days'
   where commitment_id = v_c4;

  update public.commitment set carries_penalty = false where id = v_c4;

  perform public.file_auto_check_result(v_c4, v_user4, 'missed');

  select count(*) into v_count
    from public.declaration
   where commitment_id = v_c4 and for_day = v_yesterday and answer = 'slipped'
     and filed_by = 'auto_check';

  if v_count <> 1 then
    raise exception using message = format(
      'Step 4 FAILED: expected file_auto_check_result() to file one machine-slipped '
      'declaration for yesterday (frozen carries_penalty = true at the time), got %s rows '
      '-- a toggle made today after yesterday closed must not suppress it.', v_count);
  end if;

  raise notice 'Step 4 ok: file_auto_check_result() files the miss a day genuinely earned, '
    'even though carries_penalty reads false at filing time.';

  -- =================================================================================
  -- Step 5: settle_week()'s own Weekly Quota loop reads the frozen value, anchored to the
  -- week's own last day (period + 6) — toggled off today, well after the week closed.
  -- =================================================================================
  v_isodow5 := extract(isodow from v_today)::integer;
  v_period5 := v_today - 14; -- closed, same margin 3-4-week-settlement.sql's own fixture uses

  -- created_at backdated to before the week itself (mirrors 3-4-week-settlement.sql's own
  -- v_backdate) -- settle_week()'s own quota loop requires
  -- created_at < p_period + 7 (a commitment created today would otherwise share this
  -- week_start_day with an already-elapsed period purely by coincidence and be silently
  -- excluded, per that file's own comment).
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user5, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 5, v_isodow5,
          (v_period5 - 1 + time '00:00') at time zone 'Asia/Ho_Chi_Minh')
  returning id into v_c5;

  -- Backdated well before the week's own last day (period5 + 6) closes, unlike the two-day
  -- backdate above -- this step's own freeze boundary sits 7-8 days back, not 1.
  update public.commitment_carries_penalty_change
     set changed_at = now() - interval '20 days'
   where commitment_id = v_c5;

  -- One held day only — a real shortfall against a target of 5.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user5, v_c5, gen_random_uuid(), 'held',
          ((v_period5 + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');

  -- Toggled off today, six days after the week's own last day (period5 + 6) closed.
  update public.commitment set carries_penalty = false where id = v_c5;

  perform public.settle_week(v_period5, true);

  select id, verdict into v_settlement5, v_verdict
    from public.settlement
   where subject = v_user5 and period = v_period5 and kind = 'week';

  if v_verdict <> 'failed' or v_settlement5 is null then
    raise exception using message = format(
      'Step 5 FAILED: expected a failed Weekly Quota settlement for a week that closed '
      'penalty-carrying, got settlement=%s verdict=%s.', v_settlement5,
      coalesce(v_verdict::text, '<null>'));
  end if;

  if not exists (select 1 from public.penalty where settlement_id = v_settlement5) then
    raise exception
      'Step 5 FAILED: expected a real Penalty for the Weekly Quota shortfall, found none '
      '-- the later toggle must not have erased it.';
  end if;

  raise notice 'Step 5 ok: settle_week() still charges the Weekly Quota Penalty a week '
    'genuinely earned, even though carries_penalty reads false by the time settlement runs, '
    'up to 8 days later.';

  raise notice 'PASS. carries_penalty_as_of() freezes a closed day''s own fact; '
    'settle_day(), file_auto_check_result() and settle_week() all read it instead of the '
    'live, mutable column, in both directions (never erases a genuine charge, never '
    'invents one) -- Epic 4 retrospective finding A1, closed system-wide.';
end $$;

rollback;
