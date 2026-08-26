-- Epic 5 retrospective (2026-08-26) — regression coverage for the two "fix now, urgent" action
-- items. Neither defect had any test before this file: the chain-stake drop went unnoticed
-- through two full `create or replace` rewrites of `enqueue_gate_reminders()`, and the missing
-- advisory lock went unnoticed despite the fixing migration's own commit message claiming it
-- was closed. This file exists so neither regresses silently a third time.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/epic-5-retro-2026-08-26-fixes.sql
--
-- One transaction, rolled back at the end. Mirrors `5-2-the-app-notices-i-have-gone-quiet.sql`'s
-- own structure: `enqueue_gate_reminders()` is called directly (no `pg_cron` fires in a SQL
-- test); `morning_hour` is pinned to the *current* local hour for every fixture account so
-- `slot` always lands at 0, well inside `gate_reminder_slots()`'s bound, regardless of the wall
-- clock the test happens to run against.

begin;

grant select on table public.profile to authenticated;
grant select on table public.commitment to authenticated;

do $$
declare
  v_local_hour   integer := extract(hour from (now() at time zone 'Asia/Ho_Chi_Minh'))::integer;
  v_today        date    := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_asked_day    date    := v_today - 1;

  v_user_stake   uuid := gen_random_uuid();   -- one commitment, a running chain -> stake named
  v_user_two     uuid := gen_random_uuid();   -- two commitments outstanding -> no stake
  v_user_fresh   uuid := gen_random_uuid();   -- one commitment, chain at zero -> no stake

  v_c_stake      uuid;
  v_c_two_a      uuid;
  v_c_two_b      uuid;
  v_c_fresh      uuid;

  d              date;
  v_current      integer;
  v_body         text;
  v_def          text;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- ===================================================================================
  -- Fixture: three accounts, each pinned to the current local hour so the routine
  -- gate-reminder push always fires this pass (slot 0).
  -- ===================================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_user_stake, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'retro-stake-' || v_user_stake::text || '@example.test',
     'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
     '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb),
    (v_user_two, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'retro-two-' || v_user_two::text || '@example.test',
     'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
     '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb),
    (v_user_fresh, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'retro-fresh-' || v_user_fresh::text || '@example.test',
     'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
     '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  update public.profile set morning_hour = v_local_hour
   where id in (v_user_stake, v_user_two, v_user_fresh);

  -- Account 1: one commitment, five held days ending at asked_day - 1, asked_day itself
  -- left unanswered (so it is the single outstanding commitment this pass asks about).
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user_stake, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_c_stake;

  for d in select unnest(array[v_asked_day - 5, v_asked_day - 4, v_asked_day - 3,
                               v_asked_day - 2, v_asked_day - 1])
  loop
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_user_stake, v_c_stake, gen_random_uuid(), 'held',
            ((d + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');
    perform public.settle_day(d, true);
  end loop;

  select current_days into v_current from public.chain_current where commitment_id = v_c_stake;
  if coalesce(v_current, 0) <> 5 then
    raise exception 'Fixture broken: expected a 5-day chain before the stake assertion, got %',
      coalesce(v_current, 0);
  end if;

  -- Account 2: two commitments outstanding for asked_day, neither answered -- no honest
  -- composite of two different chains exists, so no stake must be named regardless of either
  -- commitment's own chain length. Both answered `held` for asked_day - 1 only, so
  -- `enqueue_gate_reminders()`'s own Silence-streak check (quiet on *both* asked_day and
  -- asked_day - 1) never falsely opens an episode for a fixture account that is otherwise
  -- fresh -- this test is about the routine push, not Silence detection.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user_two, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_c_two_a;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user_two, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true)
  returning id into v_c_two_b;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    (v_user_two, v_c_two_a, gen_random_uuid(), 'held',
     (v_asked_day::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user_two, v_c_two_b, gen_random_uuid(), 'held',
     (v_asked_day::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  -- Account 3: one commitment, never settled -- chain at zero, "nothing waiting." Same
  -- Silence-streak guard as account 2: one prior answered day keeps this a routine-push test.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user_fresh, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c_fresh;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user_fresh, v_c_fresh, gen_random_uuid(), 'held',
          (v_asked_day::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  -- ===================================================================================
  -- Step 1: the routine gate-reminder push names the chain when exactly one commitment is
  -- outstanding and its chain is running -- Story 2.9's own feature, restored by
  -- 20260826130000 after Stories 5.2/5.3 silently dropped it across two rewrites.
  -- ===================================================================================
  perform public.enqueue_gate_reminders();

  select payload->>'body' into v_body
    from public.outbox
   where owner_id = v_user_stake and dedupe_key like 'gate-%';

  if v_body is null then
    raise exception 'Fixture broken: no routine gate-reminder push enqueued for the stake account';
  end if;

  if v_body !~ '^Day 5 is waiting\. ' then
    raise exception 'Step 1 FAILED: expected the push body to start with ''Day 5 is waiting. '', got: %',
      v_body;
  end if;

  raise notice 'Step 1 ok: a single outstanding commitment with a running 5-day chain gets '
    '''Day 5 is waiting.'' -- restored, not merely present.';

  -- ===================================================================================
  -- Step 2: two commitments outstanding -- no honest single chain to name, so no stake.
  -- ===================================================================================
  select payload->>'body' into v_body
    from public.outbox
   where owner_id = v_user_two and dedupe_key like 'gate-%';

  if v_body is null then
    raise exception 'Fixture broken: no routine gate-reminder push enqueued for the two-commitment account';
  end if;

  if v_body ~ '^Day \d+ is waiting\.' then
    raise exception 'Step 2 FAILED: two outstanding commitments must never get a stake, got: %',
      v_body;
  end if;

  raise notice 'Step 2 ok: two outstanding commitments -- no stake named, exactly as before '
    'this fix (unaffected by it).';

  -- ===================================================================================
  -- Step 3: one commitment, chain at zero -- "Day 0 is waiting" would manufacture a stake
  -- that does not exist.
  -- ===================================================================================
  select payload->>'body' into v_body
    from public.outbox
   where owner_id = v_user_fresh and dedupe_key like 'gate-%';

  if v_body is null then
    raise exception 'Fixture broken: no routine gate-reminder push enqueued for the fresh account';
  end if;

  if v_body ~ '^Day \d+ is waiting\.' then
    raise exception 'Step 3 FAILED: a chain at zero must never get a stake, got: %', v_body;
  end if;

  raise notice 'Step 3 ok: a commitment with no chain yet -- no stake named.';

  -- ===================================================================================
  -- Step 4: `mark_penalty_collected()` actually takes the per-account advisory lock.
  -- A static check on the compiled function body, not a true concurrency proof -- this
  -- suite runs one transaction sequentially and cannot express two genuinely concurrent
  -- sessions (the same accepted limitation `5-1-a-countable-way-to-be-forgiven.sql`'s own
  -- review already recorded for `grace_day_validate()`/`appeal_hold_penalty()`'s locks). What
  -- this *does* catch: the exact class of regression that shipped on 2026-08-25 -- a fix
  -- whose own commit message claimed the lock was added, when the line was never actually
  -- written. A future edit to this function that drops the lock line again fails this step
  -- immediately, without needing a concurrent session to prove it.
  -- ===================================================================================
  select pg_get_functiondef('public.mark_penalty_collected'::regproc) into v_def;

  if v_def !~ 'pg_advisory_xact_lock' then
    raise exception 'Step 4 FAILED: mark_penalty_collected() no longer calls pg_advisory_xact_lock';
  end if;

  raise notice 'Step 4 ok: mark_penalty_collected() calls pg_advisory_xact_lock (static check '
    'only -- see the comment above for why this suite cannot prove true concurrency safety).';

  raise notice 'PASS. Both 2026-08-26 retro fixes hold: the routine gate-reminder push names '
    'the chain at stake again, exactly and only when one commitment is outstanding with a '
    'running chain; and mark_penalty_collected() calls the advisory lock its own prior fix '
    'claimed to add.';
end $$;

rollback;
