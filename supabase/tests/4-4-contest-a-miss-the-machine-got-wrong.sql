-- Story 4.4 — Contest a miss the machine got wrong (FR-14, FR-15).
--
-- Covers the spec's own I/O matrix end to end: an eligible appeal holds the Penalty in the
-- same transaction it is filed in; a self-declared slip (never machine-filed) is refused
-- with nothing changed; a second eligible miss cannot also claim the one Penalty a Failed
-- Day bundles (FR-13); a duplicate appeal for the exact same (commitment_id, for_day) is
-- refused by the unique constraint itself once the trigger's own business checks would
-- otherwise allow it through; a `held` Penalty past its deadline voids to `dropped`, and
-- the guarded update is a no-op the second time it runs against the same row, from either
-- direction of the AD-15 race.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/4-4-contest-a-miss-the-machine-got-wrong.sql
--
-- One transaction, rolled back at the end. Nothing persists.
--
-- Every fixture account here is a fresh one with exactly the commitments this file
-- declares — unlike `2-1-roles-and-rls.sql`'s own step 5c, there is no earlier step's
-- undeclared commitment to answer for before a day will close.

begin;

-- The local stack's default privileges differ from the author's project (recorded in
-- `2-1-roles-and-rls.sql`'s own header): `authenticated` starts with none of select/
-- insert/update/delete on any application table here, while the live project's own
-- Supabase-provisioned defaults already grant them. Every appeal below is filed as
-- `authenticated`, through the actual RLS-gated insert policy rather than as `postgres`,
-- so these are what give `appeal: file own` something real to be exercised through --
-- `select` because `insert ... returning` needs it, and because `role_from_table()`
-- (called from that policy's own `with check`) reads `public.profile` under invoker
-- rights on purpose (`20260819121500_close_function_exposure.sql`: "role_from_table
-- never needed SECURITY DEFINER"). Rolled back with everything else.
grant select on table public.profile to authenticated;
grant select, insert on table public.appeal, public.appeal_evidence to authenticated;

do $$
declare
  -- Account 1: one Failed Day, three commitments -- two machine-filed misses sharing that
  -- day's one bundled Penalty (FR-13), and the author's own honest slip alongside them.
  v_user1     uuid := gen_random_uuid();
  v_c1        uuid; -- carries_penalty, machine-filed missed -- the appeal that succeeds
  v_c2        uuid; -- carries_penalty, the author's own honest slipped -- never appealable
  v_c3        uuid; -- carries_penalty, machine-filed missed -- loses the race for the one Penalty

  -- Account 2: one machine-filed miss, appealed, then its Penalty is put back to `owed`
  -- (standing in for a hypothetical future Story 4.6 rejection ruling) to prove the unique
  -- constraint itself refuses a second appeal even when the trigger's own business rules
  -- would otherwise allow it through.
  v_user2     uuid := gen_random_uuid();
  v_c4        uuid;

  -- Account 3: the timeout path, and the guarded update run twice against the same row.
  v_user3     uuid := gen_random_uuid();
  v_c5        uuid;

  -- Account 4: the AD-15 race from the other direction -- something else (standing in for
  -- a Story 4.6 approval ruling) resolves the Penalty before the timeout job ever looks.
  v_user4     uuid := gen_random_uuid();
  v_c6        uuid;

  -- Account 5: a day that closed `expired` (a different commitment's silence), later
  -- corrected to `failed` by `supersede_expiries()` -- proving the eligibility lookup reads
  -- the CURRENT settlement (the correction), not the original it superseded, and that the
  -- Penalty it holds is the one `penalty_current`/the Ledger actually shows as owed, not a
  -- disconnected historical row.
  v_user5      uuid := gen_random_uuid();
  v_c7         uuid; -- auto_check, carries_penalty -- machine-filed missed, appealed after correction
  v_c8         uuid; -- plain, carries_penalty -- silent past deadline, then a timely-but-late answer

  v_day        date;
  v_settlement uuid;
  v_penalty1   uuid;
  v_penalty2   uuid;
  v_penalty3   uuid;
  v_penalty4   uuid;
  v_appeal1    uuid;
  v_appeal4    uuid;

  v_count      integer;
  v_state      public.penalty_state;
  v_deadline   timestamptz;
  v_expected   timestamptz;
  v_refused    boolean;
  v_message    text;
  v_voided     integer;

  -- Account 5's own working variables.
  v_day5          date;
  v_deadline5     timestamptz;
  v_answered7     timestamptz;
  v_answered8     timestamptz;
  v_original5     uuid;
  v_correction5   uuid;
  v_verdict5      public.day_verdict;
  v_livepenalty5  uuid;
  v_appeal5       uuid;
  v_appeal5_pen   uuid;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- Fixture: four accounts, every commitment they need, and the one shared day.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-4-4-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user1, v_user2, v_user3, v_user4]) as t(id);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user1, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-c1')
  returning id into v_c1;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user1, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c2;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user1, gen_random_uuid(), 'Side project', 'do', 'daily', true,
          'account_elsewhere', 'handle-c3')
  returning id into v_c3;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user2, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-c4')
  returning id into v_c4;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user3, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-c5')
  returning id into v_c5;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user4, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-c6')
  returning id into v_c6;

  -- Every machine-filed miss goes through the actual production filer, exactly as 4-3's
  -- own test does -- proving this file's fixtures exercise the real `filed_by` write, not
  -- a hand-built stand-in for it.
  perform public.file_auto_check_result(v_c1, v_user1, 'missed');
  perform public.file_auto_check_result(v_c3, v_user1, 'missed');
  perform public.file_auto_check_result(v_c4, v_user2, 'missed');
  perform public.file_auto_check_result(v_c5, v_user3, 'missed');
  perform public.file_auto_check_result(v_c6, v_user4, 'missed');

  -- v_c2's own honest slip -- the author's own tap, not the machine's. `filed_by` defaults
  -- `'doer'`, unset here on purpose: this is the exact shape a client insert produces.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user1, v_c2, gen_random_uuid(), 'slipped', now());

  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;

  -- Every account here has every one of its commitments answered for `v_day`, so this one
  -- call closes all four days regardless of the declaration deadline.
  perform public.settle_day(v_day, true);

  select id into v_settlement from public.settlement
   where subject = v_user1 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty1 from public.penalty where settlement_id = v_settlement;

  if v_penalty1 is null then
    raise exception using message = 'Fixture setup failed: account 1''s day did not settle.';
  end if;

  select count(*) into v_count
    from public.settlement_commitment
   where settlement_id = v_settlement and outcome = 'missed';
  if v_count <> 3 then
    raise exception using message = format(
      'Fixture setup failed: expected all three of account 1''s commitments to freeze as '
      'missed, found %s.', v_count);
  end if;

  raise notice using message =
    'Fixture ok: four accounts settled on the same day, account 1''s Failed Day carries '
    'exactly one Penalty (FR-13) covering three frozen misses.';

  -- -------------------------------------------------------------------------------
  -- 1. Self-declared slip refused -- nothing to contest. Run first, while the day's
  --    Penalty is still owed, so a failure here cannot be explained away by the Penalty
  --    already being held for another reason.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user1, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
    values (v_user1, v_c2, gen_random_uuid(), v_day);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'An appeal against the author''s own honest slip (never machine-filed) was accepted. '
      'FR-2a/4.4: only a machine-filed miss can be appealed.';
  end if;

  if v_message not ilike '%machine-filed%' then
    raise exception using message = format(
      'The refusal said "%s", which does not explain that only a machine-filed miss can '
      'be appealed.', v_message);
  end if;

  select count(*) into v_count from public.appeal where commitment_id = v_c2;
  select state into v_state from public.penalty where id = v_penalty1;

  if v_count <> 0 or v_state <> 'owed' then
    raise exception using message = format(
      'The refused self-declared appeal still left %s appeal row(s) and the Penalty at '
      '`%s` -- a refusal must change nothing.', v_count, v_state);
  end if;

  raise notice using message =
    'Step 1 ok: an appeal against the author''s own honest slip is refused, with no row '
    'inserted and the Penalty untouched.';

  -- -------------------------------------------------------------------------------
  -- 2. Eligible appeal holds the Penalty, atomically, in the same transaction.
  -- -------------------------------------------------------------------------------
  -- Computed as postgres, before switching to the client role -- appeal_deadline() is
  -- revoked from authenticated (it is server/trigger-only), and `now()` is stable for the
  -- whole transaction, so this equals whatever the trigger itself stamps below regardless
  -- of which role calls it.
  v_expected := public.appeal_deadline(now());

  perform set_config('role', 'authenticated', true);

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user1, v_c1, gen_random_uuid(), v_day)
  returning id, settlement_id, penalty_id, deadline
    into v_appeal1, v_settlement, v_penalty1, v_deadline;

  perform set_config('role', 'postgres', true);

  if v_penalty1 is null then
    raise exception using message = 'The appeal row carries no penalty_id.';
  end if;

  select state into v_state from public.penalty where id = v_penalty1;
  if v_state <> 'held' then
    raise exception using message = format(
      'The day''s Penalty reads `%s` immediately after an eligible appeal, expected `held` '
      '-- FR-14: the hold must happen before the Penalty is ever shown as owed.', v_state);
  end if;

  if v_deadline <> v_expected then
    raise exception using message = format(
      'appeal.deadline is %s, expected %s from appeal_deadline(now()) -- the trigger must '
      'stamp the same deadline the function itself computes.', v_deadline, v_expected);
  end if;

  raise notice using message =
    'Step 2 ok: an eligible appeal moves the day''s Penalty to held in the same '
    'transaction, and stamps the deadline appeal_deadline() itself computes.';

  -- -------------------------------------------------------------------------------
  -- 3. A second eligible miss on the same day cannot also claim the one Penalty FR-13
  --    bundles for that day -- it is no longer owed, regardless of which commitment asks.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);

  v_refused := false;
  begin
    insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
    values (v_user1, v_c3, gen_random_uuid(), v_day);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A second machine-filed miss on the same Failed Day was allowed to appeal a Penalty '
      'that another appeal had already claimed.';
  end if;

  if v_message not ilike '%not appealable%' then
    raise exception using message = format(
      'The refusal said "%s", expected it to name the Penalty as not appealable.', v_message);
  end if;

  select count(*) into v_count from public.appeal where commitment_id = v_c3;
  select state into v_state from public.penalty where id = v_penalty1;

  if v_count <> 0 or v_state <> 'held' then
    raise exception using message = format(
      'The refused second appeal still left %s row(s) and the Penalty at `%s`, expected no '
      'row and `held` left exactly as the first appeal set it.', v_count, v_state);
  end if;

  raise notice using message =
    'Step 3 ok: a second eligible miss cannot also hold a Penalty another appeal already '
    'claimed -- refused, no second row, first appeal''s hold untouched.';

  -- -------------------------------------------------------------------------------
  -- 4. Already appealed -- refused by the unique constraint itself, on account 2. The
  --    Penalty is put back to `owed` first (standing in for a hypothetical future 4.6
  --    rejection ruling) precisely so every one of appeal_hold_penalty()'s own business
  --    checks would otherwise allow a second attempt through -- isolating that it is the
  --    `appeal_one_per_commitment_day` constraint doing the refusing here, not a business
  --    rule that would refuse it anyway even without the constraint existing at all.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user2, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user2, v_c4, gen_random_uuid(), v_day)
  returning penalty_id into v_penalty2;

  perform set_config('role', 'postgres', true);

  update public.penalty set state = 'owed' where id = v_penalty2;

  perform set_config('role', 'authenticated', true);

  v_refused := false;
  begin
    insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
    values (v_user2, v_c4, gen_random_uuid(), v_day);
  exception when unique_violation then
    v_refused := true;
    get stacked diagnostics v_message = returned_sqlstate;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A second appeal for the exact same (commitment_id, for_day) was accepted once the '
      'Penalty read owed again -- appeal_one_per_commitment_day must refuse it regardless '
      'of what appeal_hold_penalty()''s own business checks would otherwise allow.';
  end if;

  if v_message <> '23505' then
    raise exception using message = format(
      'The refusal carried SQLSTATE %s, expected 23505 (unique_violation).', v_message);
  end if;

  select count(*) into v_count from public.appeal where commitment_id = v_c4 and for_day = v_day;
  if v_count <> 1 then
    raise exception using message = format(
      'commitment_id/for_day now has %s appeal row(s), expected exactly 1 -- one appeal '
      'per (commitment_id, for_day) is a database constraint, not merely a UI guard.',
      v_count);
  end if;

  raise notice using message =
    'Step 4 ok: a second appeal for the same (commitment_id, for_day) is refused by '
    'appeal_one_per_commitment_day (23505) even when every other eligibility check would '
    'otherwise have allowed it through.';

  -- -------------------------------------------------------------------------------
  -- 5. Timeout, unruled -- a held Penalty past its own deadline voids to dropped, and
  --    never converts to owed on its own. The guarded update is then a no-op the second
  --    time it runs against the same, already-resolved row (AD-15).
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user3, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user3, v_c5, gen_random_uuid(), v_day)
  returning penalty_id into v_penalty3;

  perform set_config('role', 'postgres', true);

  update public.appeal set deadline = now() - interval '1 hour'
   where commitment_id = v_c5 and for_day = v_day;

  select public.void_expired_appeals() into v_voided;
  if v_voided < 1 then
    raise exception using message =
      'void_expired_appeals() voided nothing for a held Penalty whose deadline had already '
      'passed.';
  end if;

  select state into v_state from public.penalty where id = v_penalty3;
  if v_state <> 'dropped' then
    raise exception using message = format(
      'The expired appeal''s Penalty reads `%s`, expected `dropped` -- FR-15: it must '
      'never convert to owed on its own.', v_state);
  end if;

  -- Re-run against the exact same, now-resolved row. AD-15's whole point: the second
  -- writer to a settled terminal state affects zero rows and never raises.
  select public.void_expired_appeals() into v_voided;
  if v_voided <> 0 then
    raise exception using message = format(
      'A second run of void_expired_appeals() against an already-dropped Penalty voided '
      '%s row(s), expected 0 -- the guard (where state = ''held'') is what makes a raced '
      'second writer a no-op rather than a double-resolution.', v_voided);
  end if;

  select state into v_state from public.penalty where id = v_penalty3;
  if v_state <> 'dropped' then
    raise exception using message = format(
      'The second, no-op run of void_expired_appeals() changed the Penalty to `%s`.', v_state);
  end if;

  raise notice using message =
    'Step 5 ok: a held Penalty past its deadline voids to dropped and never reverts to '
    'owed; re-running the same guarded update against the resolved row is a no-op.';

  -- -------------------------------------------------------------------------------
  -- 5b. The same guard, raced from the other direction: something else (standing in for
  --     a future Story 4.6 approval ruling) resolves the Penalty first. The timeout job
  --     must still find zero rows to void -- no exception, and the Penalty is left exactly
  --     as whatever resolved it first left it, never overwritten to dropped after the
  --     fact.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user4, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user4, v_c6, gen_random_uuid(), v_day)
  returning id, penalty_id into v_appeal4, v_penalty4;

  perform set_config('role', 'postgres', true);

  update public.appeal set deadline = now() - interval '1 hour' where id = v_appeal4;

  -- A ruling's own state has no `settle_day`/`void_expired_appeals` twin yet (Story 4.6):
  -- this update alone is exactly what a `held -> owed` approval will one day do, and is
  -- the only fact this step depends on -- not the ruling machinery around it.
  update public.penalty set state = 'owed' where id = v_penalty4;

  select public.void_expired_appeals() into v_voided;
  if v_voided <> 0 then
    raise exception using message = format(
      'void_expired_appeals() voided %s row(s) that a ruling had already resolved off '
      'held -- the guard must leave a settled row alone regardless of its own deadline '
      'having passed.', v_voided);
  end if;

  select state into v_state from public.penalty where id = v_penalty4;
  if v_state <> 'owed' then
    raise exception using message = format(
      'The Penalty a ruling resolved to owed now reads `%s` -- the timeout job must never '
      'overwrite a state something else already settled.', v_state);
  end if;

  raise notice using message =
    'Step 5b ok: when something else resolves a held Penalty first, the timeout job finds '
    'zero rows to void and leaves it exactly as resolved -- the same guard, raced from the '
    'other direction (AD-15).';

  -- -------------------------------------------------------------------------------
  -- 6. Evidence metadata cannot be pointed at a path outside its own appeal. The
  --    storage.objects policy already refuses the client any real access to a mismatched
  --    object -- this proves the metadata row itself cannot misreport what it owns, even
  --    before any object exists at either path.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user1, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  -- captured_on is set to v_day (the appeal's own for_day) on both inserts below so the
  -- Epic 4 retrospective's captured_on guard (2026-08-27, finding A3) never fires here —
  -- this step is about storage_path's own check constraint, not that one.
  v_refused := false;
  begin
    insert into public.appeal_evidence (appeal_id, storage_path, captured_on)
    values (v_appeal1, gen_random_uuid()::text || '/not-this-appeals-folder.jpg', v_day);
  exception when others then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'appeal_evidence accepted a storage_path outside its own appeal_id''s folder -- the '
      'check constraint on storage_path did not fire.';
  end if;

  insert into public.appeal_evidence (appeal_id, storage_path, captured_on)
  values (v_appeal1, v_appeal1::text || '/proof.jpg', v_day);

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 6 ok: appeal_evidence.storage_path must lead with its own appeal_id -- a '
    'mismatched path is refused, a correctly-scoped one is accepted.';

  -- -------------------------------------------------------------------------------
  -- 7. A day that closed `expired` (a different commitment's silence), corrected to
  --    `failed` once the silent commitment's own timely-but-late answer arrives. The
  --    eligibility lookup must read the CURRENT (correction) settlement, not the original
  --    it superseded -- and the Penalty it holds must be the one `penalty_current` (and
  --    therefore the Ledger) actually shows, not a disconnected historical row still
  --    attached to the superseded original.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user5, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-4-4-' || v_user5::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user5, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-c7')
  returning id into v_c7;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user5, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c8;

  -- Four days back, so the deadline (the morning hour on day+3) has already passed and the
  -- day can genuinely expire -- mirrors `2-7-supersession.sql`'s own fixture exactly.
  v_day5 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 4;
  v_deadline5 := public.declaration_deadline(v_day5, 7);

  if v_deadline5 >= now() then
    raise exception using message = format(
      'Fixture is wrong: the deadline %s has not passed at %s.', v_deadline5, now());
  end if;

  -- v_c7's machine-filed miss, inserted directly (not through file_auto_check_result,
  -- which always stamps answered_at = now() and so could never derive for_day = v_day5) --
  -- timely, and on record before settle_day's first pass over this day.
  v_answered7 := ((v_day5 + 1)::timestamp + interval '6 hours') at time zone 'Asia/Ho_Chi_Minh';
  insert into public.declaration
    (owner_id, commitment_id, idempotency_key, answer, answered_at, filed_by)
  values
    (v_user5, v_c7, gen_random_uuid(), 'slipped', v_answered7, 'auto_check');

  -- v_c8 stays silent. The day closes `expired` on the clock -- a different fact about him
  -- from v_c7's admitted (machine-filed) slip, and the two must not be merged.
  perform public.settle_day(v_day5, true);

  select id, verdict into v_original5, v_verdict5
    from public.settlement
   where subject = v_user5 and period = v_day5 and kind = 'day' and supersedes is null;

  if v_original5 is null or v_verdict5 <> 'expired' then
    raise exception using message = format(
      'Fixture setup failed: expected an `expired` settlement for account 5''s day, found '
      '%s / %s.', v_original5, v_verdict5);
  end if;

  -- v_c8's own answer, given in time but delivered late (the offline-queue scenario
  -- `supersede_expiries()` exists for) -- `held`, so it admits nothing of its own; v_c7
  -- alone carries the correction's Penalty.
  v_answered8 := ((v_day5 + 1)::timestamp + interval '7 hours 31 minutes')
                 at time zone 'Asia/Ho_Chi_Minh';
  if v_answered8 >= v_deadline5 then
    raise exception using message = 'Fixture is wrong: v_c8''s answer is not inside the deadline.';
  end if;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user5, v_c8, gen_random_uuid(), 'held', v_answered8);

  if public.supersede_expiries() <> 1 then
    raise exception using message = 'supersede_expiries() did not correct account 5''s day.';
  end if;

  select id, verdict into v_correction5, v_verdict5
    from public.settlement where supersedes = v_original5;

  if v_correction5 is null or v_verdict5 <> 'failed' then
    raise exception using message = format(
      'Fixture setup failed: expected a `failed` correction for account 5''s day, found '
      '%s / %s.', v_correction5, v_verdict5);
  end if;

  select id into v_livepenalty5 from public.penalty_current where subject = v_user5;
  if v_livepenalty5 is null then
    raise exception using message = 'Fixture setup failed: no live penalty for account 5.';
  end if;

  raise notice using message =
    'Fixture ok: account 5''s day closed `expired` on a different commitment''s silence, '
    'then corrected to `failed` once that answer turned out to be timely -- two penalty '
    'rows now exist, only one of them live.';

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user5, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user5, v_c7, gen_random_uuid(), v_day5)
  returning id, penalty_id into v_appeal5, v_appeal5_pen;

  perform set_config('role', 'postgres', true);

  if v_appeal5_pen <> v_livepenalty5 then
    raise exception using message = format(
      'The appeal held penalty %s, but %s is the one penalty_current (and therefore the '
      'Ledger) actually reads as owed for this day. The eligibility lookup read the '
      'superseded original''s settlement rather than the correction that stands.',
      v_appeal5_pen, v_livepenalty5);
  end if;

  select state into v_state from public.penalty_current where subject = v_user5;
  if v_state <> 'held' then
    raise exception using message = format(
      'The Penalty the Ledger actually displays for account 5''s day still reads `%s` after '
      'a successful-looking appeal -- the money the author sees as owed never moved.',
      v_state);
  end if;

  raise notice using message =
    'Step 7 ok: an appeal against a machine-filed miss on a day that was corrected from '
    '`expired` to `failed` holds the CURRENT (correction) Penalty -- the one penalty_current '
    'and the Ledger actually show -- not a disconnected historical row left on the '
    'superseded original.';

  raise notice using message =
    'PASS. An eligible appeal holds the Penalty atomically; a self-declared slip and a '
    'second claim on an already-held Penalty are both refused with nothing changed; a '
    'duplicate appeal is refused by the unique constraint itself; the timeout path '
    'voids to dropped, idempotently, and is a no-op from either direction of the AD-15 '
    'race; evidence metadata cannot be pointed outside its own appeal; and an appeal '
    'against a corrected day holds the Penalty that actually stands, not the one it '
    'superseded.';
end $$;

rollback;
