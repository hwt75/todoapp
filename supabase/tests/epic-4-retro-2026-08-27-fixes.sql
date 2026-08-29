-- Epic 4 retrospective (2026-08-27) — regression coverage for the action items this retro
-- confirmed by direct code inspection. None of these had a test before this file:
--
--   1. `commitment_carries_penalty_off_ends_appeal()` (finding A2) -- FR-2a's own documented
--      invariant, "turning a Penalty off on a commitment with a pending Appeal resolves that
--      Appeal in the author's favor immediately," had no implementation until this fix.
--   2. `appeal_hold_penalty()`'s `verdict = 'failed'` eligibility clause (finding A4a) --
--      real, present code, never exercised by any prior test.
--   3. `appeal_hold_penalty()`'s `carries_penalty` eligibility clause (finding A4b) -- same.
--   4. `rule_appeal()`/`mark_penalty_collected()`'s `role_from_table()` vs `role_from_token()`
--      choice (finding A5) -- no fixture before this one ever made a caller's token claim and
--      its `profile.role` row disagree.
--   5. `commitment_auto_check_not_on_hours_quota` (finding A7) -- a new constraint, its own
--      first test.
--   6. `evidence.captured_on` (finding A3, FR-14) -- a new column/trigger validation,
--      its own first test.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/epic-4-retro-2026-08-27-fixes.sql
--
-- One transaction, rolled back at the end. Nothing persists.

begin;

grant select on table public.profile to authenticated;
grant select, insert on table public.appeal, public.evidence to authenticated;

do $$
declare
  -- Step 1: the toggle-off-ends-appeal trigger, positive case.
  v_user1      uuid := gen_random_uuid();
  v_c1         uuid;
  v_appeal1    uuid;
  v_penalty1   uuid;

  -- Step 1b: the same trigger, no-op case (nothing held to resolve).
  v_user1b     uuid := gen_random_uuid();
  v_c1b        uuid;
  v_penalty1b  uuid;

  -- Step 2: appeal_hold_penalty()'s untested verdict = 'failed' guard.
  v_user2      uuid := gen_random_uuid();
  v_c2a        uuid; -- machine-filed missed, on record before the day closes
  v_c2b        uuid; -- stays silent, so the day closes `expired`, not `failed`
  v_day2       date;
  v_penalty2   uuid;

  -- Step 3: appeal_hold_penalty()'s untested carries_penalty guard.
  v_user3      uuid := gen_random_uuid();
  v_c3         uuid;
  v_penalty3   uuid;

  -- Step 4: role_from_table() vs role_from_token() — a spoofed token claiming `referee`
  -- for an account whose profile row genuinely reads `doer`. Two independent accounts (not
  -- one account with two commitments the same day, which FR-13's one-Penalty-per-day model
  -- would bundle into a single row) so rule_appeal()'s own held target and
  -- mark_penalty_collected()'s own owed target are unambiguously two different Penalties.
  v_target     uuid := gen_random_uuid(); -- rule_appeal()'s own target: appealed, held
  v_c4a        uuid;
  v_target2    uuid := gen_random_uuid(); -- mark_penalty_collected()'s own target: owed
  v_c4b        uuid;
  v_spoofer    uuid := gen_random_uuid(); -- a plain doer, never promoted, never paired
  v_day4       date;
  v_appeal4    uuid;
  v_penalty4a  uuid;
  v_penalty4b  uuid;

  v_refused    boolean;
  v_message    text;
  v_state      public.penalty_state;
  v_verdict    public.day_verdict;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- =================================================================================
  -- Step 1: turning carries_penalty off on a commitment with a held Penalty resolves
  -- the Appeal in the author's favor immediately (FR-2a, finding A2).
  -- =================================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-4r-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user1, v_user1b, v_user2, v_user3, v_target, v_target2, v_spoofer])
      as t(id);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user1, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-1')
  returning id into v_c1;

  perform public.file_auto_check_result(v_c1, v_user1, 'missed');
  -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
  -- This fixture creates its commitments moments before judging days that predate them, which is
  -- a state no real account can reach — so it now says when they began. Order-preserving, so
  -- every created_at comparison downstream reads the same way, and idempotent, so the repeats
  -- below (each covering commitments created after the previous pass) age nothing twice.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day((now() at time zone 'Asia/Ho_Chi_Minh')::date - 1, true);

  select p.id into v_penalty1
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_user1 and s.kind = 'day';

  if v_penalty1 is null then
    raise exception 'Fixture broken: account 1''s day did not settle a Penalty.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user1, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user1, v_c1, gen_random_uuid(),
          (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1)
  returning id into v_appeal1;
  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty1;
  if v_state <> 'held' then
    raise exception using message = format(
      'Fixture broken: expected account 1''s Penalty `held` after filing an appeal, got `%s`.',
      v_state);
  end if;

  update public.commitment set carries_penalty = false where id = v_c1;

  select state into v_state from public.penalty where id = v_penalty1;
  if v_state <> 'dropped' then
    raise exception using message = format(
      'Step 1 FAILED: turning carries_penalty off on a commitment with a held Penalty must '
      'resolve the Appeal in the author''s favor (state -> dropped), got `%s`.', v_state);
  end if;

  raise notice 'Step 1 ok: turning carries_penalty off drops a held Penalty behind a pending '
    'Appeal, exactly as epic-4-context.md''s own Requirements & Constraints documented.';

  -- Step 1b: the identical toggle on a commitment with no held Appeal is a no-op — a plain,
  -- never-appealed owed Penalty must not be touched.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user1b, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c1b;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user1b, v_c1b, gen_random_uuid(), 'slipped', now());

  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day((now() at time zone 'Asia/Ho_Chi_Minh')::date - 1, true);

  select p.id into v_penalty1b
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_user1b and s.kind = 'day';

  if v_penalty1b is null then
    raise exception 'Fixture broken: account 1b''s day did not settle a Penalty.';
  end if;

  update public.commitment set carries_penalty = false where id = v_c1b;

  select state into v_state from public.penalty where id = v_penalty1b;
  if v_state <> 'owed' then
    raise exception using message = format(
      'Step 1b FAILED: turning carries_penalty off on a commitment with no held Appeal must '
      'never touch an existing owed Penalty, got `%s`.', v_state);
  end if;

  raise notice 'Step 1b ok: the same toggle is a no-op when nothing is held — an ordinary '
    'owed Penalty is left exactly as settle_day set it.';

  -- =================================================================================
  -- Step 2: appeal_hold_penalty()'s `verdict = 'failed'` guard, never exercised before —
  -- a day that closes `expired` (a different commitment's silence) while still freezing
  -- one commitment's own machine-filed miss must refuse an appeal, not hold its Penalty.
  -- Mirrors `4-4-contest-a-miss-the-machine-got-wrong.sql`'s own account-5 fixture shape
  -- (proven there for the eligibility lookup's settlement-currency fix), stopped short of
  -- that file's own supersession step so the day stays `expired`, never corrected.
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user2, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-2')
  returning id into v_c2a;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user2, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c2b;

  -- Four days back, so the deadline has already passed and the day can genuinely expire.
  v_day2 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 4;

  insert into public.declaration
    (owner_id, commitment_id, idempotency_key, answer, answered_at, filed_by)
  values
    (v_user2, v_c2a, gen_random_uuid(), 'slipped',
     ((v_day2 + 1)::timestamp + interval '6 hours') at time zone 'Asia/Ho_Chi_Minh',
     'auto_check');

  -- v_c2b stays silent — the day closes `expired` on the clock.
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day2, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_user2 and period = v_day2 and kind = 'day' and supersedes is null;

  if v_verdict <> 'expired' then
    raise exception using message = format(
      'Fixture broken: expected account 2''s day to close `expired`, got `%s`.', v_verdict);
  end if;

  select p.id into v_penalty2
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_user2 and s.period = v_day2 and s.kind = 'day' and s.supersedes is null;

  if v_penalty2 is null then
    raise exception 'Fixture broken: account 2''s expired day did not settle a Penalty.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user2, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
    values (v_user2, v_c2a, gen_random_uuid(), v_day2);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%No machine miss on record%' then
    raise exception using message = format(
      'Step 2 FAILED: an appeal against a machine-filed miss on a day that closed `expired` '
      '(not `failed`) must be refused with "No machine miss on record...", got refused=%s, '
      'message=%s.', v_refused, coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty2;
  if v_state <> 'owed' then
    raise exception using message = format(
      'Step 2 FAILED: the refused appeal must leave the Penalty untouched, got `%s`.', v_state);
  end if;

  raise notice 'Step 2 ok: appeal_hold_penalty()''s verdict = ''failed'' guard is real and '
    'exercised — a machine-filed miss on a day that closed `expired` cannot be appealed.';

  -- =================================================================================
  -- Step 3: appeal_hold_penalty()'s `carries_penalty` guard, never exercised before — a
  -- machine-filed miss on a commitment that no longer carries a Penalty must be refused.
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user3, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-3')
  returning id into v_c3;

  perform public.file_auto_check_result(v_c3, v_user3, 'missed');
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day((now() at time zone 'Asia/Ho_Chi_Minh')::date - 1, true);

  select p.id into v_penalty3
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_user3 and s.kind = 'day';

  if v_penalty3 is null then
    raise exception 'Fixture broken: account 3''s day did not settle a Penalty.';
  end if;

  -- Turned off *after* the miss was recorded, *before* the appeal is attempted — Step 1's
  -- own trigger fires here too and is a no-op (nothing held yet to resolve).
  update public.commitment set carries_penalty = false where id = v_c3;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user3, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
    values (v_user3, v_c3, gen_random_uuid(), (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%Penalty-carrying commitment%' then
    raise exception using message = format(
      'Step 3 FAILED: an appeal against a commitment that no longer carries a Penalty must '
      'be refused with "...Penalty-carrying commitment...", got refused=%s, message=%s.',
      v_refused, coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty3;
  if v_state <> 'owed' then
    raise exception using message = format(
      'Step 3 FAILED: the refused appeal must leave the Penalty untouched, got `%s`.', v_state);
  end if;

  raise notice 'Step 3 ok: appeal_hold_penalty()''s carries_penalty guard is real and '
    'exercised — a commitment that stopped carrying a Penalty cannot have its earlier miss '
    'appealed.';

  -- =================================================================================
  -- Step 4: rule_appeal() and mark_penalty_collected() both read role_from_table(), never
  -- role_from_token() — a session whose JWT claims `app_role: referee` but whose real
  -- `profile.role` row still reads `doer` must be refused by both, exactly as a plain doer
  -- session would be. No fixture before this one ever made the two disagree.
  -- =================================================================================
  -- Two independent accounts, not one account with two commitments the same day — FR-13
  -- bundles one Penalty per Failed Day, never per commitment, so sharing an account would
  -- bundle both misses into a single row and leave nothing distinct for each RPC to target.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_target, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-target')
  returning id into v_c4a;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_target2, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c4b;

  perform public.file_auto_check_result(v_c4a, v_target, 'missed');
  v_day4 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day4, true);

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_target2, v_c4b, gen_random_uuid(), 'slipped', now());
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day4, true);

  select p.id into v_penalty4a
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_target and s.kind = 'day' and s.period = v_day4;

  select p.id into v_penalty4b
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_target2 and s.kind = 'day' and s.period = v_day4;

  if v_penalty4a is null or v_penalty4b is null then
    raise exception 'Fixture broken: one of the two target accounts did not settle a Penalty.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_target, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_target, v_c4a, gen_random_uuid(), v_day4)
  returning id into v_appeal4;
  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty4a;
  if v_state <> 'held' then
    raise exception using message = format(
      'Fixture broken: expected the target''s appealed Penalty `held`, got `%s`.', v_state);
  end if;

  select state into v_state from public.penalty where id = v_penalty4b;
  if v_state <> 'owed' then
    raise exception using message = format(
      'Fixture broken: expected the target''s other Penalty `owed`, got `%s`.', v_state);
  end if;

  -- The spoofed session: sub = the spoofer's own id (a real row, genuinely `doer`), but the
  -- token's own app_role claims `referee`. role_from_token() would read `referee` here;
  -- role_from_table() reads the actual row and finds `doer`.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_spoofer, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.rule_appeal(v_appeal4, true);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%referee%' then
    raise exception using message = format(
      'Step 4 FAILED: rule_appeal() must refuse a spoofed app_role=referee token whose real '
      'profile.role reads doer, got refused=%s, message=%s.', v_refused,
      coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.mark_penalty_collected(v_penalty4b);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%referee%' then
    raise exception using message = format(
      'Step 4 FAILED: mark_penalty_collected() must refuse a spoofed app_role=referee token '
      'whose real profile.role reads doer, got refused=%s, message=%s.', v_refused,
      coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty4a;
  if v_state <> 'held' then
    raise exception using message = format(
      'Step 4 FAILED: the spoofed ruling attempt must leave the appealed Penalty untouched, '
      'got `%s`.', v_state);
  end if;

  select state into v_state from public.penalty where id = v_penalty4b;
  if v_state <> 'owed' then
    raise exception using message = format(
      'Step 4 FAILED: the spoofed collection attempt must leave the other Penalty untouched, '
      'got `%s`.', v_state);
  end if;

  raise notice 'Step 4 ok: rule_appeal() and mark_penalty_collected() both refuse a session '
    'whose token claims app_role=referee but whose real profile.role row still reads doer — '
    'role_from_table(), not role_from_token(), is genuinely load-bearing for both.';

  raise notice 'PASS. All five 2026-08-27 Epic 4 retro fixes hold: the appeal-drop-on-'
    'toggle-off trigger fires exactly when a held Penalty exists and never otherwise; '
    'appeal_hold_penalty()''s verdict and carries_penalty guards both refuse an ineligible '
    'appeal and leave its Penalty untouched; and rule_appeal()/mark_penalty_collected() both '
    'refuse a stale/spoofed referee token whose real profile row disagrees.';
end $$;

-- =====================================================================================
-- Step 5: commitment_auto_check_not_on_hours_quota (finding A7) — a plain constraint
-- check, no session/settlement machinery needed.
-- =====================================================================================
do $$
declare
  v_user5   uuid := gen_random_uuid();
  v_refused boolean := false;
  v_message text;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user5, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-4r-hours-' || v_user5::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  begin
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   carries_penalty, daily_minutes_target,
                                   auto_check_kind, auto_check_account_ref)
    values (v_user5, gen_random_uuid(), 'Deep work', 'do', 'daily_hours_quota',
            true, 120, 'account_elsewhere', 'handle-5');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%commitment_auto_check_not_on_hours_quota%' then
    raise exception using message = format(
      'Step 5 FAILED: an Hours-per-day commitment with an Auto-check attached must be '
      'refused by commitment_auto_check_not_on_hours_quota, got refused=%s, message=%s.',
      v_refused, coalesce(v_message, '<null>'));
  end if;

  raise notice 'Step 5 ok: commitment_auto_check_not_on_hours_quota refuses an Auto-check on '
    'an Hours-per-day commitment, mirroring the existing abstain exclusion.';
end $$;

-- =====================================================================================
-- Step 6: evidence.captured_on (finding A3, FR-14) — evidence dated a day other
-- than the one being appealed is refused; evidence dated the appealed day is accepted.
-- =====================================================================================
do $$
declare
  v_user6    uuid := gen_random_uuid();
  v_c6       uuid;
  v_day6     date;
  v_appeal6  uuid;
  v_refused  boolean := false;
  v_message  text;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user6, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-4r-evidence-' || v_user6::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user6, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-6')
  returning id into v_c6;

  perform public.file_auto_check_result(v_c6, v_user6, 'missed');
  v_day6 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day6, true);

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user6, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user6, v_c6, gen_random_uuid(), v_day6)
  returning id into v_appeal6;

  begin
    insert into public.evidence (appeal_id, storage_path, captured_on)
    values (v_appeal6, v_appeal6::text || '/wrong-day.jpg', v_day6 - 1);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%dated the day it proves%' then
    raise exception using message = format(
      'Step 6 FAILED: evidence dated a day other than the one being proved must be '
      'refused, got refused=%s, message=%s.', v_refused, coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    insert into public.evidence (appeal_id, storage_path, captured_on)
    values (v_appeal6, v_appeal6::text || '/no-day.jpg', null);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%dated the day it proves%' then
    raise exception using message = format(
      'Step 6 FAILED: evidence with no captured_on at all must be refused the same way, '
      'got refused=%s, message=%s.', v_refused, coalesce(v_message, '<null>'));
  end if;

  insert into public.evidence (appeal_id, storage_path, captured_on)
  values (v_appeal6, v_appeal6::text || '/right-day.jpg', v_day6);

  perform set_config('role', 'postgres', true);

  if not exists (
    select 1 from public.evidence
     where appeal_id = v_appeal6 and captured_on = v_day6
  ) then
    raise exception 'Step 6 FAILED: evidence dated exactly the appealed day was not accepted.';
  end if;

  raise notice 'Step 6 ok: evidence.captured_on refuses a missing or wrong-day '
    'capture date, and accepts one that matches the appealed day exactly.';
end $$;

rollback;
