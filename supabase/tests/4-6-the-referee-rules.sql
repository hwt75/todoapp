-- Story 4.6 — The referee rules (FR-20).
--
-- Covers the spec's own I/O matrix end to end: approval on a day where the appealed miss was
-- the only one (voided, corrective settlement reads clean, chain restored); approval on a day
-- a second, non-appealed miss also touched (voided, corrective settlement stays failed with a
-- smaller-context penalty); rejection (owed, no settlement change); both directions of the
-- AD-15 race (a timeout that beat the ruling, and a ruling that beat a second ruling); a
-- non-referee session refused before any row is read, proven against both a real appeal and a
-- bogus id so the refusal order itself is pinned down; the referee's own read of evidence
-- through the new storage.objects policy, proven against a real object row and refused for a
-- doer session the same way; and the approval recompute's own `cadence <> 'weekly_quota'`
-- exclusion, proven against a real same-day weekly_quota slip that must not keep the
-- corrected day failed.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/4-6-the-referee-rules.sql
--
-- One transaction, rolled back at the end. Nothing persists.

begin;

-- The local stack's default privileges differ from the author's own project (recorded in
-- `2-1-roles-and-rls.sql`'s own header) -- `rule_appeal`'s own EXECUTE grant to `authenticated`
-- is written into the migration itself and needs nothing extra here, but the ordinary table
-- reads/writes this fixture exercises through RLS still do.
grant select on table public.profile to authenticated;
grant select, insert on table public.appeal, public.evidence to authenticated;
grant select on public.penalty, public.settlement, public.settlement_commitment, public.commitment
  to authenticated;

do $$
declare
  -- Account 1: sole cause. One machine-filed miss, appealed, then approved -- the day's only
  -- penalty-carrying miss, so the correction reads clean and carries no penalty at all.
  v_user1        uuid := gen_random_uuid();
  v_c1           uuid;

  -- Account 2: another genuine miss the same day. c2's own honest slip is never appealed --
  -- approving c1's appeal must still leave the day `failed`, with a new, smaller-context
  -- penalty that is not the one the appeal voided.
  v_user2        uuid := gen_random_uuid();
  v_c2a          uuid; -- machine-filed missed, appealed, approved
  v_c2b          uuid; -- the author's own honest slip, never appealed

  -- Account 3: rejection. "He didn't" -- owed, no settlement written.
  v_user3        uuid := gen_random_uuid();
  v_c3           uuid;

  -- Account 4: the timeout wins the AD-15 race first -- void_expired_appeals() already moved
  -- this Penalty to dropped before any ruling is attempted.
  v_user4        uuid := gen_random_uuid();
  v_c4           uuid;

  -- Account 5: a ruling wins the AD-15 race against a second ruling attempt on the exact
  -- same appeal -- the second call must find zero rows and change nothing further.
  v_user5        uuid := gen_random_uuid();
  v_c5           uuid;

  -- Account 6: a doer, ruling on his own appeal -- refused before anything about the appeal
  -- is even read, the same as it would be for any other non-referee caller.
  v_user6        uuid := gen_random_uuid();
  v_c6           uuid;

  -- Account 7: the weekly_quota exclusion. Owns the appealed daily commitment AND a
  -- separate weekly_quota, carries_penalty commitment declared `slipped` the same day --
  -- `commitments_owing()` never excludes weekly_quota from its result set (only
  -- daily_hours_quota is excluded), so without the `cadence <> 'weekly_quota'` filter on
  -- rule_appeal()'s own admitted/silent recompute, c7w's own slip would wrongly count and
  -- keep the corrected day `failed` with an unwarranted new penalty. Approving c7's appeal
  -- must correct the day to `clean` with zero new penalty rows.
  v_user7        uuid := gen_random_uuid();
  v_c7           uuid; -- daily, auto_check, appealed
  v_c7w          uuid; -- weekly_quota, carries_penalty, declared slipped -- never appealed

  v_referee      uuid := gen_random_uuid();

  v_day          date;

  v_settlement1  uuid;
  v_penalty1     uuid;
  v_appeal1      uuid;
  v_correction1  uuid;

  v_settlement2  uuid;
  v_penalty2     uuid;
  v_appeal2      uuid;
  v_correction2  uuid;
  v_penalty2new  uuid;

  v_settlement3  uuid;
  v_penalty3     uuid;
  v_appeal3      uuid;

  v_settlement4  uuid;
  v_penalty4     uuid;
  v_appeal4      uuid;

  v_settlement5  uuid;
  v_penalty5     uuid;
  v_appeal5      uuid;

  v_settlement6  uuid;
  v_penalty6     uuid;
  v_appeal6      uuid;

  v_settlement7  uuid;
  v_penalty7     uuid;
  v_appeal7      uuid;
  v_correction7  uuid;

  v_evidence1    uuid;

  v_state        public.penalty_state;
  v_verdict      public.day_verdict;
  v_count        integer;
  v_refused      boolean;
  v_message      text;
  v_outcome      public.commitment_outcome;
  v_body         text;
  v_amount       bigint;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- Fixture: six doer accounts, the referee, and every commitment each account needs.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-4-6-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user1, v_user2, v_user3, v_user4, v_user5, v_user6, v_user7, v_referee])
      as t(id);

  update public.profile set role = 'referee' where id = v_referee;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user1, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-1')
  returning id into v_c1;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user2, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-2a')
  returning id into v_c2a;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user2, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c2b;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user3, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-3')
  returning id into v_c3;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user4, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-4')
  returning id into v_c4;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user5, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-5')
  returning id into v_c5;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user6, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-6')
  returning id into v_c6;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user7, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-7')
  returning id into v_c7;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day)
  values (v_user7, gen_random_uuid(), 'Weekly gym', 'do', 'weekly_quota', true, 3, 1)
  returning id into v_c7w;

  perform public.file_auto_check_result(v_c1, v_user1, 'missed');
  perform public.file_auto_check_result(v_c2a, v_user2, 'missed');
  perform public.file_auto_check_result(v_c3, v_user3, 'missed');
  perform public.file_auto_check_result(v_c4, v_user4, 'missed');
  perform public.file_auto_check_result(v_c5, v_user5, 'missed');
  perform public.file_auto_check_result(v_c6, v_user6, 'missed');
  perform public.file_auto_check_result(v_c7, v_user7, 'missed');

  -- Account 2's own honest slip alongside its machine-filed miss -- never machine-filed,
  -- never appealable, and still owed after c2a's own Penalty voids.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user2, v_c2b, gen_random_uuid(), 'slipped', now());

  -- Account 7's own weekly_quota commitment, declared slipped the same day as its
  -- (appealed) daily one. carries_penalty on a weekly_quota commitment never triggers a
  -- *daily* Penalty (FR-2, 20260820140000) -- this row exists only to prove
  -- rule_appeal()'s own recompute excludes it from admitted the same way settle_day() does.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user7, v_c7w, gen_random_uuid(), 'slipped', now());

  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
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

  select id into v_settlement5 from public.settlement
   where subject = v_user5 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty5 from public.penalty where settlement_id = v_settlement5;

  select id into v_settlement6 from public.settlement
   where subject = v_user6 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty6 from public.penalty where settlement_id = v_settlement6;

  select id into v_settlement7 from public.settlement
   where subject = v_user7 and period = v_day and kind = 'day' and supersedes is null;
  select id into v_penalty7 from public.penalty where settlement_id = v_settlement7;

  if v_penalty1 is null or v_penalty2 is null or v_penalty3 is null
     or v_penalty4 is null or v_penalty5 is null or v_penalty6 is null or v_penalty7 is null then
    raise exception using message = 'Fixture setup failed: not every account''s day settled.';
  end if;

  -- Every appeal, filed as its own owning account.
  perform set_config('role', 'authenticated', true);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user1, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user1, v_c1, gen_random_uuid(), v_day) returning id into v_appeal1;

  insert into public.evidence (appeal_id, storage_path, captured_on)
  values (v_appeal1, v_appeal1::text || '/proof.jpg', v_day) returning id into v_evidence1;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user2, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user2, v_c2a, gen_random_uuid(), v_day) returning id into v_appeal2;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user3, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user3, v_c3, gen_random_uuid(), v_day) returning id into v_appeal3;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user4, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user4, v_c4, gen_random_uuid(), v_day) returning id into v_appeal4;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user5, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user5, v_c5, gen_random_uuid(), v_day) returning id into v_appeal5;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user6, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user6, v_c6, gen_random_uuid(), v_day) returning id into v_appeal6;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user7, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_user7, v_c7, gen_random_uuid(), v_day) returning id into v_appeal7;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Fixture ok: seven accounts settled the same day, seven Held Penalties behind seven '
    'appeals, account 2 carries a second, non-appealed genuine miss the same day, account 7 '
    'carries a separate weekly_quota slip the same day.';

  -- -------------------------------------------------------------------------------
  -- 1. Non-referee refused, before any row is read -- proven against a real appeal AND a
  --    bogus id, so the message itself (not merely the final state) pins down that the role
  --    check runs first. Account 6 rules on its own appeal, which RLS would let it read
  --    (appeal: read own) even though rule_appeal() never reaches that read at all.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user6, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    perform public.rule_appeal(v_appeal6, true);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%referee%' then
    raise exception using message = format(
      'A doer session ruling on its own appeal was not refused with a referee-specific '
      'message. refused=%s, message=%s', v_refused, coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.rule_appeal(gen_random_uuid(), true);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%referee%' or v_message ilike '%no such appeal%' then
    raise exception using message = format(
      'A doer session ruling on a bogus appeal id read "%s" -- the role check must refuse '
      'before the appeal is ever looked up, so this must read the same referee-only message '
      'as a real appeal, never "no such appeal".', coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty6;
  if v_state <> 'held' then
    raise exception using message = format(
      'Account 6''s penalty reads `%s` after two refused non-referee attempts, expected '
      '`held` -- untouched.', v_state);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 1 ok: a non-referee session is refused before any appeal row is read, whether the '
    'id is real (even its own appeal) or bogus -- both read the same referee-only message.';

  -- -------------------------------------------------------------------------------
  -- 2. Referee, bogus id -- "No such appeal", distinct from the role refusal above.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.rule_appeal(gen_random_uuid(), true);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%no such appeal%' then
    raise exception using message = format(
      'A referee session ruling on a bogus appeal id read "%s", expected "No such appeal."',
      coalesce(v_message, '<null>'));
  end if;

  raise notice using message = 'Step 2 ok: a referee session ruling on a bogus id is refused '
    'with "No such appeal.", not the role-refusal message.';

  -- -------------------------------------------------------------------------------
  -- 2b. A NULL p_approved is refused before the appeal is touched -- the exact hazard the
  --     migration's own comment names: `if not p_approved` treats a NULL argument as false
  --     and falls through into the approval branch, voiding a Held Penalty for a call that
  --     named no ruling at all. Run against account 1's own appeal, which Step 3 below then
  --     rules on normally -- proving the guard changed nothing about the real ruling that
  --     follows it.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.rule_appeal(v_appeal1, null);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%p_approved%' then
    raise exception using message = format(
      'A NULL p_approved read "%s", expected the "p_approved must not be null." refusal.',
      coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty1;
  if v_state <> 'held' then
    raise exception using message = format(
      'Account 1''s penalty reads `%s` after a refused NULL-approved ruling, expected `held` '
      '-- untouched.', v_state);
  end if;

  raise notice using message = 'Step 2b ok: rule_appeal() with a NULL p_approved is refused '
    'before anything is written, leaving the Penalty exactly where Step 3 expects to find it.';

  -- -------------------------------------------------------------------------------
  -- 3. Approve, sole cause (account 1). Penalty voids; the corrective settlement reads
  --    clean and carries no penalty; the chain reads the appealed commitment as held, not
  --    missed, on the day it was corrected; one outbox notification, self-dated, naming the
  --    amount cleared.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.rule_appeal(v_appeal1, true);

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty1;
  if v_state <> 'voided' then
    raise exception using message = format(
      'Account 1''s original penalty reads `%s` after approval, expected `voided`.', v_state);
  end if;

  select id, verdict into v_correction1, v_verdict from public.settlement
   where supersedes = v_settlement1;
  if v_correction1 is null or v_verdict <> 'clean' then
    raise exception using message = format(
      'Account 1''s corrective settlement is %s / `%s`, expected a row reading `clean` -- the '
      'appealed commitment was the day''s only penalty-carrying miss.', v_correction1, v_verdict);
  end if;

  select count(*) into v_count from public.penalty where settlement_id = v_correction1;
  if v_count <> 0 then
    raise exception using message = format(
      'Account 1''s corrective settlement carries %s penalty row(s), expected 0 -- a clean '
      'day owes nothing.', v_count);
  end if;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_correction1 and commitment_id = v_c1;
  if v_outcome <> 'held' then
    raise exception using message = format(
      'The corrected day''s own frozen outcome for the appealed commitment reads `%s`, '
      'expected `held` -- the chain must read restored, not merely skipped.', v_outcome);
  end if;

  -- The Ledger's own read (penalty_current, joined through settlement_current) must show
  -- nothing owed for this day any more -- the voided original belongs to a superseded
  -- settlement and drops out of the current view entirely, which is what "restoring the '
  -- chain rather than merely forgiving money" means in practice.
  select count(*) into v_count from public.penalty_current
   where subject = v_user1 and period = v_day and kind = 'day';
  if v_count <> 0 then
    raise exception using message = format(
      'penalty_current still carries %s row(s) for account 1''s corrected day, expected 0.',
      v_count);
  end if;

  select payload ->> 'body' into v_body from public.outbox
   where dedupe_key = 'ruling-' || v_appeal1::text;
  if v_body is null or v_body not ilike '%did it%' or v_body not ilike '%cleared%' then
    raise exception using message = format(
      'Account 1''s ruling notification reads "%s", expected it to say he did it and that '
      'the amount is cleared.', coalesce(v_body, '<none enqueued>'));
  end if;

  raise notice using message =
    'Step 3 ok: approving the day''s only penalty-carrying miss voids the Penalty, corrects '
    'the day to clean with no penalty, freezes the appealed commitment as held (chain '
    'restored), drops the day out of the current Ledger view entirely, and notifies the '
    'author.';

  -- -------------------------------------------------------------------------------
  -- 4. Approve, another genuine miss the same day (account 2). Penalty voids; the
  --    corrective settlement still reads failed, with a new, smaller-context penalty --
  --    distinct from the one that voided -- covering c2b's own honest, non-appealed slip.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.rule_appeal(v_appeal2, true);

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty2;
  if v_state <> 'voided' then
    raise exception using message = format(
      'Account 2''s original penalty reads `%s` after approval, expected `voided`.', v_state);
  end if;

  select id, verdict into v_correction2, v_verdict from public.settlement
   where supersedes = v_settlement2;
  if v_correction2 is null or v_verdict <> 'failed' then
    raise exception using message = format(
      'Account 2''s corrective settlement is %s / `%s`, expected `failed` -- c2b''s own '
      'honest slip was never appealed and still counts.', v_correction2, v_verdict);
  end if;

  select id into v_penalty2new from public.penalty where settlement_id = v_correction2;
  if v_penalty2new is null or v_penalty2new = v_penalty2 then
    raise exception using message = format(
      'Account 2''s corrective settlement carries penalty %s, expected a NEW row distinct '
      'from the voided original %s.', v_penalty2new, v_penalty2);
  end if;

  select state, amount_dong into v_state, v_amount from public.penalty where id = v_penalty2new;
  if v_state <> 'owed' or v_amount <> public.penalty_amount_dong() then
    raise exception using message = format(
      'Account 2''s new penalty reads `%s` / %s, expected `owed` / %s.',
      v_state, v_amount, public.penalty_amount_dong());
  end if;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_correction2 and commitment_id = v_c2a;
  if v_outcome <> 'held' then
    raise exception using message = format(
      'c2a''s frozen outcome on the corrected day reads `%s`, expected `held`.', v_outcome);
  end if;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_correction2 and commitment_id = v_c2b;
  if v_outcome <> 'missed' then
    raise exception using message = format(
      'c2b''s own honest slip reads `%s` on the corrected day, expected `missed` -- it was '
      'never appealed and must still count.', v_outcome);
  end if;

  -- The current Ledger view now shows exactly one owed penalty for the day, at the plain
  -- amount -- not two, and not the voided original.
  select count(*), coalesce(sum(amount_dong), 0) into v_count, v_amount
    from public.penalty_current
   where subject = v_user2 and period = v_day and kind = 'day';
  if v_count <> 1 or v_amount <> public.penalty_amount_dong() then
    raise exception using message = format(
      'penalty_current reads %s row(s) totalling %s for account 2''s corrected day, expected '
      '1 row at %s.', v_count, v_amount, public.penalty_amount_dong());
  end if;

  raise notice using message =
    'Step 4 ok: approving one of two genuine misses the same day voids only the appealed '
    'Penalty and corrects the day to a new, smaller-context penalty covering the other, '
    'still-standing miss -- never the same row, never two penalties live at once.';

  -- -------------------------------------------------------------------------------
  -- 5. Reject (account 3). "He didn't" -- owed, no settlement written, no chain change.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.rule_appeal(v_appeal3, false);

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty3;
  if v_state <> 'owed' then
    raise exception using message = format(
      'Account 3''s penalty reads `%s` after rejection, expected `owed`.', v_state);
  end if;

  select count(*) into v_count from public.settlement where supersedes = v_settlement3;
  if v_count <> 0 then
    raise exception using message = format(
      'Account 3''s settlement gained %s correction row(s) on a rejection -- "no settlement '
      'change" means none, not merely none that voids anything.', v_count);
  end if;

  select payload ->> 'body' into v_body from public.outbox
   where dedupe_key = 'ruling-' || v_appeal3::text;
  if v_body is null or v_body not ilike '%didn''t%' or v_body not ilike '%owed%' then
    raise exception using message = format(
      'Account 3''s ruling notification reads "%s", expected it to say he didn''t and that '
      'the amount is owed.', coalesce(v_body, '<none enqueued>'));
  end if;

  raise notice using message =
    'Step 5 ok: rejecting converts the Penalty to owed, writes no settlement row of any '
    'kind, and notifies the author that it stands.';

  -- -------------------------------------------------------------------------------
  -- 6. Race: the timeout wins first (account 4). void_expired_appeals() already moved this
  --    Penalty to dropped -- a ruling attempted afterward must refuse cleanly and change
  --    nothing, from either direction (approve or reject both tried).
  -- -------------------------------------------------------------------------------
  update public.appeal set deadline = now() - interval '1 hour' where id = v_appeal4;
  perform public.void_expired_appeals();

  select state into v_state from public.penalty where id = v_penalty4;
  if v_state <> 'dropped' then
    raise exception using message = format(
      'Fixture setup failed: account 4''s penalty reads `%s` after void_expired_appeals(), '
      'expected `dropped`.', v_state);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.rule_appeal(v_appeal4, true);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%already been resolved%' then
    raise exception using message = format(
      'Ruling on an already-timed-out appeal read "%s", expected the "already been '
      'resolved" refusal.', coalesce(v_message, '<null>'));
  end if;

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty4;
  if v_state <> 'dropped' then
    raise exception using message = format(
      'Account 4''s penalty reads `%s` after a refused ruling, expected it to stay `dropped` '
      '-- untouched by the losing side of the race.', v_state);
  end if;

  select count(*) into v_count from public.outbox where dedupe_key = 'ruling-' || v_appeal4::text;
  if v_count <> 0 then
    raise exception using message = format(
      'A refused ruling still enqueued %s outbox row(s) -- the race loser must never reach '
      'the notification at all.', v_count);
  end if;

  raise notice using message =
    'Step 6 ok: a ruling attempted after the timeout already dropped the Penalty is refused '
    'cleanly, leaves the Penalty exactly as the timeout left it, and enqueues nothing.';

  -- -------------------------------------------------------------------------------
  -- 7. Race: a ruling wins first, a second ruling on the same appeal loses (account 5).
  --    AD-15 from the other direction -- the first call's own side effects must stand
  --    exactly as it left them.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.rule_appeal(v_appeal5, true);

  v_refused := false;
  begin
    perform public.rule_appeal(v_appeal5, false);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%already been resolved%' then
    raise exception using message = format(
      'A second ruling call on an already-ruled appeal read "%s", expected the "already '
      'been resolved" refusal.', coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty5;
  if v_state <> 'voided' then
    raise exception using message = format(
      'Account 5''s penalty reads `%s` after a second, refused ruling call, expected it to '
      'stay `voided` exactly as the first call left it.', v_state);
  end if;

  select count(*) into v_count from public.settlement where supersedes = v_settlement5;
  if v_count <> 1 then
    raise exception using message = format(
      'Account 5''s settlement gained %s correction row(s) across two ruling calls on the '
      'same appeal, expected exactly 1 -- the guarded update''s own first-writer-wins '
      'guarantee (rule_appeal() has no separate settlement_once_correction constraint; the '
      'second call''s `where state = ''held''` finds zero rows and never reaches the insert).',
      v_count);
  end if;

  select count(*) into v_count from public.outbox where dedupe_key = 'ruling-' || v_appeal5::text;
  if v_count <> 1 then
    raise exception using message = format(
      'account 5''s ruling enqueued %s outbox row(s) across two calls, expected exactly 1.',
      v_count);
  end if;

  raise notice using message =
    'Step 7 ok: a second ruling call on an appeal a first call already resolved is refused, '
    'leaves the Penalty exactly as the winning call left it, writes no second correction, '
    'and enqueues no second notification.';

  -- -------------------------------------------------------------------------------
  -- 8. Evidence read: the referee reads account 1's evidence object through the new
  --    storage.objects policy; a doer session (account 2, reading account 1's evidence)
  --    still cannot, the same as before this story.
  -- -------------------------------------------------------------------------------
  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_appeal1::text || '/proof.jpg', v_user1);

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  select count(*) into v_count from storage.objects
   where bucket_id = 'appeal-evidence' and name = v_appeal1::text || '/proof.jpg';
  if v_count <> 1 then
    raise exception using message = format(
      'The referee session read %s row(s) of account 1''s evidence object through '
      'storage.objects, expected 1 -- the new referee SELECT policy.', v_count);
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user2, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select count(*) into v_count from storage.objects
   where bucket_id = 'appeal-evidence' and name = v_appeal1::text || '/proof.jpg';
  if v_count <> 0 then
    raise exception using message = format(
      'A doer session (account 2) read %s row(s) of account 1''s evidence object -- only the '
      'submitting owner and the referee may ever read it (NFR4).', v_count);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 8 ok: the referee reads an appeal''s evidence object through the new '
    'storage.objects policy; a doer session reading another account''s evidence still cannot.';

  -- -------------------------------------------------------------------------------
  -- 9. The weekly_quota exclusion (account 7). c7w's own slip is real, carries_penalty,
  --    and unappealed -- if rule_appeal()'s own admitted/silent recompute ever lost its
  --    `cadence <> 'weekly_quota'` filter, this is exactly the case that would silently
  --    break: the corrected day would wrongly stay `failed` and charge an unwarranted new
  --    penalty. commitments_owing() never excludes weekly_quota from its result set (only
  --    daily_hours_quota is), so this is a real, reachable path, not a hypothetical one.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.rule_appeal(v_appeal7, true);

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where id = v_penalty7;
  if v_state <> 'voided' then
    raise exception using message = format(
      'Account 7''s original penalty reads `%s` after approval, expected `voided`.', v_state);
  end if;

  select id, verdict into v_correction7, v_verdict from public.settlement
   where supersedes = v_settlement7;
  if v_correction7 is null or v_verdict <> 'clean' then
    raise exception using message = format(
      'Account 7''s corrective settlement is %s / `%s`, expected `clean` -- c7w''s own '
      'weekly_quota slip must be excluded from admitted, the same way settle_day() excludes '
      'it, or this reads `failed` instead.', v_correction7, v_verdict);
  end if;

  select count(*) into v_count from public.penalty where settlement_id = v_correction7;
  if v_count <> 0 then
    raise exception using message = format(
      'Account 7''s corrective settlement carries %s penalty row(s), expected 0 -- a '
      'weekly_quota slip must never trigger a daily Penalty (FR-2), corrected or otherwise.',
      v_count);
  end if;

  -- c7w's own frozen outcome on the correction is untouched by the exclusion -- it still
  -- reads `missed` (the exclusion is about money, never about the chain/history freeze).
  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_correction7 and commitment_id = v_c7w;
  if v_outcome <> 'missed' then
    raise exception using message = format(
      'c7w''s frozen outcome on the corrected day reads `%s`, expected `missed` -- the '
      'money exclusion must not also erase its own history.', v_outcome);
  end if;

  raise notice using message =
    'Step 9 ok: a separate weekly_quota slip the same day is correctly excluded from the '
    'approval recompute''s own admitted count -- the corrected day reads clean with no new '
    'penalty, while the weekly_quota commitment''s own frozen outcome still reads missed.';

  raise notice using message =
    'PASS. Approval voids the Held Penalty and corrects the day -- clean with no penalty when '
    'it was the day''s only miss, still failed with a new smaller-context penalty when '
    'another genuine miss remains, and still clean when the only other same-day miss is a '
    'weekly_quota commitment''s own slip -- and freezes the appealed commitment as held so '
    'the chain reads restored. Rejection converts to owed and writes no settlement row. Both '
    'directions of the AD-15 race refuse cleanly and change nothing further. A non-referee '
    'session is refused before any row is read, real appeal or bogus id alike. The referee '
    'reads evidence through the new storage policy; a doer session still cannot.';
end $$;

rollback;
