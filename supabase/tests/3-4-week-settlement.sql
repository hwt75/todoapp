-- Story 3.4 — the week closes and settles.
--
-- `settle_day` had 2-5-settlement.sql; `settle_week` gets its own file, modeled on that
-- one's own shape and its own reasoning: nothing exercised the decision this migration
-- makes before this file existed.
--
-- What is asserted here is the spec's own I/O matrix, restated in SQL:
--
--   FR-13, mirrored   a Failed Week costs exactly one 500,000₫ penalty, however many Weekly
--                      Quota commitments fell short that week
--   AD-5               a re-run of an already-settled week is a no-op
--   AD-8               the held-count rule reads the same for a live week and a closed one
--   AD-16              settlement off its schedule refuses, and the override is refused for
--                       the live doer account — by raising, not by skipping
--   AD-3                the verdict and its outbox notification land in the same transaction
--
-- A penalty-free shortfall costing nothing is asserted too, for the same reason 2-5 asserts
-- it for a day: it looks like a bug and is the case most likely to go unnoticed if it ever
-- breaks. Two commitments sharing one week_start_day producing one penalty (FR-13) and two
-- commitments with *different* week_start_day producing two independent settlement rows
-- are both asserted directly, because the whole reason `p_period` is settle_week's argument
-- rather than something derived once per account is that these two cases must not collapse
-- into each other.
--
--
-- HOW TO RUN
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/3-4-week-settlement.sql
--
-- One transaction, rolled back at the end. It needs a database with **no live doer
-- account**, for the same reason 2-5-settlement.sql does: `settle_week` raises rather than
-- skipping when `p_override` meets a profile with `is_live_doer` set, so one live account
-- disables the override path for every call in this file.

begin;

do $$
declare
  -- Fixture accounts, one per scenario so each account's own commitments never leak into
  -- another scenario's judgement — `settle_week` sums every Weekly Quota commitment an
  -- account owns that shares a period's week_start_day, so mixing scenarios under one
  -- account would make one scenario's fixture change another's verdict.
  v_user1 uuid := gen_random_uuid(); -- shortfall, carries_penalty = true
  v_user2 uuid := gen_random_uuid(); -- target met exactly
  v_user3 uuid := gen_random_uuid(); -- two commitments, one short one met
  v_user4 uuid := gen_random_uuid(); -- shortfall, carries_penalty = false
  v_user5 uuid := gen_random_uuid(); -- two commitments, different week_start_day
  v_user6 uuid := gen_random_uuid(); -- archived mid-week
  v_user7 uuid := gen_random_uuid(); -- week not yet over
  v_user8 uuid := gen_random_uuid(); -- commitment created after p_period already elapsed
  v_user9 uuid := gen_random_uuid(); -- settle_due_weeks(), the schedule path itself
  v_userA uuid := gen_random_uuid(); -- two commitments fall short together -> plural body
  v_live  uuid := gen_random_uuid(); -- AD-16's own account

  v_c1 uuid; v_c2 uuid; v_c3a uuid; v_c3b uuid; v_c4 uuid;
  v_c5a uuid; v_c5b uuid; v_c6 uuid; v_c7 uuid; v_c8 uuid; v_c9 uuid;
  v_ca1 uuid; v_ca2 uuid;

  v_today      date;
  v_isodow     integer;
  v_period     date; -- a closed week, week_start_day = v_isodow
  v_wsd_b      integer;
  v_period_b   date; -- a second closed week, a different week_start_day
  v_period9    date; -- the closest-to-today edge of settle_due_weeks()'s own window
  v_backdate   timestamptz; -- a created_at safely before every candidate period's own
                             -- cutoff (p_period + 7) used below, so a fixture commitment is
                             -- never excluded by the guard step 11 exists to test on purpose
  v_day_label  text; -- v_period's own "Weekday, YYYY-MM-DD", built the same way
                      -- week_summary_body builds it, so the body assertions below check
                      -- the function's arithmetic and pluralization rather than re-deriving
                      -- a date format from scratch.

  -- `for_day` is `answered_at::date - 1` (`declaration_derive_day`, AD-6): a declaration
  -- filed in the morning answers for yesterday. So `answered_at`'s date must be one past
  -- the `for_day` a fixture wants — every `+ N + 1 + time '07:00'` below is "for_day
  -- period + N" plus that one-day trigger offset, not a copy-paste slip.

  v_settlement uuid;
  v_verdict    public.day_verdict;
  v_missed     integer;
  v_amount     bigint;
  v_count      integer;
  v_raised     boolean;
  v_body       text;
  v_expected   text;
begin
  -- -------------------------------------------------------------------------------
  -- 0. Refuse to run where the AD-16 guard would make the result meaningless.
  -- -------------------------------------------------------------------------------
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_week refuses every override '
      '(AD-16). Run against a local or branch database instead. Never work around the '
      'guard by setting app.settlement_invocation by hand.';
  end if;

  v_today  := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_isodow := extract(isodow from v_today)::integer;

  -- Two weeks back shares today's own weekday (14 is a multiple of 7), so a commitment's
  -- week_start_day can be set to v_isodow without hardcoding which real weekday this file
  -- happens to run on. period + 8 is six days short of today — safely closed against
  -- `settle_week`'s own gate (a week judges only once its last day's answer day has fully
  -- passed, `today < p_period + 8` — see the migration's own comment on why `+ 8`, not
  -- `+ 7`), matching the margin 2-5-settlement.sql's own fixture days keep against theirs.
  v_period := v_today - 14;

  -- A second, different week_start_day (cyclically the next ISO day) and the closed period
  -- that belongs to it — one day later than v_period, since a date's isodow advances by
  -- exactly one per day. Still seven days short of today, safely closed.
  v_wsd_b    := (v_isodow % 7) + 1;
  v_period_b := v_period + 1;

  -- Every fixture commitment below is backdated to this instant unless a step's own point
  -- is the created_at cutoff itself (step 11) — comfortably before every candidate period's
  -- `p_period + 7` eligibility boundary used in this file.
  v_backdate := (v_period - 1 + time '00:00') at time zone 'Asia/Ho_Chi_Minh';

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-3-4-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user1, v_user2, v_user3, v_user4, v_user5, v_user6, v_user7, v_user8,
                       v_user9, v_userA, v_live])
      as t(id);

  -- The same "Weekday, YYYY-MM-DD" label week_summary_body builds from p_period, computed
  -- independently here so the body assertions below check the function's own arithmetic
  -- and wording rather than merely re-deriving to_char's output a second time.
  v_day_label := to_char(v_period, 'FMDay') || ', ' || to_char(v_period, 'YYYY-MM-DD');

  -- -------------------------------------------------------------------------------
  -- 1. Shortfall, carries_penalty = true, week over -> failed, exactly one penalty.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user1, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow, v_backdate)
  returning id into v_c1;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user1, v_c1, gen_random_uuid(), 'held',
          (v_period + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_week(v_period, true);

  select id, verdict, missed_count into v_settlement, v_verdict, v_missed
    from public.settlement
   where subject = v_user1 and period = v_period and kind = 'week' and supersedes is null;

  if v_settlement is null then
    raise exception using message = 'A closed week with a shortfall must settle. It did not.';
  end if;

  if v_verdict <> 'failed' then
    raise exception using message = format(
      '1 of 3 held on a penalty-carrying commitment must settle `failed`, not `%s`.', v_verdict);
  end if;

  if v_missed <> 1 then
    raise exception using message = format(
      'missed_count is %s, expected 1 — one commitment fell short of its own target.', v_missed);
  end if;

  select count(*) into v_count from public.penalty where settlement_id = v_settlement;
  if v_count <> 1 then
    raise exception using message = format(
      'FR-13, mirrored: a Failed Week costs exactly ONE penalty. Found %s.', v_count);
  end if;

  select amount_dong into v_amount from public.penalty where settlement_id = v_settlement;
  if v_amount <> public.penalty_amount_dong() then
    raise exception using message = format(
      'A Failed Week costs penalty_amount_dong(); this one cost %s.', v_amount);
  end if;

  -- The Ledger's own reads depend on `penalty_current` carrying `kind`/`period` (the
  -- "Always" boundary this spec's own migration adds them for) — asserted here directly
  -- rather than only through the client mock, which cannot see a missing column.
  select count(*) into v_count
    from public.penalty_current
   where subject = v_user1 and settlement_id = v_settlement
     and kind = 'week' and period = v_period;
  if v_count <> 1 then
    raise exception using message = format(
      'penalty_current must carry kind = ''week'' and period = %s for this penalty. Found '
      '%s matching rows.', v_period, v_count);
  end if;

  -- AD-3: the verdict and its notification land in the same transaction.
  select count(*) into v_count
    from public.outbox
   where owner_id = v_user1
     and dedupe_key = 'week-' || v_user1::text || '-' || v_period::text;
  if v_count <> 1 then
    raise exception using message = format(
      'A closed week writes its notification to the outbox in the same transaction as the '
      'verdict (AD-3). Found %s rows.', v_count);
  end if;

  -- The notification's actual text, not just its presence. Exactly one commitment fell
  -- short, so it is named (mirroring settle_day's own single-suggestion rule) alongside
  -- its own held/target figures and the amount — the exact spot a swapped
  -- held_sum/target_sum at the call site, or a broken pluralization branch, would show up
  -- with every count-only assertion above still green.
  select payload ->> 'body' into v_body
    from public.outbox
   where owner_id = v_user1
     and dedupe_key = 'week-' || v_user1::text || '-' || v_period::text;

  v_expected := 'Gym, 1 of 3 held, week of ' || v_day_label || '. That''s 500.000₫.';
  if v_body <> v_expected then
    raise exception using message = format(
      'Expected "%s", got "%s". A single shortfall must name the commitment and carry its '
      'own held/target figures and the amount.', v_expected, v_body);
  end if;

  raise notice using message = format(
    'Step 1 ok: 1 of 3 held on a penalty-carrying commitment settles `failed`, one 500000₫ '
    'penalty, notification reads "%s".', v_body);

  -- -------------------------------------------------------------------------------
  -- 2. Target met exactly -> clean, no penalty. Still notifies (AD-3 does not gate on
  --    verdict).
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user2, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow, v_backdate)
  returning id into v_c2;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    (v_user2, v_c2, gen_random_uuid(), 'held',
     (v_period + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user2, v_c2, gen_random_uuid(), 'held',
     (v_period + 2 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user2, v_c2, gen_random_uuid(), 'held',
     (v_period + 4 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_week(v_period, true);

  select id, verdict, missed_count into v_settlement, v_verdict, v_missed
    from public.settlement
   where subject = v_user2 and period = v_period and kind = 'week' and supersedes is null;

  if v_verdict is distinct from 'clean' or v_missed <> 0 then
    raise exception using message = format(
      '3 of 3 held must settle `clean` with 0 missed, not `%s` with %s.', v_verdict, v_missed);
  end if;

  select count(*) into v_count from public.penalty where settlement_id = v_settlement;
  if v_count <> 0 then
    raise exception using message = format(
      'Target met exactly must cost nothing. %s penalties were charged.', v_count);
  end if;

  select count(*) into v_count
    from public.outbox
   where owner_id = v_user2
     and dedupe_key = 'week-' || v_user2::text || '-' || v_period::text;
  if v_count <> 1 then
    raise exception using message = format(
      'A closed clean week still notifies in the same transaction as its verdict (AD-3). '
      'Found %s rows.', v_count);
  end if;

  -- Nothing fell short, so nothing is named and no amount is stated — a clean week must
  -- not name a commitment or a price it never cost.
  select payload ->> 'body' into v_body
    from public.outbox
   where owner_id = v_user2
     and dedupe_key = 'week-' || v_user2::text || '-' || v_period::text;

  v_expected := '3 of 3 held, week of ' || v_day_label || '.';
  if v_body <> v_expected then
    raise exception using message = format(
      'Expected "%s", got "%s". A met target names no commitment and states no amount.',
      v_expected, v_body);
  end if;

  raise notice using message = format(
    'Step 2 ok: 3 of 3 held settles `clean`, costs nothing, notification reads "%s".', v_body);

  -- -------------------------------------------------------------------------------
  -- 3. Two commitments, same week_start_day, one short one met -> still exactly one
  --    penalty (FR-13), never two.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user3, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow, v_backdate)
  returning id into v_c3a;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user3, gen_random_uuid(), 'Swim', 'do', 'weekly_quota', true, 2, v_isodow, v_backdate)
  returning id into v_c3b;

  -- Gym: 1 of 3, short. Swim: 2 of 2, met.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    (v_user3, v_c3a, gen_random_uuid(), 'held',
     (v_period + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user3, v_c3b, gen_random_uuid(), 'held',
     (v_period + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user3, v_c3b, gen_random_uuid(), 'held',
     (v_period + 3 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_week(v_period, true);

  select count(*) into v_count
    from public.settlement
   where subject = v_user3 and period = v_period and kind = 'week' and supersedes is null;
  if v_count <> 1 then
    raise exception using message = format(
      'Two commitments sharing one week_start_day must settle as ONE row, not %s.', v_count);
  end if;

  select id, verdict, missed_count into v_settlement, v_verdict, v_missed
    from public.settlement
   where subject = v_user3 and period = v_period and kind = 'week' and supersedes is null;

  if v_verdict <> 'failed' or v_missed <> 1 then
    raise exception using message = format(
      'One short of two commitments must settle `failed` with missed_count 1, got `%s`/%s.',
      v_verdict, v_missed);
  end if;

  select count(*) into v_count from public.penalty where settlement_id = v_settlement;
  if v_count <> 1 then
    raise exception using message = format(
      'FR-13: one Failed Week costs exactly ONE penalty regardless of how many commitments '
      'fell short. Found %s.', v_count);
  end if;

  raise notice using message =
    'Step 3 ok: one short of two commitments sharing a week_start_day still settles as one '
    'row with exactly one penalty.';

  -- -------------------------------------------------------------------------------
  -- 4. Shortfall, carries_penalty = false -> clean. A penalty-free miss costs nothing,
  --    even though the commitment did fall short of its own target.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user4, gen_random_uuid(), 'Reading', 'do', 'weekly_quota', false, 3, v_isodow,
          v_backdate)
  returning id into v_c4;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user4, v_c4, gen_random_uuid(), 'held',
          (v_period + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_week(v_period, true);

  select id, verdict, missed_count into v_settlement, v_verdict, v_missed
    from public.settlement
   where subject = v_user4 and period = v_period and kind = 'week' and supersedes is null;

  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'A shortfall on a commitment with carries_penalty = false must settle `clean`, not '
      '`%s`. The money toggle is what makes a miss cost, and it was off.', v_verdict);
  end if;

  -- missed_count mirrors settle_day's own meaning exactly (only carries_penalty shortfalls
  -- count) — a penalty-free miss must not appear here any more than it appears in the
  -- penalty count below. The notification still names it (week_summary_body's own
  -- shortfall_count/shortfall_name are independent of missed_count, and do count it).
  if v_missed <> 0 then
    raise exception using message = format(
      'missed_count must be 0 for a penalty-free shortfall — it mirrors settle_day, which '
      'never counts a carries_penalty = false miss. Got %s.', v_missed);
  end if;

  select count(*) into v_count from public.penalty where settlement_id = v_settlement;
  if v_count <> 0 then
    raise exception using message = format(
      'A penalty-free shortfall cost %s penalties. It must cost nothing.', v_count);
  end if;

  -- The notification still names what fell short — week_summary_body's own shortfall
  -- naming is independent of carries_penalty (only the amount clause is), so the doer
  -- still learns Reading came up short even though it cost nothing.
  select payload ->> 'body' into v_body
    from public.outbox
   where owner_id = v_user4
     and dedupe_key = 'week-' || v_user4::text || '-' || v_period::text;

  v_expected := 'Reading, 1 of 3 held, week of ' || v_day_label || '.';
  if v_body <> v_expected then
    raise exception using message = format(
      'Expected "%s", got "%s". A penalty-free shortfall is still named, with no amount '
      'clause since nothing was charged.', v_expected, v_body);
  end if;

  raise notice using message = format(
    'Step 4 ok: a penalty-free shortfall settles `clean` and costs nothing, though it is '
    'still named: "%s".', v_body);

  -- -------------------------------------------------------------------------------
  -- 5. Two commitments, different week_start_day -> two separate settlement rows, two
  --    periods. This is the whole reason settle_week takes p_period as an argument rather
  --    than deriving "this account's week" once.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user5, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow, v_backdate)
  returning id into v_c5a;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user5, gen_random_uuid(), 'Swim', 'do', 'weekly_quota', true, 2, v_wsd_b, v_backdate)
  returning id into v_c5b;

  -- Gym (v_period): 1 of 3, short. Swim (v_period_b): 2 of 2, met.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    (v_user5, v_c5a, gen_random_uuid(), 'held',
     (v_period + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user5, v_c5b, gen_random_uuid(), 'held',
     (v_period_b + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user5, v_c5b, gen_random_uuid(), 'held',
     (v_period_b + 3 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_week(v_period, true);
  perform public.settle_week(v_period_b, true);

  select count(*) into v_count
    from public.settlement
   where subject = v_user5 and kind = 'week' and supersedes is null;
  if v_count <> 2 then
    raise exception using message = format(
      'Two commitments with different week_start_day must produce two settlement rows, '
      'not %s.', v_count);
  end if;

  select verdict into v_verdict
    from public.settlement
   where subject = v_user5 and period = v_period and kind = 'week' and supersedes is null;
  if v_verdict <> 'failed' then
    raise exception using message = format(
      'Gym''s own period must settle `failed` on its own shortfall, not `%s`.', v_verdict);
  end if;

  select verdict into v_verdict
    from public.settlement
   where subject = v_user5 and period = v_period_b and kind = 'week' and supersedes is null;
  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'Swim''s own period must settle `clean` on its own target being met, unaffected by '
      'Gym''s shortfall in a different period. Got `%s`.', v_verdict);
  end if;

  raise notice using message =
    'Step 5 ok: two commitments with different week_start_day settle as two independent '
    'rows in two different periods, neither verdict bleeding into the other.';

  -- -------------------------------------------------------------------------------
  -- 6. A commitment archived mid-week is excluded entirely, matching
  --    weekly_quota_progress — no settlement row at all, not a shortfall counted against
  --    an account that has nothing left to judge.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, archived_at,
                                 created_at)
  values (v_user6, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow,
          (v_period + 3 + time '12:00') at time zone 'Asia/Ho_Chi_Minh', v_backdate)
  returning id into v_c6;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user6, v_c6, gen_random_uuid(), 'held',
          (v_period + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_week(v_period, true);

  select count(*) into v_count
    from public.settlement
   where subject = v_user6 and period = v_period and kind = 'week';
  if v_count <> 0 then
    raise exception using message = format(
      'An archived commitment must be excluded entirely, the same as '
      'weekly_quota_progress excludes it — no settlement row at all. Found %s.', v_count);
  end if;

  raise notice using message =
    'Step 6 ok: a commitment archived mid-week is excluded entirely; nothing settles for '
    'an account with nothing left to judge.';

  -- -------------------------------------------------------------------------------
  -- 7. A week not yet over settles nothing — the boundary is the calendar (AD-6), not an
  --    answered-vs-owed count the way a day's is.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user7, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow, v_backdate)
  returning id into v_c7;

  perform public.settle_week(v_today - 3, true);

  select count(*) into v_count
    from public.settlement where subject = v_user7 and kind = 'week';
  if v_count <> 0 then
    raise exception using message = format(
      'A week that has not yet ended must not settle. %s rows were written.', v_count);
  end if;

  raise notice using message = 'Step 7 ok: a week not yet over settles nothing.';

  -- -------------------------------------------------------------------------------
  -- 8. AD-5 — a re-run of an already-settled week is a no-op.
  -- -------------------------------------------------------------------------------
  perform public.settle_week(v_period, true);
  perform public.settle_week(v_period, true);

  select count(*) into v_count
    from public.settlement
   where subject = v_user1 and period = v_period and kind = 'week' and supersedes is null;
  if v_count <> 1 then
    raise exception using message = format(
      'AD-5: a settled week is never re-settled. Two further passes over %s produced %s '
      'verdicts.', v_period, v_count);
  end if;

  select count(*) into v_count
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_user1 and s.period = v_period and s.kind = 'week';
  if v_count <> 1 then
    raise exception using message = format(
      'Two further settlement passes over one Failed Week produced %s penalties.', v_count);
  end if;

  select count(*) into v_count
    from public.outbox
   where owner_id = v_user1
     and dedupe_key = 'week-' || v_user1::text || '-' || v_period::text;
  if v_count <> 1 then
    raise exception using message = format(
      'Two further settlement passes over one Failed Week enqueued %s notifications.', v_count);
  end if;

  raise notice using message = 'Step 8 ok: further passes over an already-settled week changed nothing.';

  -- -------------------------------------------------------------------------------
  -- 9. AD-16, first guard — settlement off its schedule refuses.
  -- -------------------------------------------------------------------------------
  begin
    perform public.settle_week(v_period);
    v_raised := false;
  exception when others then
    v_raised := true;
  end;

  if not v_raised then
    raise exception using message =
      'AD-16: settle_week ran with no schedule marker and no override, and did not refuse.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 10. AD-16, second guard — the override is refused for the live doer account, by
  --     raising rather than by skipping that account.
  -- -------------------------------------------------------------------------------
  update public.profile set is_live_doer = true where id = v_live;

  begin
    perform public.settle_week(v_period, true);
    v_raised := false;
  exception when others then
    v_raised := true;
  end;

  if not v_raised then
    raise exception using message =
      'AD-16: an override was accepted while a live doer account existed. Only the '
      'schedule may settle it.';
  end if;

  update public.profile set is_live_doer = false where id = v_live;

  raise notice using message = 'Step 9-10 ok: both AD-16 guards refused.';

  -- -------------------------------------------------------------------------------
  -- 11. A commitment created after its own candidate period already elapsed is excluded
  --     entirely — the one guard settle_week has with no counterpart in settle_day.
  --     Without it, settle_due_weeks()'s two-week-wide sweep could charge a real penalty
  --     within the hour of creating a commitment, for a week that ended before it existed.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user8, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow,
          (v_period + 7 + time '10:00') at time zone 'Asia/Ho_Chi_Minh')
  returning id into v_c8;

  -- No declaration at all — the commitment did not exist for any day of v_period's week,
  -- so it could not have been held even once. Without the created_at guard this would
  -- settle `failed` (0 of 3) and charge a real penalty for a week it never had.
  perform public.settle_week(v_period, true);

  select count(*) into v_count
    from public.settlement
   where subject = v_user8 and period = v_period and kind = 'week';
  if v_count <> 0 then
    raise exception using message = format(
      'A commitment created after p_period already elapsed must be excluded entirely — no '
      'settlement row, no penalty for a week it never had a chance to meet. Found %s.', v_count);
  end if;

  raise notice using message =
    'Step 11 ok: a commitment created after its own candidate period elapsed is excluded '
    'entirely, never charged for a week it did not exist for.';

  -- -------------------------------------------------------------------------------
  -- 12. Two commitments falling short together -> the notification states the count and
  --     sums held/target across both, naming neither (Design Notes' own pluralization
  --     rule, untested until now).
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_userA, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow, v_backdate)
  returning id into v_ca1;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_userA, gen_random_uuid(), 'Swim', 'do', 'weekly_quota', true, 2, v_isodow, v_backdate)
  returning id into v_ca2;

  -- Gym: 1 of 3, short. Swim: 0 of 2, short. Both carry a penalty.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_userA, v_ca1, gen_random_uuid(), 'held',
          (v_period + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_week(v_period, true);

  select payload ->> 'body' into v_body
    from public.outbox
   where owner_id = v_userA
     and dedupe_key = 'week-' || v_userA::text || '-' || v_period::text;

  v_expected := '2 commitments fell short, 1 of 5 held, week of ' || v_day_label
    || '. That''s 500.000₫.';
  if v_body <> v_expected then
    raise exception using message = format(
      'Expected "%s", got "%s". Two shortfalls must state the count, sum held/target across '
      'both commitments, and name neither.', v_expected, v_body);
  end if;

  select missed_count into v_missed
    from public.settlement
   where subject = v_userA and period = v_period and kind = 'week' and supersedes is null;
  if v_missed <> 2 then
    raise exception using message = format(
      'Both shortfalls carry a penalty, so missed_count must be 2, not %s.', v_missed);
  end if;

  raise notice using message = format(
    'Step 12 ok: two commitments falling short together produce a pluralized, unnamed '
    'notification: "%s".', v_body);

  -- -------------------------------------------------------------------------------
  -- 13. settle_due_weeks() — the only entry point production ever calls — actually settles
  --     a just-closed week through its own sweep window and schedule marker, not merely
  --     through the p_override path every step above has used.
  -- -------------------------------------------------------------------------------
  v_period9 := v_today - 8; -- the closest-to-today edge of settle_due_weeks()'s own window

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day, created_at)
  values (v_user9, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 1,
          extract(isodow from v_period9)::integer,
          (v_period9 - 1 + time '00:00') at time zone 'Asia/Ho_Chi_Minh')
  returning id into v_c9;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user9, v_c9, gen_random_uuid(), 'held',
          (v_period9 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_due_weeks();

  -- settle_due_weeks() sets its own schedule marker with set_config(..., true) — local to
  -- the rest of this transaction, not to the call itself — so it is reset immediately after,
  -- or every settle_week() call from here on would silently stop needing an override.
  perform set_config('app.settlement_invocation', '', true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_user9 and period = v_period9 and kind = 'week' and supersedes is null;
  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'settle_due_weeks() must sweep today - 8 through the schedule path and settle it '
      '`clean` (1 of 1 held). Got `%s` (or no row at all).', v_verdict);
  end if;

  raise notice using message =
    'Step 13 ok: settle_due_weeks() settles a just-closed week through its own window and '
    'schedule marker.';

  raise notice using message =
    'PASS. A shortfall settles `failed` with one penalty, a met target settles `clean`, '
    'two commitments sharing a week_start_day still cost one penalty, a penalty-free '
    'shortfall costs nothing (but is still named), two commitments with different '
    'week_start_day settle independently, an archived commitment is excluded entirely, an '
    'open week settles nothing, a re-run changes nothing, both AD-16 guards hold, a '
    'commitment created after its period elapsed is excluded, two simultaneous shortfalls '
    'produce a pluralized unnamed notification, and settle_due_weeks() itself settles '
    'through its own schedule path.';
end $$;

rollback;
