-- Story 4.7 — The app does the asking, the referee does the collecting (FR-21).
--
-- Covers the spec's own I/O matrix end to end: a single-commitment day marked collected (the
-- Penalty moves off the owed list, read live through `penalty_current`); a non-referee
-- session refused before any row is read, proven against both a real owed Penalty and a
-- bogus id, so the refusal order itself is pinned down (mirrors `4-6-the-referee-rules.sql`'s
-- own step 1); a double Mark Collected, the second call finding zero rows and refused with a
-- clear message; a Held Penalty staying invisible on the owed list and refused the same
-- generic way if collection is attempted on it anyway (nothing distinguishes "held" from
-- "already collected" — mark_penalty_collected() is simpler than rule_appeal(), by design);
-- a multi-commitment day naming every commitment through `referee_missed_commitments()`, the
-- new security-definer function (never an RLS policy on `settlement_commitment` itself --
-- that table is also `chain_current`'s own base table, see the migration's own header); that
-- same function returning nothing at all for a non-referee caller (a row filter, not a
-- refusal -- AD-7's own read convention); and a week-kind owed Penalty (Week Close, 3.4)
-- collecting through `mark_penalty_collected()` exactly the same way a day-kind one does --
-- the function itself has no `kind` restriction of any sort, by design (a week-kind debt has
-- to be just as discharge-able as a day-kind one, or it sits owed forever with no control
-- that can ever reach it).
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql
--
-- One transaction, rolled back at the end. Nothing persists.

begin;

-- The local stack's default privileges differ from the author's own project (recorded in
-- `2-1-roles-and-rls.sql`'s own header) -- `mark_penalty_collected`'s own EXECUTE grant to
-- `authenticated` is written into the migration itself and needs nothing extra here, but the
-- ordinary table/view reads this fixture exercises through RLS still do.
grant select on table public.profile to authenticated;
grant select, insert on table public.appeal to authenticated;
grant select on public.penalty, public.settlement, public.commitment to authenticated;
grant select on public.penalty_current, public.settlement_current to authenticated;
-- Note: no grant on public.settlement_commitment for `authenticated` -- nothing in this file
-- reads it directly any more. referee_missed_commitments() is security definer, so it needs
-- no table-level grant from the caller at all (that is the whole point of the fix this test
-- proves -- see the migration's own header comment).

do $$
declare
  -- Account 1: sole cause. One machine-... no, one self-declared miss, marked collected --
  -- the success path, and also the target of the non-referee refusal proof before it is
  -- ever collected.
  v_user1        uuid := gen_random_uuid();
  v_c1           uuid;

  -- Account 2: two missed commitments the same day. Proves the multi-commitment naming --
  -- both must come back, never just the first.
  v_user2        uuid := gen_random_uuid();
  v_c2a          uuid; -- 'TryHackMe'
  v_c2b          uuid; -- 'Gym'

  -- Account 3: double Mark Collected. The second call's own guard must find zero rows.
  v_user3        uuid := gen_random_uuid();
  v_c3           uuid;

  -- Account 4: a Held Penalty (an open Appeal). Invisible on the owed list, and refused the
  -- same generic way if collection is attempted on it anyway.
  v_user4        uuid := gen_random_uuid();
  v_c4           uuid;

  -- Account 5: a week-kind owed Penalty (Week Close, 3.4). Fabricated directly rather than
  -- driven through settle_week()'s own multi-day gating (out of this story's own concern,
  -- and already covered by Story 3.4's own tests) -- mark_penalty_collected() reads and
  -- writes only public.penalty by id/state, with no kind of its own to check, so a direct
  -- row is exactly as real a case as one settle_week() would have produced.
  v_user5        uuid := gen_random_uuid();

  v_referee      uuid := gen_random_uuid();

  v_day          date;

  v_settlement1  uuid;
  v_penalty1     uuid;

  v_settlement2  uuid;
  v_penalty2     uuid;

  v_settlement3  uuid;
  v_penalty3     uuid;

  v_settlement4  uuid;
  v_penalty4     uuid;
  v_appeal4      uuid;

  v_settlement5  uuid;
  v_penalty5     uuid;

  v_state        public.penalty_state;
  v_count        integer;
  v_refused      boolean;
  v_message      text;
  v_names        text[];
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- Fixture: four doer accounts, the referee, and every commitment each account needs.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-4-7-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user1, v_user2, v_user3, v_user4, v_user5, v_referee]) as t(id);

  update public.profile set role = 'referee' where id = v_referee;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user1, gen_random_uuid(), 'Reading', 'do', 'daily', true)
  returning id into v_c1;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user2, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true)
  returning id into v_c2a;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user2, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c2b;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user3, gen_random_uuid(), 'Reading', 'do', 'daily', true)
  returning id into v_c3;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user4, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-4')
  returning id into v_c4;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    (v_user1, v_c1, gen_random_uuid(), 'slipped', now()),
    (v_user2, v_c2a, gen_random_uuid(), 'slipped', now()),
    (v_user2, v_c2b, gen_random_uuid(), 'slipped', now()),
    (v_user3, v_c3, gen_random_uuid(), 'slipped', now());

  -- Account 4's own miss is machine-filed, not self-declared -- appeal_hold_penalty()
  -- requires that to hold the Penalty at all.
  perform public.file_auto_check_result(v_c4, v_user4, 'missed');

  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
  -- This fixture creates its commitments moments before judging days that predate them, which is
  -- a state no real account can reach — so it now says when they began. Order-preserving, so
  -- every created_at comparison downstream reads the same way, and idempotent, so a second call
  -- further down this file does not age them twice.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day, true);

  select id into v_settlement1 from public.settlement
   where subject = v_user1 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty1 from public.penalty where settlement_id = v_settlement1;

  select id into v_settlement2 from public.settlement
   where subject = v_user2 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty2 from public.penalty where settlement_id = v_settlement2;

  select id into v_settlement3 from public.settlement
   where subject = v_user3 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty3 from public.penalty where settlement_id = v_settlement3;

  select id into v_settlement4 from public.settlement
   where subject = v_user4 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty4 from public.penalty where settlement_id = v_settlement4;

  if v_penalty1 is null or v_penalty2 is null or v_penalty3 is null or v_penalty4 is null then
    raise exception using message = 'Fixture setup failed: not every account''s day settled.';
  end if;

  -- Account 4's Penalty moves to held the moment the Appeal is filed (appeal_hold_penalty()).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user4, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user4, v_c4, gen_random_uuid(), v_day) returning id into v_appeal4;
  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty4;
  if v_state <> 'held' then
    raise exception using message = format(
      'Fixture setup failed: account 4''s penalty reads `%s`, expected `held` -- the Appeal '
      'above should have moved it there.', v_state);
  end if;

  -- Account 5: a week-kind owed Penalty, exactly the shape settle_week() would have left --
  -- an admitted Weekly Quota shortfall, one settlement, one penalty. Written directly rather
  -- than driven through settle_week()'s own gating (see the declare block's own note above).
  insert into public.settlement (subject, period, kind, verdict, missed_count)
  values (v_user5, v_day, 'week', 'failed', 1)
  returning id into v_settlement5;

  insert into public.penalty (subject, settlement_id, amount_dong)
  values (v_user5, v_settlement5, public.penalty_amount_dong())
  returning id into v_penalty5;

  raise notice using message =
    'Fixture ok: five accounts -- one single-cause owed Penalty, one day with two missed '
    'commitments, one for the double-collect proof, one Held pending an open Appeal, and one '
    'week-kind owed Penalty.';

  -- -------------------------------------------------------------------------------
  -- 1. Non-referee refused, before any row is read -- proven against a real owed Penalty
  --    (account 1 marking its own) AND a bogus id, so the message itself (not merely the
  --    final state) pins down that the role check runs first.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user1, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    perform public.mark_penalty_collected(v_penalty1);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%referee%' then
    raise exception using message = format(
      'A doer session marking its own Penalty collected was not refused with a '
      'referee-specific message. refused=%s, message=%s', v_refused, coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.mark_penalty_collected(gen_random_uuid());
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%referee%' or v_message ilike '%already been resolved%'
  then
    raise exception using message = format(
      'A doer session marking a bogus penalty id collected read "%s" -- the role check must '
      'refuse before the penalty is ever looked up, so this must read the same referee-only '
      'message as a real penalty, never the "already resolved" guard message.',
      coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty1;
  if v_state <> 'owed' then
    raise exception using message = format(
      'Account 1''s penalty reads `%s` after two refused non-referee attempts, expected '
      '`owed` -- untouched.', v_state);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 1 ok: a non-referee session is refused before any penalty row is read, whether the '
    'id is real (even the caller''s own) or bogus -- both read the same referee-only message, '
    'and the real Penalty is left exactly as it was.';

  -- -------------------------------------------------------------------------------
  -- 2. Mark Collected (account 1). Penalty moves to collected, and leaves the referee's own
  --    live `state = 'owed'` read of penalty_current -- the same view/filter the owed list
  --    itself reads through.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.mark_penalty_collected(v_penalty1);

  select count(*) into v_count from public.penalty_current
   where id = v_penalty1 and state = 'owed';
  if v_count <> 0 then
    raise exception using message = format(
      'penalty_current still reads account 1''s penalty as owed after Mark Collected -- %s '
      'row(s), expected 0. The row must leave the owed list.', v_count);
  end if;

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty1;
  if v_state <> 'collected' then
    raise exception using message = format(
      'Account 1''s penalty reads `%s` after Mark Collected, expected `collected`.', v_state);
  end if;

  raise notice using message =
    'Step 2 ok: Mark Collected moves the Penalty to collected, and it leaves the referee''s '
    'own live read of the owed list (penalty_current filtered state = owed).';

  -- -------------------------------------------------------------------------------
  -- 3. Double Mark Collected (account 1's own Penalty, already collected by step 2). The
  --    second call's own guard finds zero rows and is refused with a clear message, never
  --    silently ignored -- and changes nothing further.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.mark_penalty_collected(v_penalty1);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%already been resolved%' then
    raise exception using message = format(
      'A second Mark Collected call on an already-collected Penalty read "%s", expected the '
      '"already been resolved" refusal.', coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty1;
  if v_state <> 'collected' then
    raise exception using message = format(
      'Account 1''s penalty reads `%s` after a refused second Mark Collected, expected it to '
      'stay `collected` -- untouched by the losing call.', v_state);
  end if;

  raise notice using message =
    'Step 3 ok: a second Mark Collected call on the same Penalty is refused cleanly and '
    'leaves it exactly as the first call left it.';

  -- -------------------------------------------------------------------------------
  -- 4. Mark Collected on a Held Penalty (account 4). Nothing distinguishes "held" from
  --    "already collected" in mark_penalty_collected()'s own guard -- both are simply not
  --    `owed` -- so this reads the same generic refusal, never a silent no-op, and the
  --    Penalty stays held (an open Appeal is still the referee's own to rule on, Story 4.6 --
  --    never something Mark Collected can shortcut).
  -- -------------------------------------------------------------------------------
  select count(*) into v_count from public.penalty_current
   where id = v_penalty4 and state = 'owed';
  if v_count <> 0 then
    raise exception using message = format(
      'A Held Penalty read %s row(s) under a `state = owed` filter, expected 0 -- it must '
      'stay invisible on the owed list until it is ruled on.', v_count);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.mark_penalty_collected(v_penalty4);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%already been resolved%' then
    raise exception using message = format(
      'Marking a Held Penalty collected read "%s", expected the same "already been resolved" '
      'refusal a non-owed Penalty always gets.', coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty4;
  if v_state <> 'held' then
    raise exception using message = format(
      'Account 4''s penalty reads `%s` after a refused Mark Collected, expected it to stay '
      '`held` -- untouched.', v_state);
  end if;

  -- referee_missed_commitments() must also treat account 4's day as off-limits, even though
  -- a genuine `outcome = 'missed'` settlement_commitment row exists for it (settle_day()
  -- froze c4 as missed the moment the auto-check reported it, before the Appeal ever held
  -- the Penalty). Without the function's own `exists (... p.state = 'owed')` clause, this
  -- would wrongly name c4 for a Penalty that is not, in fact, owed.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  select count(*) into v_count from public.referee_missed_commitments(array[v_settlement4]);

  perform set_config('role', 'postgres', true);

  if v_count <> 0 then
    raise exception using message = format(
      'referee_missed_commitments() named %s commitment(s) for account 4''s Held Penalty, '
      'expected 0 -- outcome = ''missed'' alone is not enough; the Penalty itself must also '
      'read owed.', v_count);
  end if;

  raise notice using message =
    'Step 4 ok: a Held Penalty stays invisible on the owed list (state = owed excludes it '
    'structurally), an attempt to mark it collected anyway is refused leaving it held, and '
    'referee_missed_commitments() names nothing for it either, despite a genuine '
    'outcome = ''missed'' row existing -- the function checks the Penalty''s own state, not '
    'merely the frozen outcome.';

  -- -------------------------------------------------------------------------------
  -- 5. Multi-commitment naming (account 2). referee_missed_commitments(), the new
  --    security-definer function, names every commitment the day's Penalty covers -- never
  --    just the first.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  select array_agg(r.commitment_name order by r.commitment_name)
    into v_names
    from public.referee_missed_commitments(array[v_settlement2]) r;

  if v_names is null or array_length(v_names, 1) <> 2
     or v_names <> array['Gym', 'TryHackMe']
  then
    raise exception using message = format(
      'The referee''s own call to referee_missed_commitments() for account 2''s day came '
      'back as %s, expected exactly [Gym, TryHackMe] -- every commitment named, never just '
      'the first.', coalesce(v_names::text, '<null>'));
  end if;

  -- The same day's Penalty collects the same way any other owed Penalty does -- naming
  -- multiple commitments changes nothing about the transition itself.
  perform public.mark_penalty_collected(v_penalty2);

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty2;
  if v_state <> 'collected' then
    raise exception using message = format(
      'Account 2''s multi-commitment penalty reads `%s` after Mark Collected, expected '
      '`collected`.', v_state);
  end if;

  raise notice using message =
    'Step 5 ok: referee_missed_commitments() names every commitment a multi-miss day''s '
    'Penalty covers, and that Penalty collects the same way any other does.';

  -- -------------------------------------------------------------------------------
  -- 6. referee_missed_commitments() filters rather than refuses (AD-7's own read
  --    convention) -- a non-referee session calling it gets back an empty set, never an
  --    exception, and never another account's own commitment names.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user3, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select count(*) into v_count from public.referee_missed_commitments(array[v_settlement2]);

  perform set_config('role', 'postgres', true);

  if v_count <> 0 then
    raise exception using message = format(
      'A doer session (account 3) called referee_missed_commitments() for account 2''s own '
      'settlement and got %s row(s) back, expected 0 -- only a referee session may ever read '
      'these names.', v_count);
  end if;

  raise notice using message =
    'Step 6 ok: referee_missed_commitments() returns nothing at all to a non-referee session '
    '-- a row filter, never an exception, and never another account''s own commitment names.';

  -- -------------------------------------------------------------------------------
  -- 7. A week-kind owed Penalty (account 5, Week Close/3.4) collects exactly the way a
  --    day-kind one does -- mark_penalty_collected() has no kind of its own to check, so a
  --    week-kind debt must never sit uncollectable just because it has no per-commitment
  --    settlement_commitment rows to name (Week Close freezes none, lib/ledger.ts's own
  --    "Never" -- that is a client-side rendering fact, not a server-side restriction).
  -- -------------------------------------------------------------------------------
  select count(*) into v_count from public.penalty_current
   where id = v_penalty5 and state = 'owed' and kind = 'week';
  if v_count <> 1 then
    raise exception using message = format(
      'Fixture setup failed: account 5''s week-kind penalty read %s row(s) under `state = '
      'owed and kind = week`, expected 1.', v_count);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.mark_penalty_collected(v_penalty5);

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty5;
  if v_state <> 'collected' then
    raise exception using message = format(
      'Account 5''s week-kind penalty reads `%s` after Mark Collected, expected `collected` '
      '-- a week-kind debt must collect exactly the way a day-kind one does.', v_state);
  end if;

  raise notice using message =
    'Step 7 ok: a week-kind owed Penalty collects through mark_penalty_collected() exactly '
    'the same way a day-kind one does -- the function checks no kind at all.';

  -- -------------------------------------------------------------------------------
  -- 8. A referee session calling Mark Collected with a bogus id gets a distinct "No such
  --    penalty." message -- never the "already been resolved" guard message, which means
  --    something different (a real Penalty that simply is not owed any more). Mirrors
  --    rule_appeal()'s own precedent (Story 4.6: "No such appeal.").
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.mark_penalty_collected(gen_random_uuid());
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%no such penalty%'
     or v_message ilike '%already been resolved%'
  then
    raise exception using message = format(
      'A referee session marking a bogus penalty id collected read "%s", expected "No such '
      'penalty." -- distinct from the "already been resolved" guard message.',
      coalesce(v_message, '<null>'));
  end if;

  raise notice using message =
    'Step 8 ok: a referee session marking a bogus penalty id collected reads "No such '
    'penalty.", distinct from the "already been resolved" guard message.';

  raise notice using message =
    'PASS. Mark Collected moves an owed Penalty to collected and it leaves the owed list; a '
    'second call on the same Penalty is refused cleanly; a non-referee session is refused '
    'before any row is read, real Penalty or bogus id alike; a Held Penalty stays invisible '
    'on the owed list, is refused the same generic way if collection is attempted anyway, and '
    'names nothing through referee_missed_commitments() despite a genuine missed outcome '
    'existing for it; a multi-commitment day names every commitment through '
    'referee_missed_commitments(), which returns nothing at all to any non-referee session; a '
    'week-kind owed Penalty collects exactly the same way a day-kind one does; and a bogus '
    'penalty id reads a distinct "No such penalty." message, never "already been resolved."';
end $$;

rollback;
