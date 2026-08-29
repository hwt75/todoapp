-- Story 5.1 — A countable way to be forgiven (FR-17).
--
-- Every row of the spec's own I/O & Edge-Case Matrix, end to end: a spend accepted while the
-- allowance still has room; a day already Collected refused; a day under Appeal (held)
-- refused; the allowance itself exhausted after two spends this calendar month; a same-day
-- double-spend caught by the unique constraint rather than a race window; a normal fold-in
-- (Penalty waived, corrective settlement clean, chain restored, and — the fact that makes
-- this different from a won Appeal — the Ledger's own `penalty_current` read actually shows
-- `waived`, not nothing); a fold-in that loses its own race against an out-of-band change
-- (silent no-op, `processed_at` still set); the `grace_allowance_remaining` view's own
-- arithmetic; the RLS boundary (own rows only, no update, no delete, never someone else's
-- owner_id); and that a Grace Day and an Appeal can never both claim the same day
-- (`appeal_hold_penalty()`'s own new guard, step 14).
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/5-1-a-countable-way-to-be-forgiven.sql
--
-- Mirrors `2-7-supersession.sql`'s own structure: `apply_grace_days()`/`settle_day()` are
-- called directly inside the test transaction (no `pg_cron` fires in a SQL test), never a
-- synchronous RPC-and-assert pattern. One transaction, rolled back at the end. Nothing
-- persists, and a crash mid-run leaves the database exactly as it was.

begin;

-- The local stack's default privileges differ from the author's own project
-- (`4-6-the-referee-rules.sql`'s own header) -- the ordinary table reads/writes this fixture
-- exercises through RLS still need an explicit grant here even though the migration itself
-- needs none on the author's real project.
grant select on table public.profile to authenticated;
-- update/delete are granted here too, deliberately: on the author's real project
-- `authenticated` already holds them at the table-privilege layer (Supabase's own default),
-- and RLS -- no update/delete policy on grace_day at all -- is the only thing actually
-- stopping a write. Without the grant, step 9 below would fail on "permission denied for
-- table grace_day" and never reach the RLS layer this story's own boundary is about.
grant select, insert, update, delete on table public.grace_day to authenticated;
grant select on table public.penalty, public.settlement, public.settlement_commitment,
  public.commitment, public.grace_allowance_remaining to authenticated;
-- Step 14 needs an appeal attempt, refused by appeal_hold_penalty()'s own new Grace Day
-- exclusion guard.
grant select, insert on table public.appeal to authenticated;

do $$
declare
  -- Fixture
  v_user        uuid := gen_random_uuid();
  v_other       uuid := gen_random_uuid(); -- a second doer, for the RLS cross-account checks
  v_user3       uuid := gen_random_uuid(); -- a third doer, isolated for step 14's own
                                            -- Grace-Day-then-Appeal sequence, so it never
                                            -- shares v_user's already-exhausted allowance
  v_commitment  uuid;
  v_c3          uuid;

  v_day1        date; -- happy path: spent, then folded in normally
  v_day3        date; -- allowance exhausted by the time this attempt runs
  v_day4        date; -- already Collected
  v_day5        date; -- under Appeal (held)
  v_day6        date; -- happy path: spent, then loses its own race before fold-in
  v_day14       date; -- step 14's own day: grace-dayed, then appealed before fold-in

  v_settlement1 uuid;
  v_penalty1    uuid;
  v_amount1     bigint;
  v_settlement4 uuid;
  v_settlement5 uuid;
  v_settlement6 uuid;

  -- Observed
  v_refused     boolean;
  v_message     text;
  v_sqlstate    text;
  v_count       integer;
  v_state       public.penalty_state;
  v_verdict     public.day_verdict;
  v_outcome     public.commitment_outcome;
  v_correction1 uuid;
  v_remaining   integer;
  v_current     integer;
  v_longest     integer;
begin
  -- -------------------------------------------------------------------------------
  -- 0. Refuse to run anywhere the AD-16 guard would make the result meaningless.
  -- -------------------------------------------------------------------------------
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 1. Fixture: two doer accounts, one penalty-carrying daily commitment, five distinct
  --    Failed Days for v_user (each its own settlement, its own owed Penalty).
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-5-1-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user, v_other, v_user3]) as t(id);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_commitment;

  -- Each starts at least 2 days back, so `for_day + 1` (the morning the declaration below is
  -- stamped answered) is always safely in the past regardless of the wall-clock hour this
  -- test happens to run at.
  v_day1 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 2;
  v_day3 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 4;
  v_day4 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 5;
  v_day5 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 6;
  v_day6 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 7;

  -- Each day answered in full (an admitted slip), so settle_day() closes it on the spot --
  -- the same fixture shape 4-6-the-referee-rules.sql uses, never the 4-day-back expiry dance
  -- 2-7-supersession.sql needs (nothing here exercises the 48-hour deadline).
  --
  -- `declaration_derive_day()` derives `for_day` from `answered_at` itself
  -- (`for_day := (answered_at at Asia/Ho_Chi_Minh)::date - 1`, 20260819200000) rather than
  -- taking it as a client-supplied column, so each day's own declaration is stamped answered
  -- the *morning after* the day it is about -- mirroring 2-7-supersession.sql's own
  -- `v_answered` shape -- rather than all sharing `now()`, which would derive the identical
  -- `for_day` for every one of them and collide on `declaration_one_per_commitment_day`.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user, v_commitment, gen_random_uuid(), 'slipped',
    ((v_day1 + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');
  -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
  -- This fixture creates its commitments moments before judging days that predate them, which is
  -- a state no real account can reach — so it now says when they began. Order-preserving, so
  -- every created_at comparison downstream reads the same way, and idempotent, so the repeats
  -- below (each covering commitments created after the previous pass) age nothing twice.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day1, true);

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user, v_commitment, gen_random_uuid(), 'slipped',
    ((v_day3 + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day3, true);

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user, v_commitment, gen_random_uuid(), 'slipped',
    ((v_day4 + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day4, true);

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user, v_commitment, gen_random_uuid(), 'slipped',
    ((v_day5 + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day5, true);

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user, v_commitment, gen_random_uuid(), 'slipped',
    ((v_day6 + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day6, true);

  select id into v_settlement1 from public.settlement
   where subject = v_user and period = v_day1 and kind = 'day' and supersedes is null;
  select id, amount_dong into v_penalty1, v_amount1
    from public.penalty where settlement_id = v_settlement1;

  select id into v_settlement4 from public.settlement
   where subject = v_user and period = v_day4 and kind = 'day' and supersedes is null;
  select id into v_settlement5 from public.settlement
   where subject = v_user and period = v_day5 and kind = 'day' and supersedes is null;
  select id into v_settlement6 from public.settlement
   where subject = v_user and period = v_day6 and kind = 'day' and supersedes is null;

  if v_penalty1 is null or v_settlement4 is null or v_settlement5 is null or v_settlement6 is null
  then
    raise exception using message = 'Fixture setup failed: not every day settled Failed.';
  end if;

  raise notice using message =
    'Fixture ok: five Failed Days settled for v_user, each with its own owed Penalty.';

  -- A second, isolated account for step 14: an auto_check-filed miss (file_auto_check_result
  -- stamps filed_by = 'auto_check', which appeal_hold_penalty() requires), settled Failed
  -- the same way 4-6-the-referee-rules.sql's own fixture does.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_user3, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-3')
  returning id into v_c3;

  perform public.file_auto_check_result(v_c3, v_user3, 'missed');
  v_day14 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day14, true);

  if not exists (
    select 1 from public.settlement
     where subject = v_user3 and period = v_day14 and kind = 'day' and verdict = 'failed'
  ) then
    raise exception using message = 'Fixture setup failed: v_user3''s day did not settle Failed.';
  end if;

  raise notice using message =
    'Fixture ok: v_user3''s own auto_check-filed Failed Day settled, isolated for step 14.';

  -- -------------------------------------------------------------------------------
  -- 2. Spend, allowance available.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.grace_day (owner_id, for_day) values (v_user, v_day1);

  select count(*) into v_count from public.grace_day where owner_id = v_user and for_day = v_day1;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected exactly 1 grace_day row for day1 after a valid spend, found %s.', v_count);
  end if;

  raise notice using message = 'Step 2 ok: spend accepted while the allowance still had room.';

  -- -------------------------------------------------------------------------------
  -- 3. Double-spend the same day. The second insert's own trigger validation still passes
  --    (the day still reads failed/owed -- the first grace_day row is unprocessed and has
  --    changed nothing yet), so this is refused by the unique constraint alone, not by
  --    eligibility -- exactly the race the spec's own matrix names.
  -- -------------------------------------------------------------------------------
  v_refused := false;
  begin
    insert into public.grace_day (owner_id, for_day) values (v_user, v_day1);
  exception when unique_violation then
    v_refused := true;
    get stacked diagnostics v_sqlstate = returned_sqlstate;
  end;

  if not v_refused then
    raise exception using message = 'A second grace_day for the same day was not refused.';
  end if;

  select count(*) into v_count from public.grace_day where owner_id = v_user and for_day = v_day1;
  if v_count <> 1 then
    raise exception using message = format(
      'The double-spend must leave exactly 1 row behind, found %s.', v_count);
  end if;

  raise notice using message =
    'Step 3 ok: the second insert for the same day was refused (unique_violation), only one '
    'grace_day row stands.';

  -- -------------------------------------------------------------------------------
  -- 4. Spend, allowance available (second and final spend this calendar month).
  -- -------------------------------------------------------------------------------
  insert into public.grace_day (owner_id, for_day) values (v_user, v_day6);

  select count(*) into v_count from public.grace_day where owner_id = v_user and for_day = v_day6;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected exactly 1 grace_day row for day6 after a valid spend, found %s.', v_count);
  end if;

  raise notice using message = 'Step 4 ok: the second spend this month was also accepted.';

  -- -------------------------------------------------------------------------------
  -- 5. Spend, allowance exhausted. Both Grace Days for this month are now spent (day1,
  --    day6); day3 is otherwise perfectly eligible (Failed, owed, never graced) and still
  --    refused on the allowance alone.
  -- -------------------------------------------------------------------------------
  v_refused := false;
  begin
    insert into public.grace_day (owner_id, for_day) values (v_user, v_day3);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%Grace Day%' then
    raise exception using message = format(
      'A third spend this month was not refused with an allowance-specific message. '
      'refused=%s, message=%s', v_refused, coalesce(v_message, '<null>'));
  end if;

  select count(*) into v_count from public.grace_day where owner_id = v_user and for_day = v_day3;
  if v_count <> 0 then
    raise exception using message = 'A refused spend must leave nothing written.';
  end if;

  raise notice using message = format(
    'Step 5 ok: a third spend this month was refused (%s), nothing written.', v_message);

  -- -------------------------------------------------------------------------------
  -- 6. Spend, day already Collected. Checked ahead of the (already-exhausted) allowance --
  --    the message names the real reason, not a generic refusal.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'postgres', true);
  update public.penalty set state = 'collected' where settlement_id = v_settlement4;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    insert into public.grace_day (owner_id, for_day) values (v_user, v_day4);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%collected%' then
    raise exception using message = format(
      'A Collected day was not refused with a message naming its actual state. '
      'refused=%s, message=%s', v_refused, coalesce(v_message, '<null>'));
  end if;

  select count(*) into v_count from public.grace_day where owner_id = v_user and for_day = v_day4;
  if v_count <> 0 then
    raise exception using message = 'A refused spend against a Collected day wrote a row.';
  end if;

  raise notice using message = 'Step 6 ok: a Collected day was refused, nothing written.';

  -- -------------------------------------------------------------------------------
  -- 7. Spend, day under Appeal (held).
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'postgres', true);
  update public.penalty set state = 'held' where settlement_id = v_settlement5;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    insert into public.grace_day (owner_id, for_day) values (v_user, v_day5);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%held%' then
    raise exception using message = format(
      'A Held (under-Appeal) day was not refused with a message naming its actual state. '
      'refused=%s, message=%s', v_refused, coalesce(v_message, '<null>'));
  end if;

  select count(*) into v_count from public.grace_day where owner_id = v_user and for_day = v_day5;
  if v_count <> 0 then
    raise exception using message = 'A refused spend against a Held day wrote a row.';
  end if;

  raise notice using message = 'Step 7 ok: a Held day was refused, nothing written.';

  -- -------------------------------------------------------------------------------
  -- 8. RLS: v_other can neither spend against v_user's own day nor read v_user's rows.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    insert into public.grace_day (owner_id, for_day) values (v_user, v_day3);
  exception when others then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'v_other inserted a grace_day naming v_user as owner_id -- the RLS with check '
      '(auth.uid() = owner_id) did not hold.';
  end if;

  -- Still running as v_other: RLS must filter v_user's own rows out entirely, not merely
  -- decline to name how many exist.
  select count(*) into v_count from public.grace_day where owner_id = v_user;
  if v_count <> 0 then
    raise exception using message = format(
      'v_other can read %s of v_user''s own grace_day rows -- "grace_day: read own" did not '
      'hold.', v_count);
  end if;

  raise notice using message =
    'Step 8 ok: v_other can neither spend against v_user''s day nor read v_user''s rows.';

  -- -------------------------------------------------------------------------------
  -- 9. Never: no update, no delete, once a row lands -- append-only (AD-9). RLS filters
  --    rather than raises for a command with no applicable policy, so this is 0 rows
  --    affected, not an exception.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  update public.grace_day set processed_at = now() where owner_id = v_user;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'A client session updated %s grace_day row(s) -- there must be no update policy.',
      v_count);
  end if;

  delete from public.grace_day where owner_id = v_user;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'A client session deleted %s grace_day row(s) -- there must be no delete policy.',
      v_count);
  end if;

  perform set_config('role', 'postgres', true);

  select count(*) into v_count from public.grace_day where owner_id = v_user;
  if v_count <> 2 then
    raise exception using message = format(
      'Expected the 2 spent rows (day1, day6) to still exist untouched, found %s.', v_count);
  end if;

  raise notice using message =
    'Step 9 ok: neither update nor delete reached a grace_day row from a client session.';

  -- -------------------------------------------------------------------------------
  -- 10. Fold-in, lost race -- set up before the fold-in call itself runs: between day6's
  --     insert (step 4) and the schedule catching up, its Penalty leaves owed some other
  --     way (should not happen given the Never boundary; guarded anyway).
  -- -------------------------------------------------------------------------------
  update public.penalty set state = 'collected' where settlement_id = v_settlement6;

  -- -------------------------------------------------------------------------------
  -- 11. Fold-in. Processes every unprocessed grace_day row in one pass: day1 (normal) and
  --     day6 (lost race) together.
  -- -------------------------------------------------------------------------------
  select ch.current_days into v_current from public.chain_current ch
   where ch.commitment_id = v_commitment;
  if coalesce(v_current, 0) <> 0 then
    raise exception using message = format(
      'Fixture is wrong: expected the chain to read 0 before any fold-in (day1, the most '
      'recent judged day, still reads missed), got %s.', v_current);
  end if;

  v_count := public.apply_grace_days();
  if v_count <> 1 then
    raise exception using message = format(
      'apply_grace_days() reported %s day(s) corrected, expected exactly 1 (day1 alone -- '
      'day6''s own lost race must not count as a correction).', v_count);
  end if;

  -- day1: waived, corrected, chain restored.
  select state into v_state from public.penalty where id = v_penalty1;
  if v_state <> 'waived' then
    raise exception using message = format(
      'day1''s original Penalty must read waived after fold-in, reads %s.', v_state);
  end if;

  select id, verdict into v_correction1, v_verdict
    from public.settlement where supersedes = v_settlement1;
  if v_correction1 is null then
    raise exception using message = 'No corrective settlement references day1''s original.';
  end if;
  if v_verdict <> 'clean' then
    raise exception using message = format(
      'A Grace Day forgives the whole day, so the correction must read clean, not %s.',
      v_verdict);
  end if;

  select count(*) into v_count from public.settlement_commitment where settlement_id = v_correction1;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected 1 frozen outcome on day1''s correction, found %s.', v_count);
  end if;
  select outcome into v_outcome
    from public.settlement_commitment where settlement_id = v_correction1;
  if v_outcome <> 'held' then
    raise exception using message = format(
      'day1''s commitment must freeze as held on the correction (mirrors rule_appeal()''s '
      'own chain-restoration fix), reads %s.', v_outcome);
  end if;

  -- The fact that distinguishes `waived` from `voided`: penalty_current (which the Ledger
  -- reads) must actually show a row for day1, state waived -- never nothing.
  select count(*), max(state), max(amount_dong) into v_count, v_state, v_amount1
    from public.penalty_current where subject = v_user and period = v_day1 and kind = 'day';
  if v_count <> 1 or v_state <> 'waived' then
    raise exception using message = format(
      'penalty_current for day1 must show exactly 1 row, state waived -- the Ledger''s own '
      'read -- found %s row(s), state %s.', v_count, coalesce(v_state::text, '<null>'));
  end if;

  select ch.current_days, ch.longest_days into v_current, v_longest
    from public.chain_current ch where ch.commitment_id = v_commitment;
  if v_current <> 1 or v_longest <> 1 then
    raise exception using message = format(
      'The chain must read 1 / 1 once day1 (the most recently judged day) is restored to '
      'held, got %s / %s.', v_current, v_longest);
  end if;

  select processed_at is not null into v_refused
    from public.grace_day where owner_id = v_user and for_day = v_day1;
  if not v_refused then
    raise exception using message = 'day1''s grace_day row must carry processed_at once folded in.';
  end if;

  raise notice using message =
    'Step 11a ok: day1 waived, corrective settlement clean, one held outcome frozen, '
    'penalty_current shows it, chain reads 1 / 1.';

  -- day6: the lost race. Untouched Penalty, no correction, but still marked processed --
  -- void_expired_appeals()'s own convention: no synchronous caller left to raise to.
  select state into v_state from public.penalty where settlement_id = v_settlement6;
  if v_state <> 'collected' then
    raise exception using message = format(
      'day6''s Penalty must stay exactly as the race left it (collected), reads %s -- '
      'apply_grace_days() must never overwrite a Penalty that already left owed.', v_state);
  end if;

  select count(*) into v_count from public.settlement where supersedes = v_settlement6;
  if v_count <> 0 then
    raise exception using message = format(
      'day6 lost its own race and must carry no corrective settlement, found %s.', v_count);
  end if;

  select processed_at is not null into v_refused
    from public.grace_day where owner_id = v_user and for_day = v_day6;
  if not v_refused then
    raise exception using message =
      'day6''s grace_day row must still carry processed_at even though it was a no-op -- '
      'the fold-in must not retry it forever.';
  end if;

  raise notice using message =
    'Step 11b ok: day6''s lost race left its Penalty untouched and wrote no correction, but '
    'is marked processed all the same.';

  -- -------------------------------------------------------------------------------
  -- 12. grace_allowance_remaining: 2 spent this month (day1, day6), regardless of whether
  --     either one actually corrected anything -- the count is of grace_day rows, never of
  --     successful corrections.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select remaining into v_remaining from public.grace_allowance_remaining where owner_id = v_user;
  if v_remaining <> 0 then
    raise exception using message = format(
      'Expected 0 Grace Days remaining this month (2 spent, 2 allowed), got %s.', v_remaining);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message = 'Step 12 ok: grace_allowance_remaining reads 0 after both are spent.';

  -- -------------------------------------------------------------------------------
  -- 13. Append-only, for real: once day1 is corrected, its current settlement itself reads
  --     clean -- a further attempt to grace it again is refused by eligibility before it
  --     ever reaches the unique constraint a second time.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    insert into public.grace_day (owner_id, for_day) values (v_user, v_day1);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused then
    raise exception using message = 'A corrected day accepted a second Grace Day.';
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message = format(
    'Step 13 ok: a corrected day refuses a second Grace Day (%s).', v_message);

  -- -------------------------------------------------------------------------------
  -- 14. Grace Day and Appeal are mutually exclusive on the same day. v_user3's own day is
  --     spent as a Grace Day first (unprocessed -- apply_grace_days() never runs for it in
  --     this test), then an appeal attempt against the same day is refused by
  --     appeal_hold_penalty()'s own new guard before it ever reaches the hold.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user3, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.grace_day (owner_id, for_day) values (v_user3, v_day14);

  v_refused := false;
  begin
    insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
    values (v_user3, v_c3, gen_random_uuid(), v_day14);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%Grace Day%' then
    raise exception using message = format(
      'An appeal against a day already spent as a Grace Day was not refused with a '
      'Grace-Day-specific message. refused=%s, message=%s',
      v_refused, coalesce(v_message, '<null>'));
  end if;

  select count(*) into v_count from public.appeal where owner_id = v_user3;
  if v_count <> 0 then
    raise exception using message = format(
      'A refused appeal against a grace-dayed day wrote %s row(s).', v_count);
  end if;

  -- And the Penalty itself is untouched by the refused attempt -- still owed, never held.
  select p.state into v_state
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_user3 and s.period = v_day14 and s.kind = 'day' and s.supersedes is null;
  if v_state <> 'owed' then
    raise exception using message = format(
      'A refused appeal attempt must leave the Penalty exactly as it was (owed), reads %s.',
      v_state);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message = format(
    'Step 14 ok: an appeal against a day already spent as a Grace Day was refused (%s), no '
    'row written, the Penalty left untouched.', v_message);

  raise notice using message =
    'PASS. Every I/O Matrix row holds: eligibility validated synchronously with a clear '
    'message, the correction itself folded in later by settlement alone, waived staying '
    'visible where voided never was, the RLS/append-only boundaries hold throughout, and '
    'Grace Days and Appeals cannot both claim the same day.';
end $$;

rollback;
