-- Story 2.9 — what a chain counts, over more than one day.
--
-- `2-9-chain-calendar.sql` proves a corrected day is drawn once and on both surfaces. This
-- file drives the arithmetic underneath it, which had no executable coverage at all: seven
-- days, two commitments, and every rule `chain_current` claims in its own comment.
--
--   - A miss breaks the chain.
--   - **Silence breaks it too**, and is recorded as `unanswered` rather than as a miss. The
--     money treats the two the same; the history must not, because "I said no" and "I said
--     nothing" are different things to have done.
--   - A day with no settlement at all is **skipped, not broken** — the chain runs across the
--     gap. This is the rule that makes the number survive a commitment that is not owed
--     every day, and it is the one most likely to be broken by a later change.
--   - A failed day resets **the chain of the commitment that was missed and no other**. One
--     miss out of five must not read like five out of five. This is the story's whole point.
--   - And an expired day is not a blanket punishment: the commitment that *was* answered on
--     a day the other went silent keeps its chain.
--
-- The last one is worth stating plainly because it is invisible in the money. An expired day
-- costs the same as an admitted one, so the ledger cannot tell you whether he answered for
-- four of five commitments that day. The chain can, and this is the assertion that says so.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-9-chain-arithmetic.sql
--
-- One transaction, rolled back at the end. It settles days, so it needs a database with no
-- live doer account — see supabase/tests/2-7-supersession.sql for that note at length.

begin;

do $$
declare
  v_user    uuid := gen_random_uuid();
  v_a       uuid;   -- the commitment that has a bad week
  v_b       uuid;   -- the commitment that does not
  v_today   date;
  d         date;

  v_current integer;
  v_longest integer;
  v_outcome public.commitment_outcome;
  v_verdict public.day_verdict;
  v_count   integer;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 1. One account, two commitments that both carry money.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-2-9b-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty)
  values (v_user, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_a;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty)
  values (v_user, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true)
  returning id into v_b;

  v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

  -- -------------------------------------------------------------------------------
  -- 2. Seven days, in order, each closed by settlement rather than written by hand.
  --
  --   day     A          B
  --   T-12    held       held
  --   T-11    held       held
  --   T-10    never settled at all — the gap
  --   T-9     held       held
  --   T-8     slipped    held        -> A breaks, B does not
  --   T-7     silence    held        -> the day expires; A is `unanswered`, B still held
  --   T-6     held       held
  --   T-5     held       held
  --
  -- A declaration is a tap the following morning and the trigger derives `for_day` from
  -- that instant (20260819200000:88), which is why every answer is stamped at day+1 08:00.
  -- -------------------------------------------------------------------------------
  for d in select unnest(array[v_today - 12, v_today - 11, v_today - 9,
                               v_today - 8, v_today - 7, v_today - 6, v_today - 5])
  loop
    -- A answers on every day except the one it goes silent on, and slips on one.
    if d <> v_today - 7 then
      insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                      answered_at)
      values (v_user, v_a, gen_random_uuid(),
              (case when d = v_today - 8 then 'slipped' else 'held' end)::public.declaration_answer,
              ((d + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');
    end if;

    -- B holds, every single day.
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                    answered_at)
    values (v_user, v_b, gen_random_uuid(), 'held',
            ((d + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

    perform public.settle_day(d, true);
  end loop;

  -- T-10 is deliberately never passed to settle_day. Nothing was answered for it and its
  -- deadline has long passed, so it *would* expire if anyone asked — nobody does, and the
  -- chain has to run across the hole.

  -- -------------------------------------------------------------------------------
  -- 3. The days closed as the table above says they did.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count from public.settlement_current where subject = v_user;
  if v_count <> 7 then
    raise exception using message = format(
      'Expected 7 closed days, found %s. The fixture, not the product, is probably wrong '
      '— check that every day was fully answered or past its deadline.', v_count);
  end if;

  select verdict into v_verdict
    from public.settlement_current where subject = v_user and period = v_today - 8;
  if v_verdict <> 'failed' then
    raise exception using message = format(
      'The day A slipped closed `%s`, expected `failed`.', v_verdict);
  end if;

  select verdict into v_verdict
    from public.settlement_current where subject = v_user and period = v_today - 7;
  if v_verdict <> 'expired' then
    raise exception using message = format(
      'The day A said nothing closed `%s`, expected `expired`. A day closed on the clock '
      'is a different fact about him from an admitted slip.', v_verdict);
  end if;

  select count(*) into v_count from public.penalty_current where subject = v_user;
  if v_count <> 2 then
    raise exception using message = format(
      'Expected 2 penalties — one admitted, one silent — found %s. Silence costs exactly '
      'what honesty costs, or silence becomes the cheaper answer (FR-13).', v_count);
  end if;

  raise notice using message =
    'Step 1-3 ok: seven days closed — one failed, one expired, two penalties owed.';

  -- -------------------------------------------------------------------------------
  -- 4. Silence is recorded as silence.
  -- -------------------------------------------------------------------------------
  select sc.outcome into v_outcome
    from public.settlement_commitment_current sc
   where sc.commitment_id = v_a and sc.period = v_today - 7;

  if v_outcome <> 'unanswered' then
    raise exception using message = format(
      'The day A went silent froze as `%s`. `unanswered` is its own outcome precisely so '
      'the history does not pretend it knows he chose to miss.', v_outcome);
  end if;

  select sc.outcome into v_outcome
    from public.settlement_commitment_current sc
   where sc.commitment_id = v_b and sc.period = v_today - 7;

  if v_outcome <> 'held' then
    raise exception using message = format(
      'B froze as `%s` on the expired day, but B was answered and held. An expired day is '
      'closed on the clock, not a blanket verdict against everything he was asked.',
      v_outcome);
  end if;

  raise notice using message =
    'Step 4 ok: on the expired day, A reads `unanswered` and B reads `held`.';

  -- -------------------------------------------------------------------------------
  -- 5. A's chain: broken twice, and running again.
  --
  --   T-12 held, T-11 held, [gap], T-9 held   -> three in a row, across the hole
  --   T-8 missed                              -> break
  --   T-7 unanswered                          -> break
  --   T-6 held, T-5 held                      -> current 2
  -- -------------------------------------------------------------------------------
  select current_days, longest_days into v_current, v_longest
    from public.chain_current where commitment_id = v_a;

  if v_current <> 2 then
    raise exception using message = format(
      'A''s current chain reads %s, expected 2 — the two days since silence broke it.',
      v_current);
  end if;

  if v_longest <> 3 then
    raise exception using message = format(
      'A''s longest chain reads %s, expected 3. T-10 was never settled, and a day with no '
      'row is skipped rather than breaking the run — otherwise a commitment that is not '
      'owed every day can never hold a chain at all.', v_longest);
  end if;

  raise notice using message =
    'Step 5 ok: A reads 2 current / 3 longest — the gap did not break it and both bad days did.';

  -- -------------------------------------------------------------------------------
  -- 6. And B, on the same seven days, is untouched by any of it.
  --
  -- This is Story 2.9's reason for existing: one miss out of five must not read like five
  -- out of five.
  -- -------------------------------------------------------------------------------
  select current_days, longest_days into v_current, v_longest
    from public.chain_current where commitment_id = v_b;

  if v_current <> 7 or v_longest <> 7 then
    raise exception using message = format(
      'B reads %s current / %s longest, expected 7 / 7. B held on every one of the seven '
      'days judged. A failed day resets the chain of the commitment that was missed and '
      'touches no other — if this line fails, a bad day wipes everything and the number '
      'stops being worth having.', v_current, v_longest);
  end if;

  raise notice using message =
    'Step 6 ok: B reads 7 / 7 through A''s miss, A''s silence and two penalties.';

  -- -------------------------------------------------------------------------------
  -- 7. The expired day says nothing at all.
  --
  -- Story 2.8's rule, and the one place the product declines to speak. The data for an
  -- evening sentence is there — "one of two today, start with X tomorrow" — and sending it
  -- about a day he never answered is the product pretending it knows how his day went. It
  -- knows he did not say. Every other closed day gets its summary.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count
    from public.outbox
   where owner_id = v_user and dedupe_key like 'summary-%' || (v_today - 7)::text;
  if v_count <> 0 then
    raise exception using message = format(
      'The expired day queued %s summaries. A sentence about how his day went, on a day he '
      'never answered, is the one thing this message must never be.', v_count);
  end if;

  select count(*) into v_count
    from public.outbox
   where owner_id = v_user and dedupe_key like 'summary-%' || (v_today - 8)::text;
  if v_count <> 1 then
    raise exception using message = format(
      'The failed day queued %s summaries, expected 1. A bad day becoming a bad week is '
      'the pattern this message exists to interrupt — it is needed most on exactly this '
      'evening.', v_count);
  end if;

  raise notice using message =
    'Step 7 ok: the failed day was spoken about and the expired day was not.';

  raise notice using message =
    'PASS. The chain breaks on a miss and on silence, runs across a day nobody judged, and '
    'belongs to one commitment at a time.';
end $$;

rollback;
