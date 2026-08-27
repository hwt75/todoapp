-- Story 4.5 — The referee has his own way in (FR-19).
--
-- Covers the migration's own RLS end to end: a `role = 'referee'` session reads every
-- appeal, every piece of evidence, every day/week settlement and penalty, and every
-- commitment -- across more than one doer account, since none of the new policies scope by
-- owner_id at all (there being at most one referee is what makes that safe, not a filter on
-- these tables). The same session reads nothing from `declaration`, `chain_current`,
-- `focus_session` or `push_subscription`, proven against real, existing rows rather than an
-- empty table. A `doer` session reads none of the referee-widened rows either, through the
-- same policies that grant them to a referee. `profile_single_referee` -- the partial unique
-- index this migration adds -- refuses a second account ever reaching `role = 'referee'` at
-- all. And the referee session can insert, update or delete nothing on `appeal`,
-- `appeal_evidence`, `penalty`, `settlement` or `commitment` (Step 6) -- this story's own
-- "read-only for the referee, throughout" boundary, proven by attempt rather than left to
-- the absence of a policy in the migration file speaking for itself.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/4-5-the-referee-has-his-own-way-in.sql
--
-- One transaction, rolled back at the end. Nothing persists.
--
-- The whole fixture is built as `postgres`, unlike `4-4`'s own file -- this story adds no new
-- write path for the referee (Step 6 proves exactly that absence), so there is nothing here
-- that needs to be inserted through an RLS-gated policy to be tested honestly.
-- `appeal_hold_penalty()` still fires exactly as it does for a client insert: triggers run
-- regardless of which role performs the insert -- which is what makes account D's fixture
-- below (a fully appeal-eligible, unappealed Penalty) the honest way to prove Step 6a: the
-- trigger's own preconditions are satisfied, so a refusal there is the RLS policy's own doing.

begin;

-- The local stack's default privileges differ from the author's own project (recorded in
-- `2-1-roles-and-rls.sql`'s own header): `authenticated` starts with none of these grants
-- locally, while the live project's Supabase-provisioned defaults already carry them.
-- Rolled back with everything else.
grant select on table
  public.commitment, public.declaration, public.focus_session, public.push_subscription,
  public.appeal, public.appeal_evidence, public.settlement, public.penalty,
  public.settlement_commitment
  to authenticated;
grant select on public.settlement_current, public.penalty_current, public.chain_current
  to authenticated;

-- Insert, update and delete too, on exactly the five tables Step 6 attempts writing
-- against -- the same reasoning `2-2-commitment-rules.sql`'s own header gives for its
-- identically-shaped grant: without it, a refused write here would prove only that the
-- local stack has no default privilege, not that RLS itself refuses the referee. Granting
-- the privilege and then watching RLS refuse the write anyway is what makes RLS the thing
-- actually under test.
grant insert, update, delete on table
  public.appeal, public.appeal_evidence, public.penalty, public.settlement, public.commitment
  to authenticated;

do $$
declare
  -- Account A: the appeal side. One machine-filed miss, appealed -- a `held` Penalty,
  -- evidence attached, plus a declaration, a focus session and a push subscription this
  -- file proves the referee never reads.
  v_doer_a      uuid := gen_random_uuid();
  v_commit_a1   uuid; -- auto_check, carries_penalty -- machine-filed missed, then appealed
  v_commit_a2   uuid; -- daily_hours_quota -- carries the focus session

  -- Account B: the collection side. A plain, self-declared miss with no appeal at all -- an
  -- `owed` Penalty the referee reads through the very same policies.
  v_doer_b      uuid := gen_random_uuid();
  v_commit_b    uuid;

  -- Account C: exists only to prove a `doer` token never satisfies `role_from_token() =
  -- 'referee'`, however wide these new policies read -- reads account A's rows and finds
  -- nothing, the same way `2-1`'s own step 4/5 prove for the pre-existing "own" policies.
  v_doer_c      uuid := gen_random_uuid();

  -- Account D: exists only for Step 6a below. A second machine-filed miss, deliberately
  -- left unappealed -- the one Penalty in this fixture that is genuinely appeal-eligible in
  -- full (ownership, carries_penalty, a `missed` outcome, an `auto_check`-filed declaration,
  -- an `owed` Penalty), so an insert attempted against it is refused by the referee's own
  -- missing RLS policy alone, not by appeal_hold_penalty()'s own business-logic guards the
  -- way reusing account A or B's already-consumed day would be.
  v_doer_d      uuid := gen_random_uuid();
  v_commit_d    uuid;
  v_penalty_d   uuid;

  v_referee     uuid := gen_random_uuid();
  v_third       uuid := gen_random_uuid(); -- the second promotion profile_single_referee refuses

  v_day_a       date;
  v_day_b       date;
  v_settlement_a uuid;
  v_settlement_d uuid;
  v_penalty_a   uuid;
  v_penalty_b   uuid;
  v_appeal_a    uuid;
  v_evidence_a  uuid;

  v_count       integer;
  v_total       bigint;
  v_state       public.penalty_state;
  v_refused     boolean;
  v_amount      bigint; -- penalty_amount_dong() itself, revoked from authenticated
                         -- (20260820103000) -- read once, as postgres, ahead of the referee
                         -- session below rather than called from inside it.
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- Fixture.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-4-5-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_doer_a, v_doer_b, v_doer_c, v_doer_d, v_referee, v_third]) as t(id);

  -- Account A. `v_commit_a2` is a daily_hours_quota commitment, deliberately not part of
  -- what commitments_owing() judges -- it exists only to give focus_session a real row.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_doer_a, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-a1')
  returning id into v_commit_a1;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 daily_minutes_target)
  values (v_doer_a, gen_random_uuid(), 'Deep work', 'do', 'daily_hours_quota', 30)
  returning id into v_commit_a2;

  insert into public.focus_session (owner_id, commitment_id, idempotency_key, started_at, stopped_at)
  values (v_doer_a, v_commit_a2, gen_random_uuid(), now() - interval '40 minutes', now());

  insert into public.push_subscription (owner_id, endpoint, p256dh, auth)
  values (v_doer_a, 'https://push.example.test/a', 'p256dh-a', 'auth-a');

  perform public.file_auto_check_result(v_commit_a1, v_doer_a, 'missed');
  v_day_a := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  perform public.settle_day(v_day_a, true);

  select id into v_settlement_a from public.settlement
   where subject = v_doer_a and period = v_day_a and kind = 'day' and supersedes is null;
  select id into v_penalty_a from public.penalty where settlement_id = v_settlement_a;

  if v_penalty_a is null then
    raise exception using message = 'Fixture setup failed: account A''s day did not settle.';
  end if;

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_doer_a, v_commit_a1, gen_random_uuid(), v_day_a)
  returning id into v_appeal_a;

  select state into v_state from public.penalty where id = v_penalty_a;
  if v_state <> 'held' then
    raise exception using message = format(
      'Fixture setup failed: account A''s penalty reads `%s`, expected `held` -- '
      'appeal_hold_penalty() must fire the same way for a postgres-role insert as it does '
      'for a client one; triggers do not consult the caller''s own role.', v_state);
  end if;

  insert into public.appeal_evidence (appeal_id, storage_path, captured_on)
  values (v_appeal_a, v_appeal_a::text || '/proof.jpg', v_day_a)
  returning id into v_evidence_a;

  -- Account B. A plain, self-declared miss with no appeal at all -- its Penalty stays owed,
  -- which is exactly the state the referee's own collection reading (4.7) will one day act
  -- on, and exactly what this story's own "owed-penalty count" reads today.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_doer_b, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_commit_b;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_doer_b, v_commit_b, gen_random_uuid(), 'slipped', now());

  v_day_b := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  perform public.settle_day(v_day_b, true);

  select p.id, p.state into v_penalty_b, v_state
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_doer_b and s.period = v_day_b and s.kind = 'day' and s.supersedes is null;

  if v_penalty_b is null or v_state <> 'owed' then
    raise exception using message = format(
      'Fixture setup failed: account B''s penalty reads %s / `%s`, expected a row reading '
      '`owed`.', v_penalty_b, v_state);
  end if;

  -- Account D exists from here on only as a bare `auth.users`/`profile` row (created in the
  -- unnest above, alongside A/B/C) -- its commitment, machine miss and Penalty are built
  -- later, immediately before Step 6, deliberately *after* Steps 2-5's own read assertions
  -- run. Those steps assert exact counts (`penalty_current where state = 'owed'` reads
  -- exactly 1 row, account B's), and giving account D an `owed` Penalty here, before Step 2
  -- ever runs, would silently turn that into 2 and break an assertion this file already
  -- proved correct -- Step 6a needs its own fully appeal-eligible Penalty, but only once
  -- nothing earlier is still counting on the world it disturbs.

  v_amount := public.penalty_amount_dong();

  -- The referee, paired: created exactly as `pair-referee` leaves an account -- a real
  -- `auth.users` row, a profile the trigger defaulted to `doer`, then a second, separate
  -- write promoting it (mirroring the Edge Function's own two writes, not its HTTP shape).
  update public.profile set role = 'referee' where id = v_referee;

  raise notice using message =
    'Fixture ok: account A holds a `held` Penalty behind an appeal with evidence, a '
    'declaration, a focus session and a push subscription; account B holds a plain `owed` '
    'Penalty with no appeal; the referee account is paired.';

  -- -------------------------------------------------------------------------------
  -- 1. profile_single_referee: a second promotion is refused outright, by Postgres itself,
  --    regardless of how carefully pair-referee's own check-then-act read might be raced.
  -- -------------------------------------------------------------------------------
  v_refused := false;
  begin
    update public.profile set role = 'referee' where id = v_third;
  exception when unique_violation then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'A second profile was promoted to role = ''referee'' -- profile_single_referee did '
      'not refuse it. Non-Goal: no second Referee beyond the single doer-Referee pair.';
  end if;

  raise notice using message =
    'Step 1 ok: profile_single_referee refuses a second referee profile outright.';

  -- -------------------------------------------------------------------------------
  -- 2. The referee session: appeal, appeal_evidence, penalty/penalty_current and
  --    settlement/settlement_current, across BOTH doer accounts -- none of these policies
  --    scope by owner_id, on purpose (there is at most one referee, so "every appeal" and
  --    "the one doer's appeals" are the same set).
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  select count(*) into v_count from public.appeal;
  if v_count <> 1 then
    raise exception using message = format(
      'The referee session read %s appeal row(s), expected exactly 1.', v_count);
  end if;

  select count(*) into v_count from public.appeal_evidence where id = v_evidence_a;
  if v_count <> 1 then
    raise exception using message =
      'The referee session could not read account A''s appeal evidence -- NFR4 requires it '
      'visible to the submitting doer and the ruling referee.';
  end if;

  select count(*) into v_count from public.penalty_current where state = 'held';
  if v_count <> 1 then
    raise exception using message = format(
      'The referee session read %s held penalty row(s) through penalty_current, expected 1.',
      v_count);
  end if;

  select count(*), coalesce(sum(amount_dong), 0) into v_count, v_total
    from public.penalty_current where state = 'owed';
  if v_count <> 1 or v_total <> v_amount then
    raise exception using message = format(
      'The referee session read %s owed penalty row(s) totalling %s, expected 1 row '
      'totalling %s -- the count and total FR-19''s own home surface displays.',
      v_count, v_total, v_amount);
  end if;

  select count(*) into v_count from public.settlement_current where kind in ('day', 'week');
  if v_count <> 2 then
    raise exception using message = format(
      'The referee session read %s day/week settlement row(s) across both accounts, '
      'expected 2.', v_count);
  end if;

  raise notice using message =
    'Step 2 ok: the referee session reads every appeal, every piece of evidence, and every '
    'day/week settlement and penalty across both doer accounts -- not owner-scoped, because '
    'there is at most one referee to grant it to.';

  -- -------------------------------------------------------------------------------
  -- 3. Commitment: full-row read, including the auto_check_account_ref column this
  --    migration's own comment documents as the cost of Postgres having no column-level RLS.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count from public.commitment where id in (v_commit_a1, v_commit_b);
  if v_count <> 2 then
    raise exception using message = format(
      'The referee session read %s of account A/B''s commitments, expected both (2).', v_count);
  end if;

  perform 1 from public.commitment
   where id = v_commit_a1 and auto_check_account_ref = 'handle-a1';
  if not found then
    raise exception using message =
      'The referee session could not read auto_check_account_ref through the full-row '
      'commitment policy this migration''s own comment documents granting.';
  end if;

  raise notice using message =
    'Step 3 ok: the referee session reads every commitment column, including '
    'auto_check_account_ref -- Postgres has no column-level RLS to withhold it with.';

  -- -------------------------------------------------------------------------------
  -- 4. Explicit absence, proven against real rows rather than an empty table: declaration,
  --    chain_current, focus_session, push_subscription.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count from public.declaration where commitment_id = v_commit_a1;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session read %s declaration row(s) -- no policy anywhere grants a '
      'referee access to declaration.', v_count);
  end if;

  select count(*) into v_count from public.chain_current where commitment_id = v_commit_a1;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session read %s chain_current row(s) -- it inherits settlement_commitment''s '
      'own "read own" policy, which no referee session ever satisfies.', v_count);
  end if;

  select count(*) into v_count from public.focus_session where commitment_id = v_commit_a2;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session read %s focus_session row(s) -- timed work, and the location it '
      'would eventually carry, are never the referee''s to read.', v_count);
  end if;

  select count(*) into v_count from public.push_subscription where owner_id = v_doer_a;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session read %s push_subscription row(s) -- irrelevant to a referee '
      'whose own channel is email (NFR3), and never granted regardless.', v_count);
  end if;

  raise notice using message =
    'Step 4 ok: the referee session reads zero rows of declaration, chain_current, '
    'focus_session or push_subscription, proven against real rows that exist for account A.';

  perform set_config('role', 'postgres', true);

  -- -------------------------------------------------------------------------------
  -- 5. A `doer` token never satisfies role_from_token() = 'referee', however wide these
  --    policies read -- account C reads none of account A's referee-scoped rows either.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_doer_c, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select count(*) into v_count from public.appeal where id = v_appeal_a;
  if v_count <> 0 then
    raise exception using message = format(
      'A doer session (account C) read %s row(s) of account A''s appeal -- the new referee '
      'policy must not be satisfiable by a token claiming app_role = ''doer''.', v_count);
  end if;

  select count(*) into v_count from public.penalty where id in (v_penalty_a, v_penalty_b);
  if v_count <> 0 then
    raise exception using message = format(
      'A doer session (account C) read %s of account A/B''s penalty rows -- neither the '
      'pre-existing "read own" policy nor the new referee policy should have granted this.',
      v_count);
  end if;

  select count(*) into v_count from public.commitment where id in (v_commit_a1, v_commit_b);
  if v_count <> 0 then
    raise exception using message = format(
      'A doer session (account C) read %s of account A/B''s commitments through the new '
      'referee-wide policy.', v_count);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 5 ok: a doer session reads none of another account''s referee-scoped rows -- the '
    'new policies check role_from_token() = ''referee'' exactly, never merely "authenticated".';

  -- -------------------------------------------------------------------------------
  -- Account D, built now (as postgres, still) rather than in the fixture above: a second
  -- machine-filed miss, deliberately left unappealed -- the one Penalty in this whole file
  -- that is genuinely appeal-eligible in full (ownership, carries_penalty, a `missed`
  -- outcome, an `auto_check`-filed declaration, an `owed` Penalty), built only now so
  -- Steps 2-5's own exact-count assertions above never had to know about it. Step 6a
  -- inserts against it as the referee session: refusal there is the "appeal: file own"
  -- policy's own doing, not appeal_hold_penalty()'s business-logic guards tripping over an
  -- ineligible day the way reusing account A or B's already-consumed one would.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_doer_d, gen_random_uuid(), 'LeetCode', 'do', 'daily', true,
          'account_elsewhere', 'handle-d1')
  returning id into v_commit_d;

  perform public.file_auto_check_result(v_commit_d, v_doer_d, 'missed');
  perform public.settle_day(v_day_a, true); -- same "yesterday" as account A; a distinct
                                             -- subject keeps settlement_once satisfied

  select id into v_settlement_d from public.settlement
   where subject = v_doer_d and period = v_day_a and kind = 'day' and supersedes is null;
  select id into v_penalty_d from public.penalty where settlement_id = v_settlement_d;

  if v_penalty_d is null then
    raise exception using message = 'Fixture setup failed: account D''s day did not settle.';
  end if;

  raise notice using message =
    'Account D fixture ok: a second, still-`owed`, fully appeal-eligible Penalty, built '
    'only now so Steps 2-5''s own exact-count assertions above stayed unaffected.';

  -- -------------------------------------------------------------------------------
  -- 6. Read-only for the referee, throughout (this story's own "Always" boundary) --
  --    proven by attempt, not left to the absence of a policy in the migration file to
  --    speak for itself. Every insert/update/delete below runs as the referee session,
  --    re-established after Step 5's doer_c session, and every one of them is refused.
  --
  --    An insert is refused with `insufficient_privilege` -- the same condition
  --    `2-1-roles-and-rls.sql` and `2-2-commitment-rules.sql` already catch it under,
  --    whether the cause is a `with check` clause turning the row down or (thanks to the
  --    header's own `grant insert, update, delete`) genuinely the RLS policy and nothing
  --    else. An update or delete is refused silently -- `row_count` reads 0, because a
  --    `using` clause that never matches this session's rows (or the plain absence of any
  --    policy for that command) filters the statement down to nothing rather than raising.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  -- 6a. appeal: insert. Account D's Penalty is genuinely, fully appeal-eligible --
  --     appeal_hold_penalty() would carry this exact insert through for the real doer, so a
  --     refusal here is the "appeal: file own" policy's own `role_from_table() = 'doer'`
  --     check, not the trigger tripping over an ineligible day the way reusing account A or
  --     B's already-consumed one would.
  v_refused := false;
  begin
    insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
    values (v_doer_d, v_commit_d, gen_random_uuid(), v_day_a);
  exception when insufficient_privilege then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'The referee session inserted an appeal row for account D -- every precondition '
      'appeal_hold_penalty() checks was deliberately satisfied, so only the missing '
      'referee INSERT policy should have stopped it.';
  end if;

  -- The whole statement rolls back together on refusal, including
  -- appeal_hold_penalty()'s own `update penalty set state = 'held'` side effect -- a
  -- refused insert must not leave that standing on its own.
  select state into v_state from public.penalty where id = v_penalty_d;
  if v_state <> 'owed' then
    raise exception using message = format(
      'Account D''s penalty reads `%s` after the referee''s refused appeal insert, '
      'expected `owed` -- appeal_hold_penalty()''s own side-effecting update should have '
      'rolled back with the rest of the statement, not partially applied.', v_state);
  end if;

  -- 6b. appeal: update and delete. No policy of either kind exists on this table for any
  --     role -- both affect zero rows, attempted against account A's own real, held appeal.
  update public.appeal set for_day = v_day_a - 1 where id = v_appeal_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session updated %s appeal row(s) -- there is no update policy on '
      'appeal for any role.', v_count);
  end if;

  delete from public.appeal where id = v_appeal_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session deleted %s appeal row(s) -- there is no delete policy on '
      'appeal for any role.', v_count);
  end if;

  -- 6c. appeal_evidence: insert. appeal_evidence_derive_owner() only refuses an insert
  --     naming an appeal that does not exist -- account A's real v_evidence_a proves one
  --     does, so the trigger derives the real (account A) owner and lets the "file own"
  --     policy's own `role_from_table() = 'doer'` check refuse it.
  v_refused := false;
  begin
    -- captured_on = v_day_a (the appeal's own for_day) so the Epic 4 retrospective's
    -- captured_on guard (2026-08-27, finding A3) never fires here — this step is about
    -- the RLS "file own" policy refusing a referee session, not that one.
    insert into public.appeal_evidence (appeal_id, storage_path, captured_on)
    values (v_appeal_a, v_appeal_a::text || '/second.jpg', v_day_a);
  exception when insufficient_privilege then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'The referee session inserted an appeal_evidence row -- only the missing referee '
      'INSERT policy should have stopped it.';
  end if;

  -- 6d. appeal_evidence: update and delete. Same shape as appeal above -- no policy of
  --     either kind exists for any role.
  update public.appeal_evidence set storage_path = 'tampered.jpg' where id = v_evidence_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session updated %s appeal_evidence row(s) -- there is no update '
      'policy on appeal_evidence for any role.', v_count);
  end if;

  delete from public.appeal_evidence where id = v_evidence_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session deleted %s appeal_evidence row(s) -- there is no delete '
      'policy on appeal_evidence for any role.', v_count);
  end if;

  -- 6e. penalty and settlement: update and delete only. AD-8 gives both tables exactly one
  --     writer (settlement itself), so neither carries an insert policy for any role, doer
  --     included -- attempting update/delete against the real fixture rows already proves
  --     what a synthetic-but-otherwise-valid insert attempt would, more simply.
  update public.penalty set state = 'owed' where id = v_penalty_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session updated %s penalty row(s) -- AD-8 gives settlement the only '
      'writer.', v_count);
  end if;

  delete from public.penalty where id = v_penalty_b;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session deleted %s penalty row(s) -- AD-8 gives settlement the only '
      'writer.', v_count);
  end if;

  update public.settlement set verdict = 'clean' where id = v_settlement_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session updated %s settlement row(s) -- AD-8 gives settlement the '
      'only writer of its own rows.', v_count);
  end if;

  delete from public.settlement where id = v_settlement_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session deleted %s settlement row(s) -- AD-8 gives settlement the '
      'only writer of its own rows.', v_count);
  end if;

  -- 6f. commitment: insert, update and delete. "commitment: create own" and "commitment:
  --     edit own" both require `role_from_table() = 'doer'` in their own with check clause,
  --     which the referee session never satisfies regardless of owner_id.
  v_refused := false;
  begin
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
    values (v_referee, gen_random_uuid(), 'Planted by the referee', 'do', 'daily');
  exception when insufficient_privilege then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'The referee session inserted a commitment row -- "commitment: create own" checks '
      'role_from_table() = ''doer'', which a referee session never satisfies.';
  end if;

  update public.commitment set name = 'Renamed by the referee' where id = v_commit_a1;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session updated %s commitment row(s) it does not own -- "commitment: '
      'edit own"''s using clause should have matched nothing for an account that owns no '
      'commitment.', v_count);
  end if;

  delete from public.commitment where id = v_commit_a1;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee session deleted %s commitment row(s) -- there is no delete policy on '
      'commitment for any role.', v_count);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 6 ok: read-only for the referee, throughout -- every insert, update and delete '
    'attempted against appeal, appeal_evidence, penalty, settlement and commitment was '
    'refused, including an appeal insert whose every other precondition was genuinely met.';

  raise notice using message =
    'PASS. The referee session reads every appeal, every piece of evidence, and every '
    'day/week settlement and penalty across every doer account, plus full commitment rows; '
    'it reads zero rows of declaration, chain_current, focus_session or push_subscription, '
    'proven against real data; a doer session is granted none of that width; '
    'profile_single_referee refuses a second referee outright; and the referee session can '
    'insert, update or delete nothing on appeal, appeal_evidence, penalty, settlement or '
    'commitment, proven by attempt.';
end $$;

rollback;
