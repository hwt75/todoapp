-- Story 5.4 — The long view, including whether this still works (FR-24).
--
-- Proves the server-side half of the spec's own I/O & Edge-Case Matrix: `penalty.collected_at`
-- stamped by `mark_penalty_collected()`; `appeal.ruled_at` stamped by `rule_appeal()` on both
-- the reject and the approve branch; and `commitment_answer_rate_for_month()`'s own per-day
-- summation against a known fixture -- a non-quota daily commitment, a weekly_quota commitment
-- (included, unlike `settle_day()`'s own admitted/silent counts), a `daily_hours_quota`
-- commitment (excluded entirely, the same way `commitments_owing()` always excludes it), a
-- commitment archived mid-month (asked only for the days before the archive), cross-account
-- isolation, and the function's own internal "requires an authenticated caller" guard. Every
-- other I/O Matrix row (the median/no-data folds) is pure TypeScript, already covered by
-- `lib/monthly-report.test.ts`.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/5-4-the-long-view-including-whether-this-still-works.sql
--
-- One transaction, rolled back at the end. Nothing persists.

begin;

-- The local stack's default privileges differ from the author's own project (recorded in
-- `2-1-roles-and-rls.sql`'s own header) -- `mark_penalty_collected`/`rule_appeal`/
-- `commitment_answer_rate_for_month`'s own EXECUTE grants to `authenticated` are written into
-- their migrations and need nothing extra here, but the ordinary table reads/writes this
-- fixture exercises through RLS still do.
grant select on table public.profile to authenticated;
grant select, insert on table public.appeal, public.declaration to authenticated;
grant select on public.penalty, public.settlement, public.settlement_commitment, public.commitment,
  public.penalty_current, public.settlement_current to authenticated;

do $$
declare
  -- Account 1: mark_penalty_collected() stamps collected_at.
  v_user1        uuid := gen_random_uuid();
  v_c1           uuid;

  -- Account 2: rule_appeal(approved => false) stamps ruled_at on the reject branch.
  v_user2        uuid := gen_random_uuid();
  v_c2           uuid;

  -- Account 3: rule_appeal(approved => true) stamps ruled_at on the approve branch too.
  v_user3        uuid := gen_random_uuid();
  v_c3           uuid;

  -- Account 4: commitment_answer_rate_for_month()'s own fixture.
  v_user4        uuid := gen_random_uuid();
  v_c4_daily     uuid; -- non-quota daily, carries_penalty
  v_c4_weekly    uuid; -- weekly_quota -- included, unlike settle_day()'s admitted/silent
  v_c4_hours     uuid; -- daily_hours_quota -- excluded entirely, same as commitments_owing()
  v_c4_archived  uuid; -- archived mid-month -- asked only for the days before the archive

  -- Account 5: cross-account isolation for the RPC.
  v_user5        uuid := gen_random_uuid();
  v_c5           uuid;

  v_referee      uuid := gen_random_uuid();

  v_day          date;

  v_settlement1  uuid;
  v_penalty1     uuid;

  v_settlement2  uuid;
  v_penalty2     uuid;
  v_appeal2      uuid;

  v_settlement3  uuid;
  v_penalty3     uuid;
  v_appeal3      uuid;

  v_month        date;
  v_days_in_month integer;
  v_archive_day  date;

  v_state        public.penalty_state;
  v_collected_at timestamptz;
  v_ruled_at     timestamptz;
  v_count        integer;
  v_asked        integer;
  v_answered     integer;
  v_refused      boolean;
  v_message      text;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- Fixture: five doer accounts, one referee.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-5-4-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user1, v_user2, v_user3, v_user4, v_user5, v_referee]) as t(id);

  update public.profile set role = 'referee' where id = v_referee;

  -- -------------------------------------------------------------------------------
  -- 1. penalty.collected_at, stamped by mark_penalty_collected() alongside the state
  --    transition -- one write, so a penalty can never read `collected` with `collected_at`
  --    still null.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user1, gen_random_uuid(), 'Reading', 'do', 'daily', true)
  returning id into v_c1;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user1, v_c1, gen_random_uuid(), 'slipped', now());

  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
  -- This fixture creates its commitments moments before judging days that predate them, which is
  -- a state no real account can reach — so it now says when they began. Order-preserving, so
  -- every created_at comparison downstream reads the same way, and idempotent, so the repeats
  -- below (each covering commitments created after the previous pass) age nothing twice.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day, true);

  select id into v_settlement1 from public.settlement
   where subject = v_user1 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty1 from public.penalty where settlement_id = v_settlement1;

  if v_penalty1 is null then
    raise exception using message = 'Fixture setup failed: account 1''s day did not settle Failed.';
  end if;

  select collected_at into v_collected_at from public.penalty where id = v_penalty1;
  if v_collected_at is not null then
    raise exception using message = 'A fresh owed Penalty must read collected_at null.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.mark_penalty_collected(v_penalty1);

  perform set_config('role', 'postgres', true);

  select state, collected_at into v_state, v_collected_at
    from public.penalty where id = v_penalty1;
  if v_state <> 'collected' then
    raise exception using message = format(
      'Account 1''s penalty reads `%s` after Mark Collected, expected `collected`.', v_state);
  end if;
  if v_collected_at is null then
    raise exception using message =
      'mark_penalty_collected() moved the penalty to collected but left collected_at null.';
  end if;
  if v_collected_at < now() - interval '1 minute' or v_collected_at > now() then
    raise exception using message = format(
      'collected_at (%s) is not within the last minute of now() (%s) -- expected the stamp '
      'and the state transition to land in the same statement.', v_collected_at, now());
  end if;

  raise notice using message =
    'Step 1 ok: mark_penalty_collected() stamps collected_at in the same update as the '
    'state -> collected transition.';

  -- -------------------------------------------------------------------------------
  -- 1b. collected_at, readable through penalty_current -- the view components/monthly-
  --     report.tsx's own "collected" query actually reads, never only the base table.
  --     `penalty_current` is `select p.*, s.kind, s.period ...`, and `p.*` is expanded and
  --     frozen at `create or replace view` time -- a regression that adds a column to
  --     `penalty` without also redeclaring this view would leave `collected_at` invisible
  --     here while step 1 above (reading the base table directly) kept passing regardless.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user1, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select collected_at into v_collected_at
    from public.penalty_current where id = v_penalty1;

  perform set_config('role', 'postgres', true);

  if v_collected_at is null then
    raise exception using message =
      'penalty_current.collected_at read null for account 1''s just-collected penalty -- '
      'either the view was never redeclared after collected_at was added to penalty (p.* '
      'frozen at the earlier create-or-replace), or RLS/security_invoker is hiding it.';
  end if;

  select count(*) into v_count
    from public.penalty_current where collected_at is not null;
  if v_count < 1 then
    raise exception using message = format(
      'select ... from penalty_current where collected_at is not null found %s row(s), '
      'expected at least 1 -- the column must be selectable and filterable through this '
      'view exactly as components/monthly-report.tsx''s own query does it.', v_count);
  end if;

  raise notice using message =
    'Step 1b ok: collected_at is readable (and filterable) through penalty_current, not '
    'only the base penalty table.';

  -- -------------------------------------------------------------------------------
  -- 2. appeal.ruled_at, stamped on the reject branch ("He didn't").
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user2, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-2')
  returning id into v_c2;

  perform public.file_auto_check_result(v_c2, v_user2, 'missed');
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day, true);

  select id into v_settlement2 from public.settlement
   where subject = v_user2 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty2 from public.penalty where settlement_id = v_settlement2;

  if v_penalty2 is null then
    raise exception using message = 'Fixture setup failed: account 2''s day did not settle Failed.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user2, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user2, v_c2, gen_random_uuid(), v_day)
  returning id into v_appeal2;

  select ruled_at into v_ruled_at from public.appeal where id = v_appeal2;
  if v_ruled_at is not null then
    raise exception using message = 'A freshly filed appeal must read ruled_at null.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.rule_appeal(v_appeal2, false);

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty2;
  if v_state <> 'owed' then
    raise exception using message = format(
      'Account 2''s penalty reads `%s` after a rejected appeal, expected `owed`.', v_state);
  end if;

  select ruled_at into v_ruled_at from public.appeal where id = v_appeal2;
  if v_ruled_at is null then
    raise exception using message =
      'rule_appeal(approved => false) resolved the appeal but left ruled_at null.';
  end if;
  if v_ruled_at < now() - interval '1 minute' or v_ruled_at > now() then
    raise exception using message = format(
      'ruled_at (%s) is not within the last minute of now() (%s).', v_ruled_at, now());
  end if;

  raise notice using message =
    'Step 2 ok: rule_appeal(approved => false) stamps ruled_at on the reject branch.';

  -- -------------------------------------------------------------------------------
  -- 3. appeal.ruled_at, stamped on the approve branch too ("He did it") -- both branches
  --    read as the same rule, never one remembering the stamp and the other not.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user3, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-3')
  returning id into v_c3;

  perform public.file_auto_check_result(v_c3, v_user3, 'missed');
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day, true);

  select id into v_settlement3 from public.settlement
   where subject = v_user3 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty3 from public.penalty where settlement_id = v_settlement3;

  if v_penalty3 is null then
    raise exception using message = 'Fixture setup failed: account 3''s day did not settle Failed.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user3, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user3, v_c3, gen_random_uuid(), v_day)
  returning id into v_appeal3;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.rule_appeal(v_appeal3, true);

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty3;
  if v_state <> 'voided' then
    raise exception using message = format(
      'Account 3''s penalty reads `%s` after an approved appeal, expected `voided`.', v_state);
  end if;

  select ruled_at into v_ruled_at from public.appeal where id = v_appeal3;
  if v_ruled_at is null then
    raise exception using message =
      'rule_appeal(approved => true) resolved the appeal but left ruled_at null -- the '
      'approve branch must stamp it exactly as the reject branch does.';
  end if;
  if v_ruled_at < now() - interval '1 minute' or v_ruled_at > now() then
    raise exception using message = format(
      'ruled_at (%s) is not within the last minute of now() (%s).', v_ruled_at, now());
  end if;

  raise notice using message =
    'Step 3 ok: rule_appeal(approved => true) stamps ruled_at on the approve branch too.';

  -- -------------------------------------------------------------------------------
  -- 4. commitment_answer_rate_for_month(): per-day summation against a known fixture.
  --    v_month is the live current month (Asia/Ho_Chi_Minh) -- the function itself takes any
  --    month, and this keeps the test independent of which month it happens to run in.
  -- -------------------------------------------------------------------------------
  v_month := date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_days_in_month := (v_month + interval '1 month' - interval '1 day')::date - v_month + 1;
  v_archive_day := v_month + 5; -- the 6th day of the month

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user4, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c4_daily;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day)
  values (v_user4, gen_random_uuid(), 'No fap', 'abstain', 'weekly_quota', true, 3, 1)
  returning id into v_c4_weekly;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 daily_minutes_target)
  values (v_user4, gen_random_uuid(), 'Focus hours', 'do', 'daily_hours_quota', false, 60)
  returning id into v_c4_hours;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user4, gen_random_uuid(), 'Journaling', 'do', 'daily', true)
  returning id into v_c4_archived;

  update public.commitment
     set archived_at = (v_archive_day::timestamp + interval '10 hours') at time zone 'Asia/Ho_Chi_Minh'
   where id = v_c4_archived;

  -- v_c4_daily: answered on the month's first two days, silent every other day.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    (v_user4, v_c4_daily, gen_random_uuid(), 'held',
      ((v_month + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user4, v_c4_daily, gen_random_uuid(), 'held',
      ((v_month + 2)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');

  -- v_c4_weekly: answered once, on the month's first day -- weekly_quota is still asked
  -- daily and can still be declared held (only settle_day()'s own admitted/silent counts
  -- exclude it, not commitments_owing() itself).
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user4, v_c4_weekly, gen_random_uuid(), 'held',
    ((v_month + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');

  -- v_c4_archived: answered once, on the month's first day, safely inside its own
  -- pre-archive window.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user4, v_c4_archived, gen_random_uuid(), 'held',
    ((v_month + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');

  -- A second account, isolated, to prove the RPC never crosses accounts.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user5, gen_random_uuid(), 'Reading', 'do', 'daily', true)
  returning id into v_c5;

  -- Fixture ageing again, for account 4's and 5's commitments (see the note above). This step
  -- counts a commitment as asked on every day of the month, which since Story 6.4 is only true
  -- of a commitment that existed for every one of them.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user4, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  -- 4a. The non-quota daily commitment: asked every day of the month, answered on 2.
  select asked, answered into v_asked, v_answered
    from public.commitment_answer_rate_for_month(v_month)
   where commitment_id = v_c4_daily;
  if v_asked <> v_days_in_month or v_answered <> 2 then
    raise exception using message = format(
      'v_c4_daily read asked=%s answered=%s, expected asked=%s (every day this month) '
      'answered=2 (the two declared days).', v_asked, v_answered, v_days_in_month);
  end if;

  -- 4b. The weekly_quota commitment: included, asked every day, answered on 1 -- proves this
  --     RPC does not carry settle_day()'s own weekly_quota exclusion.
  select asked, answered into v_asked, v_answered
    from public.commitment_answer_rate_for_month(v_month)
   where commitment_id = v_c4_weekly;
  if v_asked <> v_days_in_month or v_answered <> 1 then
    raise exception using message = format(
      'v_c4_weekly read asked=%s answered=%s, expected asked=%s answered=1 -- weekly_quota '
      'must be included, unlike settle_day()''s own admitted/silent counts.',
      v_asked, v_answered, v_days_in_month);
  end if;

  -- 4c. daily_hours_quota: excluded entirely, the same way commitments_owing() always
  --     excludes it -- no row at all, not a row reading asked=0.
  select count(*) into v_count
    from public.commitment_answer_rate_for_month(v_month)
   where commitment_id = v_c4_hours;
  if v_count <> 0 then
    raise exception using message = format(
      'v_c4_hours (daily_hours_quota) read %s row(s), expected 0 -- FR-2 excludes it '
      'entirely, never a row with asked=0.', v_count);
  end if;

  -- 4d. Archived mid-month: asked only for the days strictly before the archive day (5 of
  --     them), answered on the 1 declared inside that window.
  select asked, answered into v_asked, v_answered
    from public.commitment_answer_rate_for_month(v_month)
   where commitment_id = v_c4_archived;
  if v_asked <> 5 or v_answered <> 1 then
    raise exception using message = format(
      'v_c4_archived read asked=%s answered=%s, expected asked=5 (the days before its own '
      'archive day) answered=1.', v_asked, v_answered);
  end if;

  -- 4e. Cross-account isolation: v_user4's own call never returns v_user5's commitment.
  select count(*) into v_count
    from public.commitment_answer_rate_for_month(v_month)
   where commitment_id = v_c5;
  if v_count <> 0 then
    raise exception using message = format(
      'v_user4''s own call to commitment_answer_rate_for_month() returned %s row(s) for '
      'v_user5''s commitment -- auth.uid() must scope this, never a client-supplied owner.',
      v_count);
  end if;

  -- 4f. The reverse: v_user5's own call sees only its own commitment.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user5, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select asked into v_asked
    from public.commitment_answer_rate_for_month(v_month)
   where commitment_id = v_c5;
  if v_asked <> v_days_in_month then
    raise exception using message = format(
      'v_user5''s own call read asked=%s for its own commitment, expected %s.',
      v_asked, v_days_in_month);
  end if;

  select count(*) into v_count
    from public.commitment_answer_rate_for_month(v_month)
   where commitment_id in (v_c4_daily, v_c4_weekly, v_c4_archived);
  if v_count <> 0 then
    raise exception using message = format(
      'v_user5''s own call returned %s row(s) for v_user4''s commitments -- cross-account '
      'leak.', v_count);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 4 ok: commitment_answer_rate_for_month() sums asked/answered per commitment across '
    'the whole month -- daily_hours_quota excluded entirely, weekly_quota included, an '
    'archived commitment asked only for its own pre-archive days, and auth.uid() scopes every '
    'call to the caller''s own account, never a client-supplied owner.';

  -- -------------------------------------------------------------------------------
  -- 5. The function's own internal guard: a caller with no resolvable auth.uid() (here, the
  --    postgres role with no request.jwt.claims set) is refused with a specific message --
  --    never a silent empty result standing in for "not authenticated".
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', '', true);

  v_refused := false;
  begin
    perform count(*) from public.commitment_answer_rate_for_month(v_month);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%authenticated caller%' then
    raise exception using message = format(
      'A call with no resolvable auth.uid() read "%s", expected the '
      '"requires an authenticated caller" refusal.', coalesce(v_message, '<null>'));
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 5 ok: a caller with no resolvable auth.uid() is refused with a specific message, '
    'never a silent empty result.';

  raise notice using message =
    'PASS. mark_penalty_collected() and rule_appeal() (both branches) stamp their own new '
    'timestamp columns in the same statement as their state transition, and '
    'commitment_answer_rate_for_month() sums asked/answered correctly per commitment against '
    'a known fixture, excluding daily_hours_quota, including weekly_quota, respecting an '
    'archive mid-month, and scoping every call to the caller''s own account.';
end $$;

rollback;
