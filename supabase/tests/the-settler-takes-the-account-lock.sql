-- The settler takes the account lock, and every correction writer reads under it
-- (20261005090000).
--
-- What one session can prove, and what it cannot. The lock itself is only visible to a second
-- session, so the waits are proved by scripts/test-settlement-lock.mjs and
-- scripts/test-sign-off-race.mjs. This file proves the three things a single transaction can see:
--
--   1. Each of the four writers carries the account key in its live definition -- a guard
--      against a later `create or replace` that drops it silently, not the proof of a wait.
--   2. A Grace Day correction copies the frozen rows of the settlement it forgives, never a live
--      reading of commitments_owing() (Epic 6 retrospective item 44). A commitment that has
--      since dropped out of the live reading still comes back `held`, and one that has since
--      entered it does not appear.
--   3. supersede_expiries() leaves an expired day alone once its Penalty is no longer owed, and
--      still corrects one beside it whose Penalty is owed -- so the refusal is the guard, not a
--      fixture that never corrects anything.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/the-settler-takes-the-account-lock.sql
--
-- One transaction, rolled back at the end.

begin;

-- =================================================================================
-- Step 1: the key, in each writer.
-- =================================================================================
do $$
declare
  v_name text;
begin
  foreach v_name in array array[
    'public.settle_day(date, boolean)',
    'public.supersede_expiries()',
    'public.apply_grace_days()',
    'public.sign_off_day(uuid, date, boolean, text)'
  ] loop
    if pg_get_functiondef(v_name::regprocedure) not like '%pg_advisory_xact_lock(hashtext(%' then
      raise exception using message = format(
        '%s no longer takes the per-account advisory lock. Every writer of a day''s settlement '
        'or of the decision that settles it must take the same key, or the settler can read a '
        'day half-written (20261005090000).', v_name);
    end if;
  end loop;

  raise notice using message = 'Step 1 ok: all four writers carry the account key.';
end $$;

do $$
declare
  -- Fixture, step 2
  v_g           uuid := gen_random_uuid();
  v_slipped     uuid; -- A: the miss the Grace Day forgives
  v_archived    uuid; -- B: held that day, archived afterwards with a backdated instant
  v_newcomer    uuid; -- C: enters the live reading of that day after it settled
  v_day         date;
  v_original    uuid;

  -- Fixture, step 3
  v_e           uuid := gen_random_uuid(); -- an expired day whose Penalty was collected
  v_control     uuid := gen_random_uuid(); -- the same day, its Penalty still owed
  v_e_c         uuid;
  v_control_c   uuid;
  v_eday        date;
  v_e_original  uuid;
  v_control_original uuid;

  -- Observed
  v_correction  uuid;
  v_verdict     public.day_verdict;
  v_count       integer;
  v_held        integer;
  v_returned    integer;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'settler-lock-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_g, v_e, v_control]) as t(id);

  -- ===============================================================================
  -- Step 2: a Grace Day forgives the day the settlement froze, not the day as it reads now.
  -- ===============================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_g, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_slipped;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_g, gen_random_uuid(), 'No sugar', 'abstain', 'daily', true)
  returning id into v_archived;

  -- Two days back, so the morning the declarations are stamped is safely in the past at any
  -- hour this runs (5-1-a-countable-way-to-be-forgiven.sql's own reasoning).
  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 2;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    (v_g, v_slipped, gen_random_uuid(), 'slipped',
     ((v_day + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_g, v_archived, gen_random_uuid(), 'held',
     ((v_day + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');

  -- Story 6.4's fixture ageing: nothing is judged for a day before it existed.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day, true);

  select id, verdict into v_original, v_verdict
    from public.settlement
   where subject = v_g and period = v_day and kind = 'day' and supersedes is null;

  if v_original is null or v_verdict <> 'failed' then
    raise exception using message = format(
      'Fixture setup failed: account G''s day settled `%s`, expected `failed`.',
      coalesce(v_verdict::text, '<none>'));
  end if;

  -- The live reading moves in both directions after the day settled. Constructed states, set as
  -- postgres: the point is to pin which source the correction reads (6-7-the-referee-may-object.sql
  -- step 12 does the same for object_to_day()), and a recompute fails both.
  update public.commitment set archived_at = public.day_begins_at(v_day) where id = v_archived;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_g, gen_random_uuid(), 'Read', 'abstain', 'daily', false)
  returning id into v_newcomer;
  update public.commitment set created_at = created_at - interval '90 days' where id = v_newcomer;

  if exists (select 1 from public.commitments_owing(v_g, v_day) o where o.commitment_id = v_archived)
     or not exists (
       select 1 from public.commitments_owing(v_g, v_day) o where o.commitment_id = v_newcomer)
  then
    raise exception using message =
      'Fixture setup failed: the live reading of account G''s day did not move as staged, so '
      'step 2 would prove nothing.';
  end if;

  insert into public.grace_day (owner_id, for_day) values (v_g, v_day);
  perform public.apply_grace_days();

  select id, verdict into v_correction, v_verdict
    from public.settlement where supersedes = v_original;

  if v_correction is null or v_verdict <> 'clean' then
    raise exception using message = format(
      'Account G''s Grace Day left correction %s reading `%s`, expected a `clean` correction.',
      v_correction, coalesce(v_verdict::text, '<none>'));
  end if;

  select count(*), count(*) filter (where outcome = 'held') into v_count, v_held
    from public.settlement_commitment where settlement_id = v_correction;

  if v_count <> 2 or v_held <> 2
     or not exists (select 1 from public.settlement_commitment
                     where settlement_id = v_correction and commitment_id = v_slipped)
     or not exists (select 1 from public.settlement_commitment
                     where settlement_id = v_correction and commitment_id = v_archived)
  then
    raise exception using message = format(
      'The Grace Day correction froze %s row(s), %s held. Expected exactly the two the forgiven '
      'settlement froze, both `held`: the archived commitment must come back with the day, and '
      'the commitment that entered the live reading afterwards must not be added to it. A '
      'correction rebuilt from commitments_owing() fails both (Epic 6 retrospective item 44).',
      v_count, v_held);
  end if;

  raise notice using message =
    'Step 2 ok: the Grace Day correction is the frozen day, every row held, nothing added.';

  -- ===============================================================================
  -- Step 3: an expiry whose Penalty was collected stands; its owed neighbour is corrected.
  -- ===============================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_e, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_e_c;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_control, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_control_c;

  -- Four days back, so the untimed deadline has passed and the day genuinely expires
  -- (2-7-supersession.sql's reasoning).
  v_eday := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 4;

  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_eday, true);

  select id into v_e_original from public.settlement
   where subject = v_e and period = v_eday and kind = 'day' and verdict = 'expired'
     and supersedes is null;
  select id into v_control_original from public.settlement
   where subject = v_control and period = v_eday and kind = 'day' and verdict = 'expired'
     and supersedes is null;

  if v_e_original is null or v_control_original is null
     or (select count(*) from public.penalty
          where settlement_id in (v_e_original, v_control_original) and state = 'owed') <> 2
  then
    raise exception using message =
      'Fixture setup failed: both accounts'' days should have expired with an owed Penalty.';
  end if;

  -- The referee collected account E's. Set directly: the collector's own path is
  -- 4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql's subject, and what this step
  -- asks is only what the pass does once that has happened.
  update public.penalty set state = 'collected', collected_at = now()
   where settlement_id = v_e_original;

  -- The answers both authors gave in time, delivered late: the morning after, inside the deadline.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    (v_e, v_e_c, gen_random_uuid(), 'slipped',
     ((v_eday + 1)::timestamp + interval '7 hours 31 minutes') at time zone 'Asia/Ho_Chi_Minh'),
    (v_control, v_control_c, gen_random_uuid(), 'slipped',
     ((v_eday + 1)::timestamp + interval '7 hours 31 minutes') at time zone 'Asia/Ho_Chi_Minh');

  v_returned := public.supersede_expiries();

  if exists (select 1 from public.settlement where supersedes = v_e_original) then
    raise exception using message =
      'supersede_expiries() rewrote an expired day whose Penalty had already been collected. '
      'The collected Penalty drops out of penalty_current and an owed one is minted beside it -- '
      'money that changed hands, charged again by a pass.';
  end if;

  if (select state from public.penalty where settlement_id = v_e_original) <> 'collected' then
    raise exception using message = 'Account E''s collected Penalty changed state.';
  end if;

  select id, verdict into v_correction, v_verdict
    from public.settlement where supersedes = v_control_original;

  if v_returned <> 1 or v_correction is null or v_verdict <> 'failed' then
    raise exception using message = format(
      'supersede_expiries() returned %s and corrected the owed control day to `%s`. Expected '
      'exactly one correction, `failed` -- without it the refusal above proves nothing.',
      v_returned, coalesce(v_verdict::text, '<none>'));
  end if;

  raise notice using message =
    'Step 3 ok: a collected expiry stands, and its owed neighbour is still corrected.';
  raise notice using message =
    'PASS. The Grace Day reads the frozen day, and the expiry pass leaves paid money alone.';
end $$;

rollback;
