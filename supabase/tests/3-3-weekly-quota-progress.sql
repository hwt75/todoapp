-- Story 3.3 — the view that sums a week's declarations, and the formula behind its days left.
--
-- `weekly_target` and `week_start_day` have sat on `commitment` unread since Story 2.2, and a
-- Weekly Quota commitment has answered the same Declaration a Daily one does since Story 2.4 —
-- but nothing ever summed those answers into a week's standing. This is the sum, and this file
-- is what proves it: the D1 formula against both of `EXPERIENCE.md` KF-6's own numbers and a
-- non-Monday week start, the view's held count crossing from unmet to met, archived exclusion,
-- and cross-account isolation.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/3-3-weekly-quota-progress.sql
--
-- One transaction, rolled back at the end. It writes no observation the author would have to
-- have made — every declaration below belongs to a throwaway account created in this file — so,
-- unlike 3-1 and 3-2, it carries no live-doer guard: nothing here loops over every doer account
-- or could enqueue a real row for one.

begin;

-- The environment's grants, stated rather than assumed, for the reason `2-1-roles-and-rls.sql`
-- gives at length: on a local stack `authenticated` has SELECT on nothing, and no migration in
-- this repository creates those grants (recorded in deferred-work.md).
grant select on table public.profile to authenticated;
grant select, insert on table public.commitment to authenticated;
grant select, insert on table public.declaration to authenticated;
grant select on table public.weekly_quota_progress to authenticated;

do $$
declare
  v_user      uuid := gen_random_uuid();   -- the account whose week is under test
  v_other     uuid := gen_random_uuid();   -- a second account, for cross-account isolation
  v_gym       uuid;                        -- weekly_target 3, week_start_day 1 (Monday) — KF-6
  v_swim      uuid;                        -- weekly_target 2, week_start_day 5 (Friday)
  v_archived  uuid;                        -- weekly_target 3, archived from the start
  v_foreign   uuid;                        -- the other account's own weekly quota
  v_today     date;
  v_isodow    integer;
  v_thursday  date;
  v_saturday  date;
  v_held      integer;
  v_days      integer;
  v_count     integer;
  v_expected_days integer;  -- week_days_remaining(today, 1), named once so every later
                             -- assertion compares against the same captured value rather than
                             -- a fresh call that could silently drift from it.
begin
  v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_isodow := extract(isodow from v_today)::integer;
  v_expected_days := public.week_days_remaining(v_today, 1);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-3-3-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user, v_other]) as t(id);

  -- -------------------------------------------------------------------------------
  -- 1. D1's formula, checked directly against both of KF-6's own numbers.
  --
  -- Thursday reads "3 days remaining," Saturday reads "1 day remaining," week_start_day = 1.
  -- These are computed from today's own weekday rather than hardcoded to a fixed calendar date,
  -- so the assertion holds no matter which real day this file happens to run on.
  -- -------------------------------------------------------------------------------
  v_thursday := v_today + (4 - v_isodow);
  v_saturday := v_today + (6 - v_isodow);

  if public.week_days_remaining(v_thursday, 1) <> 3 then
    raise exception using message = format(
      'week_days_remaining(Thursday, 1) reads %s rather than 3. EXPERIENCE.md KF-6: one gym '
      'session done on a Thursday reads "3 days remaining."',
      public.week_days_remaining(v_thursday, 1));
  end if;

  if public.week_days_remaining(v_saturday, 1) <> 1 then
    raise exception using message = format(
      'week_days_remaining(Saturday, 1) reads %s rather than 1. EXPERIENCE.md KF-6: by '
      'Saturday morning it reads "1 day remaining."',
      public.week_days_remaining(v_saturday, 1));
  end if;

  raise notice using message =
    'Step 1 ok: week_days_remaining matches both of KF-6''s own numbers.';

  -- -------------------------------------------------------------------------------
  -- 2. The same formula, verified rather than re-guessed for a week that does not start on
  --    Monday. A Monday-start week's 6th day is Saturday, one day short of the end (Sunday).
  --    A Friday-start week's 6th day (Fri=1, Sat=2, Sun=3, Mon=4, Tue=5, Wed=6, Thu=7) is
  --    Wednesday — the same position, one day short of that week's own end (Thursday).
  -- -------------------------------------------------------------------------------
  declare
    v_wednesday date := v_today + (3 - v_isodow);  -- this week's 6th day, Friday-start numbering
  begin
    if public.week_days_remaining(v_wednesday, 5) <> public.week_days_remaining(v_saturday, 1)
    then
      raise exception using message = format(
        'A Friday-start week''s own Wednesday — its 6th day, the same position Saturday is in '
        'a Monday-start week — read %s days remaining rather than %s. The formula must not be '
        're-derived per start day.',
        public.week_days_remaining(v_wednesday, 5), public.week_days_remaining(v_saturday, 1));
    end if;
  end;

  raise notice using message =
    'Step 2 ok: a Friday-start week reads days remaining by the same formula, not a re-guess.';

  -- -------------------------------------------------------------------------------
  -- Fixtures for the view itself: three commitments on the primary account, one on another.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day)
  values (v_user, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', 3, 1)
  returning id into v_gym;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day)
  values (v_user, gen_random_uuid(), 'Swim', 'do', 'weekly_quota', 2, 5)
  returning id into v_swim;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day, archived_at)
  values (v_user, gen_random_uuid(), 'Archived quota', 'do', 'weekly_quota', 3, 1, now())
  returning id into v_archived;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 weekly_target, week_start_day)
  values (v_other, gen_random_uuid(), 'Somebody else''s gym', 'do', 'weekly_quota', 3, 1)
  returning id into v_foreign;

  -- -------------------------------------------------------------------------------
  -- 3. Nothing held yet: the view reads 0 against the target, with the same days-remaining
  --    formula, and the archived commitment never appears at all.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  perform set_config('role', 'authenticated', true);

  select held, days_remaining into v_held, v_days
    from public.weekly_quota_progress
   where commitment_id = v_gym;

  if v_held <> 0 then
    raise exception using message = format(
      'A fresh week read %s held rather than 0.', v_held);
  end if;

  if v_days <> v_expected_days then
    raise exception using message = format(
      'The view''s days_remaining (%s) disagreed with week_days_remaining(today, 1) (%s) for '
      'the same commitment on the same day.', v_days, v_expected_days);
  end if;

  select count(*) into v_count
    from public.weekly_quota_progress
   where commitment_id = v_archived;

  if v_count <> 0 then
    raise exception using message =
      'An archived Weekly Quota commitment appeared in weekly_quota_progress. archived_at is '
      'not null must exclude it from the view, the same as it excludes a row from the Today '
      'row.';
  end if;

  raise notice using message =
    'Step 3 ok: a fresh week reads 0 held, matches week_days_remaining directly, and the '
    'archived commitment never appears.';

  -- -------------------------------------------------------------------------------
  -- 4. A second Weekly Quota commitment on the same account reads its own position
  --    independently — different target, different week start, unaffected by its sibling.
  -- -------------------------------------------------------------------------------
  select held, target, days_remaining into v_held, v_count, v_days
    from public.weekly_quota_progress
   where commitment_id = v_swim;

  if v_held <> 0 or v_count <> 2 then
    raise exception using message = format(
      'Swim read held=%s target=%s rather than 0 and 2. Each Weekly Quota commitment must read '
      'its own view row independently of any other on the same account.', v_held, v_count);
  end if;

  -- Its days_remaining must come from *its own* week_start_day (5, Friday) rather than the
  -- gym's (1, Monday) — proof the view reads the column per row instead of one shared value.
  -- The two start days are 4 apart, never a multiple of 7, so the formula guarantees these
  -- differ on every possible today — this is not a coincidence of which day the suite runs on.
  if v_days = v_expected_days then
    raise exception using message = format(
      'Swim (week_start_day 5) read the same days_remaining (%s) as Gym (week_start_day 1). '
      'The view must derive this per commitment, not once for the whole account.', v_days);
  end if;

  raise notice using message =
    'Step 4 ok: a second commitment on the same account reads its own row independently, '
    'including its own week_start_day.';

  -- -------------------------------------------------------------------------------
  -- 5. The count crosses from unmet to met as declarations land inside this week, and stays
  --    within the week's own boundary rather than counting a day from the week before or after.
  --
  -- This week's Monday through Sunday is derived the same way the view derives it, so the
  -- fixture lands correctly regardless of which real day this file runs on.
  -- -------------------------------------------------------------------------------
  declare
    v_week_start date := v_today - ((v_isodow - 1 + 7) % 7);  -- this week's Monday, gym's start
    v_day1 date := v_week_start;       -- inside the week, held — must count
    v_day2 date := v_week_start + 1;   -- inside the week, slipped — must not count
    v_before date := v_week_start - 1; -- last day of the *previous* week, held — must not count
  begin
    -- `declaration.for_day` is derived by a trigger from `answered_at` (a declaration answers
    -- for the day before), so the instant sent is the morning after the day being declared for.
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values
      (v_user, v_gym, gen_random_uuid(), 'held',
       (v_day1 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
      (v_user, v_gym, gen_random_uuid(), 'slipped',
       (v_day2 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
      (v_user, v_gym, gen_random_uuid(), 'held',
       (v_before + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

    select held into v_held from public.weekly_quota_progress where commitment_id = v_gym;

    if v_held <> 1 then
      raise exception using message = format(
        'One qualifying day inside the week read %s rather than 1. A slipped answer inside '
        'the week, and a held answer from the week before, must both be excluded.', v_held);
    end if;

    raise notice using message =
      'Step 5a ok: one qualifying day inside the week reads 1; a slip inside the week and a '
      'held day from the previous week are both excluded.';

    -- Two more held days close the gap: 3 of 3, target met mid-week. Fresh days — v_day2
    -- already carries the slipped declaration above, and `declaration_one_per_commitment_day`
    -- refuses a second answer for the same commitment on the same day.
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values
      (v_user, v_gym, gen_random_uuid(), 'held',
       (v_week_start + 2 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'),
      (v_user, v_gym, gen_random_uuid(), 'held',
       (v_week_start + 3 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

    select held, target into v_held, v_count
      from public.weekly_quota_progress where commitment_id = v_gym;

    if v_held <> 3 or v_count <> 3 then
      raise exception using message = format(
        'After three qualifying days the view read held=%s target=%s rather than 3 and 3. The '
        'count must cross from unmet to met as declarations land, with nothing recomputed by '
        'the client.', v_held, v_count);
    end if;

    raise notice using message =
      'Step 5b ok: the count crosses from unmet to met as qualifying declarations land.';

    -- The upper edge of the same window. `v_before` above proved the day just *before*
    -- `week_start` is excluded; this is its mirror — a held day landing on `week_start + 7`,
    -- the *next* week's first day. The view's own `for_day < w.week_start + 7` condition is a
    -- strict `<`, so this is the first day that must NOT count, one day past the last one that
    -- does (day 3, held two steps above).
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_user, v_gym, gen_random_uuid(), 'held',
            (v_week_start + 7 + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

    select held into v_held from public.weekly_quota_progress where commitment_id = v_gym;

    if v_held <> 3 then
      raise exception using message = format(
        'After a held declaration landed on week_start + 7 — the next week''s first day — the '
        'view read held=%s rather than staying at 3. The window''s upper edge is a strict "<", '
        'not "<=", and a day just past it must not count toward this week.', v_held);
    end if;
  end;

  raise notice using message =
    'Step 5c ok: a held day on the next week''s first day (week_start + 7) does not count '
    'toward this week — the upper edge of the window is exclusive.';

  perform set_config('role', 'postgres', true);

  -- -------------------------------------------------------------------------------
  -- 6. Cross-account isolation: each account's view rows are scoped to itself (RLS), filtered
  --    to zero rather than refused — a refusal would confirm the row exists.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  perform set_config('role', 'authenticated', true);

  select count(*) into v_count
    from public.weekly_quota_progress
   where commitment_id in (v_gym, v_swim, v_archived);

  if v_count <> 0 then
    raise exception using message = format(
      'The other account read %s rows belonging to the primary account through '
      'weekly_quota_progress. security_invoker must scope every row through RLS on '
      'commitment and declaration, exactly as focus_day_minutes and chain_current already do.',
      v_count);
  end if;

  select count(*) into v_count
    from public.weekly_quota_progress
   where commitment_id = v_foreign;

  if v_count <> 1 then
    raise exception using message = format(
      'The other account read %s rows of its own commitment rather than 1.', v_count);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 6 ok: each account''s view rows are scoped to itself.';

  raise notice using message =
    'PASS. week_days_remaining matches both of KF-6''s numbers and a Friday-start week by the '
    'same formula; weekly_quota_progress excludes archived commitments, tracks two '
    'commitments under one account independently, crosses from unmet to met as declarations '
    'land inside the week and only inside it, and scopes every row to its own account.';
end $$;

rollback;
