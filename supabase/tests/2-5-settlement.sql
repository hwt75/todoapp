-- Story 2.5 / 2.6 — the day closes on its own, and a failed one costs exactly once.
--
-- `settle_day` is the only thing in this product that decides anything, and the only thing
-- that writes money. Before this file it had no executable coverage of any kind: 401 tests
-- across 16 files and not one of them calls it, `supersede_expiries()`, or the penalty
-- write. `lib/ledger.test.ts` exercises `buildLedger`, the client-side fold; nothing
-- exercises the decision behind it.
--
-- What is asserted here is the epic's own declared criteria, restated in SQL:
--
--   FR-13 / 2.6  one Failed Day costs exactly one 500,000₫ penalty, however many
--                commitments were missed, stored as an integer number of đồng
--   FR-10 / 2.5  a day nobody has finished answering stays open, and announces nothing
--   AD-5         a pass that is retried, overlapped or triggered twice is a no-op
--   AD-8         verdicts, penalties and frozen outcomes have exactly one writer
--   AD-16        settlement off its schedule refuses, and the override is refused for the
--                live doer account — by raising, not by skipping
--
-- A penalty-free miss costing nothing is asserted too, because it is the case most likely
-- to be broken by a later change and least likely to be noticed: it looks like a bug.
--
--
-- HOW TO RUN
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-5-settlement.sql
--
-- One transaction, rolled back at the end. Nothing persists, and no cleanup step exists
-- that could be forgotten.
--
-- It needs a database with **no live doer account**, for the reason step 0 states — which
-- is the same reason this cannot run against the author's own project. Local stack or
-- preview branch. See supabase/tests/2-7-supersession.sql for the same note at length.

begin;

do $$
declare
  -- Fixture
  v_user      uuid := gen_random_uuid();
  v_live      uuid := gen_random_uuid();
  v_money_1   uuid;   -- daily, carries the penalty
  v_money_2   uuid;   -- daily, carries the penalty
  v_free      uuid;   -- daily, carries nothing

  v_today     date;
  d_open      date;   -- partly answered, deadline not passed -> must stay open
  d_failed    date;   -- everything slipped
  d_clean     date;   -- everything held
  d_free_miss date;   -- only the penalty-free one slipped

  -- Observed
  v_settlement uuid;
  v_verdict    public.day_verdict;
  v_missed     integer;
  v_amount     bigint;
  v_state      public.penalty_state;
  v_type       text;
  v_count      integer;
  v_raised     boolean;
begin
  -- -------------------------------------------------------------------------------
  -- 0. Refuse to run where the AD-16 guard would make the result meaningless.
  --
  -- `settle_day` raises rather than skipping when `p_override` meets a profile with
  -- `is_live_doer` set (20260819241000:105-110), so one live account disables the
  -- override path for every call in this file. Step 7 relies on exactly that behaviour,
  -- which is why the flag has to start clean.
  -- -------------------------------------------------------------------------------
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead. Never work around the '
      'guard by setting app.settlement_invocation by hand.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 1. One account, three commitments, two of which carry money.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-2-5-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_money_1;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true)
  returning id into v_money_2;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user, gen_random_uuid(), 'Morning exercise', 'do', 'daily', false)
  returning id into v_free;

  v_today     := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  d_open      := v_today - 1;
  d_failed    := v_today - 2;
  d_clean     := v_today - 3;
  d_free_miss := v_today - 4;

  -- A day is answered by a tap the following morning; the trigger derives `for_day` from
  -- that instant (20260819200000:88). A fully answered day closes whatever its age, so
  -- only `d_open` depends on its deadline still being ahead — and it is, at day+3 07:00.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    -- d_open: two of three. The third is never answered.
    (v_user, v_money_1, gen_random_uuid(), 'held',
     ((d_open + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user, v_money_2, gen_random_uuid(), 'held',
     ((d_open + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),

    -- d_failed: the worst possible day. Everything slipped.
    (v_user, v_money_1, gen_random_uuid(), 'slipped',
     ((d_failed + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user, v_money_2, gen_random_uuid(), 'slipped',
     ((d_failed + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user, v_free,    gen_random_uuid(), 'slipped',
     ((d_failed + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),

    -- d_clean: everything held.
    (v_user, v_money_1, gen_random_uuid(), 'held',
     ((d_clean + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user, v_money_2, gen_random_uuid(), 'held',
     ((d_clean + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user, v_free,    gen_random_uuid(), 'held',
     ((d_clean + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),

    -- d_free_miss: only the commitment that carries nothing slipped.
    (v_user, v_money_1, gen_random_uuid(), 'held',
     ((d_free_miss + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user, v_money_2, gen_random_uuid(), 'held',
     ((d_free_miss + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_user, v_free,    gen_random_uuid(), 'slipped',
     ((d_free_miss + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  -- -------------------------------------------------------------------------------
  -- 2. FR-13 — the worst possible day costs exactly one penalty.
  -- -------------------------------------------------------------------------------
  perform public.settle_day(d_failed, true);

  select id, verdict, missed_count into v_settlement, v_verdict, v_missed
    from public.settlement
   where subject = v_user and period = d_failed and kind = 'day' and supersedes is null;

  if v_settlement is null then
    raise exception using message = format(
      'Every declaration for %s was filed, so the day must have closed. It did not.',
      d_failed);
  end if;

  if v_verdict <> 'failed' then
    raise exception using message = format(
      'A day where a penalty-carrying commitment was missed is a Failed Day, not `%s`.',
      v_verdict);
  end if;

  if v_missed <> 2 then
    raise exception using message = format(
      'missed_count is %s, expected 2 — it counts the commitments that carry the penalty, '
      'and the third slip carries none. The count is for the record, never for the '
      'arithmetic of the charge.', v_missed);
  end if;

  select count(*) into v_count from public.penalty where settlement_id = v_settlement;
  if v_count <> 1 then
    raise exception using message = format(
      'FR-13: one Failed Day generates exactly ONE penalty regardless of how many '
      'commitments were missed. Two commitments were missed and %s penalties exist. Two '
      'rows for one 500,000 either double the visible debt or show two half-penalties '
      'that do not exist.', v_count);
  end if;

  select amount_dong, state, pg_typeof(amount_dong)::text
    into v_amount, v_state, v_type
    from public.penalty where settlement_id = v_settlement;

  if v_amount <> public.penalty_amount_dong() or v_amount <> 500000 then
    raise exception using message = format(
      'A Failed Day costs 500000 đồng; this one cost %s.', v_amount);
  end if;

  if v_type <> 'bigint' then
    raise exception using message = format(
      'Money is stored as `%s`. It must be an integer number of đồng, never a floating '
      'point value — a rounding error in a number that only grows is a number that '
      'eventually disagrees with itself, and this one is a claim against a real person.',
      v_type);
  end if;

  if v_state <> 'owed' then
    raise exception using message = format(
      'A new penalty stands as `owed`, not `%s`. It is discharged only by the Referee '
      'marking it collected; nothing in this product settles a debt on its own (NFR5).',
      v_state);
  end if;

  -- AD-3, applied inward: the verdict and the message it produces are written in one
  -- transaction, and settlement never calls out.
  select count(*) into v_count
    from public.outbox
   where owner_id = v_user
     and dedupe_key = 'summary-' || v_user::text || '-' || d_failed::text;
  if v_count <> 1 then
    raise exception using message = format(
      'A closed day writes its summary to the outbox in the same transaction as the '
      'verdict (AD-3). Found %s rows for %s.', v_count, d_failed);
  end if;

  raise notice using message = format(
    'Step 2 ok: %s closed `failed`, missed_count 2, one 500000₫ penalty owed, one summary queued.',
    d_failed);

  -- -------------------------------------------------------------------------------
  -- 3. AD-5 — retried, overlapped, triggered twice: a no-op.
  --
  -- Asserted on rows rather than on the return value, because `settle_day` counts what it
  -- inserted across every doer account in the database and this file cannot assume it is
  -- the only one.
  -- -------------------------------------------------------------------------------
  perform public.settle_day(d_failed, true);
  perform public.settle_day(d_failed, true);

  select count(*) into v_count
    from public.settlement
   where subject = v_user and period = d_failed and kind = 'day' and supersedes is null;
  if v_count <> 1 then
    raise exception using message = format(
      'AD-5: a settled period is never re-settled. Three passes over %s produced %s '
      'verdicts. Cron runs overlap, get retried and get triggered by hand, and under a '
      'flat penalty each of those is a chance to charge twice for one day.',
      d_failed, v_count);
  end if;

  select count(*) into v_count
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_user and s.period = d_failed;
  if v_count <> 1 then
    raise exception using message = format(
      'Three settlement passes over one Failed Day produced %s penalties.', v_count);
  end if;

  raise notice using message = 'Step 3 ok: two further passes changed nothing.';

  -- -------------------------------------------------------------------------------
  -- 4. A clean day, and a penalty-free miss that costs nothing.
  -- -------------------------------------------------------------------------------
  perform public.settle_day(d_clean, true);

  select verdict, missed_count into v_verdict, v_missed
    from public.settlement
   where subject = v_user and period = d_clean and kind = 'day' and supersedes is null;

  if v_verdict is distinct from 'clean' or v_missed <> 0 then
    raise exception using message = format(
      'A day where everything held closes `clean` with 0 missed, not `%s` with %s.',
      v_verdict, v_missed);
  end if;

  perform public.settle_day(d_free_miss, true);

  select id, verdict, missed_count into v_settlement, v_verdict, v_missed
    from public.settlement
   where subject = v_user and period = d_free_miss and kind = 'day' and supersedes is null;

  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'Only a commitment carrying no penalty slipped, so the day is `clean`, not `%s`. '
      'The money toggle is what makes a miss cost, and it was off.', v_verdict);
  end if;

  select count(*) into v_count from public.penalty where settlement_id = v_settlement;
  if v_count <> 0 then
    raise exception using message = format(
      'A penalty-free miss cost %s penalties. It must cost nothing — this is the case '
      'most likely to be broken later and least likely to be noticed, because being '
      'charged looks more like working than not being charged does.', v_count);
  end if;

  raise notice using message =
    'Step 4 ok: an all-held day is clean, and a penalty-free miss costs nothing.';

  -- -------------------------------------------------------------------------------
  -- 5. FR-10 — a day he has not finished answering stays open, and announces nothing.
  --
  -- Two of three answered, deadline still ahead. Nothing may be decided, and nothing may
  -- be said: once he knows the day is already lost, the rest of it has no stakes.
  -- -------------------------------------------------------------------------------
  perform public.settle_day(d_open, true);

  select count(*) into v_count
    from public.settlement where subject = v_user and period = d_open;
  if v_count <> 0 then
    raise exception using message = format(
      'A day with an unanswered declaration and its deadline still ahead must stay open. '
      '%s verdicts were written for %s.', v_count, d_open);
  end if;

  select count(*) into v_count
    from public.outbox
   where owner_id = v_user
     and dedupe_key = 'summary-' || v_user::text || '-' || d_open::text;
  if v_count <> 0 then
    raise exception using message = format(
      'FR-10: nothing announces an open day. %s messages were queued for %s.',
      v_count, d_open);
  end if;

  raise notice using message = format(
    'Step 5 ok: %s stayed open and said nothing.', d_open);

  -- -------------------------------------------------------------------------------
  -- 6. AD-16, first guard — settlement off its schedule refuses.
  -- -------------------------------------------------------------------------------
  begin
    perform public.settle_day(v_today - 5);
    v_raised := false;
  exception when others then
    v_raised := true;
  end;

  if not v_raised then
    raise exception using message =
      'AD-16: settle_day ran with no schedule marker and no override, and did not refuse. '
      'The guard exists for the moment someone is iterating on settlement against a real '
      'ledger that by design cannot be quietly cleaned up.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 7. AD-16, second guard — the override is refused for the live doer account, and it
  --    refuses by RAISING rather than by skipping that account.
  --
  -- The distinction matters beyond this test: because one live account aborts the whole
  -- call, no settlement test can ever run against the author's own project. That is what
  -- forces these files onto a local or branch database, and it is worth having asserted
  -- rather than rediscovered.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_live, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-2-5-live-' || v_live::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  update public.profile set is_live_doer = true where id = v_live;

  begin
    perform public.settle_day(v_today - 6, true);
    v_raised := false;
  exception when others then
    v_raised := true;
  end;

  if not v_raised then
    raise exception using message =
      'AD-16: an override was accepted while a live doer account existed. Only the '
      'schedule may settle that account.';
  end if;

  update public.profile set is_live_doer = false where id = v_live;

  raise notice using message = 'Step 6-7 ok: both AD-16 guards refused.';

  -- -------------------------------------------------------------------------------
  -- 8. AD-8 — derived state has exactly one writer, and it is settlement.
  --
  -- A catalog assertion rather than a behavioural one, because the failure mode is a
  -- future migration adding a policy in good faith. A client that could write a verdict
  -- could decide its own day; one that could write a penalty could forgive its own.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count
    from pg_policies
   where schemaname = 'public'
     and tablename in ('settlement', 'penalty', 'settlement_commitment')
     and cmd <> 'SELECT';
  if v_count <> 0 then
    raise exception using message = format(
      'AD-8: %s write policies exist on settlement, penalty or settlement_commitment. '
      'These tables carry no insert, update or delete policy by design.', v_count);
  end if;

  select count(*) into v_count
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('settlement', 'penalty', 'settlement_commitment')
     and not c.relrowsecurity;
  if v_count <> 0 then
    raise exception using message = format(
      'Row-level security is disabled on %s of the three settlement tables.', v_count);
  end if;

  raise notice using message =
    'Step 8 ok: no write policy on the settlement tables, RLS on all three.';
  raise notice using message =
    'PASS. One Failed Day costs one 500000₫ penalty, a re-run changes nothing, an open '
    'day says nothing, and both AD-16 guards hold.';
end $$;

rollback;
