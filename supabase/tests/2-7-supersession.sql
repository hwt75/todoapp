-- Story 2.7 — an answer given in time takes back an expiry, and the day it belongs to
-- comes back with it.
--
-- This file exists because the retrospective could not settle a question by reading:
-- `supersede_expiries()` writes a correction row, but nothing in it writes
-- `public.settlement_commitment`, which did not exist when that function was authored
-- (20260819241000_expiry_and_supersession.sql:175). If that reading is right, the
-- corrected day carries no frozen outcomes, drops out of `public.chain_current`, and the
-- author who answered honestly and in time is quietly short a day of chain.
--
-- Spec 2.9's decision table says the opposite — *Superseded settlement -> the chain
-- follows the correction* — and records a live check that agrees with the spec. One of
-- those two is wrong, and prose cannot say which. This can.
--
-- Step 5 checks a second, unrelated defect found while building Story 3.3 and fixed by
-- `20260820140000_weekly_quota_is_not_judged_daily.sql`: `supersede_expiries()` shares
-- `commitments_owing()` with `settle_day` and had the identical bug — a Weekly Quota
-- commitment's own admitted slip could fail a corrected day and charge a penalty, exactly
-- as `settle_day` could before its own fix. Traced in deferred-work.md.
--
-- **So a failure here is not a broken test. It is the answer.** Every assertion below is
-- the specification restated in SQL; when one raises, read the message — it names what
-- the spec promised and what the database actually did.
--
--
-- HOW TO RUN
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-7-supersession.sql
--
-- Everything runs inside one transaction that **rolls back at the end**. Nothing is left
-- behind, no account needs deleting afterwards, and a crash mid-run leaves the database
-- exactly as it was. That is deliberate: the epic's ten verification records all end with
-- some form of "test accounts deleted afterwards", which is a step that can be forgotten.
-- This one cannot be.
--
--
-- WHERE IT CAN RUN, AND WHY THAT IS NARROWER THAN IT LOOKS
--
-- It needs a database with **no live doer account**. `settle_day` refuses `p_override`
-- whenever it meets a profile with `is_live_doer` set — and it raises rather than
-- skipping, so a single live account disables the override path for the whole call
-- (AD-16, 20260819241000:105-110). The only other way in is to set
-- `app.settlement_invocation` by hand, which is the exact thing AD-16 exists to stop.
--
-- So this runs against a local or branch database (`supabase start`, `supabase db reset`),
-- never against the author's project. The guard in step 0 states that outright rather
-- than letting it surface as a confusing error.

begin;

do $$
declare
  -- Fixture
  v_user        uuid := gen_random_uuid();
  v_commitment  uuid;
  v_day         date;
  v_derived_day date;
  v_answered    timestamptz;
  v_deadline    timestamptz;

  -- Observed
  v_original    uuid;
  v_correction  uuid;
  v_verdict     public.day_verdict;
  v_outcome     public.commitment_outcome;
  v_returned    integer;
  v_count       integer;
  v_chain       integer;
  v_longest     integer;

  -- Fixture, step 5
  v_user2       uuid := gen_random_uuid();
  v_weekly      uuid;
  v_day2        date;
  v_deadline2   timestamptz;
  v_answered2   timestamptz;
  v_correction2 uuid;
begin
  -- -------------------------------------------------------------------------------
  -- 0. Refuse to run anywhere the AD-16 guard would make the result meaningless.
  -- -------------------------------------------------------------------------------
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead. Never work around the '
      'guard by setting app.settlement_invocation by hand.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 1. One account, one daily commitment that carries the penalty.
  --
  -- Inserting the auth user is enough: `on_auth_user_created` creates the profile with
  -- role `doer` and `morning_hour` 7 (20260819120000:114).
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-2-7-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty)
  values (v_user, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_commitment;

  -- Four days back, so the deadline — the morning hour on day+3 — has already passed and
  -- the day can genuinely expire. Anything closer and step 2 would find the day still
  -- open, which is correct behaviour and a useless test.
  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 4;
  v_deadline := public.declaration_deadline(v_day, 7);

  if v_deadline >= now() then
    raise exception using message = format(
      'Fixture is wrong: the deadline %s has not passed at %s.', v_deadline, now());
  end if;

  -- -------------------------------------------------------------------------------
  -- 2. He says nothing, and the clock closes the day against him.
  -- -------------------------------------------------------------------------------
  -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
  -- This fixture creates its commitments moments before judging days that predate them, which is
  -- a state no real account can reach — so it now says when they began. Order-preserving, so
  -- every created_at comparison downstream reads the same way, and idempotent, so the repeats
  -- below (each covering commitments created after the previous pass) age nothing twice.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day, true);

  select id, verdict into v_original, v_verdict
    from public.settlement
   where subject = v_user and period = v_day and kind = 'day' and supersedes is null;

  if v_original is null then
    raise exception using message = format(
      'Expected an expiry settlement for %s and found none.', v_day);
  end if;

  if v_verdict <> 'expired' then
    raise exception using message = format(
      'A day nobody answered must close as `expired`, not `%s`. An admitted slip and a '
      'silence are different facts about him, and the ledger must not merge them (2.7).',
      v_verdict);
  end if;

  select count(*) into v_count
    from public.settlement_commitment where settlement_id = v_original;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected 1 frozen outcome on the expiry, found %s.', v_count);
  end if;

  select outcome into v_outcome
    from public.settlement_commitment where settlement_id = v_original;
  if v_outcome <> 'unanswered' then
    raise exception using message = format(
      'Silence must freeze as `unanswered`, not `%s`. The money treats them the same; '
      'the history must not pretend it knows (20260819260000:19-22).', v_outcome);
  end if;

  select count(*) into v_count from public.penalty_current where subject = v_user;
  if v_count <> 1 then
    raise exception using message = format(
      'An expired day costs exactly what an admitted one costs, so expected 1 standing '
      'penalty and found %s.', v_count);
  end if;

  raise notice using message = format(
    'Step 2 ok: %s closed `expired`, one `unanswered` outcome, one penalty standing.',
    v_day);

  -- -------------------------------------------------------------------------------
  -- 3. The answer he gave in time finally arrives.
  --
  -- This is Story 2.7's declared acceptance criterion: answered while offline, still
  -- queued when 48 hours elapsed, flushed afterwards. `answered_at` is the tap instant —
  -- the morning after the day in question, comfortably inside the deadline — and the
  -- trigger derives `for_day` from it (20260819200000:88).
  -- -------------------------------------------------------------------------------
  v_answered := ((v_day + 1)::timestamp + interval '7 hours 31 minutes')
                at time zone 'Asia/Ho_Chi_Minh';

  if v_answered >= v_deadline then
    raise exception using message = format(
      'Fixture is wrong: the answer at %s is not inside the deadline %s.',
      v_answered, v_deadline);
  end if;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                  answered_at)
  values (v_user, v_commitment, gen_random_uuid(), 'held', v_answered);

  select for_day into v_derived_day
    from public.declaration where commitment_id = v_commitment;
  if v_derived_day <> v_day then
    raise exception using message = format(
      'The trigger derived for_day = %s, which is not the day that expired (%s).',
      v_derived_day, v_day);
  end if;

  v_returned := public.supersede_expiries();
  if v_returned <> 1 then
    raise exception using message = format(
      'supersede_expiries() corrected %s days, expected 1. A timely answer delivered '
      'late is not a late-arriving event, and answered_at is the difference '
      '(AD-5, AD-9).', v_returned);
  end if;

  select id, verdict into v_correction, v_verdict
    from public.settlement where supersedes = v_original;

  if v_correction is null then
    raise exception using message =
      'No correction row references the expiry.';
  end if;

  if v_verdict <> 'clean' then
    raise exception using message = format(
      'He said it held and nothing was admitted, so the correction must read `clean`, '
      'not `%s`.', v_verdict);
  end if;

  select count(*) into v_count from public.penalty_current where subject = v_user;
  if v_count <> 0 then
    raise exception using message = format(
      'The expiry was taken back, so its penalty must stop counting. penalty_current '
      'still shows %s (20260819241000:38-45).', v_count);
  end if;

  raise notice using message =
    'Step 3 ok: correction written, verdict `clean`, no penalty standing.';

  -- -------------------------------------------------------------------------------
  -- 4. THE QUESTION THE RETROSPECTIVE COULD NOT ANSWER.
  --
  -- Everything above passes whether or not the correction froze the day's outcomes,
  -- because none of it reads them. These three do.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count
    from public.settlement_commitment where settlement_id = v_correction;

  if v_count <> 1 then
    raise exception using message = format(
      'A1 CONFIRMED. The correction carries %s frozen commitment outcomes, expected 1. '
      'settle_day freezes what each commitment did (20260819262000:95); '
      'supersede_expiries does not, so the corrected day has no outcomes at all. '
      'chain_current reads settlement_commitment through settlement_current, so the '
      'outcomes of the original leave with the superseded row and the correction brings '
      'none. The day he answered in time disappears from his chain entirely.', v_count);
  end if;

  select outcome into v_outcome
    from public.settlement_commitment where settlement_id = v_correction;
  if v_outcome <> 'held' then
    raise exception using message = format(
      'The corrected day froze as `%s`, but he said it held. A correction that keeps the '
      'silence is not a correction.', v_outcome);
  end if;

  select current_days, longest_days into v_chain, v_longest
    from public.chain_current where commitment_id = v_commitment;

  if v_chain is null then
    raise exception using message =
      'A1 CONFIRMED, second face. chain_current returns no row for this commitment at '
      'all: the superseded day left and nothing replaced it, so the commitment reads as '
      'never having been judged.';
  end if;

  if v_chain <> 1 or v_longest <> 1 then
    raise exception using message = format(
      'Expected a chain of 1 day current and 1 longest after the correction, got %s / '
      '%s. Spec 2.9 decision table: a superseded settlement means the chain follows the '
      'correction.', v_chain, v_longest);
  end if;

  raise notice using message =
    'Step 4 ok: the corrected day froze as `held` and the chain reads 1 / 1.';

  -- -------------------------------------------------------------------------------
  -- 5. FR-2 in the correction path — a Weekly Quota commitment's own admitted slip
  --    must not fail a corrected day or charge it a penalty either.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user2, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-2-7-fr2-' || v_user2::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day)
  values (v_user2, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, 1)
  returning id into v_weekly;

  v_day2 := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 4;
  v_deadline2 := public.declaration_deadline(v_day2, 7);

  -- He says nothing, and the day expires exactly as step 2 above.
  -- Fixture ageing again, for the commitments created since (see the note above).
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(v_day2, true);

  -- The answer he gave in time finally arrives — an admitted slip, not a `held`.
  v_answered2 := ((v_day2 + 1)::timestamp + interval '7 hours 31 minutes')
                 at time zone 'Asia/Ho_Chi_Minh';
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                  answered_at)
  values (v_user2, v_weekly, gen_random_uuid(), 'slipped', v_answered2);

  v_returned := public.supersede_expiries();
  if v_returned <> 1 then
    raise exception using message = format(
      'supersede_expiries() corrected %s days for the Weekly Quota fixture, expected 1.',
      v_returned);
  end if;

  select id, verdict into v_correction2, v_verdict
    from public.settlement where subject = v_user2 and supersedes is not null;

  if v_correction2 is null then
    raise exception using message = 'No correction row references the Weekly Quota expiry.';
  end if;

  if v_verdict <> 'clean' then
    raise exception using message = format(
      'FR-2: a Weekly Quota commitment''s own admitted slip must not fail a corrected '
      'day. Got verdict `%s`. Fixed by '
      '20260820140000_weekly_quota_is_not_judged_daily.sql.', v_verdict);
  end if;

  select count(*) into v_count from public.penalty where settlement_id = v_correction2;
  if v_count <> 0 then
    raise exception using message = format(
      'FR-2: a Weekly Quota commitment''s own admitted slip must cost nothing through the '
      'correction path either. %s penalties were charged.', v_count);
  end if;

  select outcome into v_outcome
    from public.settlement_commitment
   where settlement_id = v_correction2 and commitment_id = v_weekly;
  if v_outcome is distinct from 'missed' then
    raise exception using message = format(
      'The Weekly Quota commitment''s outcome must still freeze as `missed` through the '
      'correction path. Got `%s`.', v_outcome);
  end if;

  raise notice using message =
    'Step 5 ok: the corrected day closed `clean` with the Weekly Quota commitment''s own '
    'admitted slip costing nothing, its outcome still frozen as `missed`.';

  raise notice using message =
    'PASS. Supersession restores the day, the money and the chain. A1 is refuted, and a '
    'Weekly Quota commitment is never judged daily through the correction path either.';
end $$;

rollback;
