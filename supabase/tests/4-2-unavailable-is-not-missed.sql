-- Story 4.2 — a check that cannot run never says I missed.
--
-- `resolve_auto_checks()` and `settle_day`/`settle_week` are independent hourly cron jobs
-- with no enforced ordering. Before this migration, a delayed or failed Auto-check pass
-- meant `settle_day`/`settle_week` could judge a day or week before its attached
-- Auto-check had ever run — settling an Auto-check-linked commitment as a plain miss
-- exactly like an author who simply never answered. `auto_check_pending()` guards both
-- paths, bounded by a 96-hour grace window so a stuck pipeline cannot block a period
-- forever — the "why 96, not 48" math is below, ahead of the step summary.
--
-- What is asserted here, restated in SQL:
--
--   auto_check_pending() itself   unlinked, declared, terminal, still-pending and
--                                 grace-expired all read correctly in isolation
--   AD-13, daily                  an unanswered, owed, Auto-check-linked Daily commitment
--                                 blocks settle_day; an already-answered one never blocks;
--                                 a resolved (declared) one proceeds normally; a check
--                                 resolved this pass with nothing to declare (the real
--                                 "unavailable" shape) unblocks and settles immediately,
--                                 without waiting for grace to expire; a grace-expired one
--                                 falls through and settles as an ordinary unanswered/
--                                 silent miss; a pending Weekly Quota commitment never
--                                 blocks settle_day at all — that protection is
--                                 settle_week's job, not settle_day's
--   AD-13, weekly                 a pending check on any single day in
--                                 [p_period, p_period+6] blocks the WHOLE period, not just
--                                 that day; retried is still blocked; once every day in the
--                                 period is terminal, the period proceeds; a fully-declared
--                                 period never blocks regardless of check state; a grace-
--                                 expired period falls through and settles normally
--
-- `settle_day` already keeps a day open via `answered < total and not past_deadline` until
-- `declaration_deadline` (`day + 3 + morning_hour`, up to 71 hours past this window's own
-- base point). A grace window shorter than that (48h was tried first) would already have
-- expired by the time `declaration_deadline` arrives, making `auto_check_pending` checked
-- but never the deciding factor there. 96 hours (expiring `day + 5`) clears that worst case
-- with real margin, so the guard is genuinely load-bearing on `settle_day` too, not merely
-- redundant with the deadline — Step 2b proves this directly: blocked past its own
-- `declaration_deadline`, still within grace. `settle_week` has no such overlap at all — it
-- has no "wait for answers" logic, judging unconditionally once `today >= p_period + 8` —
-- so there the guard is the only thing standing between a stuck Auto-check and a real
-- penalty; Steps 6-7 exercise that directly.
--
--
-- HOW TO RUN
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/4-2-unavailable-is-not-missed.sql
--
-- One transaction, rolled back at the end. It needs a database with **no live doer
-- account**, for the same reason 2-5-settlement.sql and 3-4-week-settlement.sql do:
-- `settle_day`/`settle_week` raise rather than skip when `p_override` meets a profile with
-- `is_live_doer` set, so one live account disables the override path for every call here.

begin;

do $$
declare
  -- Step 1 fixtures: auto_check_pending() exercised directly, no settlement call.
  v_unit uuid := gen_random_uuid();
  c_a uuid; -- not Auto-check linked at all
  c_b uuid; -- linked, undeclared, never checked, within grace -> pending
  c_c uuid; -- linked, but already declared for the day -> never pending
  c_d uuid; -- linked, undeclared, checked_at terminal for the day -> not pending
  c_e uuid; -- linked, undeclared, checked_at stamps an EARLIER day -> still pending
  c_f uuid; -- linked, undeclared, never checked, grace already expired -> not pending
  c_g uuid; -- linked, undeclared, never checked, created AFTER p_day -> not pending
  day_a date; day_b date; day_c date; day_d date; day_e date; day_f date; day_g date;

  -- Steps 2-5: settle_day.
  v_d_block    uuid := gen_random_uuid(); -- blocks, retried still blocks
  v_d_late     uuid := gen_random_uuid(); -- blocks even PAST declaration_deadline, still in grace
  v_d_resolved uuid := gen_random_uuid(); -- resolved (declared) -> proceeds normally
  v_d_unavail  uuid := gen_random_uuid(); -- resolved via stamp only, nothing declared -> unblocks now
  v_d_grace    uuid := gen_random_uuid(); -- grace expired -> falls through
  v_d_answered uuid := gen_random_uuid(); -- already answered -> never blocks
  v_d_weekly   uuid := gen_random_uuid(); -- pending weekly_quota commitment -> never blocks settle_day
  v_d_newcheck uuid := gen_random_uuid(); -- brand-new Auto-check commitment -> never blocks an OLDER day
  c_dblock uuid; c_dlate uuid; c_dresolved uuid; c_dunavail uuid; c_dgrace uuid;
  c_danswered uuid; c_dweekly_wq uuid; c_dweekly_daily uuid;
  c_dnewcheck_old uuid; c_dnewcheck_new uuid;
  d_block date; d_late date; d_resolved date; d_unavail date; d_grace date; d_answered date;
  d_weekly date; d_newcheck date;

  -- Steps 6-9: settle_week.
  v_w_block    uuid := gen_random_uuid(); -- blocks the whole period, retried still blocks
  v_w_grace    uuid := gen_random_uuid(); -- grace expired -> falls through
  v_w_answered uuid := gen_random_uuid(); -- fully declared period -> never blocks
  v_live       uuid := gen_random_uuid();
  c_wblock uuid; c_wgrace uuid; c_wanswered uuid;

  v_today  date;
  v_isodow integer;
  v_isodow_wblock integer;
  p_wblock date;
  p_wgrace date;
  p_wanswered date;

  -- Observed
  v_pending  boolean;
  v_count    integer;
  v_verdict  public.day_verdict;
  v_missed   integer;
begin
  -- -------------------------------------------------------------------------------
  -- 0. Refuse to run where the AD-16 guard would make the result meaningless.
  -- -------------------------------------------------------------------------------
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day/settle_week refuse every '
      'override (AD-16). Run against a local or branch database instead. Never work '
      'around the guard by setting app.settlement_invocation by hand.';
  end if;

  v_today  := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_isodow := extract(isodow from v_today)::integer;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-4-2-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_unit, v_d_block, v_d_late, v_d_resolved, v_d_unavail, v_d_grace,
                       v_d_answered, v_d_weekly, v_d_newcheck, v_w_block, v_w_grace,
                       v_w_answered, v_live]) as t(id);

  -- -------------------------------------------------------------------------------
  -- 1. auto_check_pending() in isolation — the shared helper's own boundary logic,
  --    exercised directly rather than only ever seen through settle_day/settle_week.
  -- -------------------------------------------------------------------------------
  day_a := v_today - 1;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
  values (v_unit, gen_random_uuid(), 'No Auto-check', 'do', 'daily')
  returning id into c_a;

  day_b := v_today - 1;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref, created_at)
  values (v_unit, gen_random_uuid(), 'Undeclared, unchecked', 'do', 'daily',
          'account_elsewhere', 'handle-b', v_today - 30)
  returning id into c_b;

  day_c := v_today - 1;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref, created_at)
  values (v_unit, gen_random_uuid(), 'Already declared', 'do', 'daily',
          'account_elsewhere', 'handle-c', v_today - 30)
  returning id into c_c;
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_unit, c_c, gen_random_uuid(), 'held',
          (day_c + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  day_d := v_today - 1;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref,
                                 auto_check_last_checked_at, created_at)
  values (v_unit, gen_random_uuid(), 'Terminal for day_d', 'do', 'daily',
          'account_elsewhere', 'handle-d',
          -- checked_at's own HCM date is day_d + 1: (checked_at date - 1) = day_d,
          -- which is NOT < day_d -- exactly resolve_auto_checks's own "terminal" identity.
          (day_d + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh', v_today - 30)
  returning id into c_d;

  day_e := v_today - 2;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref,
                                 auto_check_last_checked_at, created_at)
  values (v_unit, gen_random_uuid(), 'Checked for an earlier day only', 'do', 'daily',
          'account_elsewhere', 'handle-e',
          -- checked_at's own HCM date is day_e: (checked_at date - 1) = day_e - 1,
          -- which IS < day_e -- the pass has not reached day_e yet.
          (day_e)::timestamp at time zone 'Asia/Ho_Chi_Minh', v_today - 30)
  returning id into c_e;

  day_f := v_today - 10;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref, created_at)
  values (v_unit, gen_random_uuid(), 'Grace expired, never checked', 'do', 'daily',
          'account_elsewhere', 'handle-f', v_today - 30)
  returning id into c_f;

  -- day_g is well within its own 96h grace (only 2 days old) and never checked -- exactly
  -- the shape that would read pending, EXCEPT the commitment itself does not exist yet on
  -- day_g: created_at defaults to now() (today), strictly after day_g.
  day_g := v_today - 2;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref)
  values (v_unit, gen_random_uuid(), 'Created after the day in question', 'do', 'daily',
          'account_elsewhere', 'handle-g')
  returning id into c_g;

  v_pending := public.auto_check_pending(c_a, day_a);
  if v_pending then
    raise exception using message =
      'auto_check_pending() read true for a commitment with no Auto-check attached at all.';
  end if;

  v_pending := public.auto_check_pending(c_b, day_b);
  if not v_pending then
    raise exception using message =
      'auto_check_pending() read false for a linked, undeclared, never-checked '
      'commitment safely inside its grace window. It must read true.';
  end if;

  v_pending := public.auto_check_pending(c_c, day_c);
  if v_pending then
    raise exception using message =
      'auto_check_pending() read true for a commitment already declared for the day in '
      'question. An answered day never blocks, regardless of Auto-check state.';
  end if;

  v_pending := public.auto_check_pending(c_d, day_d);
  if v_pending then
    raise exception using message =
      'auto_check_pending() read true for a commitment whose check has already reached a '
      'terminal result for this exact day (auto_check_last_checked_at''s own day-boundary '
      'identity, mirrored from resolve_auto_checks). It must read false.';
  end if;

  v_pending := public.auto_check_pending(c_e, day_e);
  if not v_pending then
    raise exception using message =
      'auto_check_pending() read false for a commitment whose last check ran for an '
      'EARLIER day than the one being asked about. The pass has not reached this day yet, '
      'so it must still read true.';
  end if;

  v_pending := public.auto_check_pending(c_f, day_f);
  if v_pending then
    raise exception using message =
      'auto_check_pending() read true for a commitment whose 96-hour grace window has '
      'already elapsed (day is 10 days old, never checked). Past grace it must read '
      'false regardless of check state, bounding the block instead of holding it forever.';
  end if;

  v_pending := public.auto_check_pending(c_g, day_g);
  if v_pending then
    raise exception using message =
      'auto_check_pending() read true for a commitment asked about a day BEFORE its own '
      'created_at, even though that day is well within the 96-hour grace window that '
      'would otherwise apply -- mirroring resolve_auto_checks'' own created_at guard '
      '(20260824090000), a commitment can never be pending for a day it did not exist on.';
  end if;

  raise notice using message =
    'Step 1 ok: auto_check_pending() reads false for no-Auto-check/already-declared/'
    'terminal/grace-expired/created-after-the-day, and true for a genuinely undeclared, '
    'unresolved, still-in-grace, already-existing commitment.';

  -- -------------------------------------------------------------------------------
  -- 2. settle_day: an unanswered, owed, Auto-check-linked Daily commitment blocks the
  --    account's day entirely -- no settlement row, not even an `expired` one -- and a
  --    retried pass changes nothing.
  -- -------------------------------------------------------------------------------
  d_block := v_today - 1;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_d_block, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-block', v_today - 30)
  returning id into c_dblock;

  -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
  -- This fixture creates its commitments moments before judging days that predate them, which is
  -- a state no real account can reach — so it now says when they began. Order-preserving, so
  -- every created_at comparison downstream reads the same way, and idempotent, so a second call
  -- further down this file does not age them twice.
  update public.commitment set created_at = created_at - interval '90 days'
   where created_at > now() - interval '30 days';

  perform public.settle_day(d_block, true);
  perform public.settle_day(d_block, true);

  select count(*) into v_count
    from public.settlement where subject = v_d_block and period = d_block;
  if v_count <> 0 then
    raise exception using message = format(
      'An unanswered, owed, Auto-check-linked commitment not yet terminal for the day '
      'must block settle_day entirely. Found %s settlement row(s) after two passes.',
      v_count);
  end if;

  raise notice using message =
    'Step 2 ok: a pending Auto-check blocks settle_day for the whole day, and a retried '
    'pass changes nothing.';

  -- The load-bearing case: with `d_late = v_today - 4` and `morning_hour` forced to 0,
  -- `declaration_deadline` lands at `d_late + 3` = `v_today - 1`, 00:00 HCM -- already in
  -- the past regardless of the current wall-clock hour, since `now()` is always on or
  -- after `v_today` 00:00 HCM. The pre-existing `answered < total and not past_deadline`
  -- gate alone would therefore let this settle right now, `expired`, with a silent-miss
  -- penalty. `auto_check_pending`'s 96-hour grace expires at `d_late + 5` = `v_today + 1`,
  -- 00:00 HCM -- always still in the future. The guard is checked *ahead of* past_deadline
  -- in settle_day's own body, so it must still block here on its own, proving it is
  -- genuinely load-bearing on the daily path, not merely redundant with the deadline.
  d_late := v_today - 4;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_d_late, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-late', v_today - 30)
  returning id into c_dlate;
  update public.profile set morning_hour = 0 where id = v_d_late;

  perform public.settle_day(d_late, true);

  select count(*) into v_count
    from public.settlement where subject = v_d_late and period = d_late;
  if v_count <> 0 then
    raise exception using message = format(
      'A pending Auto-check must keep blocking settle_day even once declaration_deadline '
      'has already passed, as long as its 96-hour grace has not -- otherwise the guard is '
      'checked but never the deciding factor. Found %s settlement row(s) for a day whose '
      'deadline has already passed but whose grace has not yet expired.', v_count);
  end if;

  raise notice using message =
    'Step 2b ok: a pending Auto-check keeps blocking settle_day even past its own '
    'declaration_deadline, as long as the 96-hour grace window has not yet elapsed -- the '
    'guard genuinely extends the block, it does not merely restate the existing deadline.';

  -- -------------------------------------------------------------------------------
  -- 3. settle_day: once resolved (a declaration lands, exactly what file_auto_check_result
  --    writes on `held`), the guard no longer applies and the day proceeds normally --
  --    fully answered, so it settles immediately regardless of the deadline.
  -- -------------------------------------------------------------------------------
  d_resolved := v_today - 1;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_d_resolved, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-resolved', v_today - 30)
  returning id into c_dresolved;

  perform public.file_auto_check_result(c_dresolved, v_d_resolved, 'held');

  perform public.settle_day(d_resolved, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_d_resolved and period = d_resolved and kind = 'day' and supersedes is null;
  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'A Daily commitment resolved `held` this pass must settle `clean` immediately -- '
      'fully answered, the deadline never even comes into it. Got `%s` (or no row).',
      v_verdict);
  end if;

  select count(*) into v_count
    from public.penalty p join public.settlement s on s.id = p.settlement_id
   where s.subject = v_d_resolved and s.period = d_resolved;
  if v_count <> 0 then
    raise exception using message = format(
      'A held Auto-check commitment must cost nothing. %s penalties were charged.', v_count);
  end if;

  raise notice using message =
    'Step 3 ok: a Daily commitment resolved `held` this pass settles `clean` immediately.';

  -- -------------------------------------------------------------------------------
  -- 4. settle_day: grace expired -- guard no longer blocks, and the day settles exactly
  --    as if no Auto-check were attached: the still-undeclared commitment counts as an
  --    ordinary silent, penalty-carrying miss. This is also the "unavailable/missed falls
  --    through" case -- neither result ever files a declaration (Story 4.1), so a
  --    genuinely stuck check looks identical to one that resolved `missed`/`unavailable`
  --    and never got the chance to say so before the grace window ran out.
  -- -------------------------------------------------------------------------------
  d_grace := v_today - 10;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_d_grace, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-grace', v_today - 30)
  returning id into c_dgrace;

  perform public.settle_day(d_grace, true);

  select verdict, missed_count into v_verdict, v_missed
    from public.settlement
   where subject = v_d_grace and period = d_grace and kind = 'day' and supersedes is null;
  if v_verdict is distinct from 'expired' then
    raise exception using message = format(
      'Past the 96-hour grace window, a still-undeclared Auto-check-linked day must settle '
      'exactly as if no Auto-check were attached: `expired` (unanswered, past deadline). '
      'Got `%s` (or no row) -- a permanently stuck check must never block a day forever.',
      v_verdict);
  end if;

  if v_missed <> 1 then
    raise exception using message = format(
      'The grace-expired commitment carries the penalty and was silent, so missed_count '
      'must be 1, not %s -- it counts as an ordinary silent miss, not something special.',
      v_missed);
  end if;

  select count(*) into v_count
    from public.penalty p join public.settlement s on s.id = p.settlement_id
   where s.subject = v_d_grace and s.period = d_grace;
  if v_count <> 1 then
    raise exception using message = format(
      'A penalty-carrying commitment silent past grace must cost exactly one penalty, not '
      '%s.', v_count);
  end if;

  raise notice using message = format(
    'Step 4 ok: %s (10 days old, check never ran) fell through its grace window and '
    'settled `expired` with one ordinary silent-miss penalty, exactly as if no Auto-check '
    'were attached.', d_grace);

  -- -------------------------------------------------------------------------------
  -- 5. settle_day: an already-answered Auto-check-linked commitment never blocks, even
  --    with its check never having run at all.
  -- -------------------------------------------------------------------------------
  d_answered := v_today - 1;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_d_answered, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-answered', v_today - 30)
  returning id into c_danswered;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_d_answered, c_danswered, gen_random_uuid(), 'slipped',
          (d_answered + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_day(d_answered, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_d_answered and period = d_answered and kind = 'day' and supersedes is null;
  if v_verdict is distinct from 'failed' then
    raise exception using message = format(
      'A declared (even self-admitted-slipped) Auto-check-linked commitment must never '
      'block settle_day -- it is already answered. Got `%s` (or no row: blocked).',
      v_verdict);
  end if;

  raise notice using message =
    'Step 5 ok: an already-answered Auto-check-linked commitment never blocks settle_day, '
    'regardless of its check having never run.';

  -- -------------------------------------------------------------------------------
  -- 5b. settle_day: the real "unavailable" shape -- resolve_account_elsewhere resolves,
  --     file_auto_check_result files nothing (Story 4.1), but the pass DOES stamp
  --     auto_check_last_checked_at terminal for the day. auto_check_pending must read
  --     false the moment that stamp lands, not only once the full 96-hour grace window
  --     elapses -- this is the ordinary, expected path in production (v1's one resolver
  --     only ever returns `unavailable`), unlike Step 4's grace-expiry fallthrough, which
  --     is the rare case where the pipeline never ran at all. `d_unavail` mirrors `d_late`
  --     (Step 2b): declaration_deadline already passed (morning_hour forced to 0), so the
  --     day is otherwise ready to settle `expired` the moment nothing is left blocking it
  --     -- proving the resolved stamp is what unblocks it, well before grace (day + 5)
  --     would have anyway.
  -- -------------------------------------------------------------------------------
  d_unavail := v_today - 4;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_d_unavail, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-unavail', v_today - 30)
  returning id into c_dunavail;
  update public.profile set morning_hour = 0 where id = v_d_unavail;

  perform public.file_auto_check_result(
    c_dunavail, v_d_unavail, public.resolve_account_elsewhere(c_dunavail));

  select count(*) into v_count
    from public.declaration where commitment_id = c_dunavail and for_day = d_unavail;
  if v_count <> 0 then
    raise exception using message = format(
      'resolve_account_elsewhere + file_auto_check_result filed %s declaration row(s) -- '
      'v1''s resolver only ever reads unavailable, which must file nothing.', v_count);
  end if;

  -- Before the pass stamps the day, past_deadline is already true (day + 3 = v_today - 1,
  -- 0:00 HCM, comfortably in the past) but the day is still blocked by auto_check_pending.
  perform public.settle_day(d_unavail, true);
  select count(*) into v_count
    from public.settlement where subject = v_d_unavail and period = d_unavail;
  if v_count <> 0 then
    raise exception using message = format(
      'This day must still be blocked before the resolver''s pass stamps it -- found %s '
      'settlement row(s) too early.', v_count);
  end if;

  -- The same pass that produced `unavailable` also stamps auto_check_last_checked_at
  -- unconditionally (resolve_auto_checks' own behaviour) -- simulated here directly. Only
  -- one hour after the day closed -- nowhere near the 96-hour grace boundary.
  update public.commitment
     set auto_check_last_checked_at = ((d_unavail + 1)::timestamp + interval '1 hour')
                                       at time zone 'Asia/Ho_Chi_Minh'
   where id = c_dunavail;

  perform public.settle_day(d_unavail, true);

  select verdict, missed_count into v_verdict, v_missed
    from public.settlement
   where subject = v_d_unavail and period = d_unavail and kind = 'day' and supersedes is null;
  if v_verdict is distinct from 'expired' then
    raise exception using message = format(
      'Once the resolver has run and stamped the day terminal -- even with nothing '
      'declared, one hour after the day closed rather than after the full 96-hour grace '
      '-- settle_day must proceed. Got `%s` (or no row: still blocked).', v_verdict);
  end if;
  if v_missed <> 1 then
    raise exception using message = format(
      'The unavailable, still-undeclared commitment carries the penalty and stayed '
      'silent, so missed_count must be 1, not %s.', v_missed);
  end if;

  raise notice using message =
    'Step 5b ok: a check resolved to unavailable (stamped terminal, nothing declared) '
    'unblocks settle_day as soon as the stamp lands -- it does not wait for the 96-hour '
    'grace window to run out, the common production path rather than the rare '
    'stuck-pipeline one.';

  -- -------------------------------------------------------------------------------
  -- 5c. settle_day: a pending Auto-check on a Weekly Quota commitment never blocks
  --     settle_day at all -- that protection belongs to settle_week's own guard (Steps
  --     6-9). commitments_owing() does not exclude weekly_quota (only daily_hours_quota
  --     is), so the still-unanswered weekly-quota commitment already keeps this day open
  --     via the ordinary `answered < total and not past_deadline` gate -- unrelated to
  --     Auto-checks, true even without one attached -- so `d_weekly` is pushed past its
  --     own declaration_deadline (morning_hour forced to 0, mirroring `d_late`/Step 2b) to
  --     isolate what's actually under test: whether the AD-13 guard *itself* also blocks
  --     on it. Pre-fix, it would have (grace for this day doesn't expire until
  --     `d_weekly + 5` = tomorrow) -- no settlement row at all. Post-fix, the day settles
  --     on schedule via the pre-existing deadline path, `expired` (the weekly commitment
  --     stays genuinely unanswered) with zero penalty (admitted/silent already exclude
  --     weekly_quota, and the one Daily commitment held) -- proving the AD-13 guard never
  --     saw the weekly-quota row at all, not merely that the day eventually settled.
  -- -------------------------------------------------------------------------------
  d_weekly := v_today - 4;
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_d_weekly, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-weekly-daily', v_today - 30)
  returning id into c_dweekly_daily;
  update public.profile set morning_hour = 0 where id = v_d_weekly;
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_d_weekly, c_dweekly_daily, gen_random_uuid(), 'held',
          (d_weekly + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day,
                                 auto_check_kind, auto_check_account_ref, created_at)
  values (v_d_weekly, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow,
          'account_elsewhere', 'handle-weekly-wq', v_today - 30)
  returning id into c_dweekly_wq;

  perform public.settle_day(d_weekly, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_d_weekly and period = d_weekly and kind = 'day' and supersedes is null;
  if v_verdict is distinct from 'expired' then
    raise exception using message = format(
      'A pending Auto-check on a Weekly Quota commitment must never block settle_day -- '
      'that protection is settle_week''s job. Past its own deadline with the weekly '
      'commitment still genuinely unanswered, the day must settle `expired` on schedule. '
      'Got `%s` (or no row: still blocked by the unrelated weekly-quota commitment''s '
      'pending check, exactly the pre-fix regression).', v_verdict);
  end if;

  select count(*) into v_count
    from public.penalty p join public.settlement s on s.id = p.settlement_id
   where s.subject = v_d_weekly and s.period = d_weekly;
  if v_count <> 0 then
    raise exception using message = format(
      'The Daily commitment held and weekly_quota never costs a daily penalty '
      '(admitted/silent already exclude it) -- %s penalties were charged.', v_count);
  end if;

  raise notice using message =
    'Step 5c ok: a pending Auto-check on a Weekly Quota commitment never blocks '
    'settle_day -- the day settles `expired` on schedule via the pre-existing deadline '
    'path, with no penalty, proving the AD-13 guard itself never saw the weekly-quota row.';

  -- -------------------------------------------------------------------------------
  -- 5d. settle_day: a brand-new, Auto-check-linked commitment never blocks an OLDER day it
  --     did not exist on. Without auto_check_pending's own created_at guard (20260824100000),
  --     the account's genuinely-late, unrelated commitment for that older day would get
  --     dragged into a 96-hour block purely because a second, brand-new commitment happened
  --     to be created after it -- proven with `c_dnewcheck_old` still unanswered and past its
  --     own deadline, exactly Step 2b's shape, but blocked now only by `c_dnewcheck_new`,
  --     created today, with nothing to do with that older day at all.
  --
  --     Since Story 6.4 commitments_owing() carries that same created_at guard, so the
  --     brand-new commitment is not even in the owed set for this day. Both guards are
  --     asserted here rather than one being dropped as redundant: they answer different
  --     questions (is a check still pending, versus is an answer owed at all), and the day
  --     one of them is removed is the day the other has to be already proven.
  -- -------------------------------------------------------------------------------
  d_newcheck := v_today - 4;
  -- `created_at` stated rather than defaulted: Story 6.4 gave commitments_owing() the same
  -- created_at guard auto_check_pending already carried, so a commitment created moments ago is
  -- not owed an answer for a day four days old and this step's "older, unrelated" commitment
  -- would not be in the set it is meant to represent.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, created_at)
  values (v_d_newcheck, gen_random_uuid(), 'Older, unrelated, genuinely late', 'do', 'daily',
          true, v_today - 30)
  returning id into c_dnewcheck_old;
  update public.profile set morning_hour = 0 where id = v_d_newcheck;

  -- Created "today" (default created_at), Auto-check attached, never checked -- well
  -- within its own 96h grace window for d_newcheck, which is only 4 days old.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref)
  values (v_d_newcheck, gen_random_uuid(), 'Just created, unrelated', 'do', 'daily',
          'account_elsewhere', 'handle-newcheck')
  returning id into c_dnewcheck_new;

  perform public.settle_day(d_newcheck, true);

  select verdict, missed_count into v_verdict, v_missed
    from public.settlement
   where subject = v_d_newcheck and period = d_newcheck and kind = 'day' and supersedes is null;
  if v_verdict is distinct from 'expired' then
    raise exception using message = format(
      'A brand-new, Auto-check-linked commitment must never block settle_day for an older '
      'day it did not exist on. The account''s older, unrelated, genuinely-late commitment '
      'should have settled `expired` on schedule. Got `%s` (or no row: blocked by a '
      'commitment that was never owed for this day at all).', v_verdict);
  end if;
  if v_missed <> 1 then
    raise exception using message = format(
      'The older commitment carries the penalty and stayed silent, so missed_count must '
      'be 1, not %s -- the brand-new commitment (no penalty) must not be counted either.',
      v_missed);
  end if;

  raise notice using message =
    'Step 5d ok: a brand-new, Auto-check-linked commitment never blocks settle_day for an '
    'older day it did not exist on -- auto_check_pending''s own created_at guard keeps it '
    'out of a day it was never owed for, even though that day is well within its 96-hour '
    'grace window.';

  -- -------------------------------------------------------------------------------
  -- 6. settle_week: a pending check on ANY SINGLE DAY inside [p_period, p_period+6] blocks
  --    the WHOLE period, not just that day -- and a retried pass changes nothing. Unlike
  --    settle_day, settle_week has no "wait for answers" logic of its own: without this
  --    guard it would judge the shortfall (0 of 3) unconditionally once today >= p_period+8.
  -- -------------------------------------------------------------------------------
  -- `today >= p_period + 8` is settle_week's own closing gate, and a day D's own grace
  -- (96h from D + 1) expires at D + 5. The period's last day is p_period + 6, whose grace
  -- expires at p_period + 11 -- three days AFTER the period itself first becomes eligible
  -- to close (p_period + 8). So the freshest possible closed period, p_period + 8 = today,
  -- comfortably coexists with a still-pending last day; a much older period (Step 8 below)
  -- has run out every day's grace regardless.
  p_wblock := v_today - 8;
  v_isodow_wblock := extract(isodow from p_wblock)::integer;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day,
                                 auto_check_kind, auto_check_account_ref, created_at)
  values (v_w_block, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow_wblock,
          'account_elsewhere', 'handle-wblock',
          (p_wblock - 1 + time '00:00') at time zone 'Asia/Ho_Chi_Minh')
  returning id into c_wblock;

  -- No declaration at all for any day of the period: every one of its 7 days is
  -- undeclared and unchecked. The period's last day (p_period + 6 = today - 2) has its
  -- own grace still open (expires today + 1) even though the period itself just closed --
  -- exactly the race this story exists to close.
  perform public.settle_week(p_wblock, true);
  perform public.settle_week(p_wblock, true);

  select count(*) into v_count
    from public.settlement where subject = v_w_block and period = p_wblock and kind = 'week';
  if v_count <> 0 then
    raise exception using message = format(
      'A pending Auto-check on any day inside the period must block settle_week entirely '
      '-- the whole period, not merely that day. Found %s settlement row(s) after two '
      'passes over a closed (today >= p_period + 8) period.', v_count);
  end if;

  raise notice using message =
    'Step 6 ok: a pending Auto-check blocks settle_week for the whole period, and a '
    'retried pass changes nothing.';

  -- -------------------------------------------------------------------------------
  -- 7. settle_week: once every day in the period is terminal (simulating a resolution
  --    pass that ran late but did eventually stamp the whole week, still finding nothing
  --    to declare -- "unavailable"/"missed" file no declaration, Story 4.1), the guard no
  --    longer blocks and the period proceeds -- this is the one place in this file where
  --    unblocking demonstrably changes the outcome, since settle_week has no fallback
  --    "still open" state the way settle_day does.
  -- -------------------------------------------------------------------------------
  update public.commitment
     set auto_check_last_checked_at =
           -- HCM date >= (p_wblock + 6) + 1: terminal for every day up to and including
           -- the last day of the period, all at once.
           (p_wblock + 7)::timestamp at time zone 'Asia/Ho_Chi_Minh'
   where id = c_wblock;

  perform public.settle_week(p_wblock, true);

  select verdict, missed_count into v_verdict, v_missed
    from public.settlement
   where subject = v_w_block and period = p_wblock and kind = 'week' and supersedes is null;
  if v_verdict is distinct from 'failed' then
    raise exception using message = format(
      'Once every day in the period is terminal, settle_week must proceed normally -- 0 '
      'of 3 held is a shortfall, `failed`. Got `%s` (or no row: still blocked).', v_verdict);
  end if;
  if v_missed <> 1 then
    raise exception using message = format(
      'The one shortfall carries the penalty, so missed_count must be 1, not %s.', v_missed);
  end if;

  select count(*) into v_count
    from public.penalty p join public.settlement s on s.id = p.settlement_id
   where s.subject = v_w_block and s.period = p_wblock and s.kind = 'week';
  if v_count <> 1 then
    raise exception using message = format(
      'A Failed Week costs exactly one penalty. Found %s.', v_count);
  end if;

  raise notice using message =
    'Step 7 ok: once every day in the period is terminal, settle_week proceeds and '
    'settles the shortfall `failed` with exactly one penalty.';

  -- -------------------------------------------------------------------------------
  -- 8. settle_week: grace expired -- falls through and settles exactly as if no
  --    Auto-check were attached, without the check ever having run.
  -- -------------------------------------------------------------------------------
  p_wgrace := v_today - 35; -- a multiple of 7 back; every day's own grace has long elapsed

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day,
                                 auto_check_kind, auto_check_account_ref, created_at)
  values (v_w_grace, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 3, v_isodow,
          'account_elsewhere', 'handle-wgrace',
          (p_wgrace - 1 + time '00:00') at time zone 'Asia/Ho_Chi_Minh')
  returning id into c_wgrace;

  perform public.settle_week(p_wgrace, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_w_grace and period = p_wgrace and kind = 'week' and supersedes is null;
  if v_verdict is distinct from 'failed' then
    raise exception using message = format(
      'A 35-day-old period whose Auto-check never ran must fall through its grace window '
      'and settle exactly as if no Auto-check were attached: `failed` (0 of 3). Got `%s` '
      '(or no row: still blocked, which would mean the block never expires).', v_verdict);
  end if;

  raise notice using message = format(
    'Step 8 ok: %s (35 days old, check never ran) fell through its grace window and '
    'settled `failed`, exactly as if no Auto-check were attached.', p_wgrace);

  -- -------------------------------------------------------------------------------
  -- 9. settle_week: a period fully declared on every one of its 7 days never blocks, no
  --    matter that its check never ran -- the whole-period guard reads every day in the
  --    series, not merely the days needed to reach the target.
  -- -------------------------------------------------------------------------------
  p_wanswered := v_today - 14;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day,
                                 auto_check_kind, auto_check_account_ref, created_at)
  values (v_w_answered, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', true, 2, v_isodow,
          'account_elsewhere', 'handle-wanswered',
          (p_wanswered - 1 + time '00:00') at time zone 'Asia/Ho_Chi_Minh')
  returning id into c_wanswered;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  select v_w_answered, c_wanswered, gen_random_uuid(),
         (case when n in (0, 3) then 'held' else 'slipped' end)::public.declaration_answer,
         (p_wanswered + n + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh'
    from generate_series(0, 6) as n;

  perform public.settle_week(p_wanswered, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_w_answered and period = p_wanswered and kind = 'week' and supersedes is null;
  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'A period declared on all 7 of its days (2 held, meeting the target of 2) must '
      'settle `clean` immediately -- fully declared, regardless of the Auto-check never '
      'having run. Got `%s` (or no row: blocked).', v_verdict);
  end if;

  raise notice using message =
    'Step 9 ok: a period fully declared on every one of its 7 days never blocks '
    'settle_week, no matter that its Auto-check never ran.';

  -- -------------------------------------------------------------------------------
  -- 10. AD-16 sanity: the live-doer override guard still refuses on this migration's own
  --     rewritten settle_day/settle_week, proving the guard's own body was not lost in
  --     the rewrite.
  -- -------------------------------------------------------------------------------
  update public.profile set is_live_doer = true where id = v_live;

  declare
    v_raised boolean := false;
  begin
    begin
      perform public.settle_day(v_today - 1, true);
    exception when others then
      v_raised := true;
    end;
    if not v_raised then
      raise exception using message =
        'AD-16: settle_day accepted an override against a live doer account after this '
        'migration''s rewrite.';
    end if;

    v_raised := false;
    begin
      perform public.settle_week(v_today - 14, true);
    exception when others then
      v_raised := true;
    end;
    if not v_raised then
      raise exception using message =
        'AD-16: settle_week accepted an override against a live doer account after this '
        'migration''s rewrite.';
    end if;
  end;

  update public.profile set is_live_doer = false where id = v_live;

  raise notice using message =
    'Step 10 ok: AD-16''s override guard still holds on both rewritten functions.';

  raise notice using message =
    'PASS. auto_check_pending() reads correctly in isolation; a pending Auto-check blocks '
    'settle_day/settle_week for the whole day/period (even past their own deadlines) and '
    'retries change nothing; it unblocks the moment a check resolves, whether via a '
    'declaration or a bare stamp with nothing to declare, with no wait for grace; a '
    'grace-expired check falls through and settles exactly as if no Auto-check were '
    'attached, on both paths; a pending Weekly Quota check never blocks settle_day, only '
    'settle_week; and a brand-new Auto-check commitment never blocks an older day it did '
    'not exist on.';
end $$;

rollback;
