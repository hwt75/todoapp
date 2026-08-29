-- Story 2.9 — the calendar and the number tell the same story about the same day.
--
-- The Epic 2 retrospective found the one client read in the product that went to a
-- settlement base table: `components/chains-detail.tsx` selected from
-- `settlement_commitment` and joined `settlement` back for the day (A2). Every other read
-- goes through a `*_current` view. The consequence was two surfaces of one commitment
-- disagreeing about one day: the chain followed the correction (AD-9) while the calendar
-- beside it kept the superseded verdict's marks forever — showing `unanswered` against a day
-- he had answered.
--
-- `public.settlement_commitment_current` is the door the calendar now uses
-- (`20260820100000_chain_calendar_reads_the_correction.sql`), and `lib/chain.test.ts` guards
-- the client half by reading every shipped `.ts`/`.tsx` for a base-table read. This file
-- guards the other half: that the view actually follows a supersession, and that what it
-- shows and what `chain_current` counts cannot come apart — they are the same join, or they
-- are two rules again.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-9-chain-calendar.sql
--
-- One transaction, rolled back at the end. It settles days, so it needs a database with no
-- live doer account — see supabase/tests/2-7-supersession.sql for that note at length.

begin;

do $$
declare
  v_user       uuid := gen_random_uuid();
  v_commitment uuid;
  v_day        date;
  v_original   uuid;
  v_correction uuid;
  v_answered   timestamptz;
  v_deadline   timestamptz;

  v_outcome    public.commitment_outcome;
  v_period     date;
  v_verdict    public.day_verdict;
  v_base       integer;
  v_visible    integer;
  v_chain      integer;
  v_invoker    boolean;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 1. A day that expired in silence, then turned out to have been answered in time.
  --    The same shape as 2-7, because it is the only shape where the two surfaces can
  --    disagree at all.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-2-9-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty)
  values (v_user, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true)
  returning id into v_commitment;

  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 4;
  v_deadline := public.declaration_deadline(v_day, 7);

  -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
  -- This fixture creates its commitments moments before judging days that predate them, which is
  -- a state no real account can reach — so it now says when they began. Order-preserving, so
  -- every created_at comparison downstream reads the same way, and idempotent, so a second call
  -- further down this file does not age them twice.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day, true);

  select id into v_original
    from public.settlement where subject = v_user and period = v_day;

  if v_original is null then
    raise exception using message = 'Fixture is wrong: the day did not close at all.';
  end if;

  -- The answer he gave the following morning, delivered after the deadline had passed.
  v_answered := ((v_day + 1)::timestamp + interval '7 hours 31 minutes')
                at time zone 'Asia/Ho_Chi_Minh';
  if v_answered >= v_deadline then
    raise exception using message = 'Fixture is wrong: the answer is not inside the deadline.';
  end if;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                  answered_at)
  values (v_user, v_commitment, gen_random_uuid(), 'held', v_answered);

  perform public.supersede_expiries();

  select id, verdict into v_correction, v_verdict
    from public.settlement where supersedes = v_original;
  if v_correction is null then
    raise exception using message = 'Fixture is wrong: no correction was written.';
  end if;

  raise notice using message = format(
    'Step 1 ok: %s expired and was corrected to `%s`.', v_day, v_verdict);

  -- -------------------------------------------------------------------------------
  -- 2. The calendar shows the correction, and only the correction.
  --
  -- Both settlements' outcomes are in the base table — the superseded one is history and
  -- history is kept. The question is which of them a screen can see.
  -- -------------------------------------------------------------------------------
  select count(*) into v_base
    from public.settlement_commitment where commitment_id = v_commitment;
  if v_base <> 2 then
    raise exception using message = format(
      'Expected 2 frozen outcomes in the base table (the expiry''s and the correction''s), '
      'found %s. The trace is what makes a correction auditable.', v_base);
  end if;

  select count(*) into v_visible
    from public.settlement_commitment_current where commitment_id = v_commitment;
  if v_visible <> 1 then
    raise exception using message = format(
      'The calendar sees %s rows for one day, expected 1. A view that shows both the '
      'superseded verdict and its correction is worse than the base table, not better.',
      v_visible);
  end if;

  select outcome, period into v_outcome, v_period
    from public.settlement_commitment_current where commitment_id = v_commitment;

  if v_outcome <> 'held' then
    raise exception using message = format(
      'The calendar shows `%s` for a day he answered and held. This is A2 exactly: the '
      'chain follows the correction and the calendar keeps the silence.', v_outcome);
  end if;

  if v_period <> v_day then
    raise exception using message = format(
      'The view dated the outcome %s, but the day settled was %s. The calendar reads '
      '`period` straight from this column.', v_period, v_day);
  end if;

  raise notice using message =
    'Step 2 ok: two outcomes on record, one visible, and it is the corrected `held`.';

  -- -------------------------------------------------------------------------------
  -- 3. The number and the calendar cannot come apart.
  --
  -- Not a coincidence to be re-checked by eye each time: `chain_current` and
  -- `settlement_commitment_current` are the same join, so a day either counts and is drawn
  -- or does neither.
  -- -------------------------------------------------------------------------------
  select current_days into v_chain
    from public.chain_current where commitment_id = v_commitment;

  if coalesce(v_chain, -1) <> v_visible then
    raise exception using message = format(
      'The chain reads %s day(s) and the calendar draws %s. Two surfaces, one day, two '
      'answers — the disagreement A2 was written about.', coalesce(v_chain, -1), v_visible);
  end if;

  -- -------------------------------------------------------------------------------
  -- 4. And the view is not a way around the row-level rule.
  --
  -- `settlement_commitment` has a read-own policy and no write policy at all (AD-8). A view
  -- without `security_invoker` would run as its owner and hand every row to anyone who
  -- could select from it.
  -- -------------------------------------------------------------------------------
  select 'security_invoker=true' = any(reloptions) into v_invoker
    from pg_class where oid = 'public.settlement_commitment_current'::regclass;

  if not coalesce(v_invoker, false) then
    raise exception using message =
      'settlement_commitment_current is not security_invoker, so it reads with its '
      'owner''s rights and the read-own policy on settlement_commitment stops applying.';
  end if;

  raise notice using message =
    'Step 3-4 ok: the chain and the calendar agree, and the view defers to the row policy.';
  raise notice using message =
    'PASS. A corrected day is drawn as what it turned out to be, once, on both surfaces.';
end $$;

rollback;
