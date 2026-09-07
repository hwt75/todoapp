-- Every surface asks the day the same question.
--
-- A regression introduced by `20260907100000` (Epic 6 retrospective item 38) and live on the
-- project for part of 2026-09-07. That migration moved `declaration_derive_day()` onto
-- `due_time_as_of()` so a queued claim keeps the meaning it had. On the day a due time is switched
-- on, that door reports the day untimed, so the derivation now *refuses* a same-day claim and tells
-- the author to answer in the next morning's question instead.
--
-- Three surfaces that decide **whether to ask** were left reading the live `commitment.due_time`,
-- so none of them asked: the morning gate (`isAskedNextMorning`), the gate-reminder pass
-- (`enqueue_gate_reminders`), and Today's claim block (`timed_claim_today`). The author had no
-- route to answer that day at all, and settlement counted it as silence -- `expired`, a penalty
-- minted, the chain broken, for a day he was never asked about and could not claim.
--
-- The invariant that made the live read correct was written down twice --
-- `20260829090000_midnight_decides_the_day.sql:862-864` and the `timed_claim_today` comment, both
-- saying "declaration_derive_day() reads the live value too" -- and item 38 falsified it without
-- either being opened. This file is the test that would have caught that.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/every-surface-asks-the-day-the-same-question.sql
--
-- Its own file rather than another step appended to `6-4-midnight-decides-the-day.sql`, which is
-- already 1,024 lines in a single scope holding 47 shared variables. One transaction, rolled back.

begin;

do $$
declare
  -- One account per direction, so neither can mask the other's count.
  v_switched_on   uuid := gen_random_uuid();  -- a time appeared part-way through yesterday
  v_today_edit    uuid := gen_random_uuid();  -- a time appeared part-way through today
  v_governed      uuid := gen_random_uuid();  -- timed all along; the control that must not move

  v_c_switched    uuid;
  v_c_today       uuid;
  v_c_governed    uuid;

  v_today         date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_yesterday     date;
  v_local_hour    integer;

  v_body          text;
  v_due           time;
  v_present       boolean;
  v_case          text;
begin
  v_yesterday := v_today - 1;

  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account. Run against a local stack or a preview branch.';
  end if;

  foreach v_case in array array['switched', 'today', 'governed']
  loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (case v_case
              when 'switched' then v_switched_on
              when 'today' then v_today_edit
              else v_governed
            end,
            '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'asks-the-same-question-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  -- -------------------------------------------------------------------------------
  -- Fixture: two commitments that were untimed and had a time switched on part-way through
  -- a day, and one that carried its time from the start.
  --
  -- Created untimed on purpose. `due_time_as_of()` excepts a commitment's own creation entry,
  -- so a commitment born with a time governs its first day -- that is a different case, and it
  -- is the control below.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_switched_on, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c_switched;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_today_edit, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c_today;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_governed, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '20:00', 30)
  returning id into v_c_governed;

  -- Old enough to be owed an answer for the days below (20260824090000).
  update public.commitment set created_at = created_at - interval '90 days'
   where owner_id in (v_switched_on, v_today_edit, v_governed);

  update public.commitment_due_time_change
     set changed_at = ((v_today - 90)::timestamp + interval '8 hours')
                        at time zone 'Asia/Ho_Chi_Minh'
   where commitment_id in (v_c_switched, v_c_today, v_c_governed);

  -- The edit itself. The log stamps `clock_timestamp()`, so each is back-dated to the day it is
  -- meant to have happened on.
  update public.commitment
     set due_time = time '20:00', late_window_minutes = 30
   where id = v_c_switched;

  update public.commitment_due_time_change
     set changed_at = ((v_yesterday)::timestamp + interval '12 hours')
                        at time zone 'Asia/Ho_Chi_Minh'
   where commitment_id = v_c_switched and due_time is not null;

  update public.commitment
     set due_time = time '20:00', late_window_minutes = 30
   where id = v_c_today;

  update public.commitment_due_time_change
     set changed_at = ((v_today)::timestamp + interval '9 hours')
                        at time zone 'Asia/Ho_Chi_Minh'
   where commitment_id = v_c_today and due_time is not null;

  -- -------------------------------------------------------------------------------
  -- 1. The premise: the judge already calls these days untimed.
  --
  -- Asserted first so a failure below cannot be misread as the door having changed.
  -- -------------------------------------------------------------------------------
  v_due := public.due_time_as_of(v_c_switched, v_yesterday);
  if v_due is not null then
    raise exception using message = format(
      'due_time_as_of() reports %s for the day the time was switched on. The rest of this file '
      'tests what follows from that day being untimed; if this changed, start there.', v_due);
  end if;

  v_due := public.due_time_as_of(v_c_switched, v_today);
  if v_due is distinct from time '20:00' then
    raise exception using message = format(
      'The day *after* the switch reports %s, expected 20:00. A time switched on yesterday '
      'governs today.', coalesce(v_due::text, 'nothing at all'));
  end if;

  raise notice using message =
    'Step 1 ok: the day a time was switched on is untimed, and the day after it is governed.';

  -- -------------------------------------------------------------------------------
  -- 2. The morning question asks about it.
  --
  -- The defect. `declaration_derive_day()` refuses a same-day claim for this day and names the
  -- morning question as the way to answer it; if the morning question also skips it, the day is
  -- unanswerable and settles as silence with a penalty.
  -- -------------------------------------------------------------------------------
  v_local_hour := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh')::integer;
  update public.profile set morning_hour = v_local_hour where id = v_switched_on;

  -- Answer the day before, so no Silence episode opens and suppresses the routine push.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_switched_on, v_c_switched, gen_random_uuid(), 'held',
          ((v_yesterday)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  perform public.enqueue_gate_reminders();

  select payload ->> 'body' into v_body
    from public.outbox
   where owner_id = v_switched_on
     and dedupe_key like 'gate-' || v_switched_on::text || '-' || v_yesterday::text || '%';

  if v_body is null then
    raise exception using message =
      'No morning question was raised for a day no time governed. The claim path refuses that '
      'day and points at this question; with both closed the author cannot answer at all, and '
      'settlement charges him for the silence.';
  end if;

  if v_body not like '%1 commitment is unanswered%' then
    raise exception using message = format(
      'The morning question says "%s". It must count the commitment whose day no time governed '
      '-- that day is the morning question''s to ask about, which is exactly what the claim '
      'refusal tells the author.', v_body);
  end if;

  raise notice using message =
    'Step 2 ok: a day whose time was switched on part-way through is asked about the next morning.';

  -- -------------------------------------------------------------------------------
  -- 3. Today offers no claim on the day of the edit.
  --
  -- The other half of the same lie. The server refuses every tap on this day; rendering the
  -- control anyway spends the author's attention on a button that cannot work.
  -- -------------------------------------------------------------------------------
  select exists (
    select 1 from public.timed_claim_today t where t.commitment_id = v_c_today
  ) into v_present;

  if v_present then
    raise exception using message =
      'timed_claim_today still carries the commitment whose time was switched on today. Today '
      'renders a Claim from this view, and declaration_derive_day() refuses every tap on this '
      'day -- the control can only fail.';
  end if;

  raise notice using message =
    'Step 3 ok: the day a time was switched on offers no claim control.';

  -- -------------------------------------------------------------------------------
  -- 4. The control: a commitment governed all along is untouched in both directions.
  -- -------------------------------------------------------------------------------
  select exists (
    select 1 from public.timed_claim_today t where t.commitment_id = v_c_governed
  ) into v_present;

  if not v_present then
    raise exception using message =
      'A commitment governed by its time all day vanished from timed_claim_today. The fix must '
      'narrow the view to days no time governed, not to nothing.';
  end if;

  update public.profile set morning_hour = v_local_hour where id = v_governed;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_governed, v_c_governed, gen_random_uuid(), 'held',
          ((v_yesterday)::timestamp + interval '20 hours' + interval '5 minutes')
            at time zone 'Asia/Ho_Chi_Minh');

  perform public.enqueue_gate_reminders();

  select payload ->> 'body' into v_body
    from public.outbox
   where owner_id = v_governed
     and dedupe_key like 'gate-' || v_governed::text || '-' || v_yesterday::text || '%';

  if v_body is not null then
    raise exception using message = format(
      'The morning question was raised for a commitment its time governed all day: "%s". That '
      'day was decided at its own midnight, and asking again offers a second, softer answer.',
      v_body);
  end if;

  raise notice using message =
    'Step 4 ok: a commitment governed all day is still claimed on its own day and never asked '
    'about in the morning.';

  raise notice using message =
    'PASS. Every surface that decides whether to ask about a day now reads the same door the '
    'judge reads: a day no time governed is the morning question''s, a day a time governed is '
    'claimed on its own day, and neither surface disagrees with the other.';
end $$;

rollback;
