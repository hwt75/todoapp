-- Story 6.4 — midnight decides the day.
--
-- The only story in Epic 6 that moves money. Two rules are asserted here, and everything else
-- in the file exists to make sure neither of them reached further than it was meant to:
--
--   1. On a commitment carrying a `due_time`, a claim is worth `held` only once evidence
--      exists for it, and is worth `slipped` once the day it was made has ended without any.
--      A commitment with no claim at all is still silence, unchanged — that is what Story 5.2
--      and the answer-rate measures count.
--   2. A timed commitment is judged at midnight of its own day rather than at the account's
--      morning hour on D+3. A day holding both kinds closes each on its own clock, and the
--      settlement row itself still waits for the last of them.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/6-4-midnight-decides-the-day.sql
--
-- One transaction, rolled back at the end.
--
-- It needs a database with **no live doer account**: `settle_day` raises rather than skipping
-- when `p_override` meets one (AD-16), so a single live profile would disable every call below.
-- Local stack or preview branch, never the author's own project — the same note
-- `2-5-settlement.sql` and `2-7-supersession.sql` carry at length.
--
-- **One account per scenario, deliberately.** `commitments_owing()` returns every commitment an
-- account owns, not the ones that happen to have a declaration, so two scenarios sharing an
-- account would share every day and neither could be read on its own.
--
-- Steps 12 to 15 are the review's own findings, each pinned by the sequence that produced it: a
-- time added to a commitment that already had history re-judged and charged for days already
-- answered; an unclaimed timed Weekly Quota expired every day it was not done; a commitment
-- created today was judged for the five days settle_due_days() sweeps; and an answer arriving
-- after its own midnight could still correct an expired day. Step 16 checks the claim that a
-- Grace Day, the only remedy a forgotten photo has, still works over the new verdict.

begin;

grant select on table public.profile, public.commitment, public.declaration to authenticated;
grant insert on table public.declaration, public.evidence to authenticated;
grant select on table public.evidence to authenticated;

do $$
declare
  -- One account per scenario.
  v_a          uuid := gen_random_uuid(); -- timed only: proved today, claimed-unproven, silent
  v_b          uuid := gen_random_uuid(); -- timed + untimed: the mixed day that must stay open
  v_c          uuid := gen_random_uuid(); -- timed only: a past day that was actually proved
  v_d          uuid := gen_random_uuid(); -- untimed only: the control that must not move
  v_e          uuid := gen_random_uuid(); -- the morning question's own account
  v_f          uuid := gen_random_uuid(); -- the weekly quota
  v_g          uuid := gen_random_uuid(); -- the expired day that gets corrected later
  v_h          uuid := gen_random_uuid(); -- the commitment that gains a time after the fact
  v_i          uuid := gen_random_uuid(); -- the timed weekly quota that owes nothing
  v_j          uuid := gen_random_uuid(); -- the commitment created after the days being swept
  v_k          uuid := gen_random_uuid(); -- the answer that arrives after its own midnight

  v_a_timed    uuid;
  v_b_timed    uuid;
  v_b_untimed  uuid;
  v_c_timed    uuid;
  v_d_untimed  uuid;
  v_e_timed    uuid;
  v_e_untimed  uuid;
  v_f_timed    uuid;
  v_f_untimed  uuid;
  v_g_timed    uuid;
  v_g_untimed  uuid;
  v_h_edited   uuid;
  v_i_quota    uuid;
  v_j_new      uuid;
  v_k_timed    uuid;

  v_claim      uuid;   -- v_a's claim for today
  v_c_claim    uuid;   -- v_c's claim for yesterday, the one that was proved
  v_f_claim    uuid;   -- v_f's claim for today

  v_today      date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_yesterday  date;
  v_silent_day date;
  v_old_day    date;
  v_local_hour integer;

  -- Observed
  v_answer     public.declaration_answer;
  v_settlement uuid;
  v_verdict    public.day_verdict;
  v_outcome    public.commitment_outcome;
  v_count      integer;
  v_held       integer;
  v_body       text;
  v_refused    boolean;
  v_is_untimed boolean;
  v_due_read   time;
  v_case       text;

  -- A tap inside a window fixed at 10:00, whatever hour this file is actually run at: the
  -- window is compared against the tap's own time of day, never against `now()`.
  v_tap        timestamptz := (
    (v_today || ' 10:14')::timestamp at time zone 'Asia/Ho_Chi_Minh'
  );
begin
  v_yesterday  := v_today - 1;
  v_silent_day := v_today - 2;

  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override (AD-16). '
      'Run against a local or branch database instead. Never work around the guard by '
      'setting app.settlement_invocation by hand.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 0. Fixture.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k']
  loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (case v_case
              when 'a' then v_a when 'b' then v_b when 'c' then v_c
              when 'd' then v_d when 'e' then v_e when 'f' then v_f when 'g' then v_g
              when 'h' then v_h when 'i' then v_i when 'j' then v_j else v_k
            end,
            '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'story-6-4-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_a_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_b, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_b_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_b, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_b_untimed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_c, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_c_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_d, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_d_untimed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_e, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_e_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_e, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_e_untimed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day,
                                 due_time, late_window_minutes)
  values (v_f, gen_random_uuid(), 'Call home', 'do', 'weekly_quota', true, 3, 1,
          time '10:00', 30)
  returning id into v_f_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day)
  values (v_f, gen_random_uuid(), 'Run', 'do', 'weekly_quota', true, 3, 1)
  returning id into v_f_untimed;

  -- v_c's proved yesterday, planted here rather than at step 5 because the first
  -- `settle_day(v_yesterday)` below would otherwise close v_c's day as expired first, and a
  -- settled day is never re-judged.
  --
  -- The evidence trigger refuses a claim's photo once the day it proves has ended
  -- (20260828150000), which is correct and is asserted by `6-3`. It also means a *proved
  -- yesterday* cannot be built through the front door inside one transaction, because only the
  -- passage of time produces one. So the trigger is switched off for exactly this insert and
  -- `owner_id` is written by hand — the one thing it would otherwise derive.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_c, v_c_timed, gen_random_uuid(), 'held',
          ((v_yesterday + 1)::timestamp + interval '10 hours 14 minutes')
            at time zone 'Asia/Ho_Chi_Minh')
  returning id into v_c_claim;

  alter table public.evidence disable trigger evidence_derive_owner;
  insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
  values (v_c_claim, v_c, v_c_claim::text || '/pill.jpg', v_yesterday);
  alter table public.evidence enable trigger evidence_derive_owner;

  -- Every fixture commitment has to predate the days it is judged for. `commitments_owing()`
  -- refuses a day before the commitment existed — step 14 is that rule — so a commitment created
  -- moments ago would drop out of every past day for that reason rather than the one each step is
  -- actually about. Only `created_at` moves; the due_time log keeps its own stamps, which is
  -- exactly the shape `due_time_as_of()` extrapolates backward from.
  --
  -- v_j is deliberately left un-aged. It *is* that rule's own case.
  update public.commitment set created_at = created_at - interval '90 days'
   where owner_id in (v_a, v_b, v_c, v_d, v_e, v_f);

  -- -------------------------------------------------------------------------------
  -- 1. A claim on its own day, before and after the photo.
  --
  -- Filed as the doer so it takes Story 6.2's same-day branch and lands on today. The
  -- reading before the photo is the one that matters most: it must not be `slipped` yet,
  -- because the day is still running and the photo can still arrive.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_a_timed, gen_random_uuid(), 'held', v_tap)
  returning id into v_claim;
  perform set_config('role', 'postgres', true);

  select o.answer into v_answer
    from public.commitments_owing(v_a, v_today) o
   where o.commitment_id = v_a_timed;

  if v_answer is not null then
    raise exception using message = format(
      'A claim made today with no photo yet reads `%s`. The day is still running and the '
      'photo can still land; nothing is decided until midnight.', v_answer);
  end if;

  -- And the day it belongs to is still open. `settle_due_days()` never offers today, so this
  -- is a question only this file asks — but the function has to answer it honestly rather
  -- than rely on its callers' choice of day.
  perform public.settle_day(v_today, true);

  select count(*) into v_count
    from public.settlement where subject = v_a and period = v_today and kind = 'day';

  if v_count <> 0 then
    raise exception using message =
      'A day whose claim is still waiting for its photo settled before midnight. The window '
      'to prove it had not closed.';
  end if;

  perform set_config('role', 'authenticated', true);
  insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
  values (v_claim, v_a, v_claim::text || '/pill.jpg', v_today);
  perform set_config('role', 'postgres', true);

  select o.answer into v_answer
    from public.commitments_owing(v_a, v_today) o
   where o.commitment_id = v_a_timed;

  if v_answer is distinct from 'held' then
    raise exception using message = format(
      'A claim with an accepted photo reads `%s`, expected `held`. The photo is what holds '
      'a timed day.', v_answer);
  end if;

  raise notice using message =
    'Step 1 ok: a claim is worth nothing until its photo lands, and `held` once it has.';

  -- -------------------------------------------------------------------------------
  -- 2. A claim whose photo never came, on a day that has ended.
  --
  -- Inserted as postgres, which takes the machine branch and still derives the previous day
  -- (20260828140000) — the only way to place a claim on a day that is already over, and the
  -- same technique `6-3` uses. Nothing about who filed it is read by anything below: the
  -- rule is about proof, not about authorship.
  -- -------------------------------------------------------------------------------
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_a_timed, gen_random_uuid(), 'held',
          ((v_yesterday + 1)::timestamp + interval '10 hours 14 minutes')
            at time zone 'Asia/Ho_Chi_Minh');

  select o.answer into v_answer
    from public.commitments_owing(v_a, v_yesterday) o
   where o.commitment_id = v_a_timed;

  if v_answer is distinct from 'slipped' then
    raise exception using message = format(
      'A claim whose day ended with no photo reads `%s`, expected `slipped`. He answered, '
      'and the answer is not what holds a timed day.', v_answer);
  end if;

  perform public.settle_day(v_yesterday, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_a and period = v_yesterday and kind = 'day' and supersedes is null;

  if v_verdict is distinct from 'failed' then
    raise exception using message = format(
      'A day whose only commitment was claimed and never proved settled as `%s`, expected '
      '`failed`. Under the old rule it would still be open for two more days.',
      coalesce(v_verdict::text, 'nothing at all'));
  end if;

  select sc.outcome into v_outcome
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
   where s.subject = v_a and s.period = v_yesterday and s.kind = 'day' and s.supersedes is null
     and sc.commitment_id = v_a_timed;

  if v_outcome is distinct from 'missed' then
    raise exception using message = format(
      'The unproved commitment froze as `%s`, expected `missed`. Filing it as `unanswered` '
      'would put a day he engaged with into a history of days he did not.', v_outcome);
  end if;

  select count(*) into v_count
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_a and s.period = v_yesterday;

  if v_count <> 1 then
    raise exception using message = format(
      'A failed day costs exactly one penalty; found %s.', v_count);
  end if;

  raise notice using message =
    'Step 2 ok: a forgotten photo fails the day at midnight, as a miss, for exactly one penalty.';

  -- -------------------------------------------------------------------------------
  -- 3. A timed commitment never claimed at all is still silence — judged at midnight.
  --
  -- The load-bearing half of this is `answer is null`: Silence detection (5.2) and the
  -- monthly answer-rate measures (5.4) both read `count(*)` against `count(answer)` over this
  -- function, and a synthesised miss here would tell both that he spoke when he did not.
  -- -------------------------------------------------------------------------------
  select o.answer into v_answer
    from public.commitments_owing(v_a, v_silent_day) o
   where o.commitment_id = v_a_timed;

  if v_answer is not null then
    raise exception using message = format(
      'A timed commitment with no declaration at all reads `%s`. It must stay null — that is '
      'what Silence detection and the answer-rate measures count.', v_answer);
  end if;

  perform public.settle_day(v_silent_day, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_a and period = v_silent_day and kind = 'day' and supersedes is null;

  if v_verdict is distinct from 'expired' then
    raise exception using message = format(
      'A timed day nobody claimed settled as `%s`, expected `expired`.',
      coalesce(v_verdict::text, 'nothing at all'));
  end if;

  select count(*) into v_count
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_a and s.period = v_silent_day;

  if v_count <> 1 then
    raise exception using message = format(
      'Silence on a penalty-carrying commitment still costs; found %s penalties.', v_count);
  end if;

  raise notice using message =
    'Step 3 ok: an unclaimed timed commitment is silence, closed at its own midnight.';

  -- -------------------------------------------------------------------------------
  -- 4. A day holding both kinds waits for the untimed one.
  --
  -- The timed verdict is fixed at midnight and cannot move; the settlement row still covers
  -- a day, not a commitment, so it waits for the commitment whose clock is still running.
  -- Settled by step 2's own call — `settle_day` walks every doer account.
  -- -------------------------------------------------------------------------------
  select o.answer into v_answer
    from public.commitments_owing(v_b, v_yesterday) o
   where o.commitment_id = v_b_timed;

  if v_answer is not null then
    raise exception using message = format(
      'v_b filed no claim yesterday, so its timed commitment must read null, not `%s`.',
      v_answer);
  end if;

  select count(*) into v_count
    from public.settlement
   where subject = v_b and period = v_yesterday and kind = 'day';

  if v_count <> 0 then
    raise exception using message =
      'A day whose untimed commitment is still inside its own 48 hours must stay open, '
      'however decided the timed one already is.';
  end if;

  raise notice using message =
    'Step 4 ok: each kind closes on its own clock, and the day waits for the last of them.';

  -- -------------------------------------------------------------------------------
  -- 5. A past day that really was proved — planted in the fixture, settled by step 2's call.
  -- -------------------------------------------------------------------------------
  select o.answer into v_answer
    from public.commitments_owing(v_c, v_yesterday) o
   where o.commitment_id = v_c_timed;

  if v_answer is distinct from 'held' then
    raise exception using message = format(
      'A proved day reads `%s`, expected `held`.', v_answer);
  end if;

  select verdict into v_verdict
    from public.settlement
   where subject = v_c and period = v_yesterday and kind = 'day' and supersedes is null;

  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'A day proved by a photo settled as `%s`, expected `clean`.',
      coalesce(v_verdict::text, 'nothing at all'));
  end if;

  select sc.outcome into v_outcome
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
   where s.subject = v_c and s.period = v_yesterday and s.kind = 'day' and s.supersedes is null
     and sc.commitment_id = v_c_timed;

  if v_outcome is distinct from 'held' then
    raise exception using message = format(
      'A proved commitment froze as `%s`, expected `held` — its chain has to survive.',
      v_outcome);
  end if;

  select count(*) into v_count
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_c and s.period = v_yesterday;

  if v_count <> 0 then
    raise exception using message = format(
      'A proved day costs nothing; found %s penalties.', v_count);
  end if;

  raise notice using message = 'Step 5 ok: a proved day holds, keeps its chain, and costs nothing.';

  -- -------------------------------------------------------------------------------
  -- 6. The untimed control, which must read exactly as it did before this story.
  -- -------------------------------------------------------------------------------
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_d, v_d_untimed, gen_random_uuid(), 'held',
          ((v_yesterday + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  select o.answer, o.due_time is null into v_answer, v_is_untimed
    from public.commitments_owing(v_d, v_yesterday) o
   where o.commitment_id = v_d_untimed;

  if v_answer is distinct from 'held' or not v_is_untimed then
    raise exception using message = format(
      'An untimed commitment declared held reads `%s` (due_time null: %s). Nothing about an '
      'untimed commitment changed in this story.', v_answer, v_is_untimed);
  end if;

  perform public.settle_day(v_yesterday, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_d and period = v_yesterday and kind = 'day' and supersedes is null;

  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'The untimed control settled as `%s`, expected `clean`.',
      coalesce(v_verdict::text, 'nothing at all'));
  end if;

  raise notice using message = 'Step 6 ok: an untimed commitment is untouched.';

  -- -------------------------------------------------------------------------------
  -- 7. The morning question does not ask about a day that ended at midnight.
  --
  -- `morning_hour` pinned to the current local hour so the pass runs whatever time this file
  -- is executed at — the same technique `5-2` uses. The day before yesterday is answered so
  -- no Silence episode opens, which would suppress the routine push entirely.
  -- -------------------------------------------------------------------------------
  v_local_hour := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh')::integer;
  update public.profile set morning_hour = v_local_hour where id = v_e;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_e, v_e_untimed, gen_random_uuid(), 'held',
          ((v_silent_day + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  perform public.enqueue_gate_reminders();

  select payload ->> 'body' into v_body
    from public.outbox
   where owner_id = v_e and dedupe_key like 'gate-' || v_e::text || '-' || v_yesterday::text || '%';

  if v_body is null then
    raise exception using message =
      'No gate reminder was enqueued for the account whose untimed commitment is unanswered.';
  end if;

  if v_body not like '%1 commitment is unanswered%' then
    raise exception using message = format(
      'The morning question says "%s". It must count the untimed commitment only — the timed '
      'one was decided at midnight and asking again offers a second, softer answer.', v_body);
  end if;

  raise notice using message = 'Step 7 ok: the morning question skips a timed commitment.';

  -- -------------------------------------------------------------------------------
  -- 8. A weekly quota counts proved days only.
  --
  -- `weekly_held_count()` is the one place outside `commitments_owing()` that tallies a held
  -- day, and `settle_week()` pays out on it.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_f, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_f, v_f_timed, gen_random_uuid(), 'held', v_tap)
  returning id into v_f_claim;
  perform set_config('role', 'postgres', true);

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_f, v_f_untimed, gen_random_uuid(), 'held',
          ((v_yesterday + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  v_held := public.weekly_held_count(v_f_timed, v_today - 3);
  if v_held <> 0 then
    raise exception using message = format(
      'An unproved claim counted %s toward the week. A quota met on unproved claims would be '
      'paid out by settle_week().', v_held);
  end if;

  v_held := public.weekly_held_count(v_f_untimed, v_today - 3);
  if v_held <> 1 then
    raise exception using message = format(
      'An untimed weekly commitment declared held counted %s, expected 1. Nothing about an '
      'untimed commitment changed.', v_held);
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_f, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
  values (v_f_claim, v_f, v_f_claim::text || '/call.jpg', v_today);
  perform set_config('role', 'postgres', true);

  v_held := public.weekly_held_count(v_f_timed, v_today - 3);
  if v_held <> 1 then
    raise exception using message = format(
      'A proved claim counted %s toward the week, expected 1.', v_held);
  end if;

  raise notice using message = 'Step 8 ok: the weekly quota counts proved days only.';

  -- -------------------------------------------------------------------------------
  -- 9. A sensor and a photo are two answers to one question.
  --
  -- Story 6.2's open question, answered by refusing the combination. Each alone still works.
  -- -------------------------------------------------------------------------------
  v_refused := false;
  begin
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   due_time, late_window_minutes,
                                   auto_check_kind, auto_check_account_ref)
    values (v_d, gen_random_uuid(), 'Both', 'do', 'daily', time '10:00', 30,
            'account_elsewhere', 'my-handle');
  -- The named constraint, not `when others`: a typo in a column name or an unrelated NOT NULL
  -- would otherwise read as "the rule held" and this step would pass on nothing.
  exception when check_violation then
    if sqlerrm not like '%commitment_time_not_with_auto_check%' then
      raise exception using message = format(
        'Refused, but by the wrong rule: %s', sqlerrm);
    end if;
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'A commitment carrying both a due_time and an Auto-check was accepted. A sensor filing '
      '`held` the next morning would hold a day no photo ever proved.';
  end if;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref)
  values (v_d, gen_random_uuid(), 'Sensor only', 'do', 'daily',
          'account_elsewhere', 'my-handle');

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_d, gen_random_uuid(), 'Time only', 'do', 'daily', time '10:00', 30);

  raise notice using message =
    'Step 9 ok: the combination is refused and each half alone still saves.';

  -- -------------------------------------------------------------------------------
  -- 10. An expired day corrected later still reads the timed claim as a miss.
  --
  -- `supersede_expiries()` measures each answer against its own deadline now, and reads what
  -- the answer was *worth* from `commitments_owing()` rather than from `declaration.answer`.
  -- Those are the same number for every untimed commitment and different for exactly this
  -- case: a timed claim whose photo never came still says `held` in the table.
  --
  -- The day-derivation trigger is switched off for the planted claim. A machine-filed row on
  -- day D always carries `answered_at` on D+1 — after D's own midnight — so it could never be
  -- timely, and a doer's tap can only ever land on today. A past day that was claimed inside
  -- its own window is another thing only the passage of time produces.
  -- -------------------------------------------------------------------------------
  v_old_day := v_today - 4;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_g, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_g_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_g, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_g_untimed;

  update public.commitment set created_at = created_at - interval '90 days' where owner_id = v_g;


  alter table public.declaration disable trigger declaration_derive_day;
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                  answered_at, for_day)
  values (v_g, v_g_timed, gen_random_uuid(), 'held',
          ((v_old_day || ' 10:14')::timestamp at time zone 'Asia/Ho_Chi_Minh'), v_old_day);
  alter table public.declaration enable trigger declaration_derive_day;

  perform public.settle_day(v_old_day, true);

  select id, verdict into v_settlement, v_verdict
    from public.settlement
   where subject = v_g and period = v_old_day and kind = 'day' and supersedes is null;

  if v_verdict is distinct from 'expired' then
    raise exception using message = format(
      'A day one commitment never answered settled as `%s`, expected `expired`.',
      coalesce(v_verdict::text, 'nothing at all'));
  end if;

  -- The late answer, given in time — before its own deadline at the morning hour on D+3.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_g, v_g_untimed, gen_random_uuid(), 'held',
          ((v_old_day + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  perform public.supersede_expiries();

  select verdict, missed_count into v_verdict, v_count
    from public.settlement
   where subject = v_g and period = v_old_day and kind = 'day' and supersedes = v_settlement;

  if v_verdict is distinct from 'failed' or v_count <> 1 then
    raise exception using message = format(
      'The correction reads `%s` with missed_count %s, expected `failed` and 1. It read the '
      'timed claim as the table stores it (`held`) rather than as it is worth.',
      coalesce(v_verdict::text, 'no correction at all'), v_count);
  end if;

  select sc.outcome into v_outcome
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
   where s.subject = v_g and s.period = v_old_day and s.supersedes = v_settlement
     and sc.commitment_id = v_g_timed;

  if v_outcome is distinct from 'missed' then
    raise exception using message = format(
      'The corrected day froze the unproved claim as `%s`, expected `missed`.', v_outcome);
  end if;

  raise notice using message =
    'Step 10 ok: a corrected day still costs what the unproved claim cost.';

  -- -------------------------------------------------------------------------------
  -- 11. AD-5 — the pass is safe to run again.
  --
  -- Step 2's day has been settled once and walked over three more times by the calls in
  -- steps 5, 6 and 10. It must still hold exactly one settlement and exactly one penalty.
  -- -------------------------------------------------------------------------------
  perform public.settle_day(v_yesterday, true);

  select count(*) into v_count
    from public.settlement where subject = v_a and period = v_yesterday and kind = 'day';

  if v_count <> 1 then
    raise exception using message = format(
      'A settled day was judged again: %s settlement rows for one day.', v_count);
  end if;

  select count(*) into v_count
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_a and s.period = v_yesterday;

  if v_count <> 1 then
    raise exception using message = format(
      'A settled day cost again: %s penalties for one day.', v_count);
  end if;

  raise notice using message = 'Step 11 ok: re-running the pass changes nothing.';

  -- -------------------------------------------------------------------------------
  -- 12. A time added today does not re-judge a day already answered.
  --
  -- The defect the Epic 4 retrospective fixed for `carries_penalty`, one column away. Before
  -- `due_time_as_of()` this exact sequence turned a `held` day into `slipped`, settled it
  -- `failed`, charged for it and broke the chain — for a day answered correctly under the rule
  -- that was actually in force.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_h, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_h_edited;

  update public.commitment set created_at = created_at - interval '90 days' where owner_id = v_h;


  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_h, v_h_edited, gen_random_uuid(), 'held',
          ((v_yesterday + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  update public.commitment
     set due_time = time '10:00', late_window_minutes = 30
   where id = v_h_edited;

  select o.answer into v_answer
    from public.commitments_owing(v_h, v_yesterday) o
   where o.commitment_id = v_h_edited;

  if v_answer is distinct from 'held' then
    raise exception using message = format(
      'A day answered `held` before the commitment carried any time reads `%s` once a time is '
      'added. A settings edit today must not move money for a day already answered.', v_answer);
  end if;

  perform public.settle_day(v_yesterday, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_h and period = v_yesterday and kind = 'day' and supersedes is null;

  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'The edited commitment''s already-answered day settled as `%s`, expected `clean`.',
      coalesce(v_verdict::text, 'nothing at all'));
  end if;

  -- And the day the time was actually changed on is judged untimed too: nothing governed the
  -- whole of it. Today is that day, and today must still be waiting on the morning question
  -- rather than on a photo.
  select o.due_time into v_due_read
    from public.commitments_owing(v_h, v_today) o
   where o.commitment_id = v_h_edited;

  if v_due_read is not null then
    raise exception using message = format(
      'The day the time was switched on reads a due_time of %s. A window that appeared at '
      'midday governed neither the hour that had already passed nor a whole day.', v_due_read);
  end if;

  -- From tomorrow it governs, which is the other half of the same rule.
  select o.due_time into v_due_read
    from public.commitments_owing(v_h, v_today + 1) o
   where o.commitment_id = v_h_edited;

  if v_due_read is distinct from time '10:00' then
    raise exception using message = format(
      'The first full day after the edit reads `%s`, expected 10:00.', v_due_read);
  end if;

  raise notice using message =
    'Step 12 ok: a time governs the days it governed, and not one day more.';

  -- -------------------------------------------------------------------------------
  -- 13. A timed Weekly Quota owes nothing on a day nobody claimed.
  --
  -- Not doing it on a Tuesday is the shape of the commitment, not a silence. v_i owns exactly
  -- one, so if it were still owed the day would settle `expired` and cost a penalty.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day,
                                 due_time, late_window_minutes)
  values (v_i, gen_random_uuid(), 'Call home', 'do', 'weekly_quota', true, 3, 1,
          time '10:00', 30)
  returning id into v_i_quota;

  -- Aged, or this step would pass on the created_at guard rather than on the rule it is about.
  update public.commitment set created_at = created_at - interval '90 days' where owner_id = v_i;


  select count(*) into v_count from public.commitments_owing(v_i, v_yesterday) o;

  if v_count <> 0 then
    raise exception using message = format(
      'An unclaimed timed Weekly Quota day is owed %s answer(s). It is judged at week close, '
      'and every unclaimed day left here settles the whole day expired.', v_count);
  end if;

  perform public.settle_day(v_yesterday, true);

  select count(*) into v_count
    from public.settlement where subject = v_i and period = v_yesterday and kind = 'day';

  if v_count <> 0 then
    raise exception using message =
      'A day whose only commitment is an unclaimed timed Weekly Quota settled anyway.';
  end if;

  raise notice using message =
    'Step 13 ok: a timed Weekly Quota says nothing about a day it was not claimed on.';

  -- -------------------------------------------------------------------------------
  -- 14. Nothing is judged for a day it did not exist on.
  --
  -- v_j's commitment is created now, so every day settle_due_days() sweeps predates it. With a
  -- midnight deadline and no guard, all five would fail on this pass.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_j, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_j_new;

  select count(*) into v_count from public.commitments_owing(v_j, v_yesterday) o;

  if v_count <> 0 then
    raise exception using message = format(
      'A commitment created today is owed %s answer(s) for yesterday.', v_count);
  end if;

  perform public.settle_day(v_yesterday, true);
  perform public.settle_day(v_silent_day, true);

  select count(*) into v_count from public.settlement where subject = v_j;

  if v_count <> 0 then
    raise exception using message = format(
      'A commitment created today was judged for %s day(s) it was not alive for.', v_count);
  end if;

  raise notice using message = 'Step 14 ok: a day before the commitment existed is not judged.';

  -- -------------------------------------------------------------------------------
  -- 15. An answer given after its own day ended cannot correct an expired day.
  --
  -- The half of `supersede_expiries()`'s change that step 10 cannot see: both of its claims are
  -- timely under the old account-wide deadline and under the new per-row one. This one is
  -- timely under the old and late under the new, which is the only input that tells them apart.
  -- Planted the same way step 10's is, and for the same reason.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_k, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_k_timed;

  update public.commitment set created_at = created_at - interval '90 days' where owner_id = v_k;


  perform public.settle_day(v_old_day, true);

  select id into v_settlement
    from public.settlement
   where subject = v_k and period = v_old_day and kind = 'day' and supersedes is null;

  if v_settlement is null then
    raise exception using message =
      'The unclaimed timed day did not settle, so there is no expiry to try to correct.';
  end if;

  -- Answered at 10:14 the *following* morning: inside the account-wide D+3 window, and hours
  -- after its own midnight.
  alter table public.declaration disable trigger declaration_derive_day;
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                  answered_at, for_day)
  values (v_k, v_k_timed, gen_random_uuid(), 'held',
          ((v_old_day + 1)::timestamp + interval '10 hours 14 minutes')
            at time zone 'Asia/Ho_Chi_Minh', v_old_day);
  alter table public.declaration enable trigger declaration_derive_day;

  perform public.supersede_expiries();

  select count(*) into v_count
    from public.settlement where subject = v_k and period = v_old_day and supersedes = v_settlement;

  if v_count <> 0 then
    raise exception using message =
      'An expired timed day was corrected by an answer given after its own midnight. Its '
      'question died at midnight and no later answer can reopen it.';
  end if;

  raise notice using message =
    'Step 15 ok: each answer is measured against its own deadline, not the account''s.';

  -- -------------------------------------------------------------------------------
  -- 16. A Grace Day still forgives a day a forgotten photo failed.
  --
  -- The spec calls it the only remedy for a missed photo, and `apply_grace_days()` reads
  -- `commitments_owing()` to freeze every commitment of the forgiven day as held. It is on the
  -- list of consumers this story claims it did not have to touch; this is that claim, checked.
  -- v_a's yesterday is the day step 2 failed for a missing photo.
  -- -------------------------------------------------------------------------------
  insert into public.grace_day (owner_id, for_day) values (v_a, v_yesterday);

  perform public.apply_grace_days();

  select verdict into v_verdict
    from public.settlement_current s
   where s.subject = v_a and s.period = v_yesterday and s.kind = 'day';

  if v_verdict is distinct from 'clean' then
    raise exception using message = format(
      'A Grace Day left the failed day reading `%s`, expected `clean`. It is the only remedy '
      'a forgotten photo has.', coalesce(v_verdict::text, 'nothing at all'));
  end if;

  select sc.outcome into v_outcome
    from public.settlement_commitment_current sc
   where sc.subject = v_a and sc.period = v_yesterday and sc.commitment_id = v_a_timed;

  if v_outcome is distinct from 'held' then
    raise exception using message = format(
      'The forgiven commitment reads `%s`, expected `held` — a Grace Day forgives the day '
      'whole, chain included.', v_outcome);
  end if;

  raise notice using message =
    'Step 16 ok: a Grace Day still undoes a day a missing photo failed.';

  raise notice using message = 'All 16 steps passed.';
end;
$$;

rollback;
